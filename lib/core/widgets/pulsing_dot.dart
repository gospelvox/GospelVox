// Shared pulsing-dot widget. A tiny breathing animation used to flag
// "LIVE NOW" status across the app — bible session cards, the priest
// detail header, the call-like overlay, the bible-tab "N live" hint.
//
// Implementation:
//   • SingleTickerProviderStateMixin keeps the animation cheap (one
//     ticker per dot, no shared resource contention).
//   • A solid dot in the centre + an animated ring behind it. The
//     ring scales 0.85→1.25 and fades 1.0→0.35 in sync, producing
//     the "heartbeat" silhouette without a third animation.
//   • Curve is easeInOut so the dot never has a hard discontinuity
//     at the loop boundary — a linear curve produced a visible
//     "click" at every cycle.

import 'package:flutter/material.dart';

class PulsingDot extends StatefulWidget {
  final double size;
  final Color color;
  const PulsingDot({
    super.key,
    this.size = 8,
    this.color = const Color(0xFFE53E3E),
  });

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.85, end: 1.25).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    _opacity = Tween<double>(begin: 1.0, end: 0.35).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        return SizedBox(
          width: widget.size * 1.6,
          height: widget.size * 1.6,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: _opacity.value * 0.4,
                child: Transform.scale(
                  scale: _scale.value,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color,
                    ),
                  ),
                ),
              ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
