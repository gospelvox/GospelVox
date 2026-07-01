// GoRouter configuration with role-based routing

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/features/admin/dashboard/pages/admin_dashboard_page.dart';
import 'package:gospel_vox/features/admin/notifications/pages/admin_notifications_page.dart';
import 'package:gospel_vox/features/admin/reports/pages/reports_page.dart';
import 'package:gospel_vox/features/admin/revenue/pages/revenue_page.dart';
import 'package:gospel_vox/features/admin/sessions/pages/admin_sessions_page.dart';
import 'package:gospel_vox/features/admin/settings/pages/admin_settings_page.dart';
import 'package:gospel_vox/features/admin/users/pages/admin_users_page.dart';
import 'package:gospel_vox/features/admin/withdrawals/pages/withdrawals_page.dart';
import 'package:gospel_vox/features/auth/pages/login_page.dart';
import 'package:gospel_vox/features/auth/pages/onboarding_page.dart';
import 'package:gospel_vox/features/auth/pages/role_selection_page.dart';
import 'package:gospel_vox/features/priest/activation/pages/activation_paywall_page.dart';
import 'package:gospel_vox/features/priest/activation/pages/activation_success_page.dart';
import 'package:gospel_vox/features/priest/dashboard/pages/priest_dashboard_page.dart';
import 'package:gospel_vox/features/priest/missed/pages/missed_requests_page.dart';
import 'package:gospel_vox/features/priest/notifications/pages/notifications_page.dart';
import 'package:gospel_vox/features/priest/profile/pages/priest_profile_page.dart'
    as priest_profile;
import 'package:gospel_vox/features/priest/registration/pages/application_rejected_page.dart';
import 'package:gospel_vox/features/priest/registration/pages/approval_congrats_page.dart';
import 'package:gospel_vox/features/priest/registration/pages/pending_approval_page.dart';
import 'package:gospel_vox/features/priest/reviews/pages/priest_reviews_page.dart';
import 'package:gospel_vox/features/admin/speakers/pages/speaker_detail_page.dart';
import 'package:gospel_vox/features/admin/speakers/pages/speakers_list_page.dart';
import 'package:gospel_vox/features/priest/registration/pages/priest_registration_page.dart';
import 'package:gospel_vox/features/priest/session/bloc/incoming_request_cubit.dart';
import 'package:gospel_vox/features/priest/session/pages/incoming_request_page.dart';
import 'package:gospel_vox/features/priest/session/pages/priest_chat_session_page.dart';
import 'package:gospel_vox/features/priest/session/pages/priest_voice_call_page.dart';
import 'package:gospel_vox/features/priest/session/pages/session_dropped_page.dart';
import 'package:gospel_vox/features/priest/session/pages/session_summary_page.dart';
import 'package:gospel_vox/features/priest/settings/pages/priest_availability_page.dart';
import 'package:gospel_vox/features/priest/settings/pages/priest_settings_page.dart';
import 'package:gospel_vox/features/priest/users/pages/my_users_page.dart';
import 'package:gospel_vox/features/priest/users/pages/priest_chat_page.dart';
import 'package:gospel_vox/features/priest/wallet/bloc/priest_wallet_cubit.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';
import 'package:gospel_vox/features/priest/wallet/pages/bank_details_page.dart';
import 'package:gospel_vox/features/priest/wallet/pages/priest_wallet_page.dart';
import 'package:gospel_vox/features/priest/wallet/pages/withdrawal_status_page.dart';
import 'package:gospel_vox/features/priest/bible/pages/priest_bible_detail_page.dart';
import 'package:gospel_vox/features/priest/bible/pages/priest_bible_sessions_page.dart';
import 'package:gospel_vox/features/shared/bloc/chat_session_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/session_history_cubit.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/user/bible/pages/bible_session_detail_page.dart';
import 'package:gospel_vox/features/shared/pages/chat_transcript_page.dart';
import 'package:gospel_vox/features/shared/pages/session_detail_page.dart';
import 'package:gospel_vox/features/user/sessions/pages/chat_history_page.dart';
import 'package:gospel_vox/features/user/wallet/pages/wallet_page.dart';
import 'package:gospel_vox/features/shared/pages/session_history_page.dart';
import 'package:gospel_vox/features/user/home/pages/all_speakers_page.dart';
import 'package:gospel_vox/features/user/home/pages/priest_profile_page.dart';
import 'package:gospel_vox/features/user/home/pages/user_shell_page.dart';
import 'package:gospel_vox/features/user/notifications/pages/user_notifications_page.dart';
import 'package:gospel_vox/features/user/profile/pages/about_page.dart';
import 'package:gospel_vox/features/user/profile/pages/edit_profile_page.dart';
import 'package:gospel_vox/features/user/profile/pages/user_settings_page.dart';
import 'package:gospel_vox/features/user/session/bloc/session_request_cubit.dart';
import 'package:gospel_vox/features/user/session/pages/chat_session_page.dart';
import 'package:gospel_vox/features/user/session/pages/session_waiting_page.dart';
import 'package:gospel_vox/features/user/session/pages/voice_call_page.dart';
import 'package:gospel_vox/features/user/wallet/pages/payment_success_page.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

