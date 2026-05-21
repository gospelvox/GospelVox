// Coming-soon screen for the Matrimony feature.
//
// Rendered as a child of the UserShellPage IndexedStack, so we do NOT
// draw a bottom navigation bar here — the shell's FloatingBottomNav
// already sits on top. Content gets bottom padding sized to clear that
// floating nav (kFloatingNavTotalHeight + margin + safe-area inset).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/features/user/home/widgets/floating_bottom_nav.dart';

class MatrimonyTab extends StatefulWidget {
  const MatrimonyTab({super.key});

  @override
  State<MatrimonyTab> createState() => _MatrimonyTabState();
}

class _MatrimonyTabState extends State<MatrimonyTab>
    with TickerProviderStateMixin {
  bool _isNotified = false;

  late final AnimationController _breatheController;
  late final AnimationController _floatController;
  late final AnimationController _sparkleController;
  late final AnimationController _shimmerController;
  late final AnimationController _pulseController;

  late final Animation<double> _breatheAnim;
  late final Animation<double> _sparkle1Anim;
  late final Animation<double> _sparkle2Anim;
  late final Animation<double> _sparkle3Anim;

  static const _rose = Color(0xFFFF385C);
  static const _roseDark = Color(0xFFD70466);
  static const _roseMid = Color(0xFFE31C5F);
  static const _amber = Color(0xFFBF8840);
  static const _amberLight = Color(0xFFD4A060);
  static const _textPrimary = Color(0xFF222222);
  static const _textSecondary = Color(0xFF717171);
  static const _textTertiary = Color(0xFFB0B0B0);
  static const _green = Color(0xFF34A853);
  static const _greenBg = Color(0xFFE8F5E9);
  static const _cardBorder = Color(0xFFFFD6CF);

  TextStyle _inter(
    double size,
    FontWeight weight,
    Color color, {
    double? height,
    double? letterSpacing,
  }) {
    return GoogleFonts.inter(
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  @override
  void initState() {
    super.initState();

    _breatheController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);
    _breatheAnim = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(parent: _breatheController, curve: Curves.easeInOut),
    );

    _floatController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat(reverse: true);

    _sparkleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _sparkle1Anim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _sparkleController, curve: Curves.easeInOut),
    );
    _sparkle2Anim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _sparkleController,
        curve: const Interval(0.35, 1.0, curve: Curves.easeInOut),
      ),
    );
    _sparkle3Anim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _sparkleController,
        curve: const Interval(0.7, 1.0, curve: Curves.easeInOut),
      ),
    );

    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _breatheController.dispose();
    _floatController.dispose();
    _sparkleController.dispose();
    _shimmerController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    // Clear the shell's floating bottom nav (card + lifted FAB) plus
    // its bottom margin and a little breathing room.
    final navClearance = kFloatingNavTotalHeight + 12 + bottomInset + 20;

    return Scaffold(
      body: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.0, 0.2, 0.5, 0.8, 1.0],
                colors: [
                  Color(0xFFFFFFFF),
                  Color(0xFFFFF5F3),
                  Color(0xFFFFEFEB),
                  Color(0xFFFFE4DE),
                  Color(0xFFFFD6CC),
                ],
              ),
            ),
          ),
          ..._buildFloatingRings(size),
          ..._buildFloatingDots(size),
          SafeArea(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.only(bottom: navClearance),
              child: Column(
                children: [
                  SizedBox(height: size.height * 0.08),
                  _buildHeroIcon(),
                  const SizedBox(height: 36),
                  _buildTextBlock(size),
                  const SizedBox(height: 36),
                  _buildFeaturesStrip(size),
                  const SizedBox(height: 40),
                  _buildNotifySection(size),
                  const SizedBox(height: 14),
                  GestureDetector(
                    onTap: () => Navigator.of(context).maybePop(),
                    child: Text(
                      'Explore other features',
                      style: _inter(13, FontWeight.w400, _textTertiary),
                    ),
                  ),
                  const SizedBox(height: 40),
                  _buildBottomText(),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildFloatingRings(Size size) {
    return [
      _animatedRing(
        ringSize: 300,
        top: -60,
        right: -size.width * 0.21,
        color: _rose.withValues(alpha: 0.08),
        dxRange: -10,
        dyRange: 15,
        phaseCurve: const Interval(0.0, 1.0, curve: Curves.easeInOut),
      ),
      _animatedRing(
        ringSize: 200,
        bottom: 120,
        left: -60,
        color: _rose.withValues(alpha: 0.08),
        dxRange: 10,
        dyRange: -12,
        phaseCurve: const Interval(0.1, 1.0, curve: Curves.easeInOut),
      ),
      _animatedRing(
        ringSize: 160,
        top: 200,
        right: -40,
        color: _amber.withValues(alpha: 0.08),
        dxRange: -8,
        dyRange: 10,
        phaseCurve: const Interval(0.2, 1.0, curve: Curves.easeInOut),
      ),
      _animatedRing(
        ringSize: 100,
        bottom: 300,
        left: 40,
        color: _amber.withValues(alpha: 0.1),
        dxRange: 6,
        dyRange: -8,
        phaseCurve: const Interval(0.3, 1.0, curve: Curves.easeInOut),
      ),
    ];
  }

  Widget _animatedRing({
    required double ringSize,
    double? top,
    double? bottom,
    double? left,
    double? right,
    required Color color,
    required double dxRange,
    required double dyRange,
    required Curve phaseCurve,
  }) {
    return AnimatedBuilder(
      animation: _floatController,
      builder: (context, child) {
        final t = CurvedAnimation(
          parent: _floatController,
          curve: phaseCurve,
        ).value;
        return Positioned(
          top: top != null ? top + (dyRange * t) : null,
          bottom: bottom != null ? bottom + (dyRange * t) : null,
          left: left != null ? left + (dxRange * t) : null,
          right: right != null ? right + (dxRange * t) : null,
          child: Container(
            width: ringSize,
            height: ringSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 1.5),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildFloatingDots(Size size) {
    return [
      _animatedDot(
        8,
        140,
        null,
        50,
        null,
        _rose.withValues(alpha: 0.06),
        0.0,
      ),
      _animatedDot(
        6,
        300,
        null,
        null,
        60,
        _rose.withValues(alpha: 0.06),
        0.3,
      ),
      _animatedDot(
        10,
        null,
        250,
        80,
        null,
        _rose.withValues(alpha: 0.06),
        0.15,
      ),
      _animatedDot(
        5,
        400,
        null,
        160,
        null,
        _amber.withValues(alpha: 0.1),
        0.6,
      ),
      _animatedDot(
        7,
        null,
        180,
        null,
        100,
        _amber.withValues(alpha: 0.08),
        0.45,
      ),
    ];
  }

  Widget _animatedDot(
    double dotSize,
    double? top,
    double? bottom,
    double? left,
    double? right,
    Color color,
    double phase,
  ) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, child) {
          final t = Curves.easeInOut.transform(
            ((_pulseController.value + phase) % 1.0),
          );
          final scale = 1.0 + (0.5 * t);
          final opacity = 0.3 + (0.7 * t);
          return Transform.scale(
            scale: scale,
            child: Opacity(
              opacity: opacity,
              child: Container(
                width: dotSize,
                height: dotSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildHeroIcon() {
    return AnimatedBuilder(
      animation: _breatheAnim,
      builder: (context, child) {
        return Transform.scale(
          scale: _breatheAnim.value,
          child: SizedBox(
            width: 140,
            height: 140,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        _rose.withValues(alpha: 0.08),
                        _rose.withValues(alpha: 0.03),
                      ],
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 88,
                      height: 88,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            _rose.withValues(alpha: 0.12),
                            _rose.withValues(alpha: 0.05),
                          ],
                        ),
                      ),
                      child: Center(
                        child: Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [_rose, _roseDark],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: _rose.withValues(alpha: 0.3),
                                blurRadius: 32,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.favorite_rounded,
                            size: 28,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                _buildSparkle(
                  top: -8,
                  right: 10,
                  sparkleSize: 14,
                  color: _amber,
                  animation: _sparkle1Anim,
                ),
                _buildSparkle(
                  bottom: 5,
                  left: 5,
                  sparkleSize: 10,
                  color: _rose,
                  animation: _sparkle2Anim,
                ),
                _buildSparkle(
                  top: 20,
                  left: -5,
                  sparkleSize: 8,
                  color: _amberLight,
                  animation: _sparkle3Anim,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSparkle({
    double? top,
    double? bottom,
    double? left,
    double? right,
    required double sparkleSize,
    required Color color,
    required Animation<double> animation,
  }) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) {
          final t = math.sin(animation.value * math.pi);
          return Transform.scale(
            scale: 0.5 + (0.5 * t),
            child: Transform.rotate(
              angle: animation.value * 0.35,
              child: Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: CustomPaint(
                  size: Size(sparkleSize, sparkleSize),
                  painter: _SparklePainter(color: color),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTextBlock(Size size) {
    // Headline style — pure typographic style (no color) so the
    // gradient TextSpan can attach a Paint shader via `foreground`
    // without conflicting with `color`.
    final headlineBase = GoogleFonts.inter(
      fontSize: 30,
      fontWeight: FontWeight.w800,
      height: 1.2,
      letterSpacing: -0.5,
      color: _textPrimary,
    );
    final headlineGradient = GoogleFonts.inter(
      fontSize: 30,
      fontWeight: FontWeight.w800,
      height: 1.2,
      letterSpacing: -0.5,
    ).copyWith(
      foreground: Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_rose, _roseDark],
        ).createShader(const Rect.fromLTWH(0, 0, 320, 80)),
    );

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: size.width * 0.06),
      child: Column(
        children: [
          Text(
            'COMING SOON',
            style: _inter(11, FontWeight.w600, _amber, letterSpacing: 3.0),
          ),
          const SizedBox(height: 12),
          // Single wrapping headline. The explicit '\n' between
          // "God-" and "given" forces the exact two-line layout
          // ("Find your God-" / "given partner") that the design
          // calls for, instead of relying on width-driven wrapping
          // that would shift between phone sizes.
          Text.rich(
            TextSpan(
              style: headlineBase,
              children: [
                const TextSpan(text: 'Find your '),
                TextSpan(text: 'God-\ngiven', style: headlineGradient),
                const TextSpan(text: ' partner'),
              ],
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            'Gospel Vox Matrimony is being crafted with care. A trusted Christian community to help you find your life partner through faith and family values.',
            textAlign: TextAlign.center,
            style: _inter(15, FontWeight.w400, _textSecondary, height: 1.6),
          ),
        ],
      ),
    );
  }

  Widget _buildFeaturesStrip(Size size) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: size.width * 0.064),
      child: Row(
        children: [
          _featureItem(
            icon: Icons.people_outline,
            iconColor: _rose,
            bgColor: _rose.withValues(alpha: 0.08),
            label: 'Verified Christian\nprofiles',
          ),
          const SizedBox(width: 20),
          _featureItem(
            icon: Icons.shield_outlined,
            iconColor: _amber,
            bgColor: _amber.withValues(alpha: 0.08),
            label: 'Safe and private\nmatching',
          ),
          const SizedBox(width: 20),
          _featureItem(
            icon: Icons.check_circle_outline,
            iconColor: _green,
            bgColor: _green.withValues(alpha: 0.08),
            label: 'Denomination\nbased search',
          ),
        ],
      ),
    );
  }

  Widget _featureItem({
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required String label,
  }) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 20, color: iconColor),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: _inter(11, FontWeight.w500, _textSecondary, height: 1.3),
          ),
        ],
      ),
    );
  }

  Widget _buildNotifySection(Size size) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: size.width * 0.085),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, anim) {
          return FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.1),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          );
        },
        child: _isNotified ? _buildConfirmationCard() : _buildNotifyButton(),
      ),
    );
  }

  Widget _buildNotifyButton() {
    return GestureDetector(
      key: const ValueKey('notify'),
      onTap: () => setState(() => _isNotified = true),
      child: Container(
        width: double.infinity,
        height: 52,
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(
            colors: [Color(0xFFE61E4D), _roseMid, _roseDark],
          ),
        ),
        child: Stack(
          children: [
            AnimatedBuilder(
              animation: _shimmerController,
              builder: (context, child) {
                return Positioned(
                  left: (_shimmerController.value * 3 - 1) * 375,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 200,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.white.withValues(alpha: 0.15),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.notifications_outlined,
                    size: 18,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Notify me when it launches',
                    style: _inter(15, FontWeight.w600, Colors.white),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfirmationCard() {
    return Container(
      key: const ValueKey('confirmed'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _cardBorder, width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: _greenBg,
            ),
            child: const Icon(Icons.check, size: 18, color: _green),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: _inter(13, FontWeight.w400, _textPrimary, height: 1.5),
                children: [
                  const TextSpan(text: "You'll be the "),
                  TextSpan(
                    text: 'first to know',
                    style: _inter(13, FontWeight.w700, _rose),
                  ),
                  const TextSpan(
                    text: ' when Gospel Vox Matrimony launches.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomText() {
    return Column(
      children: [
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: _inter(11, FontWeight.w400, _textTertiary, height: 1.6),
            children: [
              const TextSpan(text: 'Launching '),
              TextSpan(
                text: 'Phase 2',
                style: _inter(11, FontWeight.w600, _rose),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Crafted with prayer and purpose',
          style: _inter(11, FontWeight.w400, _textTertiary),
        ),
      ],
    );
  }
}

class _SparklePainter extends CustomPainter {
  final Color color;

  _SparklePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;
    final ir = r * 0.3;

    final path = Path();
    for (int i = 0; i < 4; i++) {
      final angle = (i * math.pi / 2) - (math.pi / 2);
      final innerAngle = angle + (math.pi / 4);

      if (i == 0) {
        path.moveTo(cx + r * math.cos(angle), cy + r * math.sin(angle));
      } else {
        path.lineTo(cx + r * math.cos(angle), cy + r * math.sin(angle));
      }
      path.lineTo(
        cx + ir * math.cos(innerAngle),
        cy + ir * math.sin(innerAngle),
      );
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklePainter oldDelegate) =>
      color != oldDelegate.color;
}
