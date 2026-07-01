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
import 'package:flutter/foundation.dart';

import 'package:gospel_vox/core/utils/date_format.dart' as df;
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

// Sealed history-entry type unifying regular sessions (chat / voice)
// and bible sessions in one chronologically-sortable list. The page
// branches on the variant when rendering to avoid shoehorning bible
// fields onto SessionModel and vice-versa.
sealed class HistoryEntry {
  const HistoryEntry();

  // Sort axis: when a bible session was attended (registration paidAt
  // or scheduledAt) vs. when a regular session was created. Older
  // entries sink to the bottom.
  DateTime? get sortAt;

  // Filter axis: 'chat' / 'voice' / 'bible'. Used by the chip-driven
  // local filter in SessionHistoryLoaded.
  String get kind;

  // Row counters for the summary card. Coins for regular sessions,
  // 0 for bible (whose payments are in INR — see priceInr below).
  int get coinsSpent;
  int get coinsEarned;

  // Bible row INR — 0 for regular sessions. Surfaced separately on
  // the summary card so coin amounts and rupee amounts never get
  // averaged or summed across units.
  int get inrSpent;
  int get inrEarned;

  // Rating (1-5) when the user has submitted one. Used by the avg-
  // rating stat regardless of entry kind.
  int? get rating;
}

class RegularSessionEntry extends HistoryEntry {
  final SessionModel session;
  const RegularSessionEntry(this.session);

  @override
  DateTime? get sortAt => session.endedAt ?? session.createdAt;

  @override
  String get kind => session.type;

  @override
  int get coinsSpent =>
      session.status == 'completed' ? session.totalCharged : 0;

  @override
  int get coinsEarned =>
      session.status == 'completed' ? session.priestEarnings : 0;

  @override
  int get inrSpent => 0;

  @override
  int get inrEarned => 0;

  @override
  int? get rating => (session.userRating ?? 0) > 0
      ? session.userRating!.toInt()
      : null;
}

// `registration` is non-null on the user side (their own paid /
// registered subdoc) and null on the priest side (the priest hosts,
// they don't register). `priestRevenueInr` is non-zero only when
// the caller is the priest viewing their own hosted session — it's
// computed against the bible session's price + paid count at load
// time and snapshotted onto this entry so the summary card never
// has to re-query.
class BibleSessionEntry extends HistoryEntry {
  final BibleSessionModel session;
  final BibleRegistration? registration;
  final int priestRevenueInr;
  const BibleSessionEntry({
    required this.session,
    this.registration,
    this.priestRevenueInr = 0,
  });

  // Prefer the date the registration was paid (most relevant to the
  // user's own history); fall back to the session's scheduled time
  // (priest hosting view) and finally createdAt.
  @override
  DateTime? get sortAt {
    final paid = registration?.registeredAt;
    if (paid != null) return paid;
    if (session.completedAt != null) return session.completedAt;
    if (session.scheduledAt != null) return session.scheduledAt;
    return session.createdAt;
  }

  @override
  String get kind => 'bible';

  @override
  int get coinsSpent => 0;

  @override
  int get coinsEarned => 0;

  @override
  int get inrSpent =>
      registration?.isPaid == true ? session.price : 0;

  @override
  int get inrEarned => priestRevenueInr;

  @override
  int? get rating => registration?.rating;
}

// Snapshot of the CF-aggregated rating on priests/{uid} — fetched
// at history-load time so the summary card's "Avg Rating" stat
// reflects the same number the dashboard shows (chat/voice + bible,
// across all reviews ever, not just the ones in the visible window).
class PriestRatingAggregate {
  final double rating;
  final int reviewCount;
  const PriestRatingAggregate({
    required this.rating,
    required this.reviewCount,
  });
  static const empty = PriestRatingAggregate(rating: 0, reviewCount: 0);
}

class SessionHistoryRepository {
  // Every public loader on this class catches its own errors and
  // returns an empty list on failure. The page-level cubit fans out
  // multiple loaders in sequence; without per-loader catches a
  // single broken collection (missing index, transient network
  // blip, a single corrupt doc) would blank the entire history
  // surface for the user. Empty-on-failure means the working half
  // still renders, and a `debugPrint` keeps the actual error
  // visible to anyone running the app with logs attached.