String? _cachedRole;

void clearCachedRole() {
  _cachedRole = null;
  _cachedUid = null;
}

String? _cachedUid;

Future<String?> _getUserRole(String uid) async {
  // Cache is uid-aware: if a different user signs in after sign-out,
  // we must re-fetch from Firestore instead of returning the old role.
  if (_cachedRole != null && _cachedUid == uid) return _cachedRole;

  // Cache-first. On cold start the users/{uid} doc is almost always in
  // Firestore's local persistence (enabled by default on mobile), so a
  // cache read resolves the role in milliseconds with NO network round-
  // trip — this is what removes the multi-second blank redirect wait a
  // returning user used to see on launch. Role changes are rare and the
  // in-memory cache already accepts that staleness within a session, so
  // cache-first across launches is consistent (and Firestore rules are
  // the real authority on what a role can do, regardless of this hint).
  final usersRef = FirebaseFirestore.instance.collection('users').doc(uid);
  DocumentSnapshot<Map<String, dynamic>>? doc;
  try {
    final cached = await usersRef.get(const GetOptions(source: Source.cache));
    if (cached.exists) doc = cached;
  } catch (_) {
    // Cache miss / persistence disabled — fall through to the server.
  }
  // Server fallback only when the cache had nothing (first-ever launch
  // on this device, or an evicted cache). Lowered to 6s so a dead
  // network can't hang the launch loading screen for the old 10s.
  doc ??= await usersRef
      .get(const GetOptions(source: Source.server))
      .timeout(const Duration(seconds: 6));

  if (!doc.exists || doc.data()?['role'] == null) return null;

  _cachedUid = uid;
  _cachedRole = doc.data()!['role'] as String;
  return _cachedRole;
}

String _roleToPath(String role) {
  switch (role) {
    case 'priest':
      return '/priest';
    case 'admin':
      return '/admin';
    default:
      return '/user';
  }
}

// "Has this priest seen the approval congrats screen" flag.
//
// Persisted in THREE places, checked together in _resolvePriestDestination
// so the one-time congrats stays one-time across the situations that used
// to re-show it:
//   1. priests/{uid}.approvalCongratsSeen — the authoritative record.
//      Lives on the server, so it survives sign-out/in, reinstall, app-data
//      clear, and switching devices. This is the fix for "an already-
//      approved priest sees 'You're Approved!' again every time they log
//      in" — the old flag was device-local SharedPreferences, so any fresh
//      install/device had no flag and re-showed the screen.
//   2. SharedPreferences (device-local) — fast offline read so we don't
//      depend on the network having returned the doc to skip congrats.
//   3. In-memory set — synchronous backstop against a navigation loop
//      within a session even if both writes above fail.
// The Firestore field is whitelisted by rules implicitly: priests may
// update their own doc as long as they don't touch the protected fields
// (status/isActivated/walletBalance/...), and this is none of those — so
// no firestore.rules change is needed.
String _approvalCongratsKey(String uid) =>
    'priest_approval_congrats_seen_$uid';

// In-memory backstop against a navigation loop. If the persistent writes
// ever fail (prefs unwritable, network down), relying on them alone could
// loop congrats→dashboard→congrats and trap the priest. This set is marked
// synchronously in markApprovalCongratsSeen BEFORE the dashboard
// navigation, so the very next approved-state resolution short-circuits to
// the dashboard no matter what prefs/Firestore do. Resets on app restart.
final Set<String> _approvalCongratsShownThisSession = <String>{};

// Local (device + session) seen check. The SERVER field is read directly
// from the already-fetched priest doc in _resolvePriestDestination — this
// helper only covers the device-local layers so we can skip congrats even
// before the doc read returns.
Future<bool> _approvalCongratsSeenLocal(String uid) async {
  if (_approvalCongratsShownThisSession.contains(uid)) return true;
  try {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_approvalCongratsKey(uid)) ?? false;
  } catch (_) {
    // On any prefs failure, treat as seen so we never trap the priest in
    // a congrats→dashboard→congrats loop. Worst case: they skip the
    // celebration, not their dashboard.
    return true;
  }
}

