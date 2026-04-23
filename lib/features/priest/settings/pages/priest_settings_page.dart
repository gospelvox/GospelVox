// Priest Settings — lightweight page for toggles that don't belong on
// the dashboard.
//
// Today this hosts the single Pause Requests toggle. Availability
// (online/offline) is NOT controlled here — it's driven by app
// lifecycle on the dashboard. Pause Requests is the only manual
// knob a priest has over their visibility to users.
//
// No cubit: the page reads/writes one boolean on one document. A
// StreamBuilder keeps the switch in sync with server state (handy
// if the priest edits this from two devices or admin suspends
// requests), and the toggle writes optimistically with revert on
// failure.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/auth/data/auth_repository.dart';

class PriestSettingsPage extends StatelessWidget {
  const PriestSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Align(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (context.canPop()) context.pop();
              },
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceWhite,
                  boxShadow: [
                    BoxShadow(
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                      color: Colors.black.withValues(alpha: 0.05),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.arrow_back_rounded,
                  size: 20,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
          ),
        ),
        title: Text(
          'Settings',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.deepDarkBrown,
          ),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            height: 1,
            color: AppColors.muted.withValues(alpha: 0.1),
          ),
        ),
      ),
      body: const SafeArea(
        child: SingleChildScrollView(
          physics: BouncingScrollPhysics(),
          padding: EdgeInsets.fromLTRB(20, 20, 20, 40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SectionLabel('AVAILABILITY'),
              SizedBox(height: 10),
              _PauseRequestsTile(),
              SizedBox(height: 12),
              _AvailabilityExplainer(),
              SizedBox(height: 28),
              _SectionLabel('ACCOUNT'),
              SizedBox(height: 10),
              _SignOutTile(),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Section label ────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: AppColors.muted,
      ),
    );
  }
}

// ─── Pause Requests toggle ────────────────────────────────

class _PauseRequestsTile extends StatefulWidget {
  const _PauseRequestsTile();

  @override
  State<_PauseRequestsTile> createState() => _PauseRequestsTileState();
}

class _PauseRequestsTileState extends State<_PauseRequestsTile> {
  bool _writing = false;

  Future<void> _toggle(bool currentValue) async {
    if (_writing) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final newValue = !currentValue;
    setState(() => _writing = true);

    try {
      await FirebaseFirestore.instance.doc('priests/$uid').update({
        'isBusy': newValue,
      });
      if (!mounted) return;
      AppSnackBar.success(
        context,
        newValue
            ? 'Requests paused. You stay online but new requests '
                'won\'t come through.'
            : 'Requests resumed. You\'re available again.',
      );
    } catch (_) {
      if (!mounted) return;
      AppSnackBar.error(
        context,
        "Couldn't update settings. Check your connection.",
      );
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: uid == null
            ? const Stream.empty()
            : FirebaseFirestore.instance
                .doc('priests/$uid')
                .snapshots(),
        builder: (_, snap) {
          final isBusy =
              (snap.data?.data()?['isBusy'] as bool?) ?? false;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: isBusy
                      ? AppColors.amberGold.withValues(alpha: 0.12)
                      : AppColors.primaryBrown.withValues(alpha: 0.06),
                ),
                child: Icon(
                  isBusy
                      ? Icons.pause_circle_filled_rounded
                      : Icons.pause_circle_outline_rounded,
                  size: 22,
                  color: isBusy
                      ? AppColors.amberGold
                      : AppColors.primaryBrown.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pause Requests',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isBusy
                          ? "Users see you as Busy. Existing chats still work."
                          : 'Stop accepting new sessions without going offline.',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        height: 1.4,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _Toggle(
                value: isBusy,
                onChanged: _writing ? null : () => _toggle(isBusy),
              ),
            ],
          );
        },
      ),
    );
  }
}

// Pill toggle shared with the dashboard's old look, extracted here
// so a tap handler can be swapped in.
class _Toggle extends StatelessWidget {
  final bool value;
  final VoidCallback? onChanged;

  const _Toggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final disabled = onChanged == null;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onChanged,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        width: 52,
        height: 30,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          color: value
              ? AppColors.amberGold
                  .withValues(alpha: disabled ? 0.5 : 1.0)
              : AppColors.muted
                  .withValues(alpha: disabled ? 0.1 : 0.2),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment:
              value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                  color: Colors.black.withValues(alpha: 0.1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Sign-out tile ────────────────────────────────────────
//
// Temporary scaffolding for dev — makes it easy to flip between
// user and priest roles without clearing storage. Can be promoted
// into a proper account section later.

class _SignOutTile extends StatefulWidget {
  const _SignOutTile();

  @override
  State<_SignOutTile> createState() => _SignOutTileState();
}

class _SignOutTileState extends State<_SignOutTile> {
  bool _signingOut = false;
  double _scale = 1.0;

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() => _signingOut = true);

    try {
      // Clear the router's cached role first — a lingering cache
      // would send the next sign-in back to the priest shell even
      // after they picked a different role.
      clearCachedRole();
      await sl<AuthRepository>().signOut();
      if (!mounted) return;
      context.go('/select-role');
    } catch (_) {
      if (!mounted) return;
      setState(() => _signingOut = false);
      AppSnackBar.error(context, 'Failed to sign out. Try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        if (!_signingOut) setState(() => _scale = 0.98);
      },
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _signingOut ? null : _signOut,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surfaceWhite,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.errorRed.withValues(alpha: 0.15),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    color: AppColors.errorRed.withValues(alpha: 0.08),
                  ),
                  child: Icon(
                    Icons.logout_rounded,
                    size: 20,
                    color: AppColors.errorRed,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sign Out',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.errorRed,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'End this session and return to role selection.',
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          height: 1.4,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (_signingOut)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.errorRed,
                    ),
                  )
                else
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: AppColors.muted,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Explainer ────────────────────────────────────────────

// Spelled out explicitly so priests never wonder why the app
// doesn't have an "online/offline" switch. This is the easiest
// confusion to pre-empt.
class _AvailabilityExplainer extends StatelessWidget {
  const _AvailabilityExplainer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.primaryBrown.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primaryBrown.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: AppColors.primaryBrown.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  height: 1.5,
                  color: AppColors.primaryBrown.withValues(alpha: 0.85),
                ),
                children: const [
                  TextSpan(
                    text: 'How availability works. ',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text:
                        'You go Online automatically when the app is open, '
                        'and Offline when it stays closed for two minutes. '
                        'Use Pause Requests to take a break without '
                        'signing out.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