  // Read the priest doc's CF-aggregated rating fields. Empty on
  // failure — same defensive pattern as the loaders, since a single
  // doc-read failure shouldn't take down the history page; the
  // Avg Rating stat just falls through to "—".
  Future<PriestRatingAggregate> getPriestRatingAggregate(
    String priestId,
  ) async {
    try {
      final snap = await FirebaseFirestore.instance
          .doc('priests/$priestId')
          .get()
          .timeout(const Duration(seconds: 8));
      final data = snap.data();
      if (data == null) return PriestRatingAggregate.empty;
      return PriestRatingAggregate(
        rating: (data['rating'] as num?)?.toDouble() ?? 0,
        reviewCount: (data['reviewCount'] as num?)?.toInt() ?? 0,
      );
    } catch (e, st) {
      debugPrint('[SessionHistory] getPriestRatingAggregate failed: $e\n$st');
      return PriestRatingAggregate.empty;
    }
  }

  // ── Bible loaders ─────────────────────────────────────────
  //
  // User side: there's no single index of "bible sessions a user has
  // attended" — registrations live in a subcollection and the rules
  // don't permit a collection-group query for a user reading across
  // all sessions. The wallet_transactions ledger, however, has a
  // type='bible_session' row per successful payment with the
  // sessionId, and the rules already allow a user to read their own
  // wallet_transactions. We use that as the authoritative index of
  // "bible sessions this user paid for" and hydrate each one in
  // parallel.
  Future<List<BibleSessionEntry>> getUserBibleSessions(
    String userId,
  ) async {
    try {
      return await _getUserBibleSessions(userId);
    } catch (e, st) {
      debugPrint('[SessionHistory] getUserBibleSessions failed: $e\n$st');
      return const [];
    }
  }

  Future<List<BibleSessionEntry>> _getUserBibleSessions(
    String userId,
  ) async {
    final db = FirebaseFirestore.instance;
    final ledgerSnap = await db
        .collection('wallet_transactions')
        .where('userId', isEqualTo: userId)
        .where('type', isEqualTo: 'bible_session')
        .get()
        .timeout(const Duration(seconds: 15));

    if (ledgerSnap.docs.isEmpty) return const [];

    // De-dupe — a retry against the same paymentId is server-side
    // idempotent (verifyBibleSessionPayment short-circuits) but a
    // pathological dataset with two ledger rows for one session
    // would otherwise show the entry twice. LinkedHashSet preserves
    // insertion order so the first-paid bible session stays first
    // when sortAt timestamps tie.
    final sessionIds = <String>{};
    for (final doc in ledgerSnap.docs) {
      final id = doc.data()['sessionId'] as String?;
      if (id != null && id.isNotEmpty) sessionIds.add(id);
    }
    if (sessionIds.isEmpty) return const [];

    // Fan-out: hydrate each bible session + the user's own
    // registration subdoc in parallel. A failed read on either
    // side becomes null and the entry is dropped — better than
    // showing a half-loaded card.
    final entries = await Future.wait(sessionIds.map((id) async {
      try {
        final results = await Future.wait([
          db
              .doc('bible_sessions/$id')
              .get()
              .timeout(const Duration(seconds: 8)),
          db
              .doc('bible_sessions/$id/registrations/$userId')
              .get()
              .timeout(const Duration(seconds: 8)),
        ]);
        final sessionDoc = results[0];
        final regDoc = results[1];
        if (!sessionDoc.exists) return null;
        return BibleSessionEntry(
          session: BibleSessionModel.fromFirestore(
            sessionDoc.id,
            sessionDoc.data() ?? const <String, dynamic>{},
          ),
          registration: regDoc.exists
              ? BibleRegistration.fromFirestore(
                  regDoc.id,
                  regDoc.data() ?? const <String, dynamic>{},
                )
              : null,
        );
      } catch (_) {
        return null;
      }
    }));

    // Only completed sessions belong in history. A user that paid
    // but the session is still upcoming / live / cancelled hasn't
    // produced "history" yet — those surfaces live on the bible
    // tab + detail page where the user can still take action.
    // Completed = the session actually happened (priest tapped
    // Mark Completed, OR the auto-complete cron flipped it after
    // its duration elapsed). A bible_session.cancelled doc is a
    // refund/cancellation event, not history.
    return entries
        .whereType<BibleSessionEntry>()
        .where((e) =>
            e.session.isCompleted && e.registration?.isPaid == true)
        .toList();
  }