// Called by the congrats screen the moment it appears, so every later
// approved-state resolution — on this device or any other — skips congrats.
Future<void> markApprovalCongratsSeen(String uid) async {
  // Synchronous in-memory mark FIRST — guarantees the subsequent
  // navigation can't loop even if the persistent writes below fail.
  _approvalCongratsShownThisSession.add(uid);

  // Server record (authoritative, survives reinstall/login/device-change).
  // Best-effort: merge so we never clobber other fields, and swallow errors
  // — the device-local layers still prevent a loop this session.
  try {
    await FirebaseFirestore.instance
        .doc('priests/$uid')
        .set(<String, dynamic>{'approvalCongratsSeen': true},
            SetOptions(merge: true));
  } catch (_) {
    // Non-fatal — offline or transient. The local flag below still skips
    // congrats on this device; the next time online + on the congrats
    // screen will retry the write.
  }

  // Device-local fast path.
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_approvalCongratsKey(uid), true);
  } catch (_) {
    // Non-fatal — the server field and in-memory set still cover us.
  }
}

// Resolves the right destination for an authenticated priest based on
// their priests/{uid} doc. Done in the router (not in the dashboard
// widget) so we never even mount the dashboard for unverified users —
// avoids a flash of "Priest Dashboard" before the redirect happens.
Future<String> _resolvePriestDestination(String uid) async {
  final ref = FirebaseFirestore.instance.doc('priests/$uid');

  // Read the priest's doc to decide their screen. We must distinguish
  // three outcomes, because they route VERY differently:
  //   • read succeeded, doc exists   → route by status
  //   • read succeeded, doc absent   → genuinely new → /priest/register
  //   • read FAILED (timeout/error)  → unknown → must NOT register them
  // The bug this guards against: a slow network or a transient Firestore
  // error used to throw straight to '/priest/register', demoting an
  // already-approved (and possibly activated) priest to the brand-new-
  // applicant screen on every flaky launch. A failed read says nothing
  // about whether the priest exists, so it must never trigger register.
  DocumentSnapshot<Map<String, dynamic>>? doc;
  try {
    // Server-first (not cache-first): a priest's status legitimately
    // changes (pending → approved) while the app is closed, and routing
    // them to the right screen on launch needs the fresh value. 6s caps
    // the launch wait on a slow network.
    doc = await ref.get().timeout(const Duration(seconds: 6));
  } catch (_) {
    // Server slow / unreachable / transient error. Fall back to the
    // locally-cached doc — any priest who has opened the app before has
    // priests/{uid} in Firestore's offline persistence, so this resolves
    // their real status without a network round-trip.
    try {
      doc = await ref.get(const GetOptions(source: Source.cache));
    } catch (_) {
      doc = null;
    }
  }

  // Total read failure (server AND cache unavailable). Do NOT route to
  // register — land on the dashboard shell, which live-streams
  // priests/{uid} and self-corrects to the right state the moment a read
  // succeeds. Worse case for a truly-new user is a momentarily empty
  // dashboard, not a wrongful "register from scratch" screen.
  if (doc == null) return '/priest';

  // A SUCCESSFUL read with no doc is the only thing that means a genuinely
  // new user who must register.
  if (!doc.exists) return '/priest/register';

  final data = doc.data() ?? const <String, dynamic>{};
  final status = data['status'] as String? ?? 'pending';

  switch (status) {
    case 'pending':
      return '/priest/pending';
    case 'rejected':
      return '/priest/rejected';
    case 'approved':
      // First time a priest reaches approved → celebrate it once with
      // the congrats screen; afterwards go straight to the dashboard.
      // Approved priests always land on the dashboard regardless of
      // activation — the activation gate lives at action points (going
      // online, accepting a session) via a bottom sheet, so an
      // unactivated priest can freely explore dashboard / wallet /
      // profile to understand what they're activating for.
      //
      // "Seen" is true if ANY signal says so:
      //   • the server field (survives reinstall/login/device-change),
      //   • the priest is already activated — an activated priest is well
      //     past the "you're approved, now activate" moment, so never show
      //     it to them (this also covers priests who were approved BEFORE
      //     the server field existed and so don't carry it),
      //   • the device-local flag (fast offline path).
      final seenServer = data['approvalCongratsSeen'] == true;
      final alreadyActivated = data['isActivated'] == true;
      final seenLocal = await _approvalCongratsSeenLocal(uid);
      final seen = seenServer || alreadyActivated || seenLocal;
      return seen ? '/priest' : '/priest/approved';
    case 'suspended':
      // Suspended priests still see the dashboard shell (it'll
      // render a "your account is suspended" card once that piece
      // exists). Not redirecting elsewhere keeps them in a visible
      // state rather than a confusing blank page.
      return '/priest';
    default:
      return '/priest/register';
  }
}

