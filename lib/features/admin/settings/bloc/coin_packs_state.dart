// Coin packs states

import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';

sealed class CoinPacksState {}

class CoinPacksInitial extends CoinPacksState {}

class CoinPacksLoading extends CoinPacksState {}

class CoinPacksLoaded extends CoinPacksState {
  final List<CoinPackModel> packs;

  CoinPacksLoaded(this.packs);

  List<CoinPackModel> get activePacks =>
      packs.where((p) => p.isActive).toList();

  List<CoinPackModel> get inactivePacks =>
      packs.where((p) => !p.isActive).toList();
}

class CoinPacksError extends CoinPacksState {
  final String message;

  CoinPacksError(this.message);
}
