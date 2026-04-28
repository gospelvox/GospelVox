// Compact in-app top-up sheet. Used in two places — mid-chat and
// mid-voice-call — so the visual layout deliberately matches the
// pattern Indian consult apps (Astrotalk, Bhrigu) ship: small
// height, contextual headline, 4-column grid of pack cards, single
// Proceed button. Anything taller pushes the live conversation off
// screen and tanks conversion.
//
// What this file owns vs delegates:
//   • Owns: the visual sheet, pack selection state, Razorpay
//     bridge, success/failure handling.
//   • Delegates: the contextual copy (headline + subtext) is
//     passed in by the caller — voice/chat decide their own
//     wording so the sheet stays caller-agnostic.

import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/services/razorpay_service.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';
import 'package:gospel_vox/features/user/wallet/data/wallet_repository.dart';

class RechargeSheet extends StatefulWidget {
  // Shown as a small wallet pill in the title row. Null hides it.
  final int? currentBalance;
  // Bold info line at the top of the gray info card.
  // e.g. "Minimum balance: ₹115 (for 5 minutes)"
  final String? infoHeadline;
  // Lighter line below the headline. Use it for the contextual
  // "with $priestName" sentence the caller wants to surface.
  final String? infoSubtext;

  const RechargeSheet({
    super.key,
    this.currentBalance,
    this.infoHeadline,
    this.infoSubtext,
  });

  // Convenience opener — mirrors the calling pattern callers got
  // used to. Optional context params let voice/chat hand in their
  // own copy without having to know about showModalBottomSheet's
  // exact options.
  static Future<bool?> show(
    BuildContext context, {
    int? currentBalance,
    String? infoHeadline,
    String? infoSubtext,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      barrierColor: Colors.black.withValues(alpha: 0.5),
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
  late final RazorpayService _razorpay;

  bool _loading = true;
  String? _error;
  List<CoinPackModel> _packs = const [];
  CoinPackModel? _selected;

  // Lock against double-tap of Proceed while we're already creating
  // a server order or waiting for Razorpay to open.
  bool _payInFlight = false;

  // Preserved across the Razorpay round-trip so the verify call
  // knows which pack the payment was for.
  CoinPackModel? _pendingPack;

  @override
  void initState() {
    super.initState();
    _razorpay = RazorpayService();
    _razorpay.init();
    _razorpay.onSuccess = _onPaySuccess;
    _razorpay.onFailure = _onPayFailure;
    _razorpay.onWallet = (_) {};
    _loadPacks();
  }

  @override
  void dispose() {
    _razorpay.dispose();
    super.dispose();
  }

  Future<void> _loadPacks() async {
    try {
      final packs = await _wallet.getCoinPacks();
      if (!mounted) return;
      // Default selection: the most popular pack if there is one,
      // otherwise the cheapest. Priests / admins control which is
      // marked popular via Firestore.
      final popular = packs.where((p) => p.isPopular).firstOrNull;
      setState(() {
        _packs = packs;
        _selected = popular ?? (packs.isNotEmpty ? packs.first : null);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
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

    HapticFeedback.lightImpact();
    setState(() => _payInFlight = true);
    _pendingPack = pack;

    try {
      final order = await _wallet.createCoinOrder(packId: pack.id);
      if (!mounted) return;

      _razorpay.openCheckout(
        razorpayOrderId: order.orderId,
        amountInPaise: order.amountPaise,
        description: '${pack.coins} coins',
        userEmail: user.email ?? '',
        userName: user.displayName ?? 'Gospel Vox user',
      );
    } catch (_) {
      _pendingPack = null;
      if (!mounted) return;
      setState(() => _payInFlight = false);
      AppSnackBar.error(
        context,
        "Couldn't start payment. Try again.",
      );
    }
  }

  Future<void> _onPaySuccess(PaymentSuccessResponse response) async {
    final pack = _pendingPack;
    _pendingPack = null;

    final paymentId = response.paymentId;
    final orderId = response.orderId;
    final signature = response.signature;

    if (pack == null ||
        paymentId == null ||
        orderId == null ||
        signature == null) {
      if (!mounted) return;
      setState(() => _payInFlight = false);
      AppSnackBar.error(
        context,
        'Payment received but verification failed. '
        'Contact support.',
      );
      return;
    }

    try {
      final newBalance = await _wallet.verifyCoinPurchase(
        razorpayPaymentId: paymentId,
        razorpayOrderId: orderId,
        razorpaySignature: signature,
        packId: pack.id,
      );
      if (!mounted) return;

      HapticFeedback.mediumImpact();
      AppSnackBar.success(
        context,
        '+${pack.coins} coins added (balance: $newBalance)',
      );
      Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _payInFlight = false);
      AppSnackBar.error(
        context,
        'Payment captured but server credit failed. '
        'Coins will land shortly.',
      );
    }
  }

  void _onPayFailure(PaymentFailureResponse response) {
    _pendingPack = null;
    if (!mounted) return;
    setState(() => _payInFlight = false);
    // Both user-cancelled and real failures land here — for the
    // sheet we treat both as "didn't go through" and stay open so
    // the user can retry without re-opening.
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(24),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _DragHandle(),
              const SizedBox(height: 14),
              _TitleRow(
                currentBalance: widget.currentBalance,
                onClose: () => Navigator.of(context).pop(),
              ),
              if (widget.infoHeadline != null ||
                  widget.infoSubtext != null) ...[
                const SizedBox(height: 14),
                _InfoCard(
                  headline: widget.infoHeadline,
                  subtext: widget.infoSubtext,
                ),
              ],
              const SizedBox(height: 16),
              _buildBody(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: CircularProgressIndicator(
            color: AppColors.primaryBrown,
            strokeWidth: 2.5,
          ),
        ),
      );
    }
    if (_error != null) {
      return _ErrorState(message: _error!, onRetry: () {
        setState(() {
          _loading = true;
          _error = null;
        });
        _loadPacks();
      });
    }
    if (_packs.isEmpty) {
      return _ErrorState(
        message: 'No coin packs available right now.',
        onRetry: _loadPacks,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PacksGrid(
          packs: _packs,
          selectedId: _selected?.id,
          onSelect: (pack) {
            HapticFeedback.selectionClick();
            setState(() => _selected = pack);
          },
        ),
        const SizedBox(height: 18),
        _ProceedButton(
          loading: _payInFlight,
          enabled: _selected != null,
          onTap: _startPayment,
        ),
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
        width: 38,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.muted.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  final int? currentBalance;
  final VoidCallback onClose;

  const _TitleRow({required this.currentBalance, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            'Low wallet balance!',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
        if (currentBalance != null) ...[
          const SizedBox(width: 10),
          _BalancePill(balance: currentBalance!),
        ],
        const Spacer(),
        // Close pill — small circular tap target, not the whole
        // background, so accidental brushes near the edge don't
        // dismiss the sheet.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onClose,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.muted.withValues(alpha: 0.12),
            ),
            child: Icon(
              Icons.close_rounded,
              size: 16,
              color: AppColors.muted,
            ),
          ),
        ),
      ],
    );
  }
}

class _BalancePill extends StatelessWidget {
  final int balance;
  const _BalancePill({required this.balance});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.muted.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.account_balance_wallet_outlined,
            size: 13,
            color: AppColors.muted,
          ),
          const SizedBox(width: 5),
          Text(
            '₹ $balance',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String? headline;
  final String? subtext;
  const _InfoCard({required this.headline, required this.subtext});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.muted.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (headline != null)
            Text(
              headline!,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                height: 1.4,
                color: AppColors.deepDarkBrown,
              ),
            ),
          if (headline != null && subtext != null)
            const SizedBox(height: 4),
          if (subtext != null)
            Text(
              subtext!,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                height: 1.4,
                color: AppColors.muted,
              ),
            ),
        ],
      ),
    );
  }
}

