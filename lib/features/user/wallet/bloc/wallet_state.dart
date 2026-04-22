import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';

sealed class WalletState {}

class WalletInitial extends WalletState {}

class WalletLoading extends WalletState {}

class WalletLoaded extends WalletState {
  final int balance;
  final List<CoinPackModel> packs;
  final bool showWelcomeOffer;
  final int welcomeOfferCoins;
  final int welcomeOfferPrice;
  final String? selectedPackId;

  // `isPurchasing` lives on WalletLoaded (rather than a separate
  // WalletPurchasing state) so the processing overlay can sit on
  // top of a fully-rendered wallet page. A separate state would
  // cause the build tree behind the overlay to collapse and flash
  // empty during CF verification.
  final bool isPurchasing;

  WalletLoaded({
    required this.balance,
    required this.packs,
    required this.showWelcomeOffer,
    required this.welcomeOfferCoins,
    required this.welcomeOfferPrice,
    this.selectedPackId,
    this.isPurchasing = false,
  });

  CoinPackModel? get selectedPack {
    if (selectedPackId == null) return null;
    try {
      return packs.firstWhere((p) => p.id == selectedPackId);
    } catch (_) {
      return null;
    }
  }

  WalletLoaded copyWith({
    int? balance,
    List<CoinPackModel>? packs,
    bool? showWelcomeOffer,
    int? welcomeOfferCoins,
    int? welcomeOfferPrice,
    String? selectedPackId,
    bool? isPurchasing,
  }) {
    return WalletLoaded(
      balance: balance ?? this.balance,
      packs: packs ?? this.packs,
      showWelcomeOffer: showWelcomeOffer ?? this.showWelcomeOffer,
      welcomeOfferCoins: welcomeOfferCoins ?? this.welcomeOfferCoins,
      welcomeOfferPrice: welcomeOfferPrice ?? this.welcomeOfferPrice,
      selectedPackId: selectedPackId ?? this.selectedPackId,
      isPurchasing: isPurchasing ?? this.isPurchasing,
    );
  }
}

class WalletPurchaseSuccess extends WalletState {
  final int newBalance;
  final int coinsPurchased;
  WalletPurchaseSuccess(this.newBalance, this.coinsPurchased);
}

class WalletError extends WalletState {
  final String message;
  WalletError(this.message);
}
