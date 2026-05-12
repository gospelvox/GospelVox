// Read-only access to past sessions, shared between user and priest
// history pages. Both halves filter the same `sessions` collection by
// the appropriate uid field so we never need two parallel models.
//
// We sort client-side instead of asking Firestore for an ordered
// query because pairing `where userId/priestId` with
// `orderBy createdAt` requires a composite index that doesn't exist
// in a fresh Firebase project — without the index the whole stream
// throws FAILED_PRECONDITION on first fire and history would render
// blank. Sessions are bounded per-user, so the cost of sorting in
// Dart is negligible.

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:gospel_vox/core/utils/date_format.dart' as df;
import 'package:gospel_vox/features/shared/data/session_model.dart';

class SessionHistoryRepository {
  // All sessions where the signed-in user was the listener side.
  // Newest first.
  Future<List<SessionModel>> getUserSessions(String userId) async {
    final snap = await FirebaseFirestore.instance
        .collection('sessions')
        .where('userId', isEqualTo: userId)
        .get()
        .timeout(const Duration(seconds: 15));

    final sessions = snap.docs
        .map((doc) => SessionModel.fromFirestore(doc.id, doc.data()))
        .toList();

    // Client-side sort to avoid the composite-index requirement
    // described in the file header. Docs whose server timestamp
    // hasn't filled in yet (a brief window after creation) are
    // pushed to the bottom by falling back to year 2000 — they'll
    // float up on the next refresh once Firestore stamps them.
    sessions.sort((a, b) {
      final aTime = a.createdAt ?? DateTime(2000);
      final bTime = b.createdAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return sessions;
  }

  // All sessions where the signed-in user was the speaker side.
  Future<List<SessionModel>> getPriestSessions(String priestId) async {
    final snap = await FirebaseFirestore.instance
        .collection('sessions')
        .where('priestId', isEqualTo: priestId)
        .get()
        .timeout(const Duration(seconds: 15));

    final sessions = snap.docs
        .map((doc) => SessionModel.fromFirestore(doc.id, doc.data()))
        .toList();

    sessions.sort((a, b) {
      final aTime = a.createdAt ?? DateTime(2000);
      final bTime = b.createdAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return sessions;
  }

  // One-time fetch of the entire transcript. We deliberately do NOT
  // open a stream here — a finished session can't gain new messages,
  // so paying for a snapshot listener would just waste sockets.
  Future<List<ChatMessage>> getSessionMessages(String sessionId) async {
    final snap = await FirebaseFirestore.instance
        .collection('sessions/$sessionId/messages')
        .orderBy('createdAt', descending: false)
        .get()
        .timeout(const Duration(seconds: 10));

    return snap.docs
        .map((doc) => ChatMessage.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  // Aggregates this user's completed sessions into one row per priest
  // for the WhatsApp-style Sessions tab. Loads each priest doc in
  // parallel via Future.wait so the page doesn't pay N sequential
  // round-trips when the user has talked to many priests.
  //
  // Denomination comes from the session's denormalized
  // `priestDenomination` (snapshot at session creation), which means
  // the row reflects the relationship at that point in time even if
  // the priest later changed denomination on their profile. Online /
  // busy state is read live from priests/{uid} because that's what
  // the user actually wants to know — "can I talk to them right now".
  Future<List<PriestSessionGroup>> getUserPriestGroups(String userId) async {
    final snap = await FirebaseFirestore.instance
        .collection('sessions')
        .where('userId', isEqualTo: userId)
        .where('status', isEqualTo: 'completed')
        .get()
        .timeout(const Duration(seconds: 15));

    final sessions = snap.docs
        .map((doc) => SessionModel.fromFirestore(doc.id, doc.data()))
        .toList();

    if (sessions.isEmpty) return const [];

    // Bucket sessions by priestId.
    final Map<String, List<SessionModel>> grouped = {};
    for (final s in sessions) {
      grouped.putIfAbsent(s.priestId, () => []).add(s);
    }

    // Fan out priest-doc reads in parallel. With 20 unique priests
    // this drops total wait from ~3-5s sequential to ~300-500ms. We
    // collapse each result down to a nullable data map right here so
    // we never have to hold sealed Firestore snapshot types past this
    // line — a failed read just becomes null and the row defaults to
    // offline status.
    final db = FirebaseFirestore.instance;
    final priestIds = grouped.keys.toList();
    final priestData = await Future.wait(
      priestIds.map((id) async {
        try {
          final snap = await db
              .doc('priests/$id')
              .get()
              .timeout(const Duration(seconds: 5));
          return snap.exists ? snap.data() : null;
        } catch (_) {
          return null;
        }
      }),
    );

    final groups = <PriestSessionGroup>[];
    for (var i = 0; i < priestIds.length; i++) {
      final priestId = priestIds[i];
      final priestSessions = grouped[priestId]!
        ..sort((a, b) {
          final aTime = a.endedAt ?? a.createdAt ?? DateTime(2000);
          final bTime = b.endedAt ?? b.createdAt ?? DateTime(2000);
          return bTime.compareTo(aTime);
        });

      final lastSession = priestSessions.first;

      final data = priestData[i] ?? const <String, dynamic>{};
      final isOnline = data['isOnline'] as bool? ?? false;
      final isBusy = data['isBusy'] as bool? ?? false;

      final rated = priestSessions
          .where((s) => s.userRating != null && s.userRating! > 0)
          .toList();
      final avgRating = rated.isEmpty
          ? null
          : rated.fold<double>(0, (acc, s) => acc + s.userRating!) /
              rated.length;

      groups.add(PriestSessionGroup(
        priestId: priestId,
        priestName: lastSession.priestName,
        priestPhotoUrl: lastSession.priestPhotoUrl,
        priestDenomination: lastSession.priestDenomination,
        isOnline: isOnline,
        isBusy: isBusy,
        totalSessions: priestSessions.length,
        chatSessions:
            priestSessions.where((s) => s.type == 'chat').length,
        voiceSessions:
            priestSessions.where((s) => s.type == 'voice').length,
        lastSessionAt: lastSession.endedAt ?? lastSession.createdAt,
        lastSessionDuration: lastSession.durationMinutes,
        lastSessionType: lastSession.type,
        averageRating: avgRating,
      ));
    }

    // Online (non-busy) priests float to the top — they're the ones
    // the user can act on right now. Within each bucket, most-recent
    // session first.
    groups.sort((a, b) {
      final aAvailable = a.isOnline && !a.isBusy;
      final bAvailable = b.isOnline && !b.isBusy;
      if (aAvailable != bAvailable) return aAvailable ? -1 : 1;
      final aTime = a.lastSessionAt ?? DateTime(2000);
      final bTime = b.lastSessionAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return groups;
  }

  // Same as getUserPriestGroups, but ALSO includes priests who have
  // only ever sent the user a priest_message (no completed session
  // yet). Without this layer, a priest who replied to a missed
  // request via the quick-reply flow lands the user a notification
  // but leaves the user's Sessions tab empty for that priest —
  // making the conversation un-findable in-app once the FCM is
  // dismissed. Wraps (not replaces) getUserPriestGroups so the
  // session-only path stays available for any caller that still
  // needs it.
  Future<List<PriestSessionGroup>> getUserPriestThreads(String userId) async {
    final sessionGroups = await getUserPriestGroups(userId);
    final knownIds = sessionGroups.map((g) => g.priestId).toSet();

    final db = FirebaseFirestore.instance;
    final messagesSnap = await db
        .collection('notifications')
        .where('userId', isEqualTo: userId)
        .where('type', whereIn: ['priest_message', 'follow_up'])
        .get()
        .timeout(const Duration(seconds: 10));

    // Bucket message-only priests with their freshest metadata.
    // Skip delivered=false (muted at send time) — the chat-history
    // view filters those out too, so showing the row would be a
    // dead-end click.
    final messageOnly = <String, _MessageOnlyMeta>{};
    for (final doc in messagesSnap.docs) {
      final data = doc.data();
      if (data['delivered'] == false) continue;
      final priestId = data['priestId'] as String? ?? '';
      if (priestId.isEmpty || knownIds.contains(priestId)) continue;

      final createdAt = data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null;
      final priestName = data['priestName'] as String? ?? '';
      final priestPhotoUrl = data['priestPhotoUrl'] as String? ?? '';

      final existing = messageOnly[priestId];
      final isFresher = existing == null ||
          (createdAt != null &&
              (existing.lastAt == null ||
                  createdAt.isAfter(existing.lastAt!)));
      if (isFresher) {
        messageOnly[priestId] = _MessageOnlyMeta(
          priestName: priestName,
          priestPhotoUrl: priestPhotoUrl,
          lastAt: createdAt,
        );
      }
    }

    if (messageOnly.isEmpty) return sessionGroups;

    // Live status fan-out for the new priests. Same parallel pattern
    // as getUserPriestGroups so a long subscriber list doesn't pay
    // sequential round-trip cost.
    final newIds = messageOnly.keys.toList();
    final newPriestData = await Future.wait(
      newIds.map((id) async {
        try {
          final snap = await db
              .doc('priests/$id')
              .get()
              .timeout(const Duration(seconds: 5));
          return snap.exists ? snap.data() : null;
        } catch (_) {
          return null;
        }
      }),
    );

    // Synthesize one PriestSessionGroup per message-only priest.
    // chatSessions=1 (vs the literal 0) is what makes them survive
    // the Sessions tab's `chatSessions > 0` Chats-sub-tab filter.
    // The renderer never displays the literal session count when
    // totalSessions is 0, so this fudge stays invisible.
    final synthetic = <PriestSessionGroup>[];
    for (var i = 0; i < newIds.length; i++) {
      final priestId = newIds[i];
      final meta = messageOnly[priestId]!;
      final data = newPriestData[i] ?? const <String, dynamic>{};

      synthetic.add(PriestSessionGroup(
        priestId: priestId,
        priestName: meta.priestName,
        priestPhotoUrl: meta.priestPhotoUrl,
        priestDenomination: data['denomination'] as String? ?? '',
        isOnline: data['isOnline'] as bool? ?? false,
        isBusy: data['isBusy'] as bool? ?? false,
        totalSessions: 0,
        chatSessions: 1,
        voiceSessions: 0,
        lastSessionAt: meta.lastAt,
        lastSessionDuration: 0,
        lastSessionType: 'chat',
        averageRating: null,
      ));
    }

    // Merge + re-sort using the same rules getUserPriestGroups uses
    // (available first, then by recency desc) so the combined list
    // stays consistent with the user's expectation of priority.
    final all = <PriestSessionGroup>[...sessionGroups, ...synthetic];
    all.sort((a, b) {
      final aAvailable = a.isOnline && !a.isBusy;
      final bAvailable = b.isOnline && !b.isBusy;
      if (aAvailable != bAvailable) return aAvailable ? -1 : 1;
      final aTime = a.lastSessionAt ?? DateTime(2000);
      final bTime = b.lastSessionAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return all;
  }

  // Mirror of getUserPriestGroups for the priest-side "My Users"
  // tab. Aggregates the priest's completed AND expired sessions
  // into one row per user. Same parallel-fetch + sort-by-recency
  // contract; the shape differs because a priest sees the USER
  // (not themselves) as the counterparty.
  //
  // Why include 'expired' here:
  //   When a user tries to reach a priest who is offline / busy
  //   and the request times out (status='expired'), the priest
  //   should still see that user in My Users so they can message
  //   them back when they return. UserSessionGroup carries
  //   `hasCompletedSession` so the renderer can distinguish
  //   "actual past customer" from "tried to reach you" rows.
  //
  // 'declined' is excluded — the priest chose to decline that
  // user, surfacing them prominently would be confusing.
  // 'cancelled' is excluded — the user actively cancelled, so
  // they're not chasing the priest, they changed their mind.
  //
  // Free-message latest-preview is computed in the cubit, not here,
  // so this method stays a single Firestore read concerned only
  // with the relationship existence + last session metadata.
  Future<List<UserSessionGroup>> getPriestUserGroups(String priestId) async {
    final snap = await FirebaseFirestore.instance
        .collection('sessions')
        .where('priestId', isEqualTo: priestId)
        .where('status', whereIn: ['completed', 'expired'])
        .get()
        .timeout(const Duration(seconds: 15));

    final sessions = snap.docs
        .map((doc) => SessionModel.fromFirestore(doc.id, doc.data()))
        .toList();

    if (sessions.isEmpty) return const [];

    // Bucket sessions by userId — one row per user.
    final Map<String, List<SessionModel>> grouped = {};
    for (final s in sessions) {
      grouped.putIfAbsent(s.userId, () => []).add(s);
    }

    final groups = <UserSessionGroup>[];
    for (final entry in grouped.entries) {
      final userId = entry.key;
      final userSessions = entry.value
        ..sort((a, b) {
          final aTime = a.endedAt ?? a.createdAt ?? DateTime(2000);
          final bTime = b.endedAt ?? b.createdAt ?? DateTime(2000);
          return bTime.compareTo(aTime);
        });

      final lastSession = userSessions.first;

      // Counts: completed-only sessions vs. expired (missed)
      // requests. The renderer reads both to decide which subtitle
      // to show ("3 sessions" vs "Tried to reach you").
      final completedCount =
          userSessions.where((s) => s.status == 'completed').length;
      final expiredCount =
          userSessions.where((s) => s.status == 'expired').length;

      // Display fields — name + photo prefer values from any
      // completed session over an expired one because expired
      // requests can have stale denormalized values if the user
      // updated their name between requests.
      final preferred = userSessions
              .where((s) =>
                  s.status == 'completed' && s.userName.isNotEmpty)
              .firstOrNull ??
          lastSession;

      groups.add(UserSessionGroup(
        userId: userId,
        userName: preferred.userName,
        userPhotoUrl: preferred.userPhotoUrl,
        totalSessions: completedCount,
        chatSessions: userSessions
            .where((s) => s.status == 'completed' && s.type == 'chat')
            .length,
        voiceSessions: userSessions
            .where((s) => s.status == 'completed' && s.type == 'voice')
            .length,
        lastSessionAt: lastSession.endedAt ?? lastSession.createdAt,
        lastSessionDuration: lastSession.durationMinutes,
        lastSessionType: lastSession.type,
        hasCompletedSession: completedCount > 0,
        missedRequests: expiredCount,
      ));
    }

    // Most-recent first. Unlike the user-side which floats online
    // priests, there's no "user is online" concept the priest
    // would care about — the only sort axis that matters is recency.
    groups.sort((a, b) {
      final aTime = a.lastSessionAt ?? DateTime(2000);
      final bTime = b.lastSessionAt ?? DateTime(2000);
      return bTime.compareTo(aTime);
    });

    return groups;
  }
}

// Priest-side mirror of PriestSessionGroup. Different name + fields
// because the priest sees a USER as the counterparty (no online/busy
// status, no denomination).
//
// `totalSessions` counts COMPLETED sessions only — it's the figure
// the priest reads as "how many actual conversations we've had".
// `missedRequests` is the separate count of expired requests where
// the user tried to reach them but the priest didn't respond.
// Combined with `hasCompletedSession`, the row renderer decides
// whether to show "3 sessions" (real customer) or "Tried to reach
// you" (no completed sessions yet, only missed requests).
class UserSessionGroup {
  final String userId;
  final String userName;
  final String userPhotoUrl;
  final int totalSessions;
  final int chatSessions;
  final int voiceSessions;
  final DateTime? lastSessionAt;
  final int lastSessionDuration;
  final String lastSessionType;
  // True when at least one session with this user has reached
  // status='completed'. Drives the row's subtitle copy.
  final bool hasCompletedSession;
  // Count of status='expired' sessions for this user — i.e. how
  // many times they tried to reach this priest and the request
  // timed out. Drives a small amber indicator in the row.
  final int missedRequests;

  const UserSessionGroup({
    required this.userId,
    required this.userName,
    required this.userPhotoUrl,
    required this.totalSessions,
    required this.chatSessions,
    required this.voiceSessions,
    required this.lastSessionAt,
    required this.lastSessionDuration,
    required this.lastSessionType,
    this.hasCompletedSession = true,
    this.missedRequests = 0,
  });

  String get lastSessionText => df.formatTimeAgo(lastSessionAt);
}

// Local grouping shape for the Sessions tab. Not a Firestore model —
// built up from sessions + priest-doc reads inside the repository.
class PriestSessionGroup {
  final String priestId;
  final String priestName;
  final String priestPhotoUrl;
  final String priestDenomination;
  final bool isOnline;
  final bool isBusy;
  final int totalSessions;
  final int chatSessions;
  final int voiceSessions;
  final DateTime? lastSessionAt;
  final int lastSessionDuration;
  final String lastSessionType;
  final double? averageRating;

  const PriestSessionGroup({
    required this.priestId,
    required this.priestName,
    required this.priestPhotoUrl,
    required this.priestDenomination,
    required this.isOnline,
    required this.isBusy,
    required this.totalSessions,
    required this.chatSessions,
    required this.voiceSessions,
    required this.lastSessionAt,
    required this.lastSessionDuration,
    required this.lastSessionType,
    required this.averageRating,
  });

  // "Available" = online and not in another session. Drives the
  // green dot on the avatar AND the row's sort priority.
  bool get isAvailable => isOnline && !isBusy;

  String get lastSessionText => df.formatTimeAgo(lastSessionAt);
}

// Internal helper for getUserPriestThreads — captures just enough
// of a priest_message notification (display name, photo, latest
// timestamp) to synthesize a PriestSessionGroup row for a priest
// the user has no completed session with.
class _MessageOnlyMeta {
  final String priestName;
  final String priestPhotoUrl;
  final DateTime? lastAt;

  const _MessageOnlyMeta({
    required this.priestName,
    required this.priestPhotoUrl,
    required this.lastAt,
  });
}

