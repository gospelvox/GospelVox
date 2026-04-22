// "Application under review" landing page.
//
// Why this page exists at all instead of dropping the priest onto a
// disabled dashboard: the dashboard implies functionality that isn't
// available yet, which reads as a broken app. A dedicated waiting room
// sets expectations and gives admin moderation time without anxiety.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';

class PendingApprovalPage extends StatelessWidget {
  const PendingApprovalPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            children: [
              const SizedBox(height: 24),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.amberGold.withValues(alpha: 0.1),
                      ),
                      child: const Icon(
                        Icons.hourglass_top_rounded,
                        size: 40,
                        color: AppColors.amberGold,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Text(
                      'Application Under Review',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Thank you for applying to be a speaker on Gospel Vox. '
                      "Our team is reviewing your application and documents. "
                      "You'll be notified once a decision is made.",
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'This usually takes 24-48 hours',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.primaryBrown,
                      ),
                    ),
                    const SizedBox(height: 40),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceWhite,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AppColors.muted.withValues(alpha: 0.1),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.info_outline,
                            size: 20,
                            color: AppColors.muted,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              "We'll send you a notification when your "
                              'application is approved or if we need '
                              'additional information.',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color: AppColors.muted,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () async {
                  await FirebaseAuth.instance.signOut();
                  // Wipe the cached role so the router doesn't try to
                  // bounce the next sign-in straight back to /priest.
                  clearCachedRole();
                  if (!context.mounted) return;
                  context.go('/select-role');
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
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
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
