// Celebratory post-purchase screen. Shown only once verifyCoinPurchase
// returns a success — so by the time the user sees this, the coins
// are already credited server-side and the balance stream will have
// updated. The screen is effectively a victory lap, not a loading
// state.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/coin_icon.dart';

// Forest green used for the success checkmark. Kept local because
// AppColors doesn't carry a success-green token and the checkmark
// circle is the only place on this screen that needs it.
const Color _kSuccessGreen = Color(0xFF2E7D4F);

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
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<double> _fadeAnimation;

  double _continueScale = 1.0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );

    // Checkmark scales up with a light overshoot — easeOutBack gives
    // that "pop" feel that reads as genuine celebration without being
    // so bouncy it looks cartoonish.
    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack),
      ),
    );

    // Text fades in only after the checkmark is mostly on screen, so
    // the eye lands on the tick first, then reads the message.
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
    super.dispose();
  }

  String _formatCoins(int coins) {
    if (coins >= 1000) return NumberFormat('#,###').format(coins);
    return coins.toString();
  }

  void _onContinue() {
    // No reload needed here. The WalletCubit awaits reloadAfterPurchase
    // internally right after emitting WalletPurchaseSuccess, so by the
    // time the user taps Continue the wallet state has already
    // transitioned back to WalletLoaded with fresh balance + packs.
    // A context.read<WalletCubit>() here would fail anyway because
    // this route sits outside the wallet page's BlocProvider scope.
    context.pop();
  }

  void _viewTransactions() {
    // TODO Week 4: navigate to transaction history page
    AppSnackBar.info(context, "Transaction history coming soon");
  }

  @override
  Widget build(BuildContext context) {
    // PopScope blocks the hardware back button mid-animation. Without
    // it, a user who taps back during the first 300ms sees a janky
    // half-drawn tick and misses the confirmation entirely.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              children: [
                const Spacer(flex: 3),
                _buildCheckmark(),
                const SizedBox(height: 32),
                _buildSuccessText(),
                const SizedBox(height: 40),
                _buildCoinsCard(),
                const Spacer(flex: 4),
                _buildContinueButton(),
                const SizedBox(height: 12),
                _buildViewTransactionsLink(),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCheckmark() {
    return ScaleTransition(
      scale: _scaleAnimation,
      child: Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFF0FDF4),
          border: Border.all(
            color: _kSuccessGreen.withValues(alpha: 0.2),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: _kSuccessGreen.withValues(alpha: 0.1),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: const Icon(
          Icons.check_rounded,
          size: 48,
          color: _kSuccessGreen,
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
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "Your coins have been added",
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
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
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
        decoration: BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.muted.withValues(alpha: 0.1),
          ),
          boxShadow: [
            BoxShadow(
              color: AppColors.deepDarkBrown.withValues(alpha: 0.06),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CoinIcon(size: 36),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      "+${_formatCoins(widget.coinsPurchased)}",
                      style: GoogleFonts.inter(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: AppColors.deepDarkBrown,
                        height: 1.1,
                        letterSpacing: -0.6,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "coins credited",
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              height: 1,
              color: AppColors.muted.withValues(alpha: 0.1),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "New Balance",
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CoinIcon(size: 20),
                    const SizedBox(width: 6),
                    Text(
                      "${_formatCoins(widget.newBalance)} coins",
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryBrown,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
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
            height: 54,
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primaryBrown.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Center(
              child: Text(
                "Continue",
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildViewTransactionsLink() {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _viewTransactions,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            "View transaction history",
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}
