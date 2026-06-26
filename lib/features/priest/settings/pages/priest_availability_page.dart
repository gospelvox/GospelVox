// Priest's availability sub-page — single Go Offline toggle.
//
// Three-state availability model (kept simple):
//   • Online  — isOnline=true, isBusy=false. The default for an
//     activated priest with the app open. Set on dashboard mount,
//     refreshed via the 30s heartbeat.
//   • Busy    — isOnline=true, isBusy=true. Owned entirely by the
//     session system (acceptSession sets, endSession clears).
//     Never written from this page.
//   • Offline — isOnline=false. Either via the toggle here or via
//     the watchdog detecting >5 minutes of stale heartbeat.
//
// The Go Offline toggle is the priest's only manual control. There
// is no "pause requests" mid-state any more — if you want to be
// unavailable, you go offline. Simpler model, fewer ways for the
// priest's actual availability to drift away from what users see.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/user/home/widgets/no_priests_widget.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

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
  bool _isOffline = false;

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
        // Offline state is the inverse of isOnline. We don't track
        // any other flags — the watchdog can flip isOnline=false on
        // stale heartbeat, the toggle here can flip it either way,
        // and that's the entire universe of inputs.
        _isOffline = !(data['isOnline'] as bool? ?? false);
        _loading = false;
      });
    }, onError: (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    });
  }

  // Toggle between Online and Offline. Going offline:
  //   isOnline=false. lastHeartbeat is left alone — it would only
  //   matter for the watchdog, which already skips priests whose
  //   isOnline is false.
  // Going back online:
  //   isOnline=true, lastHeartbeat=now. The fresh heartbeat keeps
  //   the watchdog from immediately re-flipping us offline if the
  //   priest had been stale before manually toggling.
  Future<void> _toggle() async {
    if (_writing) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final goingOffline = !_isOffline;
    setState(() {
      _isOffline = goingOffline;
      _writing = true;
    });

    try {
      // Always include lastHeartbeat so the write payload matches the
      // dashboard's known-working pattern. Single-field updates have
      // tripped restrictive rules in the past — keeping the shape
      // identical avoids that whole class of regression.
      final updates = <String, dynamic>{
        'isOnline': !goingOffline,
        'lastHeartbeat': FieldValue.serverTimestamp(),
      };
      await FirebaseFirestore.instance
          .doc('priests/$uid')
          .update(updates)
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      setState(() => _writing = false);
      AppSnackBar.success(
        context,
        goingOffline
            ? "You're offline. Users won't see you in the feed."
            : "You're back online. Users can send you requests.",
      );
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _isOffline = !goingOffline;
        _writing = false;
      });
      AppSnackBar.error(
        context,
        'Save timed out. Check your connection.',
      );
    } catch (e, st) {
      debugPrint('[PriestAvailability] toggle failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _isOffline = !goingOffline;
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
              child: AppLoader(),
            )
          : SafeArea(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _GoOfflineCard(
                      isOffline: _isOffline,
                      writing: _writing,
                      onToggle: _toggle,
                    ),
                    const SizedBox(height: 12),
                    InfoTipBlock(
                      _isOffline
                          ? "While offline you're hidden from the user "
                              "feed. Active sessions still work; new "
                              "requests can't reach you."
                          : "When online, users can send you chat or "
                              "voice requests. Toggle off to drop out "
                              "of the feed temporarily.",
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
      leading: const Padding(
        padding: EdgeInsets.only(left: 12),
        child: Align(
          child: AppBackButton(),
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

// ─── Go Offline / Go Online card ──────────────────────────────

class _GoOfflineCard extends StatelessWidget {
  final bool isOffline;
  final bool writing;
  final VoidCallback onToggle;

  const _GoOfflineCard({
    required this.isOffline,
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
        color: isOffline
            ? AppColors.muted.withValues(alpha: 0.06)
            : AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isOffline
              ? AppColors.muted.withValues(alpha: 0.2)
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
                  isOffline ? 'Offline' : 'Online',
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  isOffline
                      ? "You're hidden from the user feed. New "
                          "requests can't reach you."
                      : "You'll receive session requests from users.",
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
            value: isOffline,
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
    // value == true means "offline" so the visual cue is muted
    // grey; value == false means "online" so we use the green
    // pill from chat's live-state palette.
    final trackColor = value
        ? AppColors.muted
        : AppColors.successGreen;

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
