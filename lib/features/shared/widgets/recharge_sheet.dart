// In-app top-up sheet shown when the user runs low mid-session or
// fails the 5-minute preflight before starting one. Used by:
//   • voice_call_view.dart  (mid-call low-balance prompt)
//   • chat_session_view.dart (mid-chat low-balance prompt)
//   • session_preflight.dart (pre-session balance gate)
//
// The visual has two goals:
//   1. Hero up the best-value pack so the user doesn't have to
//      pick — a single tap on "Proceed" should close the gap.
//   2. Cap the visible packs to 4 so a low-balance user isn't
//      forced to read a long catalogue. The full pack list lives
//      on the dedicated Wallet page, reachable via "See all plans".
//
// What this file owns vs delegates:
//   • Owns: the visual sheet, local pack selection state, Razorpay
//     bridge, success/failure handling.
//   • Delegates: the contextual subtitle ("Add ₹X to continue...")
//     is passed in by the caller via `infoHeadline` — voice/chat
//     decide their own wording so the sheet stays caller-agnostic.

import 'dart:math' as math;

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/config/iap_products.dart';
import 'package:gospel_vox/core/services/iap_service.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';
import 'package:gospel_vox/features/user/wallet/data/wallet_repository.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

class RechargeSheet extends StatefulWidget {
  // Current wallet balance — displayed in the "Current balance" info
  // strip. Defaults to 0 if the caller doesn't have a reading.
  final int? currentBalance;
  // Subtitle under the title. The 3 callers already build a
  // contextual "Add ₹X more to keep your chat going" string; the
  // sheet just renders whatever they pass.
  final String? infoHeadline;
  // Kept on the API surface so callers still compile, but the new
  // layout has no slot for a third line — intentionally unused.
  // ignore: unused_element_parameter
  final String? infoSubtext;

  const RechargeSheet({
    super.key,
    this.currentBalance,
    this.infoHeadline,
    this.infoSubtext,
  });

  static Future<bool?> show(
    BuildContext context, {
    int? currentBalance,
    String? infoHeadline,
    String? infoSubtext,
  }) {
    // Cap sheet height at 92% of screen so on short phones / when
    // text scaling pushes content tall, the sheet still reads as a
    // sheet (not a full page) and the SingleChildScrollView inside
    // takes over.
    final mq = MediaQuery.of(context);
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      // Snappier enter/exit than the Material default (250/200 ms).
      // 180 ms enter + decelerate curve reads as immediate without
      // the slow "creeping up" feel the stock animation has — paired
      // with the pre-warmed pack cache below, the user experiences
      // the sheet as instant content from the moment they tap Call.
      sheetAnimationStyle: AnimationStyle(
        duration: const Duration(milliseconds: 180),
        reverseDuration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      constraints: BoxConstraints(
        // 0.88 leaves a visible strip of the underlying screen at
        // the top so the sheet reads as a sheet (not a full page).
        maxHeight: mq.size.height * 0.88,
        // Tablets: don't let the sheet stretch edge-to-edge. 520
        // matches the comfortable phone-portrait width users are
        // already used to from every other sheet in the app.
        maxWidth: math.min(mq.size.width, 520),
      ),
      builder: (_) => RechargeSheet(
        currentBalance: currentBalance,
        infoHeadline: infoHeadline,
        infoSubtext: infoSubtext,
      ),
    );
  }

  @override
  State<RechargeSheet> createState() => _RechargeSheetState();
}

class _RechargeSheetState extends State<RechargeSheet> {
  late final WalletRepository _wallet = sl<WalletRepository>();
  late final IapService _iap = sl<IapService>();
  StreamSubscription<IapOutcome>? _iapOutcomeSubscription;

  bool _loading = true;
  String? _error;
  List<CoinPackModel> _packs = const [];
  CoinPackModel? _selected;

  // Lock against double-tap of Proceed while a buy is dispatching
  // to the Play sheet or the server verify is in flight. The
  // app-wide IapService outcome stream releases this on
  // success/error/cancel.
  bool _payInFlight = false;

  // Tracks the pack the user picked when we kicked off a buy so the
  // success snackbar can render "+N coins" without re-deriving N
  // from the productId. Cleared on every outcome.
  CoinPackModel? _pendingPack;

