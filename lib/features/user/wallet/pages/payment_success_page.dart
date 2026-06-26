// Celebratory post-purchase screen. Shown only once verifyCoinPurchase
// returns a success — so by the time the user sees this, the coins
// are already credited server-side and the balance stream will have
// updated. The screen is effectively a victory lap, not a loading
// state.
//
// The "blessing scene" at the bottom (soft layered mountains, a cross
// on the summit, a winding path and leaf sprigs in both corners) is
// painted entirely in code via _BlessingScenePainter — NOT a bitmap.
// That keeps it pixel-crisp on every device (phone + tablet), adds
// nothing to the app download size, and is driven from the same warm
// brand tokens as the rest of the UI so the colours stay in sync.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:lottie/lottie.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

class PaymentSuccessPage extends StatefulWidget {
  final int coinsPurchased;
  final int newBalance;

  const PaymentSuccessPage({
    super.key,
    required this.coinsPurchased,
    required this.newBalance,
  });

  @override
  State<PaymentSuccessPage> createState() => _PaymentSuccessPageState();
}

class _PaymentSuccessPageState extends State<PaymentSuccessPage>
    with TickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeAnimation;

  // Drives the success Lottie. Kept separate from _controller because we
  // stop it partway (just before the animation fades the mark out) and
  // hold there, rather than running its full timeline.
  late final AnimationController _lottieController;

  double _continueScale = 1.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    // Duration is set from the composition in Lottie's onLoaded callback.
    _lottieController = AnimationController(vsync: this);

    // The success tick is now a Lottie that draws itself once, so the
    // controller only drives the supporting fade-ins. Text + card + the
    // sparkles around the tick fade in after the check has begun
    // drawing, so the eye lands on the tick first, then reads the
    // message.
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _lottieController.dispose();
    super.dispose();
  }

  String _formatCoins(int coins) {
    if (coins >= 1000) return NumberFormat('#,###').format(coins);
    return coins.toString();
  }

  void _onContinue() {
    // Return to the user home, NOT back to the wallet. context.go('/user')
    // resets the stack to the home shell, dropping both this success page
    // and the wallet beneath it — after buying coins the user wants to be
    // back in the app, not staring at the wallet again. The new balance is
    // already credited server-side, so the next time they open the wallet
    // it loads fresh. (PopScope(canPop:false) only blocks the hardware
    // back gesture — this explicit go() is unaffected.)
    context.go('/user');
  }

  @override
  Widget build(BuildContext context) {
    final screenH = MediaQuery.sizeOf(context).height;
    // The decorative scene fills the bottom band of the screen and
    // fades up into the page. Clamp so it never dominates a tall tablet
    // nor crowds the card on a short phone.
    final sceneHeight = (screenH * 0.45).clamp(300.0, 520.0);

    // PopScope blocks the hardware back button mid-animation. Without
    // it, a user who taps back during the first 300ms sees a janky
    // half-drawn tick and misses the confirmation entirely.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Stack(
          children: [
            // ── Warm base wash: page cream at the top easing into a
            // soft sand at the very bottom so the scene sits on warmth,
            // not a hard seam.
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      AppColors.background,
                      AppColors.background,
                      Color(0xFFF3E3C6),
                    ],
                    stops: [0.0, 0.55, 1.0],
                  ),
                ),
              ),
            ),

            // ── Painted blessing scene, anchored to the bottom and
            // feathered into the page at its top edge.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: sceneHeight,
              child: IgnorePointer(
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.white, Colors.white],
                    stops: [0.0, 0.35, 1.0],
                  ).createShader(rect),
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: const _BlessingScenePainter(),
                  ),
                ),
              ),
            ),

            // ── Foreground content. Capped to a comfortable column width
            // and centred so it stays composed on a tablet while still
            // filling a phone edge-to-edge.
            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    // Scroll-fallback: the Spacers still centre the content
                    // on a normal screen, but on a very short device (or a
                    // large system text scale) the fixed-height tick + card
                    // + button no longer overflow — the column scrolls.
                    child: LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                              minHeight: constraints.maxHeight),
                          child: IntrinsicHeight(
                            child: Column(
                              children: [
                            const Spacer(flex: 3),
                            _buildCheckmark(),
                            const SizedBox(height: 28),
                            _buildSuccessText(),
                            const SizedBox(height: 34),
                            _buildCoinsCard(),
                            const Spacer(flex: 4),
                            _buildMissionNote(),
                            const SizedBox(height: 22),
                            _buildContinueButton(),
                            const SizedBox(height: 20),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCheckmark() {
    return SizedBox(
      width: 220,
      height: 192,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // Tasteful gold confetti / sparkles around the tick.
          _sparkleStar(top: 4, left: 22, size: 16),
          _sparkleStar(top: 12, right: 18, size: 13),
          _sparkleDot(top: 40, left: 6, size: 7),
          _sparkleDot(bottom: 22, right: 10, size: 9),
          _sparkleDot(bottom: 8, left: 36, size: 6),
          _sparkleStar(bottom: 2, right: 40, size: 11),

          // Self-drawing success checkmark. The animation draws the
          // circle + check by ~frame 36, then FADES THE WHOLE MARK OUT
          // from frame 50→62 — so holding the true last frame shows
          // nothing. We stop at ~frame 48 (0.66 of the timeline): fully
          // drawn, just before the fade, and hold there.
          Lottie.asset(
            'assets/lottie_asset/tina-demo-success.json',
            controller: _lottieController,
            width: 172,
            height: 172,
            fit: BoxFit.contain,
            onLoaded: (composition) {
              _lottieController
                ..duration = composition.duration
                ..animateTo(0.66);
            },
          ),
        ],
      ),
    );
  }

  Widget _sparkleDot({
    double? top,
    double? bottom,
    double? left,
    double? right,
    required double size,
  }) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.amberGold.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }

  Widget _sparkleStar({
    double? top,
    double? bottom,
    double? left,
    double? right,
    required double size,
  }) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: AppIcon(
          AppIcons.starFilled,
          size: size,
          color: AppColors.amberGold.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _buildSuccessText() {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Column(
        children: [
          Text(
            "Payment Successful",
            style: GoogleFonts.inter(
              fontSize: 25,
              fontWeight: FontWeight.w800,
              color: AppColors.deepDarkBrown,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Your coins have been added to your account",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoinsCard() {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
        decoration: BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.circular(AppRadius.large),
          border: Border.all(
            color: AppColors.amberGold.withValues(alpha: 0.20),
          ),
          boxShadow: kWarmCardShadow,
        ),
        child: Column(
          children: [
            Row(
              children: [
                Image.asset(
                  'assets/coins_images/single_coins.png',
                  width: 58,
                  height: 58,
                  filterQuality: FilterQuality.medium,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "+${_formatCoins(widget.coinsPurchased)}",
                        style: GoogleFonts.inter(
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          color: AppColors.deepDarkBrown,
                          height: 1.05,
                          letterSpacing: -0.8,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        "coins credited",
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _dividerWithDiamond(),
            const SizedBox(height: 18),
            Row(
              children: [
                Text(
                  "New Balance",
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(width: 12),
                // Right-aligned value that shrinks gracefully — a very
                // large balance ("1,000,000 coins") ellipsises instead
                // of overflowing the card.
                Expanded(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Image.asset(
                        'assets/coins_images/single_coins.png',
                        width: 24,
                        height: 24,
                        filterQuality: FilterQuality.medium,
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          "${_formatCoins(widget.newBalance)} coins",
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppColors.primaryBrown,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dividerWithDiamond() {
    Widget line() => Expanded(
          child: Container(
            height: 1,
            color: AppColors.amberGold.withValues(alpha: 0.18),
          ),
        );
    return Row(
      children: [
        line(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: AppColors.amberGold.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
        line(),
      ],
    );
  }

  Widget _buildMissionNote() {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: Column(
        children: [
          Text(
            "Thank you for supporting our mission.\nTogether, we're spreading the Good News.",
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13.5,
              fontWeight: FontWeight.w500,
              color: AppColors.primaryBrown.withValues(alpha: 0.78),
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 26,
                height: 1,
                color: AppColors.amberGold.withValues(alpha: 0.4),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: AppIcon(
                  AppIcons.heart,
                  size: 12,
                  color: AppColors.amberGold,
                ),
              ),
              Container(
                width: 26,
                height: 1,
                color: AppColors.amberGold.withValues(alpha: 0.4),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildContinueButton() {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _continueScale = 0.97),
        onTapUp: (_) => setState(() => _continueScale = 1.0),
        onTapCancel: () => setState(() => _continueScale = 1.0),
        onTap: _onContinue,
        child: AnimatedScale(
          scale: _continueScale,
          duration: const Duration(milliseconds: 100),
          child: Container(
            width: double.infinity,
            height: 56,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF7C4634),
                  AppColors.primaryBrown,
                  Color(0xFF5A2E20),
                ],
              ),
              borderRadius: BorderRadius.circular(AppRadius.medium),
              border: Border.all(
                color: AppColors.amberGold.withValues(alpha: 0.45),
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primaryBrown.withValues(alpha: 0.35),
                  blurRadius: 22,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Continue",
                    style: GoogleFonts.inter(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Icon(
                    Icons.arrow_forward_rounded,
                    size: 19,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the "blessing scene" — layered mountains, a winding path up
/// to a cross on the central summit, leaf sprigs in both bottom corners
/// and a few sparkles. Everything is vector, so it renders crisp at any
/// resolution and weighs nothing on disk. Colours follow the
/// illustration brief, anchored to the warm brand palette.
class _BlessingScenePainter extends CustomPainter {
  const _BlessingScenePainter();

  // Illustration palette (warm sand → gold), expressed so the scene
  // reads as one surface with the cream page above it.
  static const Color _farRange = Color(0xFFEFE0C8);
  static const Color _midRange = Color(0xFFEAD2A8);
  static const Color _frontHill = Color(0xFFE2BE86);
  static const Color _pathFill = Color(0xFFFFF8EE);
  static const Color _crossHi = Color(0xFFF7D69B);
  static const Color _leafShadow = Color(0xFFC28D49);
  static const Color _sparkle = Color(0xFFFFF4D7);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final summit = Offset(w * 0.5, h * 0.50);

    // ── Mountains, back to front ───────────────────────────────
    _fillRidge(canvas, size, const [
      Offset(0, 0.50),
      Offset(0.22, 0.40),
      Offset(0.45, 0.48),
      Offset(0.70, 0.38),
      Offset(1, 0.47),
    ], _farRange.withValues(alpha: 0.40));

    _fillRidge(canvas, size, const [
      Offset(0, 0.60),
      Offset(0.26, 0.49),
      Offset(0.5, 0.57),
      Offset(0.76, 0.46),
      Offset(1, 0.58),
    ], _midRange.withValues(alpha: 0.60));

    _fillRidge(canvas, size, const [
      Offset(0, 0.74),
      Offset(0.20, 0.68),
      Offset(0.36, 0.71),
      Offset(0.5, 0.50),
      Offset(0.64, 0.70),
      Offset(0.82, 0.66),
      Offset(1, 0.73),
    ], _frontHill.withValues(alpha: 0.78));

    // ── Winding path up to the summit ──────────────────────────
    _drawTrail(canvas, size, summit);

    // ── Cross on the summit, with a soft glow ──────────────────
    _drawCross(canvas, summit, h);

    // ── Leaf sprigs rising from both bottom corners ────────────
    _drawLeafSprig(canvas, Offset(w * 0.015, h), -1, h);
    _drawLeafSprig(canvas, Offset(w * 0.985, h), 1, h);

    // ── Sparkles ───────────────────────────────────────────────
    _drawSparkle(canvas, Offset(w * 0.30, h * 0.33), 5.5);
    _drawSparkle(canvas, Offset(w * 0.70, h * 0.29), 7.0);
    _drawSparkle(canvas, Offset(w * 0.60, h * 0.43), 4.0);
    _drawSparkle(canvas, Offset(w * 0.38, h * 0.49), 3.5);
  }

  // Smooth filled hill from a list of fractional ridge points
  // (x, y in 0..1 of the canvas). Uses midpoint quadratics so the
  // ridgeline reads as rolling rather than jagged.
  void _fillRidge(Canvas canvas, Size size, List<Offset> frac, Color color) {
    final pts = frac
        .map((f) => Offset(f.dx * size.width, f.dy * size.height))
        .toList();
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length - 1; i++) {
      final xc = (pts[i].dx + pts[i + 1].dx) / 2;
      final yc = (pts[i].dy + pts[i + 1].dy) / 2;
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, xc, yc);
    }
    final last = pts.last;
    path.quadraticBezierTo(last.dx, last.dy, last.dx, last.dy);
    path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawTrail(Canvas canvas, Size size, Offset summit) {
    final w = size.width;
    final h = size.height;
    final topY = summit.dy + h * 0.02;
    // A gently winding ribbon, wide at the foot and tapering to the
    // base of the cross.
    final path = Path()
      ..moveTo(w * 0.42, h)
      ..cubicTo(w * 0.40, h * 0.86, w * 0.60, h * 0.80, w * 0.52, h * 0.66)
      ..cubicTo(w * 0.46, h * 0.58, summit.dx - 4, h * 0.54, summit.dx - 3, topY)
      ..lineTo(summit.dx + 3, topY)
      ..cubicTo(summit.dx + 4, h * 0.54, w * 0.54, h * 0.58, w * 0.60, h * 0.66)
      ..cubicTo(w * 0.70, h * 0.80, w * 0.52, h * 0.86, w * 0.58, h)
      ..close();
    canvas.drawPath(path, Paint()..color = _pathFill.withValues(alpha: 0.85));
  }

  void _drawCross(Canvas canvas, Offset summit, double h) {
    // Soft glow behind the cross.
    canvas.drawCircle(
      Offset(summit.dx, summit.dy - h * 0.06),
      h * 0.10,
      Paint()
        ..color = const Color(0xFFFFF5DD).withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    final ch = h * 0.16; // overall cross height
    final t = ch * 0.075; // bar thickness
    final top = summit.dy - ch;
    final r = Radius.circular(t * 0.4);
    final gold = Paint()..color = AppColors.amberGold;

    final vBar = RRect.fromRectAndRadius(
      Rect.fromLTWH(summit.dx - t / 2, top, t, ch),
      r,
    );
    final armY = top + ch * 0.30;
    final armW = ch * 0.52;
    final hBar = RRect.fromRectAndRadius(
      Rect.fromLTWH(summit.dx - armW / 2, armY, armW, t),
      r,
    );
    canvas
      ..drawRRect(vBar, gold)
      ..drawRRect(hBar, gold);

    // Thin highlight down the left face of the upright.
    canvas.drawLine(
      Offset(summit.dx - t * 0.18, top + t),
      Offset(summit.dx - t * 0.18, top + ch - t),
      Paint()
        ..color = _crossHi
        ..strokeWidth = t * 0.3
        ..strokeCap = StrokeCap.round,
    );
  }

  // A frond rising from a bottom corner. [dir] is the outward direction
  // (-1 = leans toward the left edge, +1 = right edge).
  void _drawLeafSprig(Canvas canvas, Offset base, int dir, double h) {
    final stemLen = h * 0.55;
    final tip = Offset(base.dx - dir * h * 0.06, base.dy - stemLen);
    final ctrl = Offset(base.dx + dir * h * 0.05, base.dy - stemLen * 0.45);

    final stem = Path()
      ..moveTo(base.dx, base.dy)
      ..quadraticBezierTo(ctrl.dx, ctrl.dy, tip.dx, tip.dy);
    canvas.drawPath(
      stem,
      Paint()
        ..color = AppColors.amberGold.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.012
        ..strokeCap = StrokeCap.round,
    );

    const count = 7;
    for (var i = 1; i <= count; i++) {
      final t = i / (count + 1);
      final at = _quad(base, ctrl, tip, t);
      final leafLen = h * (0.155 - 0.009 * i);
      // Alternate the fan angle so the frond reads as full, not a comb.
      final angle = (i.isEven) ? 0.55 : 0.95;
      final leafTip = Offset(
        at.dx + dir * leafLen * math.sin(angle),
        at.dy - leafLen * math.cos(angle),
      );
      _drawLeaf(canvas, at, leafTip, leafLen * 0.34);
    }
  }

  void _drawLeaf(Canvas canvas, Offset start, Offset tip, double width) {
    final dx = tip.dx - start.dx;
    final dy = tip.dy - start.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    final px = -dy / len * width; // perpendicular offset
    final py = dx / len * width;
    final mid = Offset((start.dx + tip.dx) / 2, (start.dy + tip.dy) / 2);

    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..quadraticBezierTo(mid.dx + px, mid.dy + py, tip.dx, tip.dy)
      ..quadraticBezierTo(mid.dx - px, mid.dy - py, start.dx, start.dy)
      ..close();
    canvas.drawPath(
      path,
      Paint()..color = AppColors.amberGold.withValues(alpha: 0.82),
    );
    // Central vein for a touch of depth.
    canvas.drawLine(
      start,
      tip,
      Paint()
        ..color = _leafShadow.withValues(alpha: 0.6)
        ..strokeWidth = width * 0.16
        ..strokeCap = StrokeCap.round,
    );
  }

  // Point on a quadratic bezier at parameter [t].
  Offset _quad(Offset p0, Offset p1, Offset p2, double t) {
    final u = 1 - t;
    return Offset(
      u * u * p0.dx + 2 * u * t * p1.dx + t * t * p2.dx,
      u * u * p0.dy + 2 * u * t * p1.dy + t * t * p2.dy,
    );
  }

  void _drawSparkle(Canvas canvas, Offset at, double r) {
    // Faint glow.
    canvas.drawCircle(
      at,
      r * 1.6,
      Paint()
        ..color = const Color(0xFFFFE8B5).withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // Four-point star.
    final path = Path()
      ..moveTo(at.dx, at.dy - r)
      ..quadraticBezierTo(at.dx + r * 0.18, at.dy - r * 0.18, at.dx + r, at.dy)
      ..quadraticBezierTo(at.dx + r * 0.18, at.dy + r * 0.18, at.dx, at.dy + r)
      ..quadraticBezierTo(at.dx - r * 0.18, at.dy + r * 0.18, at.dx - r, at.dy)
      ..quadraticBezierTo(at.dx - r * 0.18, at.dy - r * 0.18, at.dx, at.dy - r)
      ..close();
    canvas.drawPath(path, Paint()..color = _sparkle.withValues(alpha: 0.9));
  }

  @override
  bool shouldRepaint(covariant _BlessingScenePainter oldDelegate) => false;
}
