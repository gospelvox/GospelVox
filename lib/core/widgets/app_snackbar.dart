// Custom floating snackbar — drops from the top with brand styling
//
// Why we don't use ScaffoldMessenger: the default SnackBar is anchored to the
// bottom Material Scaffold, has its own clunky animation, and ignores our
// theme. Using an OverlayEntry lets us slide in from the top of the screen,
// match the warm beige/brown palette, and stack consistently across pages
// regardless of the widget tree.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

// Forest green for success; AppColors has no proper "success-green" token.
const Color _kSuccessGreen = Color(0xFF2E7D4F);

enum _SnackType { error, success, info }

class AppSnackBar {
  static GlobalKey<_SnackBarOverlayState>? _currentKey;
  static OverlayEntry? _currentEntry;

  /// Show a destructive/error snackbar (red).
  /// Example: AppSnackBar.error(context, "Invalid credentials.");
  static void error(BuildContext context, String message) =>
      _show(context, message, _SnackType.error);

  /// Show a positive/success snackbar (green).
  /// Example: AppSnackBar.success(context, "Signed in successfully");
  static void success(BuildContext context, String message) =>
      _show(context, message, _SnackType.success);

  /// Show an informational snackbar (brown).
  /// Example: AppSnackBar.info(context, "Tap a card to choose a role");
  static void info(BuildContext context, String message) =>
      _show(context, message, _SnackType.info);

  static void _show(BuildContext context, String message, _SnackType type) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    // Dismiss any existing snackbar immediately so they don't stack.
    _hideImmediately();

    final key = GlobalKey<_SnackBarOverlayState>();
    late OverlayEntry entry;

    entry = OverlayEntry(
      builder: (_) => _SnackBarOverlay(
        key: key,
        message: message,
        type: type,
        onRemove: () {
          if (entry.mounted) entry.remove();
          if (_currentEntry == entry) {
            _currentEntry = null;
            _currentKey = null;
          }
        },
      ),
    );

    _currentEntry = entry;
    _currentKey = key;
    overlay.insert(entry);
  }

  static void _hideImmediately() {
    final state = _currentKey?.currentState;
    if (state != null) {
      state.dismiss();
    } else {
      _currentEntry?.remove();
      _currentEntry = null;
      _currentKey = null;
    }
  }
}

class _SnackBarOverlay extends StatefulWidget {
  final String message;
  final _SnackType type;
  final VoidCallback onRemove;

  const _SnackBarOverlay({
    super.key,
    required this.message,
    required this.type,
    required this.onRemove,
  });

  @override
  State<_SnackBarOverlay> createState() => _SnackBarOverlayState();
}

class _SnackBarOverlayState extends State<_SnackBarOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  Timer? _autoDismissTimer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      reverseDuration: const Duration(milliseconds: 200),
    );
    _controller.forward();
    _autoDismissTimer =
        Timer(const Duration(milliseconds: 3500), dismiss);
  }

  Future<void> dismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    _autoDismissTimer?.cancel();
    try {
      await _controller.reverse();
    } catch (_) {
      // controller may have been disposed mid-animation
    }
    if (!mounted) return;
    widget.onRemove();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Color get _bgColor {
    switch (widget.type) {
      case _SnackType.error:
        return AppColors.error;
      case _SnackType.success:
        return _kSuccessGreen;
      case _SnackType.info:
        return AppColors.primaryBrown;
    }
  }

  IconData get _icon {
    switch (widget.type) {
      case _SnackType.error:
        return Icons.error_outline;
      case _SnackType.success:
        return Icons.check_circle_outline;
      case _SnackType.info:
        return Icons.info_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final progress = _controller.value;
        final fadeOpacity =
            Curves.easeOut.transform(progress.clamp(0.0, 1.0));
        final slideY =
            (1.0 - Curves.easeOutQuart.transform(progress.clamp(0.0, 1.0))) *
                -60.0;

        return Positioned(
          top: topPadding + 16 + slideY,
          left: 16,
          right: 16,
          child: Opacity(
            opacity: fadeOpacity,
            child: child,
          ),
        );
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56, maxHeight: 96),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _bgColor,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                blurRadius: 20,
                offset: const Offset(0, 8),
                color: Colors.black.withValues(alpha: 0.118),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(_icon, color: Colors.white, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.message,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.warmBeige,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: dismiss,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
