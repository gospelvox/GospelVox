// Empty state shown on the home feed when Firestore returns zero
// eligible priests. We keep the copy reassuring rather than
// apologetic — "no one around right now, come back soon" reads
// as honest; "something went wrong" would alarm a user whose
// feed is simply quiet on a Tuesday afternoon.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

class NoPriestsWidget extends StatelessWidget {
  const NoPriestsWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primaryBrown.withValues(alpha: 0.06),
                ),
                child: Icon(
                  Icons.people_outline_rounded,
                  size: 36,
                  color: AppColors.primaryBrown.withValues(alpha: 0.4),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'No Speakers Available',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Our speakers are currently offline. "
                "They'll be back soon — check again shortly.",
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  height: 1.6,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 24),
              const _InfoTipBlock(
                text: 'Speakers set their own availability. '
                    "You'll be able to connect when they come online. "
                    'Try checking back in a few minutes.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Inline informational panel — not to be confused with the icon-
// based `InfoHint` used in forms. This is a full-width advisory
// block for trust-building copy on the home feed and profile pages.
class _InfoTipBlock extends StatelessWidget {
  final String text;

  const _InfoTipBlock({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.primaryBrown.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
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
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.primaryBrown.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Exposed version of the info tip block for reuse on other home-
// feature pages (priest profile, etc.) without duplicating styling.
class InfoTipBlock extends StatelessWidget {
  final String text;

  const InfoTipBlock(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return _InfoTipBlock(text: text);
  }
}