  // Priest side: a single equality query against bible_sessions
  // returns every session this priest has ever hosted. We filter
  // to status='completed' BEFORE the per-session paid-count read,
  // so we don't waste round-trips on upcoming/live/cancelled
  // sessions that never belong in history.
  //
  // Per-session paid count + revenue are computed inline so the
  // summary card doesn't need a separate aggregation pass.
  Future<List<BibleSessionEntry>> getPriestBibleSessions(
    String priestId,
  ) async {
    try {
      return await _getPriestBibleSessions(priestId);
    } catch (e, st) {
      // Most likely: missing composite index on
      // bible_sessions(priestId, status). Firestore embeds a one-click
      // create-index URL in the error message. Building the index
      // takes a few minutes, after which the next refresh succeeds.
      debugPrint('[SessionHistory] getPriestBibleSessions failed: $e\n$st');
      return const [];
    }
  }

  Future<List<BibleSessionEntry>> _getPriestBibleSessions(
    String priestId,
  ) async {
    final db = FirebaseFirestore.instance;
    final snap = await db
        .collection('bible_sessions')
        .where('priestId', isEqualTo: priestId)
        .where('status', isEqualTo: 'completed')
        .get()
        .timeout(const Duration(seconds: 15));

    if (snap.docs.isEmpty) return const [];

    final sessions = snap.docs
        .map((d) => BibleSessionModel.fromFirestore(d.id, d.data()))
        .toList();

    // Commission split (%) from app_config — so "Earned · Bible" shows
    // the NET the priest actually received (matching the wallet ledger),
    // not the gross ticket price. Falls back to the model default.
    int commissionPercent = BibleSessionModel.defaultCommissionPercent;
    try {
      final cfg = await db
          .doc('app_config/settings')
          .get()
          .timeout(const Duration(seconds: 8));
      final raw = cfg.data()?['bibleCommissionPercent'];
      final pct = (raw as num?)?.toInt();
      if (pct != null && pct >= 0 && pct <= 100) commissionPercent = pct;
    } catch (_) {
      // Keep the default on any read failure.
    }

    // Parallel paid-count reads.
    final paidCounts = await Future.wait(sessions.map((s) async {
      try {
        final regs = await db
            .collection('bible_sessions/${s.id}/registrations')
            .where('status', isEqualTo: 'paid')
            .get()
            .timeout(const Duration(seconds: 8));
        return regs.size;
      } catch (_) {
        return 0;
      }
    }));

    final entries = <BibleSessionEntry>[];
    for (var i = 0; i < sessions.length; i++) {
      entries.add(BibleSessionEntry(
        session: sessions[i],
        priestRevenueInr:
            sessions[i].priestNetEarnings(paidCounts[i], commissionPercent),
      ));
    }
    return entries;
  }

  // All sessions where the signed-in user was the listener side.
  // Newest first.
  Future<List<SessionModel>> getUserSessions(String userId) async {
    try {
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
    } catch (e, st) {
      debugPrint('[SessionHistory] getUserSessions failed: $e\n$st');
      return const [];
    }
  }

