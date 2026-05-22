// Floating bottom navigation card for the signed-in user shell.
//
// Renders a rounded pill that sits with side+bottom margins instead
// of filling the screen edge-to-edge. Active state is communicated
// purely by colour and label weight — no pill / background container
// behind the active item, per the design brief.
//
// This widget is intentionally stateless and side-effect-free. All
// animation (hide-on-scroll) is owned by UserShellPage, which wraps
// this in an AnimatedBuilder + Transform.translate. Keeping animation
// state outside this widget means tab-switch repaints don't churn the
// scroll-hide controller and vice-versa.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

// Diameter of the centre matrimony FAB, and how far it lifts above
// the card's top edge. Exported so the shell can reserve enough
// vertical room in its Positioned slot — without this, the outer
// Stack would clip the FAB's upper half.
const double _kCenterFabSize = 56;
const double _kCenterFabLift = 22;
// Trimmed 5 px (64 → 59) to claw back vertical space on shorter
// phones. The labels still fit comfortably: 22 px icon + 4 px gap +
// ~14 px label + ~9 px symmetric vertical padding ≈ 59 px.
const double kFloatingNavCardHeight = 59;
const double kFloatingNavTotalHeight =
    kFloatingNavCardHeight + _kCenterFabLift;

class FloatingBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;
  // Index that the centre matrimony FAB switches to.
  final int matrimonyIndex;
  // Optional upcoming-session count for the Bible tab. 0 hides the
  // badge. Stays as a single int rather than a per-slot map because
  // Bible is the only tab that surfaces a count today.
  final int bibleBadgeCount;

  const FloatingBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.matrimonyIndex,
    this.bibleBadgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary isolates the nav's paint layer from the
    // scrolling content underneath. When the hide-on-scroll Transform
    // ticks above, only this subtree's compositor layer is touched.
    return RepaintBoundary(
      child: SizedBox(
        // Total widget height includes the lift area above the card
        // so the centre FAB has room to render without being clipped
        // by ancestors.
        height: kFloatingNavTotalHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // The card itself — pinned to the bottom of the SizedBox.
            // The lift area sits above and is transparent except for
            // the FAB.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                height: kFloatingNavCardHeight,
                decoration: BoxDecoration(
                  // Warmer than `surfaceWhite` — sits a hair forward
                  // of the page background without breaking the warm
                  // cream palette.
                  color: AppColors.surfaceCream,
                  borderRadius: BorderRadius.circular(24),
                  // Hairline brown top-edge stroke replaces the prior
                  // drop shadow as the card's visual lift. Reads as a
                  // crisp edge on the parchment surface rather than a
                  // floating sticker.
                  border: Border.all(
                    color:
                        AppColors.deepDarkBrown.withValues(alpha: 0.04),
                    width: 1,
                  ),
                  // Drop shadow intentionally removed — the warm
                  // surface + hairline border provide enough lift on
                  // the parchment background; an additional shadow
                  // would read as a heavy "elevated card" against
                  // the otherwise flat palette.
                ),
                child: Row(
                  children: [
                    _NavSlot(
                      index: 0,
                      currentIndex: currentIndex,
                      icon: AppIcons.home,
                      label: 'Home',
                      onTap: () => onTap(0),
                    ),
                    _NavSlot(
                      index: 1,
                      currentIndex: currentIndex,
                      icon: AppIcons.chats,
                      activeIcon: AppIcons.chat,
                      label: 'Connect',
                      onTap: () => onTap(1),
                    ),
                    // Reserved column under the centre FAB. The FAB
                    // is in its own Positioned layer above, so this
                    // slot stays empty — it only exists to balance
                    // the Row spacing so the four labelled icons sit
                    // evenly around the centre.
                    const Expanded(child: SizedBox.shrink()),
                    _NavSlot(
                      index: 2,
                      currentIndex: currentIndex,
                      icon: AppIcons.bible,
                      label: 'Bible',
                      badgeCount: bibleBadgeCount,
                      onTap: () => onTap(2),
                    ),
                    _NavSlot(
                      index: 3,
                      currentIndex: currentIndex,
                      icon: AppIcons.userOutline,
                      activeIcon: AppIcons.user,
                      label: 'Me',
                      onTap: () => onTap(3),
                    ),
                  ],
                ),
              ),
            ),
            // Centre matrimony FAB — lifted so its lower half sits
            // inside the card and its upper half rises above. left:0/
            // right:0 + Center horizontally locks it to the visual
            // midline of the card, which matches the empty Row slot.
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Center(
                child: _MatrimonyFab(
                  isActive: currentIndex == matrimonyIndex,
                  onTap: () => onTap(matrimonyIndex),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Circular raised button for the Matrimony feature. Rose gradient,
// white separator ring (matches the demo image), and a rose-tinted
// glow shadow that doubles as a "look here" affordance for the new
// feature.
class _MatrimonyFab extends StatelessWidget {
  final bool isActive;
  final VoidCallback onTap;

  const _MatrimonyFab({required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // Subtle scale-up when active so tapping the FAB also feels
      // like a state change, even though there is no label/colour to
      // flip. Same 180ms curve as the other slots for consistency.
      child: AnimatedScale(
        scale: isActive ? 1.06 : 1.0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: Container(
          width: _kCenterFabSize,
          height: _kCenterFabSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [
                AppColors.loveRoseLight,
                AppColors.loveRose,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            // Cream ring (matches the new nav surface) separates the
            // FAB from the card so the overlap reads cleanly. The
            // ring used to be pure white when the nav was white —
            // now that the nav surface is `#FAF5EC`, the ring needs
            // to match or it leaves a sliver of pure-white visible
            // between the FAB and the card.
            border: Border.all(
              color: AppColors.surfaceCream,
              width: 3,
            ),
            boxShadow: [
              // Rose-tinted glow — uses the brighter end of the
              // gradient so the halo reads as the same hot pink as
              // the matrimony hero icon's glow.
              BoxShadow(
                color: AppColors.loveRoseLight.withValues(alpha: 0.40),
                blurRadius: 16,
                spreadRadius: -2,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const Icon(
            AppIcons.heart,
            color: Colors.white,
            size: 22,
          ),
        ),
      ),
    );
  }
}

class _NavSlot extends StatelessWidget {
  final int index;
  final int currentIndex;
  final IconData icon;
  // When the slot has a distinct filled / outline pair (e.g. user /
  // userOutline, chat / chats), `activeIcon` carries the filled
  // variant. Null means the same icon is used in both states and
  // colour alone communicates active.
  final IconData? activeIcon;
  final String label;
  final VoidCallback onTap;
  final int badgeCount;

  const _NavSlot({
    required this.index,
    required this.currentIndex,
    required this.icon,
    required this.label,
    required this.onTap,
    this.activeIcon,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = index == currentIndex;
    final targetColor =
        isActive ? AppColors.deepDarkBrown : AppColors.muted;
    final shownIcon = isActive ? (activeIcon ?? icon) : icon;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // TweenAnimationBuilder smoothly interpolates the icon + label
        // colour between active and inactive states whenever the
        // target changes. Without it, tab switches read as a hard cut;
        // 180ms easeOut gives a premium "settling" feel without
        // delaying the user's perception of "I tapped it".
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: targetColor),
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          builder: (_, color, _) {
            final c = color ?? targetColor;
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon + optional badge. Stack lets the badge sit
                // over the icon corner without expanding the row's
                // hit-area. AnimatedScale gives the active icon a
                // subtle 8% lift — tiny enough to feel responsive
                // without becoming a "bouncing" animation.
                SizedBox(
                  height: 26,
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      AnimatedScale(
                        scale: isActive ? 1.08 : 1.0,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        child: Icon(shownIcon, size: 22, color: c),
                      ),
                      if (badgeCount > 0)
                        Positioned(
                          top: -5,
                          right: -8,
                          // Mirror of the home-screen bell badge —
                          // same growing-stadium recipe so the two
                          // surfaces share one visual system:
                          //   • minWidth == minHeight == 18 →
                          //     single-digit counts render as a
                          //     perfect 18×18 circle (radius height/2
                          //     keeps the ends fully round).
                          //   • As digits are added, padding lets the
                          //     container widen; the radius stays
                          //     constant so the badge morphs into a
                          //     stadium without overflowing the
                          //     surface.
                          //   • "99+" cap caps the widest case at
                          //     ~30 px so the badge never crowds the
                          //     adjacent nav slot.
                          //
                          // Painted in its own Stack layer so it
                          // never picks up the icon's active /
                          // inactive tween — sits at full opacity in
                          // every tab state.
                          child: Container(
                            constraints: const BoxConstraints(
                              minWidth: 18,
                              minHeight: 18,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                            ),
                            decoration: BoxDecoration(
                              color: AppColors.terraCotta,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              badgeCount > 99 ? '99+' : '$badgeCount',
                              maxLines: 1,
                              softWrap: false,
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                                height: 1.05,
                                // Tabular keeps digit widths constant
                                // so the morph from circle → pill
                                // happens cleanly as counts roll over.
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: GoogleFonts.inter(
                    // 10.5 sits between the requested 10 and 11 — at
                    // exactly 10 the label feels cramped under the
                    // 22 px icon, but 11 leans large for a tab label.
                    fontSize: 10.5,
                    // Both states at w600 — colour does the active
                    // work, and the icon AnimatedScale carries the
                    // pressed-state cue. Locking to a single weight
                    // keeps the nav inside the pruned 400/600/700
                    // palette and stops the label from "jumping" 1 px
                    // wider when a tab activates.
                    fontWeight: FontWeight.w600,
                    color: c,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