final appRouter = GoRouter(
  initialLocation: '/select-role',
  redirect: (BuildContext context, GoRouterState state) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final path = state.matchedLocation;
      final isSelectRole = path == '/select-role';
      final isSignIn = path.startsWith('/signin');
      final isOnboarding = path == '/onboarding';

      // Not authenticated → allow auth-flow routes
      if (user == null) {
        if (isSelectRole || isSignIn || isOnboarding) return null;
        return '/select-role';
      }

      // Authenticated → check role
      final role = await _getUserRole(user.uid);

      if (role == null) {
        if (isSelectRole || isSignIn || isOnboarding) return null;
        return '/select-role';
      }

      // Has role → don't allow auth-flow pages
      if (isSelectRole || isSignIn || isOnboarding) {
        if (role == 'priest') {
          return await _resolvePriestDestination(user.uid);
        }
        return _roleToPath(role);
      }

      // Role-vs-route guard. The redirect previously only checked
      // auth-flow paths, so a logged-in user who deep-linked to /admin
      // (or a priest to /user) would mount the wrong shell — Firestore
      // rules blocked the data fetches but the broken-looking UI still
      // rendered. This is the in-router gate; rules remain the
      // backstop.
      //
      // Shared routes (/session/*, /bible/*) are intentionally NOT
      // gated here — both user and priest sides legitimately use them.
      if (role == 'user' &&
          (path.startsWith('/admin') || path.startsWith('/priest'))) {
        return '/user';
      }
      if (role == 'priest' &&
          (path.startsWith('/admin') || path.startsWith('/user'))) {
        return '/priest';
      }
      if (role == 'admin' &&
          (path.startsWith('/user') || path.startsWith('/priest'))) {
        return '/admin';
      }

      // Priest-specific gating: when a speaker lands on the dashboard
      // shell at /priest, we have to check their priests/{uid} state
      // and route to the right substate (register / pending / rejected).
      // Sub-paths like /priest/register are allowed through unchanged
      // so the user can navigate inside the wizard.
      if (role == 'priest' && path == '/priest') {
        final dest = await _resolvePriestDestination(user.uid);
        if (dest != '/priest') return dest;
      }

      return null;
    } catch (_) {
      // If Firestore is unreachable on cold start, fall back safely
      // to role selection instead of crashing the app.
      return '/select-role';
    }
  },
  routes: [
    GoRoute(
      path: '/select-role',
      builder: (context, state) => const RoleSelectionPage(),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) {
        final role = state.extra as String?;
        if (role == null || (role != 'user' && role != 'priest')) {
          return const RoleSelectionPage();
        }
        return OnboardingPage(presetRole: role);
      },
    ),
    GoRoute(
      path: '/signin/:role',
      builder: (context, state) {
        final role = state.pathParameters['role'] ?? 'user';
        return LoginPage(selectedRole: role);
      },
    ),
    GoRoute(
      path: '/user',
      builder: (context, state) => const UserShellPage(),
    ),
    GoRoute(
      // Pushed by WalletPage's BlocListener after verifyCoinPurchase
      // returns. The extras carry the amounts — the page itself does
      // no network work, so stale/missing extras just show zeros.
      path: '/user/payment-success',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? const {};
        return PaymentSuccessPage(
          coinsPurchased: (extra['coins'] as num?)?.toInt() ?? 0,
          newBalance: (extra['newBalance'] as num?)?.toInt() ?? 0,
        );
      },
    ),
    GoRoute(
      // Priest profile viewed by a USER from the home feed. Distinct
      // from /admin/speakers/:id which renders admin moderation tools.
      path: '/user/priest/:id',
      builder: (context, state) {
        final priestId = state.pathParameters['id'] ?? '';
        return PriestProfilePage(priestId: priestId);
      },
    ),
    // Bible session detail (user side). Pushed from the BibleTab
    // card. The page handles its own load + register + pay flow,
    // so the route is just an id passthrough.
    GoRoute(
      path: '/bible/detail/:id',
      builder: (context, state) {
        final id = state.pathParameters['id'] ?? '';
        return BibleSessionDetailPage(sessionId: id);
      },
    ),
    // User-side profile sub-routes. The Me tab is rendered inside
    // the shell's IndexedStack, so these are pushed on top of the
    // shell rather than replacing it — the bottom nav stays out of
    // view while the user is editing or browsing settings.
    GoRoute(
      path: '/user/edit-profile',
      builder: (context, state) => const EditProfilePage(),
    ),
    GoRoute(
      path: '/user/settings',
      builder: (context, state) => const UserSettingsPage(),
    ),
    GoRoute(
      path: '/user/about',
      builder: (context, state) => const AboutPage(),
    ),
    GoRoute(
      path: '/user/notifications',
      builder: (context, state) => const UserNotificationsPage(),
    ),
    // Full priest list — destination of "Available now → See all"
    // on the home feed. Spawns its own HomeCubit, so popping back to
    // the shell leaves the home page's cubit/scroll position intact.
    GoRoute(
      path: '/user/speakers',
      // Optional ?filter=<chip> pre-selects a filter chip so a user who
      // tapped a chip on Home (e.g. "Online") lands on the matching list
      // here instead of the full catalogue. Unknown/absent → "All".
      builder: (context, state) => AllSpeakersPage(
        initialFilter: state.uri.queryParameters['filter'],
      ),
    ),
    GoRoute(
      path: '/priest',
      builder: (context, state) => const PriestDashboardPage(),
    ),
    // Session request flow — the waiting screen fires the CF itself
    // in initState, so this route exists purely to supply the cubit
    // and hand the priest metadata through as extras. Using `extra`
    // (not path params) keeps URLs clean and lets us pass photo
    // URLs and denomination without encoding them.
    GoRoute(
      path: '/session/waiting',
      builder: (context, state) {
        final extra = state.extra as Map<String, dynamic>? ?? const {};
        return BlocProvider(
          create: (_) => sl<SessionRequestCubit>(),
          child: SessionWaitingPage(
            priestId: extra['priestId'] as String? ?? '',
            priestName: extra['priestName'] as String? ?? '',
            priestPhotoUrl: extra['priestPhotoUrl'] as String? ?? '',
            priestDenomination:
                extra['priestDenomination'] as String? ?? '',
            sessionType: extra['type'] as String? ?? 'chat',
          ),
        );
      },
    ),
    // Priest incoming-request screen. The dashboard stream listener
    // navigates here with the already-hydrated SessionModel and the
    // priest's current activation flag, so the page can gate the
    // Accept button without a second read.
    GoRoute(
      path: '/priest/incoming',
      builder: (context, state) {
        final extra = state.extra;
        final session = extra is Map<String, dynamic>
            ? extra['session'] as SessionModel?
            : extra as SessionModel?;
        final isActivated = extra is Map<String, dynamic>
            ? (extra['isActivated'] as bool? ?? false)
            : false;
        if (session == null) {
          return const _MissingSessionPlaceholder();
        }
        return BlocProvider(
          create: (_) =>
              sl<IncomingRequestCubit>()..receiveRequest(session),
          child: IncomingRequestPage(
            session: session,
            isActivated: isActivated,
          ),
        );
      },
    ),
    // Live chat — user side. Both sides share ChatSessionView but
    // each owns its own cubit so isUserSide is seeded correctly
    // (drives whether heartbeat + billingTick run here).
    GoRoute(
      path: '/session/chat/:id',
      builder: (context, state) {
        final sessionId = state.pathParameters['id'] ?? '';
        return BlocProvider(
          create: (_) => sl<ChatSessionCubit>()
            ..startSession(sessionId: sessionId, isUserSide: true),
          child: ChatSessionPage(sessionId: sessionId),
        );
      },
    ),
    // Live chat — priest side. Same view, passive cubit (no
    // heartbeat, no billing) so we never double-bill the user.
    GoRoute(
      path: '/session/priest-chat/:id',
      builder: (context, state) {
        final sessionId = state.pathParameters['id'] ?? '';
        return BlocProvider(
          create: (_) => sl<ChatSessionCubit>()
            ..startSession(sessionId: sessionId, isUserSide: false),
          child: PriestChatSessionPage(sessionId: sessionId),
        );
      },
    ),
    // Live voice call — user side. The page constructs its own
    // VoiceCallCubit + AgoraService inline (see voice_call_page.dart
    // for why those aren't sourced from the DI container).
    GoRoute(
      path: '/session/voice/:id',
      builder: (context, state) {
        final sessionId = state.pathParameters['id'] ?? '';
        return VoiceCallPage(sessionId: sessionId);
      },
    ),
    // Live voice call — priest side. Mirror of the user route with
    // isUserSide: false wired inside the page so billing only ever
    // runs from the user's client.
    GoRoute(
      path: '/session/priest-voice/:id',
      builder: (context, state) {
        final sessionId = state.pathParameters['id'] ?? '';
        return PriestVoiceCallPage(sessionId: sessionId);
      },
    ),
    // Priest's summary — earnings/commission/net.
    GoRoute(
      path: '/session/priest-summary',
      builder: (context, state) {
        final extra = state.extra;
        if (extra is! Map<String, dynamic>) {
          return const _MissingSessionPlaceholder();
        }
        final summary = extra['summary'] as SessionSummary?;
        final session = extra['session'] as SessionModel?;
        if (summary == null || session == null) {
          return const _MissingSessionPlaceholder();
        }
        return SessionSummaryPage(
          summary: summary,
          session: session,
          endReason:
              (extra['endReason'] as String?) ?? 'priest_ended',
        );
      },
    ),
    // Priest's "session ended unexpectedly" landing. Reached when
    // the chat ends for any reason OTHER than the priest tapping
    // End — see priest_chat_session_page._onEnded for the branch.
    GoRoute(
      path: '/priest/session-dropped',
      builder: (context, state) {
        final extra = state.extra;
        if (extra is! Map<String, dynamic>) {
          return const _MissingSessionPlaceholder();
        }
        final session = extra['session'] as SessionModel?;
        if (session == null) {
          return const _MissingSessionPlaceholder();
        }
        return SessionDroppedPage(
          session: session,
          earnedAmount: (extra['earned'] as int?) ?? 0,
          duration: (extra['duration'] as int?) ?? 0,
          endReason: (extra['endReason'] as String?) ?? 'external',
        );
      },
    ),
    // Priest's availability sub-page (Pause Requests). The
    // settings hub at /priest/settings has a tile that opens
    // this; nothing else routes to it directly today, but the
    // explicit path makes it easy to deep-link from a future
    // notification ("you've been paused for 24h").
    GoRoute(
      path: '/priest/settings/availability',
      builder: (context, state) => const PriestAvailabilityPage(),
    ),
    // Session-history list — shared page driven by `isUserSide`.
    // Loads on construction since the page does no work without uid;
    // currentUser is guaranteed non-null here because the router's
    // top-level redirect bounces unauthenticated users to /select-role
    // before any sub-route mounts.
    GoRoute(
      path: '/user/session-history',
      builder: (context, state) {
        final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
        return BlocProvider(
          create: (_) => sl<SessionHistoryCubit>()
            ..loadUserSessions(uid),
          child: const SessionHistoryPage(isUserSide: true),
        );
      },
    ),
    // Wallet — was a tab at index 2 in earlier builds, now lives as
    // a push route so the Sessions tab can take that slot. WalletPage
    // creates and loads its own WalletCubit internally, so no
    // BlocProvider wrap is needed here (would only allocate a
    // duplicate cubit the page never reads).
    GoRoute(
      path: '/user/wallet',
      builder: (context, state) => const WalletPage(),
    ),
    // Chat history — opens when the user taps a row in the Chats
    // sub-tab of the Sessions tab. Renders every message from
    // completed chat sessions with this priest in the last 14 days,
    // grouped by session with date separators. Read-only — the
    // sticky bottom button hands off to /user/priest/:id where rate
    // is disclosed and the new paid session begins.
    //
    // Calls sub-tab does NOT use this page — voice calls have no
    // text history, so tapping a Calls row goes straight to the
    // priest profile.
    GoRoute(
      path: '/user/chat-history/:priestId',
      builder: (context, state) {
        final priestId = state.pathParameters['priestId'] ?? '';
        final extra = state.extra;
        final extraMap =
            extra is Map<String, dynamic> ? extra : const <String, dynamic>{};
        return ChatHistoryPage(
          priestId: priestId,
          priestName: extraMap['priestName'] as String? ?? '',
          priestPhotoUrl: extraMap['priestPhotoUrl'] as String? ?? '',
        );
      },
    ),
    GoRoute(
      path: '/priest/session-history',
      builder: (context, state) {
        final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
        return BlocProvider(
          create: (_) => sl<SessionHistoryCubit>()
            ..loadPriestSessions(uid),
          child: const SessionHistoryPage(isUserSide: false),
        );
      },
    ),
    // Priest's primary relationship surface — WhatsApp-style list
    // grouped by user. The session-history route above is kept for
    // deep links and any analytics surface that still needs the
    // per-session view, but the dashboard now points at this one.
    GoRoute(
      path: '/priest/my-users',
      builder: (context, state) => const PriestMyUsersPage(),
    ),
    // Dedicated inbox for unread missed-request notifications.
    // Reached from the dashboard amber banner, foreground in-app
    // banner, FCM tap, and the notifications inbox row. Lives at a
    // separate route from My Users because missed requests are
    // pending ACTIONS (respond / dismiss), not relationships.
    GoRoute(
      path: '/priest/missed-requests',
      builder: (context, state) => const MissedRequestsPage(),
    ),
    // Priest-side per-user chat view. Tap a row in My Users → here.
    // Pushes a fresh page each time so back-stack behavior matches
    // every other priest sub-route.
    GoRoute(
      path: '/priest/chat/:userId',
      builder: (context, state) {
        final userId = state.pathParameters['userId'] ?? '';
        final extra = state.extra is Map<String, dynamic>
            ? state.extra as Map<String, dynamic>
            : const <String, dynamic>{};
        return PriestChatPage(
          userId: userId,
          userName: extra['userName'] as String? ?? '',
          userPhotoUrl: extra['userPhotoUrl'] as String? ?? '',
        );
      },
    ),
    // Per-session detail page. The session itself is passed as an
    // extra rather than re-fetched by id — the list already has the
    // hydrated model and a refetch would cost a round-trip for no
    // new data on a page that's effectively read-only.
    GoRoute(
      path: '/session/detail',
      builder: (context, state) {
        final extra = state.extra;
        if (extra is! Map<String, dynamic>) {
          return const _MissingSessionPlaceholder();
        }
        final session = extra['session'] as SessionModel?;
        final isUserSide = extra['isUserSide'] as bool? ?? true;
        if (session == null) {
          return const _MissingSessionPlaceholder();
        }
        return SessionDetailPage(
          session: session,
          isUserSide: isUserSide,
        );
      },
    ),
    // Read-only chat transcript. otherName + sessionDate are optional
    // niceties for the header; if they're missing (deep link) the
    // page still renders fine with a generic title.
    GoRoute(
      path: '/session/transcript/:id',
      builder: (context, state) {
        final sessionId = state.pathParameters['id'] ?? '';
        final extra = state.extra is Map<String, dynamic>
            ? state.extra as Map<String, dynamic>
            : const <String, dynamic>{};
        return ChatTranscriptPage(
          sessionId: sessionId,
          otherName: extra['otherName'] as String? ?? '',
          sessionDate: extra['sessionDate'] as String? ?? '',
        );
      },
    ),
    // Placeholders for dashboard quick-action tiles. Each route exists
    // today so tapping the tile navigates somewhere readable instead
    // of silently doing nothing; the real pages ship later this week.
    ..._priestPlaceholderRoutes(),
    GoRoute(
      path: '/priest/register',
      builder: (context, state) => const PriestRegistrationPage(),
    ),
    GoRoute(
      path: '/priest/pending',
      builder: (context, state) => const PendingApprovalPage(),
    ),
    GoRoute(
      path: '/priest/approved',
      builder: (context, state) => const ApprovalCongratsPage(),
    ),
    GoRoute(
      path: '/priest/rejected',
      builder: (context, state) => const ApplicationRejectedPage(),
    ),
    GoRoute(
      path: '/priest/activation',
      builder: (context, state) => const ActivationPaywallPage(),
    ),
    GoRoute(
      path: '/priest/activation-success',
      builder: (context, state) => const ActivationSuccessPage(),
    ),
    GoRoute(
      path: '/admin',
      builder: (context, state) => const AdminDashboardPage(),
    ),
    ..._adminSubRoutes(),
  ],
);