  // All sessions where the signed-in user was the speaker side.
  Future<List<SessionModel>> getPriestSessions(String priestId) async {
    try {
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
    } catch (e, st) {
      // One bad doc that fails SessionModel.fromFirestore (e.g. a
      // legacy session with a non-string field where we expect a
      // string) would otherwise blank the entire page for THIS
      // priest while every other priest still loads — that's the
      // most likely cause of "session history works for some priests
      // but not others." Swallow + log so the page renders empty
      // rather than going to the error state.
      debugPrint('[SessionHistory] getPriestSessions failed: $e\n$st');
      return const [];
    }
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

    // Pre-sort each priest's sessions so we can grab the most-recent
    // chat session (if any) for the last-message fetch below.
    for (final priestId in priestIds) {
      grouped[priestId]!.sort((a, b) {
        final aTime = a.endedAt ?? a.createdAt ?? DateTime(2000);
        final bTime = b.endedAt ?? b.createdAt ?? DateTime(2000);
        return bTime.compareTo(aTime);
      });
    }

    // Fan-out: fetch the last message for each priest's most-recent
    // chat session. One small Firestore read per priest (orderBy +
    // limit 1). Returns null for voice-only priests, or on any
    // failure — the renderer falls back to "Last call" / "Last chat".
    final lastMessages = await Future.wait(priestIds.map((priestId) async {
      final chatSessions = grouped[priestId]!
          .where((s) => s.type == 'chat' && s.id.isNotEmpty)
          .toList();
      if (chatSessions.isEmpty) return null;
      final lastChat = chatSessions.first; // already sorted desc above

      try {
        final messagesSnap = await db
            .collection('sessions/${lastChat.id}/messages')
            .orderBy('createdAt', descending: true)
            .limit(1)
            .get()
            .timeout(const Duration(seconds: 5));
        if (messagesSnap.docs.isEmpty) return null;
        final doc = messagesSnap.docs.first;
        final data = doc.data();
        final text = data['text'] as String? ?? '';
        if (text.isEmpty) return null;
        final senderId = data['senderId'] as String? ?? '';
        final createdAt = data['createdAt'] is Timestamp
            ? (data['createdAt'] as Timestamp).toDate()
            : null;
        return (
          text: text,
          fromUser: senderId == userId,
          at: createdAt,
        );
      } catch (_) {
        return null;
      }
    }));

    final groups = <PriestSessionGroup>[];
    for (var i = 0; i < priestIds.length; i++) {
      final priestId = priestIds[i];
      final priestSessions = grouped[priestId]!;

      final lastSession = priestSessions.first;

      final data = priestData[i] ?? const <String, dynamic>{};
      // A deleted priest is forced offline + identity-stripped here so
      // the row renders as a neutral "Unavailable" entry regardless of
      // the name/photo snapshotted into the session at chat time.
      final isDeleted = data['isDeleted'] as bool? ?? false;
      final isOnline = isDeleted ? false : (data['isOnline'] as bool? ?? false);
      final isBusy = isDeleted ? false : (data['isBusy'] as bool? ?? false);

      final rated = priestSessions
          .where((s) => s.userRating != null && s.userRating! > 0)
          .toList();
      final avgRating = rated.isEmpty
          ? null
          : rated.fold<double>(0, (acc, s) => acc + s.userRating!) /
              rated.length;

      final msg = lastMessages[i];

      groups.add(PriestSessionGroup(
        priestId: priestId,
        priestName: isDeleted ? 'Unavailable' : lastSession.priestName,
        priestPhotoUrl: isDeleted ? '' : lastSession.priestPhotoUrl,
        priestDenomination:
            isDeleted ? '' : lastSession.priestDenomination,
        isDeleted: isDeleted,
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
        lastMessageText: msg?.text,
        lastMessageFromUser: msg?.fromUser,
        lastMessageAt: msg?.at,
      ));
    }

    // Online (non-busy) priests float to the top — they're the ones
    // the user can act on right now. Within each bucket, the most-
    // recent ACTIVITY (last session OR last message) wins — that way
    // a priest whose follow-up message arrived yesterday outranks
    // one whose session was three days ago.
    groups.sort((a, b) {
      final aAvailable = a.isOnline && !a.isBusy;
      final bAvailable = b.isOnline && !b.isBusy;
      if (aAvailable != bAvailable) return aAvailable ? -1 : 1;
      final aTime = a.lastActivityAt ?? DateTime(2000);
      final bTime = b.lastActivityAt ?? DateTime(2000);
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
    // Two buckets:
    //   • messageOnly  → priests with NO completed session (need a
    //                    synthetic PriestSessionGroup built below).
    //   • freeMsgEnrich → priests WITH a completed session — we track
    //                    their latest free message so we can override
    //                    the session-message preview when the free
    //                    message is newer. Without this, a priest
    //                    sending a follow-up free message after a
    //                    session would look stale on the history row.
    final messageOnly = <String, _MessageOnlyMeta>{};
    final freeMsgEnrich = <String, ({String text, DateTime? at})>{};

    for (final doc in messagesSnap.docs) {
      final data = doc.data();
      if (data['delivered'] == false) continue;
      final priestId = data['priestId'] as String? ?? '';
      if (priestId.isEmpty) continue;

      final createdAt = data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null;
      final priestName = data['priestName'] as String? ?? '';
      final priestPhotoUrl = data['priestPhotoUrl'] as String? ?? '';
      final messageText = (data['body'] as String? ??
              data['message'] as String? ??
              '')
          .trim();

      if (knownIds.contains(priestId)) {
        // Priest already has a session — track their latest free
        // message for preview-enrichment below.
        if (messageText.isEmpty) continue;
        final existing = freeMsgEnrich[priestId];
        final isFresher = existing == null ||
            (createdAt != null &&
                (existing.at == null ||
                    createdAt.isAfter(existing.at!)));
        if (isFresher) {
          freeMsgEnrich[priestId] = (text: messageText, at: createdAt);
        }
        continue;
      }

      // Priest has NO completed session — needs a synthetic group.
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
          messageText: messageText,
        );
      }
    }

    // Enrich session-based groups whose newest free message is more
    // recent than their session-message preview. The user-side row
    // should always show the genuinely most-recent thing the priest
    // said, regardless of whether it came through a session bubble
    // or a free message.
    final enrichedSessionGroups = freeMsgEnrich.isEmpty
        ? sessionGroups
        : sessionGroups.map((g) {
            final free = freeMsgEnrich[g.priestId];
            if (free == null) return g;
            // Free message must be strictly newer than the current
            // preview's timestamp to take over. If timestamps tie
            // (rare), prefer the session message so the bubble we
            // already have stays consistent.
            if (g.lastMessageAt != null &&
                free.at != null &&
                !free.at!.isAfter(g.lastMessageAt!)) {
              return g;
            }
            return g.copyWith(
              lastMessageText: free.text,
              // Free messages are always priest → user, so the
              // preview never gets a "You: " prefix here.
              lastMessageFromUser: false,
              lastMessageAt: free.at,
            );
          }).toList();

    // Early-return path now uses the enriched list so a priest who
    // ONLY had a follow-up free message (no new session) still gets
    // their preview line updated.
    if (messageOnly.isEmpty) return enrichedSessionGroups;

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
      // Same identity-strip as the session-based rows: a message-only
      // thread from a priest who has since deleted their account shows
      // as a neutral "Unavailable" row, never their old name/photo.
      final isDeleted = data['isDeleted'] as bool? ?? false;

      synthetic.add(PriestSessionGroup(
        priestId: priestId,
        priestName: isDeleted ? 'Unavailable' : meta.priestName,
        priestPhotoUrl: isDeleted ? '' : meta.priestPhotoUrl,
        priestDenomination:
            isDeleted ? '' : (data['denomination'] as String? ?? ''),
        isDeleted: isDeleted,
        isOnline: isDeleted ? false : (data['isOnline'] as bool? ?? false),
        isBusy: isDeleted ? false : (data['isBusy'] as bool? ?? false),
        totalSessions: 0,
        chatSessions: 1,
        voiceSessions: 0,
        lastSessionAt: meta.lastAt,
        lastSessionDuration: 0,
        lastSessionType: 'chat',
        averageRating: null,
        // Priest-sent follow-up. Always fromUser=false because these
        // entries come from priest_message notifications addressed
        // TO this user.
        lastMessageText: meta.messageText.isEmpty ? null : meta.messageText,
        lastMessageFromUser: meta.messageText.isEmpty ? null : false,
        lastMessageAt: meta.lastAt,
      ));
    }

