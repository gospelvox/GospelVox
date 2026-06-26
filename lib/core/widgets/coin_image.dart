// Renders the 3D coin artwork (assets/coins_images/*) at a given box
// size. Used where we want the premium rendered coins instead of the
// flat painted CoinIcon gem — e.g. the wallet balance chip, pack cards
// and the "you will receive" hero.
//
// Memory note: decode is capped to the display size via cacheWidth so a
// ~360–580px source PNG doesn't sit full-resolution in the image cache
// (see the app size/perf audit — small icons should not hold large
// bitmaps). BoxFit.contain keeps the wider artwork (chest / wallet)
// centred inside a square slot so vertical rhythm stays consistent.

import 'package:flutter/material.dart';

class CoinImage extends StatelessWidget {
  final String asset;
  final double size;

  const CoinImage(this.asset, {super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
    return Image.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      cacheWidth: (size * dpr).round(),
    );
  }
}