class _PacksGrid extends StatelessWidget {
  final List<CoinPackModel> packs;
  final String? selectedId;
  final ValueChanged<CoinPackModel> onSelect;

  const _PacksGrid({
    required this.packs,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // 4-column grid. Tiles are deliberately taller than wide so the
    // "Most Popular" hat doesn't have to overhang into a neighbour.
    return GridView.builder(
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 14,
        childAspectRatio: 0.85,
      ),
      itemCount: packs.length,
      itemBuilder: (_, i) {
        final pack = packs[i];
        return _PackCard(
          pack: pack,
          selected: pack.id == selectedId,
          onTap: () => onSelect(pack),
        );
      },
    );
  }
}

class _PackCard extends StatefulWidget {
  final CoinPackModel pack;
  final bool selected;
  final VoidCallback onTap;

  const _PackCard({
    required this.pack,
    required this.selected,
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

    final borderColor = selected
        ? AppColors.amberGold
        : AppColors.muted.withValues(alpha: 0.18);
    final bgColor = selected
        ? AppColors.amberGold.withValues(alpha: 0.06)
        : AppColors.surfaceWhite;

    // Pull the percentage label from the pack — discountPercent is
    // the existing field we already render in the wallet page, so
    // reuse it here as "X% Extra".
    final extraPct = pack.discountPercent;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Listener(
          onPointerDown: (_) => setState(() => _scale = 0.96),
          onPointerUp: (_) => setState(() => _scale = 1.0),
          onPointerCancel: (_) => setState(() => _scale = 1.0),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedScale(
              scale: _scale,
              duration: const Duration(milliseconds: 100),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: borderColor,
                    width: selected ? 1.6 : 1,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '₹ ${pack.price}',
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                    ),
                    if (extraPct > 0) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E7D4F)
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '$extraPct% Extra',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF2E7D4F),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        // "Most Popular" hat — only on the popular tile, sits above
        // the card edge so it reads as a sticker rather than a
        // crammed-in badge.
        if (pack.isPopular)
          Positioned(
            top: -8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: AppColors.amberGold,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color:
                          AppColors.amberGold.withValues(alpha: 0.35),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Text(
                  'Most Popular',
                  style: GoogleFonts.inter(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ProceedButton extends StatefulWidget {
  final bool loading;
  final bool enabled;
  final VoidCallback onTap;

  const _ProceedButton({
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
            height: 50,
            decoration: BoxDecoration(
              color: AppColors.amberGold.withValues(
                alpha: disabled ? 0.45 : 1.0,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: disabled
                  ? null
                  : [
                      BoxShadow(
                        color:
                            AppColors.amberGold.withValues(alpha: 0.3),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            child: Center(
              child: widget.loading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Text(
                      'Proceed',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
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
          Icon(
            Icons.cloud_off_rounded,
            size: 28,
            color: AppColors.muted.withValues(alpha: 0.6),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onRetry,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 9,
              ),
              decoration: BoxDecoration(
                color: AppColors.primaryBrown.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                'Try again',
                style: GoogleFonts.inter(
                  fontSize: 13,
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