  @override
  void initState() {
    super.initState();

    // Subscribe to the SAME global IapService.outcomes stream the
    // wallet page listens on. Two surfaces share one listener so a
    // purchase that completes after the user dismissed the sheet
    // still credits without losing the outcome.
    _iapOutcomeSubscription = _iap.outcomes.listen(_onIapOutcome);

    // Warm-cache fast-path. If the pack list was fetched recently
    // (within the repository's TTL), render the sheet with content on
    // the very first frame — no shimmer, no perceived lag. The
    // network refresh still kicks off below so the cache stays fresh.
    final cached = _wallet.getCachedCoinPacks();
    if (cached != null && cached.isNotEmpty) {
      final display = _orderedDisplayPacks(cached);
      final popular = display.where((p) => p.isPopular).firstOrNull;
      _packs = cached;
      _selected = popular ?? (display.isNotEmpty ? display.first : null);
      _loading = false;
    }
    _loadPacks();
  }

  @override
  void dispose() {
    _iapOutcomeSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadPacks() async {
    try {
      final packs = await _wallet.getCoinPacks();
      if (!mounted) return;
      // If the cached-path already populated the sheet AND the new
      // result is byte-identical (same length / ids), skip the
      // setState — repainting just to overwrite identical data jolts
      // the visual state for no user-visible reason.
      if (_packs.length == packs.length &&
          _packs.isNotEmpty &&
          _packs.every((p) => packs.any((q) => q.id == p.id))) {
        return;
      }
      final display = _orderedDisplayPacks(packs);
      final popular = display.where((p) => p.isPopular).firstOrNull;
      setState(() {
        _packs = packs;
        // Preserve the user's selection if they already picked one
        // before the refresh landed.
        _selected = _selected ??
            (popular ?? (display.isNotEmpty ? display.first : null));
        _loading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      // Don't blow away content if the cached path already filled the
      // sheet — keep showing the (slightly stale) cached packs.
      if (_packs.isNotEmpty) return;
      setState(() {
        _error = "Couldn't load coin packs. Check connection.";
        _loading = false;
      });
    }
  }

  Future<void> _startPayment() async {
    final pack = _selected;
    if (pack == null || _payInFlight) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (!_iap.isStoreAvailable) {
      AppSnackBar.error(
        context,
        "In-app purchases aren't available on this device yet.",
      );
      return;
    }

    HapticFeedback.lightImpact();
    setState(() => _payInFlight = true);
    _pendingPack = pack;

    // Force-refresh the Firebase ID token so the server-side verify
    // CF doesn't reject with UNAUTHENTICATED from a stale token —
    // mirrors the wallet page's pre-purchase guard.
    try {
      await user.getIdToken(true);
    } catch (e) {
      _pendingPack = null;
      if (!mounted) return;
      setState(() => _payInFlight = false);
      AppSnackBar.error(
        context,
        "Couldn't verify your session. Sign out and sign in, then retry.",
      );
      return;
    }

    final productId = IapProducts.packIdToProductId(pack.id);
    if (productId == null) {
      _pendingPack = null;
      if (!mounted) return;
      setState(() => _payInFlight = false);
      AppSnackBar.error(context, "Couldn't find this pack. Please refresh.");
      return;
    }

    // Look up product details — the wallet cubit may have warm-
    // cached it, but the recharge sheet is also a valid entry point
    // (e.g. user pulled it up mid-call without visiting the wallet
    // first), so we query lazily here too.
    final products = await _iap.queryProducts({productId});
    final product = products[productId];
    if (product == null) {
      _pendingPack = null;
      if (!mounted) return;
      setState(() => _payInFlight = false);
      AppSnackBar.error(
        context,
        "This pack isn't available in the Play Store yet.",
      );
      return;
    }

    final started = await _iap.buyConsumable(product);
    if (!mounted) return;
    if (!started) {
      // The IapService already emitted an unavailable/error outcome
      // which our listener will handle. Release the local lock so
      // the user can pick a different pack.
      _pendingPack = null;
      setState(() => _payInFlight = false);
    }
  }

  void _onIapOutcome(IapOutcome outcome) {
    if (!mounted) return;

    // Ignore outcomes for products this sheet doesn't own. The
    // recharge sheet is a coin-pack surface only; activation /
    // bible outcomes share the same broadcast stream after the
    // IapService multi-product refactor and would otherwise fire
    // the success snackbar / pop(true) when an unrelated purchase
    // landed elsewhere in the app.
    //
    // `unavailable` carries no productId and falls through so the
    // sheet still shows the "in-app purchases aren't available"
    // message if the store dies mid-session.
    final pid = outcome.productId;
    if (pid != null && !IapProducts.allCoinPacks.contains(pid)) {
      return;
    }

    switch (outcome.kind) {
      case IapOutcomeKind.success:
        final pack = _pendingPack;
        _pendingPack = null;
        HapticFeedback.mediumImpact();
        final coinsDelta = pack?.coins ?? 0;
        final balance = outcome.newBalance ?? 0;
        AppSnackBar.success(
          context,
          coinsDelta > 0
              ? '+$coinsDelta coins added (balance: $balance)'
              : 'Coins added (balance: $balance)',
        );
        // Pop true so the caller (voice/chat view) knows to re-check
        // affordability and resume the session.
        Navigator.of(context).pop(true);
        break;

      case IapOutcomeKind.pending:
        setState(() => _payInFlight = false);
        AppSnackBar.info(
          context,
          'Payment is processing. Coins will arrive shortly.',
        );
        break;

      case IapOutcomeKind.canceled:
        _pendingPack = null;
        setState(() => _payInFlight = false);
        break;

      case IapOutcomeKind.error:
        _pendingPack = null;
        setState(() => _payInFlight = false);
        AppSnackBar.error(
          context,
          outcome.message ?? "Couldn't complete your purchase.",
        );
        break;

      case IapOutcomeKind.unavailable:
        _pendingPack = null;
        setState(() => _payInFlight = false);
        AppSnackBar.error(
          context,
          "In-app purchases aren't available on this device yet.",
        );
        break;
    }
  }

  // Picks the 4 packs to show and arranges them so the popular one
  // (if any) sits in slot 0 (top-left). Remaining slots are filled in
  // price-ascending order — so the user reads a coherent ladder of
  // increasing value, with the "best value" pre-selected at the top.
  List<CoinPackModel> _orderedDisplayPacks(List<CoinPackModel> all) {
    final active = all.where((p) => p.isActive).toList()
      ..sort((a, b) => a.price.compareTo(b.price));
    final firstFour = active.take(4).toList();
    final popIdx = firstFour.indexWhere((p) => p.isPopular);
    if (popIdx > 0) {
      final pop = firstFour.removeAt(popIdx);
      firstFour.insert(0, pop);
    }
    return firstFour;
  }

  // Data-driven image mapping. Admin can change coin counts on any
  // pack via the settings panel — this function maps the live coin
  // value to the visual tier so the icon always matches the
  // perceived "size" of the pack.
  String _coinPackImage(int coins) {
    if (coins >= 1000) return 'assets/coins_images/box_coins.png';
    if (coins >= 500) return 'assets/coins_images/sack_coins.png';
    if (coins >= 200) return 'assets/coins_images/3coins.png';
    return 'assets/coins_images/single_coins.png';
  }

  void _openWalletForAllPlans() {
    Navigator.of(context).pop();
    GoRouter.of(context).push('/user/wallet');
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(24),
        ),
      ),
      child: SafeArea(
        top: false,
        // Outer Stack lifts the close button onto a top layer so it
        // always renders ABOVE the wallet image (which overhangs
        // upward from the info strip into this region).
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Scroll fallback: if the user has large system text
            // scaling or is on a tiny device, content scrolls inside
            // the capped sheet instead of overflowing.
            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _DragHandle(),
                  const SizedBox(height: 12),
                  // Title + subtitle only. The wallet image isn't
                  // here — it lives inside _InfoStripWithWallet below,
                  // anchored to the info strip's top border.
                  _HeaderText(
                    subtitle: widget.infoHeadline ??
                        'Add coins to continue your session',
                  ),
                  // Gap is sized so the wallet image (which overhangs
                  // up from the info strip below) sits at the same
                  // vertical band as the title block.
                  const SizedBox(height: 14),
                  _InfoStripWithWallet(
                    currentBalance: widget.currentBalance ?? 0,
                  ),
                  const SizedBox(height: 16),
                  _SectionTitle('Pick the best plan for you'),
                  const SizedBox(height: 10),
                  _buildBody(),
                ],
              ),
            ),
            // Close button — overlaid at the top-right of the sheet,
            // ABOVE the wallet image in z-order.
            Positioned(
              top: 14,
              right: 14,
              child: _CloseButton(
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              color: AppColors.amberGold,
              strokeWidth: 2.5,
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return _ErrorState(
        message: _error!,
        onRetry: () {
          setState(() {
            _loading = true;
            _error = null;
          });
          _loadPacks();
        },
      );
    }

    final display = _orderedDisplayPacks(_packs);
    if (display.isEmpty) {
      return _ErrorState(
        message: 'No coin packs available right now.',
        onRetry: _loadPacks,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PacksGrid(
          packs: display,
          selectedId: _selected?.id,
          imageFor: _coinPackImage,
          onSelect: (pack) {
            HapticFeedback.selectionClick();
            setState(() => _selected = pack);
          },
        ),
        const SizedBox(height: 12),
        const _TrustPillsRow(),
        const SizedBox(height: 12),
        _ProceedButton(
          label: _selected != null
              ? 'Proceed with ₹${_selected!.price}'
              : 'Proceed',
          loading: _payInFlight,
          enabled: _selected != null,
          onTap: _startPayment,
        ),
        const SizedBox(height: 4),
        _SeeAllPlansLink(onTap: _openWalletForAllPlans),
      ],
    );
  }
}

