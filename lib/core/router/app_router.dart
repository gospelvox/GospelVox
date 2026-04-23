// GoRouter configuration with role-based routing

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/admin/dashboard/pages/admin_dashboard_page.dart';
import 'package:gospel_vox/features/admin/settings/pages/admin_settings_page.dart';
import 'package:gospel_vox/features/auth/pages/login_page.dart';
import 'package:gospel_vox/features/auth/pages/onboarding_page.dart';
import 'package:gospel_vox/features/auth/pages/role_selection_page.dart';
import 'package:gospel_vox/features/priest/activation/pages/activation_paywall_page.dart';
import 'package:gospel_vox/features/priest/activation/pages/activation_success_page.dart';
import 'package:gospel_vox/features/priest/dashboard/pages/priest_dashboard_page.dart';
import 'package:gospel_vox/features/priest/registration/pages/application_rejected_page.dart';
import 'package:gospel_vox/features/priest/registration/pages/pending_approval_page.dart';
import 'package:gospel_vox/features/admin/speakers/pages/speaker_detail_page.dart';
import 'package:gospel_vox/features/admin/speakers/pages/speakers_list_page.dart';
import 'package:gospel_vox/features/priest/registration/pages/priest_registration_page.dart';
import 'package:gospel_vox/features/priest/session/bloc/incoming_request_cubit.dart';
import 'package:gospel_vox/features/priest/session/pages/incoming_request_page.dart';
import 'package:gospel_vox/features/priest/session/pages/priest_chat_session_page.dart';
import 'package:gospel_vox/features/priest/session/pages/session_summary_page.dart';
import 'package:gospel_vox/features/priest/settings/pages/priest_settings_page.dart';
import 'package:gospel_vox/features/shared/bloc/chat_session_cubit.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/user/home/pages/priest_profile_page.dart';
import 'package:gospel_vox/features/user/home/pages/user_shell_page.dart';
import 'package:gospel_vox/features/user/session/bloc/session_request_cubit.dart';
import 'package:gospel_vox/features/user/session/pages/chat_session_page.dart';
import 'package:gospel_vox/features/user/session/pages/post_session_page.dart';
import 'package:gospel_vox/features/user/session/pages/session_waiting_page.dart';
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

  final doc =
      await FirebaseFirestore.instance.collection('users').doc(uid).get();

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

// Resolves the right destination for an authenticated priest based on
// their priests/{uid} doc. Done in the router (not in the dashboard
// widget) so we never even mount the dashboard for unverified users —
// avoids a flash of "Priest Dashboard" before the redirect happens.
Future<String> _resolvePriestDestination(String uid) async {
  try {
    final doc = await FirebaseFirestore.instance.doc('priests/$uid').get();
    if (!doc.exists) return '/priest/register';

    final data = doc.data() ?? const <String, dynamic>{};
    final status = data['status'] as String? ?? 'pending';

    switch (status) {
      case 'pending':
        return '/priest/pending';
      case 'rejected':
        return '/priest/rejected';
      case 'approved':
        // Approved priests always land on the dashboard, regardless
        // of activation. The activation gate now lives at action
        // points (going online, accepting a session) via a bottom
        // sheet — so an unactivated priest can freely explore their
        // dashboard, wallet, and profile to understand what they're
        // activating for.
        return '/priest';
      case 'suspended':
        // Suspended priests still see the dashboard shell (it'll
        // render a "your account is suspended" card once that piece
        // exists). Not redirecting elsewhere keeps them in a visible
        // state rather than a confusing blank page.
        return '/priest';
      default:
        return '/priest/register';
    }
  } catch (_) {
    // Treat connectivity errors as "needs registration" rather than
    // bouncing the user out — they can retry submitting and we'll
    // pick up the existing doc once Firestore is reachable.
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
    // User's post-session summary + rating screen. Landed on via
    // context.go (not push) so the chat can't be reached back.
    GoRoute(
      path: '/session/post',
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
        return PostSessionPage(
          summary: summary,
          session: session,
          endReason:
              (extra['endReason'] as String?) ?? 'user_ended',
        );
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

// Priest-side stubs for routes the new dashboard links to. They exist
// so the quick-action tiles don't dead-end; the real pages (wallet,
// profile, bible sessions, settings) ship later and will replace
// these entries.
List<GoRoute> _priestPlaceholderRoutes() {
  // Pages with real implementations live alongside the placeholders.
  // Settings is the first to graduate — it hosts the Pause Requests
  // toggle the dashboard points at.
  const placeholders = {
    '/priest/wallet': 'My Wallet',
    '/priest/profile': 'My Profile',
    '/priest/bible-sessions': 'Bible Sessions',
  };

  return [
    GoRoute(
      path: '/priest/settings',
      builder: (context, state) => const PriestSettingsPage(),
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
    '/admin/users': 'User Management',
    '/admin/matrimony': 'Matrimony Approvals',
    '/admin/reports': 'Reports',
    '/admin/sessions': 'Session Monitor',
    '/admin/withdrawals': 'Withdrawals',
    '/admin/revenue': 'Revenue Dashboard',
    '/admin/bible-sessions': 'Bible Sessions',
    '/admin/products': 'Products',
  };

  return [
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
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: Text(title),
        backgroundColor: const Color(0xFFF8F9FA),
        foregroundColor: const Color(0xFF111827),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: const Center(child: Text('Coming Soon')),
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