// Priest-side dashboard sub-routes. Originally stubbed when the
// dashboard was wired up; settings/wallet/profile/notifications and
// now bible-sessions have all graduated to real pages, so the
// `placeholders` map is empty — kept here as the seam where future
// dashboard tiles can land before their real screens ship.
List<GoRoute> _priestPlaceholderRoutes() {
  const placeholders = <String, String>{};

  return [
    GoRoute(
      path: '/priest/settings',
      builder: (context, state) => const PriestSettingsPage(),
    ),
    // Real wallet route — owns its own cubit so each mount starts
    // with a fresh balance stream. Loads on construction since the
    // page does no work without uid.
    GoRoute(
      path: '/priest/wallet',
      builder: (context, state) {
        final uid = FirebaseAuth.instance.currentUser?.uid;
        return BlocProvider(
          create: (_) {
            final cubit = sl<PriestWalletCubit>();
            if (uid != null) cubit.loadWallet(uid);
            return cubit;
          },
          child: const PriestWalletPage(),
        );
      },
    ),
    // Bank details page — receives existing details via `extra`
    // when the wallet routes here for editing. Null `extra` means
    // first-time setup.
    GoRoute(
      path: '/priest/bank-details',
      builder: (context, state) {
        final existing = state.extra is BankDetails
            ? state.extra as BankDetails
            : null;
        return BankDetailsPage(existingDetails: existing);
      },
    ),
    // Priest "My Withdrawals" status screen — the per-withdrawal
    // timeline (Requested -> Processing -> Sent), bank reference, and
    // on-hold fix prompt. Provides its own cubit internally.
    GoRoute(
      path: '/priest/withdrawals',
      builder: (context, state) => const WithdrawalStatusPage(),
    ),
    // Priest's own profile (view + edit). Distinct from the user-side
    // /user/priest/:id which renders a public-facing speaker profile —
    // hence the import alias on PriestMyProfilePage above.
    GoRoute(
      path: '/priest/profile',
      builder: (context, state) =>
          const priest_profile.PriestMyProfilePage(),
    ),
    // In-app notifications list. FCM push registration is a separate
    // concern (Week 5); this route only renders the in-app inbox.
    GoRoute(
      path: '/priest/notifications',
      builder: (context, state) => const NotificationsPage(),
    ),
    // Priest's reviews surface — average + distribution + per-review
    // list with reply composer. Reached from the rating stat tile on
    // the dashboard, the rating row in My Profile, and the
    // review_milestone push deep link.
    GoRoute(
      path: '/priest/reviews',
      builder: (context, state) => const PriestReviewsPage(),
    ),
    // Priest's Bible sessions list — entry point from the dashboard
    // tile. The "+" button on the page itself opens the create sheet.
    GoRoute(
      path: '/priest/bible-sessions',
      builder: (context, state) => const PriestBibleSessionsPage(),
    ),
    // Priest's session manage view. Pushed by the list page; returns
    // a `bool?` via pop() — true when something mutated (link added,
    // session cancelled / completed) so the list refreshes on return.
    GoRoute(
      path: '/priest/bible/:id',
      builder: (context, state) {
        final id = state.pathParameters['id'] ?? '';
        return PriestBibleDetailPage(sessionId: id);
      },
    ),
    ...placeholders.entries.map(
      (e) => GoRoute(
        path: e.key,
        builder: (context, state) => _PriestPlaceholder(title: e.value),
      ),
    ),
  ];
}