// ─── Sheet pieces ────────────────────────────────────────

class _DragHandle extends StatelessWidget {
  const _DragHandle();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.muted.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

// Title + subtitle only. Right-padded so the wallet image (which
// floats over from _InfoStripWithWallet below) doesn't overlap the
// text horizontally.
class _HeaderText extends StatelessWidget {
  final String subtitle;
  const _HeaderText({required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 96 = wallet image width (88) + 4 right margin + 4 buffer.
      // Keeps title text strictly to the left of the image's column.
      padding: const EdgeInsets.only(right: 96, top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Low wallet balance',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppColors.deepDarkBrown,
              height: 1.15,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 12.5,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

// Close button — extracted so the parent build can overlay it on
// the outer Stack (ensuring it z-orders above the wallet image).
class _CloseButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CloseButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.muted.withValues(alpha: 0.14),
        ),
        child: AppIcon(
          AppIcons.close,
          size: 17,
          color: AppColors.deepDarkBrown,
        ),
      ),
    );
  }
}

// Info strip + wallet image as a single composite. The image is
// Positioned with a negative `top` so its bottom edge LOCKS to the
// info strip's top border — no matter how the surrounding layout
// changes (text scaling, screen width, locale), the visual "attached"
// relationship between wallet and strip is preserved.
class _InfoStripWithWallet extends StatelessWidget {
  final int currentBalance;
  const _InfoStripWithWallet({required this.currentBalance});

