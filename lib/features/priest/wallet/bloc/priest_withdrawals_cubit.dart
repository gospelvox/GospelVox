// Drives the priest "My Withdrawals" status screen: a LIVE stream of
// the priest's withdrawal records (newest first), so the timeline,
// reference, and status advance on their own as the admin processes the
// payout — no pull-to-refresh needed. Kept separate from
// PriestWalletCubit because the status screen is its own route with its
// own lifecycle.

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/priest/wallet/data/priest_wallet_repository.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';

sealed class PriestWithdrawalsState {
  const PriestWithdrawalsState();
}

class PriestWithdrawalsLoading extends PriestWithdrawalsState {
  const PriestWithdrawalsLoading();
}

class PriestWithdrawalsLoaded extends PriestWithdrawalsState {
  final List<WithdrawalRecord> items;
  const PriestWithdrawalsLoaded(this.items);
}

class PriestWithdrawalsError extends PriestWithdrawalsState {
  final String message;
  const PriestWithdrawalsError(this.message);
}

class PriestWithdrawalsCubit extends Cubit<PriestWithdrawalsState> {
  final PriestWalletRepository _repository;
  StreamSubscription<List<WithdrawalRecord>>? _sub;

  PriestWithdrawalsCubit(this._repository)
      : super(const PriestWithdrawalsLoading());

  // Subscribes to the live withdrawals stream so the screen updates the
  // instant the admin advances any payout.
  Future<void> load(String uid) async {
    if (isClosed) return;
    if (state is! PriestWithdrawalsLoaded) {
      emit(const PriestWithdrawalsLoading());
    }
    await _sub?.cancel();
    _sub = _repository.watchWithdrawals(uid).listen(
      (items) {
        if (isClosed) return;
        emit(PriestWithdrawalsLoaded(items));
      },
      onError: (_) {
        if (isClosed) return;
        // Keep the last good list on a transient error.
        if (state is PriestWithdrawalsLoaded) return;
        emit(const PriestWithdrawalsError('Could not load withdrawals.'));
      },
    );
  }

  // Pull-to-refresh is now a no-op data-wise (the list is live); kept so
  // the screen's RefreshIndicator still has something to await.
  Future<void> refresh(String uid) async {
    // Live stream already keeps this current; nothing to fetch.
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    return super.close();
  }
}
