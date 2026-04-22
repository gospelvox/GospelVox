// Coin packs cubit — CRUD operations on coin packs

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/settings/bloc/coin_packs_state.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_pack_model.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_packs_repository.dart';

class CoinPacksCubit extends Cubit<CoinPacksState> {
  final CoinPacksRepository _repository;

  CoinPacksCubit(this._repository) : super(CoinPacksInitial());

  Future<void> loadPacks() async {
    try {
      emit(CoinPacksLoading());
      final packs = await _repository.getPacks();
      emit(CoinPacksLoaded(packs));
    } on TimeoutException {
      emit(CoinPacksError('Taking too long. Check connection.'));
    } catch (e) {
      debugPrint('[CoinPacks] load failed: $e');
      emit(CoinPacksError('Failed to load coin packs.'));
    }
  }

  Future<void> toggleActive(String packId, bool isActive) async {
    try {
      await _repository.toggleActive(packId, isActive);
      await loadPacks();
    } catch (e) {
      emit(CoinPacksError('Failed to update pack.'));
    }
  }

  Future<void> setPopular(String packId) async {
    try {
      await _repository.setPopular(packId);
      await loadPacks();
    } catch (e) {
      emit(CoinPacksError('Failed to set popular.'));
    }
  }

  Future<void> addPack(CoinPackModel pack) async {
    try {
      await _repository.addPack(pack);
      await loadPacks();
    } catch (e) {
      emit(CoinPacksError('Failed to add pack.'));
    }
  }

  Future<void> updatePack(CoinPackModel pack) async {
    try {
      await _repository.updatePack(pack);
      await loadPacks();
    } catch (e) {
      emit(CoinPacksError('Failed to update pack.'));
    }
  }

  Future<void> deletePack(String packId) async {
    try {
      await _repository.deletePack(packId);
      await loadPacks();
    } catch (e) {
      emit(CoinPacksError('Failed to delete pack.'));
    }
  }
}