  // Image size — kept here so the negative-top math is easy to read.
  static const double _imgSize = 88;
  // How many pixels of the image dip INTO the info strip below its
  // top border. A small dip (~12px) lets the visible PNG content
  // (which has internal transparent padding) appear to sit *on* the
  // border rather than floating above it.
  static const double _overlap = 12;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _InfoStrip(currentBalance: currentBalance),
        // top = -(imgSize - overlap) = -76.
        // Image extends 76px ABOVE the info strip's top and dips
        // 12px INTO the info strip.
        Positioned(
          right: 4,
          top: -(_imgSize - _overlap),
          child: SizedBox(
            width: _imgSize,
            height: _imgSize,
            child: Image.asset(
              'assets/coins_images/wallet_coins.png',
              fit: BoxFit.contain,
              alignment: Alignment.bottomCenter,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoStrip extends StatelessWidget {
  final int currentBalance;
  const _InfoStrip({required this.currentBalance});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.warmBeige.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.borderLight,
          width: 1,
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: _InfoColumn(
                icon: AppIcons.wallet,
                label: 'Current balance',
                value: '₹$currentBalance',
                valueIsAmount: true,
              ),
            ),
            Container(
              width: 1,
              color: AppColors.borderLight,
              margin: const EdgeInsets.symmetric(vertical: 3),
            ),
            Expanded(
              child: _InfoColumn(
                icon: AppIcons.verified,
                label: 'Safe & secure',
                value: '100% secure payments',
                valueIsAmount: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoColumn extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool valueIsAmount;

  const _InfoColumn({
    required this.icon,
    required this.label,
    required this.value,
    required this.valueIsAmount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.amberGold.withValues(alpha: 0.18),
            ),
            child: AppIcon(icon, size: 15, color: AppColors.amberGold),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: valueIsAmount ? 15 : 10.5,
                    fontWeight: valueIsAmount
                        ? FontWeight.w800
                        : FontWeight.w500,
                    color: valueIsAmount
                        ? AppColors.deepDarkBrown
                        : AppColors.muted,
                    height: 1.2,
                    letterSpacing: valueIsAmount ? -0.2 : 0,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: AppColors.deepDarkBrown,
        letterSpacing: -0.2,
      ),
    );
  }
}

class _PacksGrid extends StatelessWidget {
  final List<CoinPackModel> packs;
  final String? selectedId;
  final String Function(int coins) imageFor;
  final ValueChanged<CoinPackModel> onSelect;

  const _PacksGrid({
    required this.packs,
    required this.selectedId,
    required this.imageFor,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.only(top: 8),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 12,
        // 1.22 = cards distinctly shorter than they are wide. Combined
        // with the bigger text inside, content fills the card without
        // a visible empty band in the middle.
        childAspectRatio: 1.22,
      ),
      itemCount: packs.length,
      itemBuilder: (_, i) {
        final pack = packs[i];
        return _PackCard(
          pack: pack,
          selected: pack.id == selectedId,
          imagePath: imageFor(pack.coins),
          onTap: () => onSelect(pack),
        );
      },
    );
  }
}

class _PackCard extends StatefulWidget {
  final CoinPackModel pack;
  final bool selected;
  final String imagePath;
  final VoidCallback onTap;

  const _PackCard({
    required this.pack,
    required this.selected,
    required this.imagePath,
    required this.onTap,
  });

  @override
  State<_PackCard> createState() => _PackCardState();
}

class _PackCardState extends State<_PackCard> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final pack = widget.pack;
    final selected = widget.selected;

    final borderColor =
        selected ? AppColors.amberGold : AppColors.borderLight;
    final bgColor = selected
        ? AppColors.amberGold.withValues(alpha: 0.08)
        : AppColors.surfaceWhite;

    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        Listener(
          onPointerDown: (_) => setState(() => _scale = 0.97),
          onPointerUp: (_) => setState(() => _scale = 1.0),
          onPointerCancel: (_) => setState(() => _scale = 1.0),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _scale,
              duration: const Duration(milliseconds: 110),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 9),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: borderColor,
                    width: selected ? 1.6 : 1,
                  ),
                  boxShadow: selected
                      ? null
                      : [
                          BoxShadow(
                            color: AppColors.deepDarkBrown
                                .withValues(alpha: 0.03),
                            blurRadius: 5,
                            offset: const Offset(0, 1),
                          ),
                        ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Top block: image circle + (count, "coins") +
                    // optional "Best value" pill.
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.warmBeige
                                    .withValues(alpha: 0.7),
                              ),
                              padding: const EdgeInsets.all(5),
                              child: Image.asset(
                                widget.imagePath,
                                fit: BoxFit.contain,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      '${pack.coins}',
                                      maxLines: 1,
                                      style: GoogleFonts.inter(
                                        fontSize: 23,
                                        fontWeight: FontWeight.w800,
                                        color: AppColors.deepDarkBrown,
                                        height: 1.0,
                                        letterSpacing: -0.5,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'coins',
                                    style: GoogleFonts.inter(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: AppColors.muted,
                                      height: 1.0,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (pack.isPopular) ...[
                          const SizedBox(height: 6),
                          const _BestValuePill(),
                        ],
                      ],
                    ),
                    // Bottom block: hairline divider + price + state.
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          height: 1,
                          color: selected
                              ? AppColors.amberGold
                                  .withValues(alpha: 0.25)
                              : AppColors.borderLight
                                  .withValues(alpha: 0.7),
                          margin: const EdgeInsets.only(bottom: 8),
                        ),
                        Row(
                          children: [
                            Text(
                              '₹${pack.price}',
                              style: GoogleFonts.inter(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: AppColors.deepDarkBrown,
                                letterSpacing: -0.3,
                              ),
                            ),
                            const Spacer(),
                            _StateBadge(selected: selected),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // "Most Popular" ribbon — gold pill overhanging the top edge.
        if (pack.isPopular)
          Positioned(
            top: -9,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [AppColors.amberGold, Color(0xFFB87C2A)],
                ),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.amberGold.withValues(alpha: 0.4),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppIcon(
                    AppIcons.starFilled,
                    size: 10,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    'Most Popular',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: 0.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _BestValuePill extends StatelessWidget {
  const _BestValuePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepDarkBrown.withValues(alpha: 0.06),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppIcon(
            AppIcons.thumbUp,
            size: 11,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 4),
          Text(
            'Best value',
            style: GoogleFonts.inter(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  final bool selected;
  const _StateBadge({required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected
            ? AppColors.amberGold
            : AppColors.warmBeige.withValues(alpha: 0.8),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: AppColors.amberGold.withValues(alpha: 0.35),
                  blurRadius: 5,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: AppIcon(
        selected ? AppIcons.check : AppIcons.chevronRight,
        size: selected ? 14 : 16,
        color: selected ? Colors.white : AppColors.primaryBrown,
      ),
    );
  }
}

class _TrustPillsRow extends StatelessWidget {
  const _TrustPillsRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.warmBeige.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.borderLight.withValues(alpha: 0.7),
          width: 1,
        ),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: const [
            Expanded(
              child: _TrustItem(
                icon: AppIcons.shield,
                label: 'Secure',
              ),
            ),
            _TrustDivider(),
            Expanded(
              child: _TrustItem(
                icon: AppIcons.bolt,
                label: 'Instant credit',
              ),
            ),
            _TrustDivider(),
            Expanded(
              child: _TrustItem(
                icon: AppIcons.refresh,
                label: 'Cancel anytime',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrustItem extends StatelessWidget {
  final IconData icon;
  final String label;
  const _TrustItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AppIcon(icon, size: 11, color: AppColors.primaryBrown),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown.withValues(alpha: 0.78),
            ),
          ),
        ),
      ],
    );
  }
}

class _TrustDivider extends StatelessWidget {
  const _TrustDivider();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: AppColors.borderLight,
    );
  }
}

class _ProceedButton extends StatefulWidget {
  final String label;
  final bool loading;
  final bool enabled;
  final VoidCallback onTap;

