import 'dart:async';
import 'dart:math' as math;

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
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/coin_image.dart';
import 'package:gospel_vox/features/user/wallet/bloc/wallet_cubit.dart';
import 'package:gospel_vox/features/user/wallet/bloc/wallet_state.dart';
import 'package:gospel_vox/features/user/wallet/widgets/payment_processing_overlay.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

// ── Coin pack imagery ───────────────────────────────────────
// The flat painted gem (CoinIcon) is replaced across the wallet with
// the 3D coin artwork in assets/coins_images. Packs escalate visually
// by their coin amount — a single coin → a cluster → a jar → a treasure
// chest — so bigger packs *look* bigger. This is purely presentational:
// pack data, ordering and the purchase flow are untouched.
const String _kCoinSingle = 'assets/coins_images/single_coins.png';
const List<String> _kCoinTiers = [
  'assets/coins_images/single_coins.png',
  'assets/coins_images/3coins.png',
  'assets/coins_images/jar_coins.png',
  'assets/coins_images/box_coins.png',
];

// Maps each pack → a tier image keyed by its ascending coin rank, so the
// hero and the matching card always show the same artwork. Works for any
// pack count (ranks are spread across the available tiers).
Map<String, String> _coinImagesByPack(List<CoinPackModel> packs) {
  if (packs.isEmpty) return const {};
  final sorted = [...packs]..sort((a, b) => a.coins.compareTo(b.coins));
  final n = sorted.length;
  final result = <String, String>{};
  for (var i = 0; i < n; i++) {
    final tier =
        n <= 1 ? 0 : (i * (_kCoinTiers.length - 1) / (n - 1)).round();
    result[sorted[i].id] = _kCoinTiers[tier.clamp(0, _kCoinTiers.length - 1)];
  }
  return result;
}

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

  // Transient payment messages (store unavailable, verification failed,
  // "payment processing") surfaced as snackbars without replacing the
  // wallet body. See WalletCubit.notices / WalletNotice.
  StreamSubscription<WalletNotice>? _noticeSub;

  @override
  void initState() {
    super.initState();
    _cubit = sl<WalletCubit>();
    _noticeSub = _cubit.notices.listen(_onNotice);

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _cubit.loadWallet(uid);
    }
  }

  @override
  void dispose() {
    _noticeSub?.cancel();
    _cubit.close();
    super.dispose();
  }

  void _onNotice(WalletNotice notice) {
    if (!mounted) return;
    switch (notice.kind) {
      case WalletNoticeKind.error:
        AppSnackBar.error(context, notice.message);
        break;
      case WalletNoticeKind.info:
        AppSnackBar.info(context, notice.message);
        break;
    }
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

          // Block the hardware/system back button while a purchase is
          // being verified. The overlay tells the user to keep the app
          // open, so back must not pop the wallet out from under the
          // in-flight verification. At all other times back works
          // normally (canPop: true). Mirrors the PaymentSuccessPage
          // PopScope guard.
          return PopScope(
            canPop: !showOverlay,
            // Stack rather than a single Scaffold so the processing
            // overlay can cover the entire wallet (including the AppBar
            // coin chip) during CF verification without unmounting the
            // wallet body behind it.
            child: Stack(
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
            ),
          );
        },
      ),
    );
  }

  void _onStateChanged(BuildContext context, WalletState state) {
    if (state is WalletError) {
      // WalletError now means a genuine LOAD failure (initial fetch of
      // balance/packs) — _buildBody renders the full error+retry body
      // for it. Payment-time problems (store unavailable, verification
      // rejected) no longer land here: they arrive on the notices
      // stream (_onNotice) as a snackbar and keep the wallet body. We
      // still echo the load-error message as a snackbar for parity.
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
      context.push(
        '/user/payment-success',
        extra: <String, dynamic>{
          'coins': state.coinsPurchased,
          'newBalance': state.newBalance,
        },
      );
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
      leadingWidth: 64,
      leading: const Padding(
        padding: EdgeInsets.only(left: 16),
        child: AppBackButton(),
      ),
      titleSpacing: 4,
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
            child: _BalanceChip(balance: balance, isLoading: isLoading),
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
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Shimmer.fromColors(
                    baseColor: baseColor,
                    highlightColor: highlightColor,
                    child: Container(
                      height: 196,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(AppRadius.large),
                      ),
                    ),
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
                          childAspectRatio: 0.98,
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
          AppIcon(AppIcons.error, size: 44, color: AppColors.errorRed),
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
    final images = _coinImagesByPack(state.packs);

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
                  const SizedBox(height: 24),
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
                            mainAxisSpacing: 16,
                            childAspectRatio: 0.98,
                          ),
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      // Don't clip — let the bonus/popular badges straddle the
                      // top edge and the card shadows breathe past the cells.
                      clipBehavior: Clip.none,
                      itemCount: state.packs.length,
                      itemBuilder: (context, index) {
                        final pack = state.packs[index];
                        final isSelected = pack.id == state.selectedPackId;
                        return _CoinPackCard(
                          pack: pack,
                          isSelected: isSelected,
                          coinImage: images[pack.id] ?? _kCoinSingle,
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
    Widget line() => Expanded(
          child: Container(
            height: 1,
            color: AppColors.muted.withValues(alpha: 0.12),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          line(),
          const SizedBox(width: 14),
          const _SparkleAccent(size: 8),
          const SizedBox(width: 8),
          Text(
            text.toUpperCase(),
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.amberGold.withValues(alpha: 0.9),
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(width: 8),
          const _SparkleAccent(size: 8),
          const SizedBox(width: 14),
          line(),
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
            AppIcons.shield,
            size: 12,
            color: AppColors.muted.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 6),
          // Flexible so a future copy tweak can't push the icon
          // off-screen on a 320-wide device.
          Flexible(
            child: Text(
              "Secure payment · 100% safe",
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

  const _BalanceChip({required this.balance, required this.isLoading});

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
          const CoinImage(_kCoinSingle, size: 22),
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.large),
        child: Container(
          // Fill the row width. Without this the Stack shrink-wraps to its
          // content (the pill / number), making the hero card narrower than
          // the pack grid below it.
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppColors.surfaceCream,
            borderRadius: BorderRadius.circular(AppRadius.large),
            border: Border.all(
              color: AppColors.amberGold.withValues(alpha: 0.20),
            ),
            boxShadow: kWarmCardShadow,
          ),
          child: Stack(
            // Centre the content block — a Stack defaults to top-left, which
            // (now the card fills the full width) would shove the number and
            // pill to the left edge.
            alignment: Alignment.topCenter,
            children: [
              // Faded warm mountains + corner leaf sprigs behind the
              // figure — the payment-success blessing scene, contained.
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: const _WalletHeroBackdrop()),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const _SparkleAccent(size: 9),
                        const SizedBox(width: 10),
                        Text(
                          "YOU WILL RECEIVE",
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.amberGold.withValues(alpha: 0.9),
                            letterSpacing: 2.0,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const _SparkleAccent(size: 9),
                      ],
                    ),
                    const SizedBox(height: 6),
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
                          fontSize: 56,
                          fontWeight: FontWeight.w800,
                          color: hasSelection
                              ? AppColors.deepDarkBrown
                              : AppColors.muted.withValues(alpha: 0.35),
                          height: 1.0,
                          letterSpacing: -1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _dash(),
                        const SizedBox(width: 10),
                        Text(
                          "coins",
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: AppColors.muted,
                          ),
                        ),
                        const SizedBox(width: 10),
                        _dash(),
                      ],
                    ),
                    const SizedBox(height: 16),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: hasSelection
                          ? _infoPill(
                              key: ValueKey("pill-${selectedPack!.coins}"),
                              text: "Added instantly · Never expires",
                            )
                          : _infoPill(
                              key: const ValueKey("pill-hint"),
                              text: "Choose a pack below to start",
                              muted: true,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dash() => Container(
        width: 16,
        height: 1.5,
        decoration: BoxDecoration(
          color: AppColors.amberGold.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(1),
        ),
      );

  Widget _infoPill({
    required Key key,
    required String text,
    bool muted = false,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.amberGold.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: AppColors.deepDarkBrown.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(AppIcons.bolt, size: 11, color: AppColors.amberGold),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: muted
                    ? AppColors.muted
                    : AppColors.deepDarkBrown.withValues(alpha: 0.78),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Small gold 4-point sparkle used to frame the hero + section labels.
class _SparkleAccent extends StatelessWidget {
  final double size;
  const _SparkleAccent({required this.size});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: const CustomPaint(painter: _SparklePainter()),
    );
  }
}

class _SparklePainter extends CustomPainter {
  const _SparklePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2;
    final path = Path()
      ..moveTo(cx, cy - r)
      ..quadraticBezierTo(cx + r * 0.2, cy - r * 0.2, cx + r, cy)
      ..quadraticBezierTo(cx + r * 0.2, cy + r * 0.2, cx, cy + r)
      ..quadraticBezierTo(cx - r * 0.2, cy + r * 0.2, cx - r, cy)
      ..quadraticBezierTo(cx - r * 0.2, cy - r * 0.2, cx, cy - r)
      ..close();
    canvas.drawPath(path, Paint()..color = AppColors.amberGold);
  }

  @override
  bool shouldRepaint(covariant _SparklePainter oldDelegate) => false;
}

// Faded warm scene (layered mountains + corner leaf sprigs) behind the
// hero number. Painted, so it stays crisp and weighs nothing — mirrors
// the payment-success blessing scene in a contained card form.
class _WalletHeroBackdrop extends CustomPainter {
  const _WalletHeroBackdrop();

  static const Color _far = Color(0xFFE8D5B5);
  static const Color _mid = Color(0xFFDBBE8E);
  static const Color _front = Color(0xFFCBA468);
  static const Color _frontDark = Color(0xFFB68A4E);
  static const Color _leaf = Color(0xFFD0B584);
  static const Color _leafShadow = Color(0xFFB68A4E);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Four warm ranges in the lower half — bolder + more layered than a
    // faint wash, the closest a deeper brown hugging the base.
    _ridge(canvas, size, const [
      Offset(0, 0.60),
      Offset(0.22, 0.52),
      Offset(0.46, 0.58),
      Offset(0.72, 0.50),
      Offset(1, 0.58),
    ], _far.withValues(alpha: 0.48));
    _ridge(canvas, size, const [
      Offset(0, 0.70),
      Offset(0.26, 0.61),
      Offset(0.52, 0.68),
      Offset(0.78, 0.59),
      Offset(1, 0.68),
    ], _mid.withValues(alpha: 0.58));
    _ridge(canvas, size, const [
      Offset(0, 0.80),
      Offset(0.30, 0.71),
      Offset(0.56, 0.78),
      Offset(0.82, 0.69),
      Offset(1, 0.80),
    ], _front.withValues(alpha: 0.64));
    _ridge(canvas, size, const [
      Offset(0, 0.91),
      Offset(0.34, 0.84),
      Offset(0.60, 0.89),
      Offset(0.86, 0.84),
      Offset(1, 0.91),
    ], _frontDark.withValues(alpha: 0.55));

    _leafSprig(canvas, Offset(w * 0.04, h * 0.04), 1, h);
    _leafSprig(canvas, Offset(w * 0.96, h * 0.04), -1, h);
  }

  void _ridge(Canvas canvas, Size size, List<Offset> frac, Color color) {
    final pts = frac
        .map((f) => Offset(f.dx * size.width, f.dy * size.height))
        .toList();
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length - 1; i++) {
      final xc = (pts[i].dx + pts[i + 1].dx) / 2;
      final yc = (pts[i].dy + pts[i + 1].dy) / 2;
      path.quadraticBezierTo(pts[i].dx, pts[i].dy, xc, yc);
    }
    final last = pts.last;
    path.quadraticBezierTo(last.dx, last.dy, last.dx, last.dy);
    path
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _leafSprig(Canvas canvas, Offset base, int dirX, double h) {
    final stemLen = h * 0.52;
    final tip = Offset(base.dx + dirX * h * 0.14, base.dy + stemLen);
    final ctrl = Offset(base.dx + dirX * h * 0.03, base.dy + stemLen * 0.5);
    canvas.drawPath(
      Path()
        ..moveTo(base.dx, base.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, tip.dx, tip.dy),
      Paint()
        ..color = _leaf.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = h * 0.011
        ..strokeCap = StrokeCap.round,
    );
    const count = 7;
    for (var i = 1; i <= count; i++) {
      final t = i / (count + 1);
      final at = _quad(base, ctrl, tip, t);
      final leafLen = h * (0.17 - 0.013 * i);
      final angle = (i.isEven) ? 0.55 : 0.95;
      final lt = Offset(
        at.dx - dirX * leafLen * math.sin(angle),
        at.dy + leafLen * math.cos(angle),
      );
      _drawLeaf(canvas, at, lt, leafLen * 0.34);
    }
  }

  void _drawLeaf(Canvas canvas, Offset start, Offset tip, double width) {
    final dx = tip.dx - start.dx;
    final dy = tip.dy - start.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    final px = -dy / len * width;
    final py = dx / len * width;
    final mid = Offset((start.dx + tip.dx) / 2, (start.dy + tip.dy) / 2);
    canvas.drawPath(
      Path()
        ..moveTo(start.dx, start.dy)
        ..quadraticBezierTo(mid.dx + px, mid.dy + py, tip.dx, tip.dy)
        ..quadraticBezierTo(mid.dx - px, mid.dy - py, start.dx, start.dy)
        ..close(),
      Paint()..color = _leaf.withValues(alpha: 0.5),
    );
    canvas.drawLine(
      start,
      tip,
      Paint()
        ..color = _leafShadow.withValues(alpha: 0.35)
        ..strokeWidth = width * 0.16
        ..strokeCap = StrokeCap.round,
    );
  }

  Offset _quad(Offset p0, Offset p1, Offset p2, double t) {
    final u = 1 - t;
    return Offset(
      u * u * p0.dx + 2 * u * t * p1.dx + t * t * p2.dx,
      u * u * p0.dy + 2 * u * t * p1.dy + t * t * p2.dy,
    );
  }

  @override
  bool shouldRepaint(covariant _WalletHeroBackdrop oldDelegate) => false;
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
  final String coinImage;
  final VoidCallback onTap;

  const _CoinPackCard({
    required this.pack,
    required this.isSelected,
    required this.coinImage,
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
        !widget.pack.isPopular && widget.pack.discountPercent > 0;
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
                      color: AppColors.primaryBrown.withValues(alpha: 0.12),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : kWarmCardShadow,
          ),
          child: Stack(
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(12, hasTopBadge ? 22 : 14, 12, 14),
                child: Column(
                  // Distribute (not centre) so the coin sits up top and the
                  // price near the bottom, filling the card like the mockup
                  // rather than clustering in the middle. spaceEvenly also
                  // can't overflow — it absorbs slack as gaps.
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    CoinImage(widget.coinImage, size: 50),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
                      ],
                    ),
                    Container(
                      height: 1,
                      width: double.infinity,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      color: AppColors.muted.withValues(alpha: 0.14),
                    ),
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
                  top: -9,
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
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const AppIcon(
                            AppIcons.starFilled,
                            size: 8,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            "POPULAR",
                            style: GoogleFonts.inter(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: 0.6,
                            ),
                          ),
                          const SizedBox(width: 5),
                          const AppIcon(
                            AppIcons.starFilled,
                            size: 8,
                            color: Colors.white,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (hasBonusBadge)
                Positioned(
                  top: -9,
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
            height: 56,
            decoration: BoxDecoration(
              gradient: (hasPack || widget.isPaymentInProgress)
                  ? const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xFF7C4634),
                        AppColors.primaryBrown,
                        Color(0xFF5A2E20),
                      ],
                    )
                  : null,
              color: (hasPack || widget.isPaymentInProgress)
                  ? null
                  : AppColors.muted.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
              boxShadow: (hasPack || widget.isPaymentInProgress)
                  ? [
                      BoxShadow(
                        color: AppColors.primaryBrown.withValues(alpha: 0.3),
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
                        width: 35,
                        height: 35,
                        child: AppLoader(),
                      )
                    : hasPack
                    ? Row(
                        key: ValueKey("pay-${widget.selectedPack!.price}"),
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            "Proceed to Pay  ₹${widget.selectedPack!.price}",
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: 0.1,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const AppIcon(
                            AppIcons.chevronRight,
                            size: 22,
                            color: Colors.white,
                          ),
                        ],
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
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
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
