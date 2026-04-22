// Shown when admin rejects a priest application.
//
// We pull the rejection reason live from Firestore on build because
// admins may edit it after the priest first opens this page (e.g. add
// a clearer explanation), and showing a stale reason would create
// support back-and-forth.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';

class ApplicationRejectedPage extends StatelessWidget {
  const ApplicationRejectedPage({super.key});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      const SizedBox(height: 24),
                      Container(
                        width: 88,
                        height: 88,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              AppColors.errorRed.withValues(alpha: 0.08),
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 40,
                          color: AppColors.errorRed,
                        ),
                      ),
                      const SizedBox(height: 32),
                      Text(
                        'Application Not Approved',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Unfortunately, your application was not approved '
                        'at this time. You can review the reason below and '
                        'submit a new application.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 24),
                      _RejectionReasonCard(uid: user?.uid),
                      const SizedBox(height: 32),
                      _ApplyAgainButton(
                        onTap: () => context.go('/priest/register'),
                      ),
                      const SizedBox(height: 16),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () async {
                          await FirebaseAuth.instance.signOut();
                          clearCachedRole();
                          if (!context.mounted) return;
                          context.go('/select-role');
                        },
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'Sign out',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AppColors.muted,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Pulls priests/{uid}.rejectionReason once. We use a FutureBuilder
// rather than a stream because the reason rarely changes after rejection
// — a one-shot read keeps Firestore costs trivial.
class _RejectionReasonCard extends StatelessWidget {
  final String? uid;
  const _RejectionReasonCard({required this.uid});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.errorRed.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.errorRed.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reason',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.errorRed,
            ),
          ),
          const SizedBox(height: 6),
          if (uid == null)
            _reasonText(context, 'No specific reason provided.')
          else
            FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
              future: FirebaseFirestore.instance.doc('priests/$uid').get(),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return _reasonText(context, 'Loading...');
                }
                final reason = snap.data?.data()?['rejectionReason']
                    as String?;
                final shown = (reason == null || reason.trim().isEmpty)
                    ? 'No specific reason provided.'
                    : reason;
                return _reasonText(context, shown);
              },
            ),
        ],
      ),
    );
  }

  Widget _reasonText(BuildContext context, String text) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        color: AppColors.deepDarkBrown,
        height: 1.5,
      ),
    );
  }
}

class _ApplyAgainButton extends StatefulWidget {
  final VoidCallback onTap;
  const _ApplyAgainButton({required this.onTap});

  @override
  State<_ApplyAgainButton> createState() => _ApplyAgainButtonState();
}

class _ApplyAgainButtonState extends State<_ApplyAgainButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: double.infinity,
          height: 54,
          decoration: BoxDecoration(
            color: AppColors.primaryBrown,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryBrown.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              'Apply Again',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