List<GoRoute> _adminSubRoutes() {
  const placeholders = {
    '/admin/matrimony': 'Matrimony Approvals',
    '/admin/bible-sessions': 'Bible Sessions',
    '/admin/products': 'Products',
  };

  return [
    // Revenue dashboard
    GoRoute(
      path: '/admin/revenue',
      builder: (context, state) => const RevenuePage(),
    ),
    // Real settings pages
    GoRoute(
      path: '/admin/settings',
      builder: (context, state) => const AdminSettingsPage(initialTab: 0),
    ),
    GoRoute(
      path: '/admin/coin-packs',
      builder: (context, state) => const AdminSettingsPage(initialTab: 1),
    ),
    // Speaker management
    GoRoute(
      path: '/admin/speakers',
      builder: (context, state) => const SpeakersListPage(),
    ),
    GoRoute(
      path: '/admin/speakers/:id',
      builder: (context, state) {
        final id = state.pathParameters['id'] ?? '';
        return SpeakerDetailPage(speakerId: id);
      },
    ),
    // User / session / report / withdrawal dashboards. All four
    // are read-mostly: the only mutating actions live inside the
    // reports + withdrawals pages (resolve / mark-paid / block).
    GoRoute(
      path: '/admin/users',
      builder: (context, state) => const AdminUsersPage(),
    ),
    GoRoute(
      path: '/admin/sessions',
      builder: (context, state) => const AdminSessionsPage(),
    ),
    GoRoute(
      path: '/admin/reports',
      builder: (context, state) => const ReportsPage(),
    ),
    GoRoute(
      path: '/admin/withdrawals',
      builder: (context, state) => const WithdrawalsPage(),
    ),
    GoRoute(
      path: '/admin/notifications',
      builder: (context, state) => const AdminNotificationsPage(),
    ),
    // Placeholder pages
    ...placeholders.entries.map(
      (e) => GoRoute(
        path: e.key,
        builder: (context, state) => _AdminPlaceholder(title: e.value),
      ),
    ),
  ];
}

