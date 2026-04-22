// Reusable gold coin badge built from pure Flutter primitives — no
// image asset, so it scales crisply at any size and stays in sync
// with the brand palette if we ever retune amber values.

import 'package:flutter/material.dart';

class CoinIcon extends StatelessWidget {
  final double size;

  const CoinIcon({super.key, this.size = 40});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFE8C88A),
            Color(0xFFD4A060),
            Color(0xFFBF8840),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFD4A060).withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: size * 0.4,
          height: size * 0.4,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.35),
          ),
          child: Icon(
            Icons.diamond_outlined,
            size: size * 0.28,
            color: Colors.white.withValues(alpha: 0.9),
          ),
        ),
      ),
    );
  }
}
