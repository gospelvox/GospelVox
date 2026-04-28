// Priest's availability sub-page. Owns the single "Pause Requests"
// toggle that controls whether they're shown as Busy in the user
// feed and whether createSessionRequest CF lets new requests
// through.
//
// Field shape: writes the boolean to priests/{uid}.isBusy.
// We deliberately keep the existing field name even though the
// UI label is "Pause Requests" — every consumer (the CF, the
// home feed sort, the priest dashboard's status card, the
// SpeakerModel) already reads `isBusy`. Renaming would silently
// break the actual gate.
//
// Days/hours selectors are intentionally NOT here: the CF
// doesn't enforce them yet, and shipping UI for unenforced
// preferences would create a "set it and still get pinged"
// trust failure. They land alongside CF enforcement in a future
// release.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/user/home/widgets/no_priests_widget.dart';

class PriestAvailabilityPage extends StatefulWidget {
  const PriestAvailabilityPage({super.key});

  @override
  State<PriestAvailabilityPage> createState() =>
      _PriestAvailabilityPageState();
}

class _PriestAvailabilityPageState extends State<PriestAvailabilityPage> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _sub;

  bool _loading = true;
  bool _writing = false;
  bool _isPaused = false;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  // Live stream so the toggle reflects changes made from another
  // device or by an admin in real time.
  void _attach() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _sub = FirebaseFirestore.instance
        .doc('priests/$uid')
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final data = snap.data() ?? const <String, dynamic>{};
      setState(() {
        _isPaused = data['isBusy'] as bool? ?? false;
        _loading = false;
      });
    }, onError: (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    });
  }

  Future<void> _toggle() async {
    if (_writing) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final newValue = !_isPaused;
    // Optimistic UI: flip immediately so the toggle feels instant.
    // Roll back on failure.
    setState(() {
      _isPaused = newValue;
      _writing = true;
    });

    try {
      await FirebaseFirestore.instance
          .doc('priests/$uid')
          .update({'isBusy': newValue})
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      setState(() => _writing = false);
      AppSnackBar.success(
        context,
        newValue
            ? "Requests paused. You'll stay online but won't receive "
                'new sessions.'
            : "You're available again. New requests will come through.",
      );
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isPaused = !newValue;
        _writing = false;
      });
      AppSnackBar.error(
        context,
        'Save timed out. Check your connection.',
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isPaused = !newValue;
        _writing = false;
      });
      AppSnackBar.error(
        context,
        "Couldn't update settings. Try again.",
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                color: AppColors.primaryBrown,
                strokeWidth: 2.5,
              ),
            )
          : SafeArea(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PauseRequestsCard(
                      isPaused: _isPaused,
                      writing: _writing,
                      onToggle: _toggle,
                    ),
                    const SizedBox(height: 12),
                    const InfoTipBlock(
                      'When paused, you stay online but new requests '
                      "won't reach you. Active sessions are not "
                      "affected. Users see you as 'Busy' on the home "
                      'feed.',
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      leadingWidth: 56,
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
        'Availability',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
      centerTitle: false,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
    );
  }
}

// ─── Pause Requests card ─────────────────────────────────

class _PauseRequestsCard extends StatelessWidget {
  final bool isPaused;
  final bool writing;
  final VoidCallback onToggle;

  const _PauseRequestsCard({
    required this.isPaused,
    required this.writing,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isPaused
            ? AppColors.amberGold.withValues(alpha: 0.06)
            : AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isPaused
              ? AppColors.amberGold.withValues(alpha: 0.25)
              : AppColors.muted.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.03),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isPaused ? 'Requests Paused' : 'Accepting Requests',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isPaused
                      ? "You're shown as 'Busy' to users. New "
                          "requests won't reach you."
                      : "You'll receive session requests when "
                          "you're online.",
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.5,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _Toggle(
            value: isPaused,
            disabled: writing,
            onChanged: onToggle,
          ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final bool value;
  final bool disabled;
  final VoidCallback onChanged;

  const _Toggle({
    required this.value,
    required this.disabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Track color tells the priest the *current* state at a glance:
    //   amber-gold = paused (matches the warning palette)
    //   forest-green = accepting (matches the "live" pill in chat)
    final trackColor = value
        ? AppColors.amberGold
        : const Color(0xFF2E7D4F);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: disabled ? null : onChanged,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        width: 52,
        height: 30,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          color: trackColor.withValues(alpha: disabled ? 0.5 : 1.0),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
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