class _AdminPlaceholder extends StatelessWidget {
  final String title;
  const _AdminPlaceholder({required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminColors.background,
      appBar: AppBar(
        title: Text(
          title,
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AdminColors.textPrimary,
          ),
        ),
        backgroundColor: AdminColors.background,
        foregroundColor: AdminColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      // A styled, intentional "being built" state — not a bare white
      // screen, so tapping a not-yet-shipped Manage card reads as a
      // planned section rather than a broken/dead button.
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: AdminColors.warningBg,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const AppIcon(
                  AppIcons.hourglass,
                  size: 28,
                  color: AdminColors.warning,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Coming soon',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AdminColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'This section is being built and will appear here in an upcoming update.',
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  height: 1.45,
                  color: AdminColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Safety net in case /priest/incoming is opened without a session in
// extras — e.g. a stale deep link. Shouldn't happen in the real flow
// since the dashboard passes the session itself.
class _MissingSessionPlaceholder extends StatelessWidget {
  const _MissingSessionPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Text(
          'Session unavailable',
          style: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.deepDarkBrown,
          ),
        ),
      ),
    );
  }
}

// Priest-side "coming soon" pages. Styled against the warm palette so
// the quick-action tiles don't jarringly drop the user onto a
// bright admin-style screen.
class _PriestPlaceholder extends StatelessWidget {
  final String title;
  const _PriestPlaceholder({required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4EDE3),
      appBar: AppBar(
        title: Text(title),
        backgroundColor: const Color(0xFFF4EDE3),
        foregroundColor: const Color(0xFF3D1F0F),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: const Center(child: Text('Coming Soon')),
    );
  }
}
