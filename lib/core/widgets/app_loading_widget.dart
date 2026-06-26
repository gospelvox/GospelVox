// Shared loading indicator widget.
//
// Single source of truth for the app's loading animation. Renders the
// branded Lottie spinner (assets/lottie_asset/loading (1).json, a gold
// ring) in place of the stock CircularProgressIndicator everywhere.
//
// Sizing rule: when AppLoader is placed inside a parent with tight
// constraints (e.g. a SizedBox(width: 18, height: 18) inside a button),
// those constraints win and the Lottie shrinks to fit — so the in-button
// loaders keep their original footprint. In loose contexts (Center,
// Padding) the [size] default applies.
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

class AppLoader extends StatelessWidget {
  /// Edge length used when the parent does not impose a tight size.
  /// In-button spinners are wrapped in small SizedBoxes which override this.
  final double size;

  const AppLoader({super.key, this.size = 88});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Lottie.asset(
        'assets/lottie_asset/loading (1).json',
        fit: BoxFit.contain,
      ),
    );
  }
}

/// Runs [task] while a full-screen, non-dismissible Lottie overlay blocks
/// the UI, then guarantees the overlay is torn down. Use for short async
/// actions that have no on-screen surface of their own to host a spinner
/// (e.g. sign-out, which dismisses its sheet before the work begins).
Future<T> runWithAppLoader<T>(
  BuildContext context,
  Future<T> task,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  // Fire-and-forget the dialog; we dismiss it ourselves in `finally` rather
  // than awaiting its route, so the overlay never outlives the task.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    useRootNavigator: true,
    builder: (_) => const PopScope(
      canPop: false,
      child: Center(child: AppLoader(size: 96)),
    ),
  );
  try {
    return await task;
  } finally {
    // The dialog is the top route unless something else already tore the
    // stack down (e.g. an auth-redirect). Only pop when it's still ours.
    if (navigator.canPop()) navigator.pop();
  }
}