  const _ProceedButton({
    required this.label,
    required this.loading,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_ProceedButton> createState() => _ProceedButtonState();
}

class _ProceedButtonState extends State<_ProceedButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = !widget.enabled || widget.loading;
    return Listener(
      onPointerDown: (_) {
        if (!disabled) setState(() => _scale = 0.97);
      },
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: disabled ? null : widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: disabled
                  ? null
                  : const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        AppColors.amberGold,
                        Color(0xFFB87C2A),
                      ],
                    ),
              color: disabled
                  ? AppColors.amberGold.withValues(alpha: 0.45)
                  : null,
              boxShadow: disabled
                  ? null
                  : [
                      // Softer, larger spread = button feels lifted
                      // off the sheet, not pasted flat.
                      BoxShadow(
                        color: AppColors.amberGold.withValues(alpha: 0.30),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
            ),
            child: Center(
              child: widget.loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: 0.1,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const AppIcon(
                          AppIcons.arrowRight,
                          size: 16,
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

class _SeeAllPlansLink extends StatelessWidget {
  final VoidCallback onTap;
  const _SeeAllPlansLink({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'See all plans',
              style: GoogleFonts.inter(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryBrown,
              ),
            ),
            const SizedBox(width: 3),
            AppIcon(
              AppIcons.chevronDown,
              size: 16,
              color: AppColors.primaryBrown,
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          AppIcon(
            AppIcons.cloudOff,
            size: 26,
            color: AppColors.muted.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: AppColors.primaryBrown.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Try again',
                style: GoogleFonts.inter(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryBrown,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Used by callers that want to compute a "5-minute minimum / how
// much more you need" pair without duplicating the math. Returns
// (requiredFor5Min, deficit) — both nullable when inputs are
// missing. Exported as a top-level helper rather than a method on
// the sheet so callers can use it without pulling in any UI deps.
({int requiredFor5Min, int deficit}) recomputeRechargeContext({
  required int ratePerMinute,
  required int currentBalance,
}) {
  final requiredFor5Min = ratePerMinute * 5;
  final deficit = math.max(0, requiredFor5Min - currentBalance);
  return (requiredFor5Min: requiredFor5Min, deficit: deficit);
}