    // Merge + re-sort using the same rules getUserPriestGroups uses
    // (available first, then by activity recency desc) so a priest
    // whose follow-up message arrived yesterday outranks one whose
    // session was three days ago.
    final all = <PriestSessionGroup>[
      ...enrichedSessionGroups,
      ...synthetic,
    ];
    all.sort((a, b) {
      final aAvailable = a.isOnline && !a.isBusy;
      final bAvailable = b.isOnline && !b.isBusy;
      if (aAvailable != bAvailable) return aAvailable ? -1 : 1;
      final aTime = a.lastActivityAt ?? DateTime(2000);
      final bTime = b.lastActivityAt ?? DateTime(2000);
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
  // True when the priest behind this row has deleted their account.
  // The row is kept (so the user's own history isn't silently erased)
  // but its identity is stripped: name shows as "Unavailable", no
  // photo, no status dot, and the row is not tappable. Set in the
  // data layer from the live priests/{uid}.isDeleted flag.
  final bool isDeleted;
  final bool isOnline;
  final bool isBusy;
  final int totalSessions;
  final int chatSessions;
  final int voiceSessions;
  final DateTime? lastSessionAt;
  final int lastSessionDuration;
  final String lastSessionType;
  final double? averageRating;

  // WhatsApp-style last-message preview, populated for priests with
  // at least one completed chat session. Null for voice-only priests
  // and for fetch failures — the renderer falls back to a "Last call"
  // / "Last chat" descriptor in that case.
  final String? lastMessageText;
  // True when the most-recent message in the last chat session was
  // sent by the signed-in user; drives the "You: " prefix on the
  // preview line.
  final bool? lastMessageFromUser;
  // Timestamp of the most-recent message — used by the row's date
  // formatter when it's more recent than `lastSessionAt` (a chat
  // session can have follow-up messages after it ended).
  final DateTime? lastMessageAt;

  const PriestSessionGroup({
    required this.priestId,
    required this.priestName,
    required this.priestPhotoUrl,
    required this.priestDenomination,
    this.isDeleted = false,
    required this.isOnline,
    required this.isBusy,
    required this.totalSessions,
    required this.chatSessions,
    required this.voiceSessions,
    required this.lastSessionAt,
    required this.lastSessionDuration,
    required this.lastSessionType,
    required this.averageRating,
    this.lastMessageText,
    this.lastMessageFromUser,
    this.lastMessageAt,
  });

  // "Available" = online and not in another session. Drives the
  // green dot on the avatar AND the row's sort priority.
  bool get isAvailable => isOnline && !isBusy;

  String get lastSessionText => df.formatTimeAgo(lastSessionAt);

  // Most-recent activity timestamp — newer of last session vs last
  // message. Drives the row's WhatsApp-style date column.
  DateTime? get lastActivityAt {
    if (lastMessageAt == null) return lastSessionAt;
    if (lastSessionAt == null) return lastMessageAt;
    return lastMessageAt!.isAfter(lastSessionAt!)
        ? lastMessageAt
        : lastSessionAt;
  }

  PriestSessionGroup copyWith({
    String? lastMessageText,
    bool? lastMessageFromUser,
    DateTime? lastMessageAt,
  }) {
    return PriestSessionGroup(
      priestId: priestId,
      priestName: priestName,
      priestPhotoUrl: priestPhotoUrl,
      priestDenomination: priestDenomination,
      isDeleted: isDeleted,
      isOnline: isOnline,
      isBusy: isBusy,
      totalSessions: totalSessions,
      chatSessions: chatSessions,
      voiceSessions: voiceSessions,
      lastSessionAt: lastSessionAt,
      lastSessionDuration: lastSessionDuration,
      lastSessionType: lastSessionType,
      averageRating: averageRating,
      lastMessageText: lastMessageText ?? this.lastMessageText,
      lastMessageFromUser: lastMessageFromUser ?? this.lastMessageFromUser,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    );
  }
}

// Internal helper for getUserPriestThreads — captures just enough
// of a priest_message notification (display name, photo, latest
// timestamp) to synthesize a PriestSessionGroup row for a priest
// the user has no completed session with.
class _MessageOnlyMeta {
  final String priestName;
  final String priestPhotoUrl;
  final DateTime? lastAt;
  // The notification body (priest's follow-up text) — surfaced as the
  // WhatsApp-style preview on the history row. Empty when the
  // notification carried no body.
  final String messageText;

  const _MessageOnlyMeta({
    required this.priestName,
    required this.priestPhotoUrl,
    required this.lastAt,
    required this.messageText,
  });
}

