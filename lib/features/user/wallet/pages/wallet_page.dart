import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shimmer/shimmer.dart';
import 'package:intl/intl.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/coin_icon.dart';
import 'package:gospel_vox/features/user/wallet/bloc/wallet_cubit.dart';
import 'package:gospel_vox/features/user/wallet/bloc/wallet_state.dart';
import 'package:gospel_vox/features/user/wallet/widgets/payment_processing_overlay.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

class WalletPage extends StatefulWidget {
  const WalletPage({super.key});

  @override
  State<WalletPage> createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  late final WalletCubit _cubit;

  // Tap-debounce on the "Proceed to Pay" button. The cubit also
  // tracks `isPurchasing` for the overlay, but that flag isn't set
  // until the IapService dispatches to the Play sheet — a fast
  // double-tap can fire two startPurchase calls before the state
  // settles. This synchronous bool blocks the second tap.
  bool _isPaymentInProgress = false;

  @override
  void initState() {
    super.initState();
    _cubit = sl<WalletCubit>();

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _cubit.loadWallet(uid);
    }
  }

  @override
  void dispose() {
    _cubit.close();
    super.dispose();
  }

  // ── Purchase triggers ──────────────────────────────────────────

  // Triggers a Play Billing purchase via the cubit. The IapService
  // handles the actual store sheet + server verification + receipt
  // completion — the page only needs to drive the start trigger and
  // listen for the success/error state transition.
  //
  // The cubit's purchasePack() guards against double-purchase via
  // the WalletLoaded.isPurchasing flag, but we also keep a local
  // synchronous lock against a fast double-tap that arrives before
  // the state transition lands.
  Future<void> _startPurchase(CoinPackModel pack) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        AppSnackBar.error(context, "You're signed out. Please sign in again.");
      }
      return;
    }

    setState(() => _isPaymentInProgress = true);

    // Force-refresh the Firebase ID token before the verify CF
    // fires. Without this, a stale/expired token (common on Samsung
    // devices where background processes get frozen aggressively)
    // makes the callable reach the server with no auth, and the CF
    // correctly rejects with UNAUTHENTICATED.
    try {
      await user.getIdToken(true);
    } catch (e) {
      debugPrint('[Wallet] ID token refresh failed: $e');
      if (mounted) {
        setState(() => _isPaymentInProgress = false);
        AppSnackBar.error(
          context,
          "Couldn't verify your session. Sign out and sign in, then retry.",
        );
      }
      return;
    }

    await _cubit.purchasePack(pack.id);
    if (!mounted) return;
    // The cubit's listener will release `isPaymentInProgress` once it
    // sees the IAP outcome (success / error / cancel). We release the
    // local sync-lock here so a same-frame double-tap stays blocked
    // until then.
    setState(() => _isPaymentInProgress = false);
  }

  void _proceedToPay() {
    if (_isPaymentInProgress) return;

    final state = _cubit.state;
    if (state is! WalletLoaded || state.selectedPack == null) return;

    _startPurchase(state.selectedPack!);
  }

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: _cubit,
      child: BlocConsumer<WalletCubit, WalletState>(
        listener: _onStateChanged,
        builder: (context, state) {
          int? balance;
          final isLoading = state is WalletLoading;
          if (state is WalletLoaded) balance = state.balance;

          final showOverlay = state is WalletLoaded && state.isPurchasing;

          // Stack rather than a single Scaffold so the processing
          // overlay can cover the entire wallet (including the AppBar
          // coin chip) during CF verification without unmounting the
          // wallet body behind it.
          return Stack(
            children: [
              Scaffold(
                backgroundColor: AppColors.background,
                appBar: _buildAppBar(
                  context,
                  balance: balance,
                  isLoading: isLoading,
                ),
                body: _buildBody(context, state),
              ),
              if (showOverlay) const PaymentProcessingOverlay(),
            ],
          );
        },
      ),
    );
  }

  void _onStateChanged(BuildContext context, WalletState state) {
    if (state is WalletError) {
      // Surface payment-side errors as a transient snackbar so the
      // wallet body itself isn't replaced for a verification failure.
      // Unlike the Razorpay flow, IAP failures never put money in a
      // captured-but-uncredited state — the server is idempotent and
      // the plugin re-delivers transient failures on next launch, so
      // we don't need a dedicated "Payment Failed — don't worry about
      // refunds" sheet here.
      AppSnackBar.error(context, state.message);
    } else if (state is WalletPurchaseSuccess) {
      // Navigate. The cubit fires reloadAfterPurchase in the
      // background right after emitting WalletPurchaseSuccess, so by
      // the time the user taps Continue on the success page the
      // state has typically already transitioned back to WalletLoaded
      // — no stranded-on-shimmer. In the rare case the reload is
      // still in flight when the user returns, _buildBody renders
      // the shimmer briefly until the new WalletLoaded lands (a few
      // hundred ms).
      context.push('/user/payment-success', extra: <String, dynamic>{
        'coins': state.coinsPurchased,
        'newBalance': state.newBalance,
      });
    }
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context, {
    required int? balance,
    required bool isLoading,
  }) {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      toolbarHeight: 64,
      automaticallyImplyLeading: false,
      titleSpacing: 20,
      title: Text(
        "Wallet",
        style: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: AppColors.deepDarkBrown,
          letterSpacing: -0.2,
        ),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: _BalanceChip(
              balance: balance,
              isLoading: isLoading,
            ),
          ),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 1,
          color: AppColors.muted.withValues(alpha: 0.1),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, WalletState state) {
    if (state is WalletLoading) {
      return _buildLoadingBody(context);
    }
    if (state is WalletLoaded) {
      // Purchase-in-progress is rendered as an overlay (see build()),
      // not a separate body — the wallet stays fully mounted behind.
      return _buildLoadedBody(context, state);
    }
    if (state is WalletPurchaseSuccess) {
      // Transient state between the CF credit and reloadAfterPurchase
      // completing. Show the shimmer rather than an empty Scaffold so
      // the user doesn't return from the success screen to a blank
      // wallet page. The listener kicked off reloadAfterPurchase
      // already — it'll land us in WalletLoaded within ~500ms.
      return _buildLoadingBody(context);
    }
    if (state is WalletError) {
      // Payment-verification errors are surfaced through the failure
      // sheet by the listener, so a payment-side WalletError doesn't
      // replace the wallet body. But load-time errors (initial fetch
      // failed) still land here because there's no wallet to show.
      return _buildErrorBody(context, state.message);
    }
    return const SizedBox.shrink();
  }

  Widget _buildLoadingBody(BuildContext context) {
    // Warm shimmer tones so the loading state reads as part of the
    // listener-side design language. The earlier gray values were
    // imported from the admin palette and looked jarring against
    // the warm-beige scaffold.
    final baseColor = AppColors.muted.withValues(alpha: 0.14);
    final highlightColor = AppColors.warmBeige;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 32),
                Text(
                  "YOU WILL RECEIVE",
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.amberGold.withValues(alpha: 0.85),
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                Shimmer.fromColors(
                  baseColor: baseColor,
                  highlightColor: highlightColor,
                  child: Container(
                    width: 80,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "coins",
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 28),
                _buildSectionDivider("Choose a pack"),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                      childAspectRatio: 0.88,
                    ),
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: 4,
                    itemBuilder: (context, index) {
                      return Shimmer.fromColors(
                        baseColor: baseColor,
                        highlightColor: highlightColor,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 100),
              ],
            ),
          ),
        ),
        const _FloatingPayButton(
          selectedPack: null,
          isPaymentInProgress: false,
          onTap: null,
        ),
      ],
    );
  }

  Widget _buildErrorBody(BuildContext context, String message) {
    // Wrap in a scroll view because developer-facing messages can
    // include a FirebaseFunctionsException toString that exceeds the
    // viewport, especially on smaller phones. Without this the screen
    // yields a yellow-striped RenderFlex overflow.
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            AppIcons.error,
            size: 44,
            color: AppColors.errorRed,
          ),
          const SizedBox(height: 14),
          Text(
            message,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          _RetryButton(
            onTap: () {
              final uid = FirebaseAuth.instance.currentUser?.uid;
              if (uid != null) _cubit.loadWallet(uid);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLoadedBody(BuildContext context, WalletLoaded state) {
    final selectedPack = state.selectedPack;

    return Column(
      children: [
        Expanded(
          // Pull-to-refresh re-fetches packs + balance so the user
          // can refresh after a failed purchase without leaving the
          // screen. The balance chip already streams live, but pack
          // edits by admin only reach us via refetch.
          child: RefreshIndicator(
            color: AppColors.primaryBrown,
            backgroundColor: AppColors.surfaceWhite,
            onRefresh: () async {
              final uid = FirebaseAuth.instance.currentUser?.uid;
              if (uid != null) await _cubit.reloadAfterPurchase(uid);
            },
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              child: Column(
              children: [
                const SizedBox(height: 32),
                _HeroReceiveSection(selectedPack: selectedPack),
                // Welcome offer card removed for this slice — the
                // server's welcome-offer special case was dropped
                // when coin purchase migrated to Play Billing, and
                // there's no live SKU to back the synthetic pack.
                // The card returns in a future slice once the
                // introductory-offer SKU is wired in Play Console.
                const SizedBox(height: 28),
                _buildSectionDivider("Choose a pack"),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 14,
                      mainAxisSpacing: 14,
                      childAspectRatio: 0.88,
                    ),
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: state.packs.length,
                    itemBuilder: (context, index) {
                      final pack = state.packs[index];
                      final isSelected = pack.id == state.selectedPackId;
                      return _CoinPackCard(
                        pack: pack,
                        isSelected: isSelected,
                        onTap: () => _cubit.selectPack(pack.id),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
                _buildTrustFooter(),
                const SizedBox(height: 100),
              ],
            ),
            ),
          ),
        ),
        _FloatingPayButton(
          selectedPack: selectedPack,
          isPaymentInProgress: _isPaymentInProgress,
          onTap: _proceedToPay,
        ),
      ],
    );
  }

  Widget _buildSectionDivider(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 1,
              color: AppColors.muted.withValues(alpha: 0.12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppColors.muted,
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 1,
              color: AppColors.muted.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrustFooter() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(
            AppIcons.magic,
            size: 12,
            color: AppColors.muted.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 6),
          // Flexible so a future copy tweak can't push the icon
          // off-screen on a 320-wide device.
          Flexible(
            child: Text(
              "Coins never expire · Use anytime",
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: AppColors.muted.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// BALANCE CHIP (top-right)
// ============================================================

class _BalanceChip extends StatelessWidget {
  final int? balance;
  final bool isLoading;

  const _BalanceChip({
    required this.balance,
    required this.isLoading,
  });

  String _format(int coins) {
    if (coins >= 1000) return NumberFormat('#,###').format(coins);
    return coins.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 5, 12, 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.25),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepDarkBrown.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CoinIcon(size: 22),
          const SizedBox(width: 6),
          if (isLoading)
            Shimmer.fromColors(
              baseColor: AppColors.muted.withValues(alpha: 0.14),
              highlightColor: AppColors.warmBeige,
              child: Container(
                width: 30,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            )
          else
            Text(
              balance != null ? _format(balance!) : "—",
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
                letterSpacing: -0.1,
              ),
            ),
        ],
      ),
    );
  }
}

// ============================================================
// HERO "YOU WILL RECEIVE" SECTION
// ============================================================

class _HeroReceiveSection extends StatelessWidget {
  final CoinPackModel? selectedPack;

  const _HeroReceiveSection({required this.selectedPack});

  String _formatCoins(int coins) {
    if (coins >= 1000) return NumberFormat('#,###').format(coins);
    return coins.toString();
  }

  @override
  Widget build(BuildContext context) {
    final hasSelection = selectedPack != null;
    final coinText = hasSelection ? _formatCoins(selectedPack!.coins) : "—";

    return Column(
      children: [
        Text(
          "YOU WILL RECEIVE",
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.amberGold.withValues(alpha: 0.85),
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          transitionBuilder: (child, animation) {
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.2),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            );
          },
          child: Text(
            coinText,
            key: ValueKey(selectedPack?.coins ?? 0),
            style: GoogleFonts.inter(
              fontSize: 52,
              fontWeight: FontWeight.w800,
              color: hasSelection
                  ? AppColors.deepDarkBrown
                  : AppColors.muted.withValues(alpha: 0.35),
              height: 1.0,
              letterSpacing: -1.5,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          "coins",
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w400,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 14),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: hasSelection
              ? Padding(
                  key: ValueKey("confirm-${selectedPack!.coins}"),
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(
                        AppIcons.bolt,
                        size: 14,
                        color: AppColors.amberGold,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          "Added instantly · Never expires",
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: AppColors.deepDarkBrown
                                .withValues(alpha: 0.7),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                )
              : Padding(
                  key: const ValueKey("hint"),
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    "Choose a pack below to get started",
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppColors.muted.withValues(alpha: 0.8),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

// Note: the welcome-offer card widget was removed in the Play
// Billing migration slice — the synthetic 'welcome_offer' SKU has
// no Play product to back it. The widget returns once the
// introductory-offer product is wired in Play Console.

// ============================================================
// COIN PACK CARD — content truly centered via StackFit.expand
// ============================================================

class _CoinPackCard extends StatefulWidget {
  final CoinPackModel pack;
  final bool isSelected;
  final VoidCallback onTap;

  const _CoinPackCard({
    required this.pack,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_CoinPackCard> createState() => _CoinPackCardState();
}

class _CoinPackCardState extends State<_CoinPackCard> {
  double _pressScale = 1.0;

  String _formatCoins(int coins) {
    if (coins >= 1000) return NumberFormat('#,###').format(coins);
    return coins.toString();
  }

  @override
  Widget build(BuildContext context) {
    final hasBonusBadge =
        !widget.pack.isPopular && widget.pack.discountPercent > 5;
    final hasTopBadge = widget.pack.isPopular || hasBonusBadge;

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressScale = 0.97),
      onTapUp: (_) => setState(() => _pressScale = 1.0),
      onTapCancel: () => setState(() => _pressScale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressScale,
        duration: const Duration(milliseconds: 100),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.isSelected
                  ? AppColors.primaryBrown
                  : AppColors.muted.withValues(alpha: 0.12),
              width: widget.isSelected ? 2 : 1,
            ),
            boxShadow: widget.isSelected
                ? [
                    BoxShadow(
                      color: AppColors.primaryBrown.withValues(alpha: 0.1),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : const [],
          ),
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(12, hasTopBadge ? 22 : 14, 12, 14),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const CoinIcon(size: 40),
                    const SizedBox(height: 12),
                    Text(
                      _formatCoins(widget.pack.coins),
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.deepDarkBrown,
                        height: 1.1,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "coins",
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "₹${widget.pack.price}",
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: widget.isSelected
                            ? AppColors.primaryBrown
                            : AppColors.deepDarkBrown,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.pack.isPopular)
                Positioned(
                  top: -1,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.amberGold,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                          bottomLeft: Radius.circular(8),
                          bottomRight: Radius.circular(8),
                        ),
                      ),
                      child: Text(
                        "POPULAR",
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ),
                ),
              if (hasBonusBadge)
                Positioned(
                  top: -1,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primaryBrown,
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(16),
                          topRight: Radius.circular(16),
                          bottomLeft: Radius.circular(8),
                          bottomRight: Radius.circular(8),
                        ),
                      ),
                      child: Text(
                        "+${widget.pack.discountPercent}% BONUS",
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// FLOATING PAY BUTTON
// ============================================================

class _FloatingPayButton extends StatefulWidget {
  final CoinPackModel? selectedPack;
  final bool isPaymentInProgress;
  final VoidCallback? onTap;

  const _FloatingPayButton({
    required this.selectedPack,
    required this.isPaymentInProgress,
    required this.onTap,
  });

  @override
  State<_FloatingPayButton> createState() => _FloatingPayButtonState();
}

class _FloatingPayButtonState extends State<_FloatingPayButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final hasPack = widget.selectedPack != null;
    final isActive =
        hasPack && widget.onTap != null && !widget.isPaymentInProgress;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        8,
        20,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      child: GestureDetector(
        onTapDown: isActive ? (_) => setState(() => _scale = 0.97) : null,
        onTapUp: isActive ? (_) => setState(() => _scale = 1.0) : null,
        onTapCancel: isActive ? () => setState(() => _scale = 1.0) : null,
        onTap: isActive ? widget.onTap : null,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 100),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: double.infinity,
            height: 54,
            decoration: BoxDecoration(
              color: (hasPack || widget.isPaymentInProgress)
                  ? AppColors.primaryBrown
                  : AppColors.muted.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(14),
              boxShadow: (hasPack || widget.isPaymentInProgress)
                  ? [
                      BoxShadow(
                        color:
                            AppColors.primaryBrown.withValues(alpha: 0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : const [],
            ),
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: widget.isPaymentInProgress
                    ? const SizedBox(
                        key: ValueKey("progress"),
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : hasPack
                        ? Text(
                            "Proceed to Pay  ₹${widget.selectedPack!.price}",
                            key: ValueKey(
                                "pay-${widget.selectedPack!.price}"),
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: 0.1,
                            ),
                          )
                        : Text(
                            "Select a pack",
                            key: const ValueKey("select"),
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AppColors.muted,
                            ),
                          ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Retry button on the wallet error state. Small stateful widget
// because we want the tactile press-scale every other tappable on
// the listener side gets — a bare GestureDetector here felt dead.
class _RetryButton extends StatefulWidget {
  final VoidCallback onTap;
  const _RetryButton({required this.onTap});

  @override
  State<_RetryButton> createState() => _RetryButtonState();
}

class _RetryButtonState extends State<_RetryButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.95),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Retry',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
