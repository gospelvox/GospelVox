// Cubit driving the priest wallet page. Owns the live priest-doc
// stream, the transaction list, and the withdrawal request flow.
//
// Notable choices:
//   • The summary stream is restarted on every loadWallet so a
//     re-entry (pull-to-refresh after sign-out/in) doesn't fight
//     a stale subscription tied to the previous uid.
//   • Withdrawal errors `rethrow` after rolling back isWithdrawing,
//     because the page wants to inspect the WithdrawalException's
//     `reason` token and surface a specific snackbar (insufficient_
//     balance vs. below_minimum vs. generic). Emitting an error
//     state here would replace the wallet body, which we don't
//     want — the wallet should remain visible underneath the
//     failure message.

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/priest/wallet/bloc/priest_wallet_state.dart';
import 'package:gospel_vox/features/priest/wallet/data/priest_wallet_repository.dart';
import 'package:gospel_vox/features/priest/wallet/data/wallet_models.dart';
import 'package:gospel_vox/features/priest/wallet/data/withdrawal_status.dart';

class PriestWalletCubit extends Cubit<PriestWalletState> {
  final PriestWalletRepository _repository;
  StreamSubscription<PriestWalletSummary>? _summarySubscription;
  StreamSubscription<List<WithdrawalRecord>>? _withdrawalsSubscription;
  // Latest streamed withdrawals, cached so the value is available
  // whether the withdrawals stream or the summary stream (which flips
  // us into Loaded) fires first.
  List<WithdrawalRecord> _withdrawalsCache = const [];

  PriestWalletCubit(this._repository) : super(const PriestWalletInitial());

  Future<void> loadWallet(String uid) async {
    try {
      if (isClosed) return;
      emit(const PriestWalletLoading());

      // Parallel because none of these reads depend on each other.
      // Bank details now ride on the summary stream, so we only
      // need transactions + the admin-controlled minimum here.
      final results = await Future.wait([
        _repository.getTransactions(uid),
        _repository.getMinWithdrawalAmount(),
      ]);

      if (isClosed) return;

      final transactions = results[0] as List<WalletTransaction>;
      final minAmount = results[1] as int;

      // Cancel-then-resubscribe so a re-load doesn't leak the prior
      // subscription. The first summary event is what flips us from
      // Loading to Loaded — we deliberately don't emit Loaded with
      // a placeholder zero balance first, since that flickers the
      // hero amount on first paint.
      await _summarySubscription?.cancel();
      _summarySubscription = _repository.watchSummary(uid).listen(
        (summary) {
          if (isClosed) return;
          final current = state;
          if (current is PriestWalletLoaded) {
            emit(current.copyWith(
              balance: summary.balance,
              totalEarnings: summary.totalEarnings,
              totalWithdrawn: summary.totalWithdrawn,
              overwriteBankDetails: true,
              bankDetails: summary.bankDetails,
            ));
          } else {
            emit(PriestWalletLoaded(
              balance: summary.balance,
              totalEarnings: summary.totalEarnings,
              totalWithdrawn: summary.totalWithdrawn,
              transactions: transactions,
              bankDetails: summary.bankDetails,
              minWithdrawalAmount: minAmount,
              withdrawals: _withdrawalsCache,
            ));
          }
        },
        onError: (_) {
          // Stream errors here are usually transient (auth refresh,
          // brief offline). We don't tear down the loaded state —
          // the next snapshot will re-sync.
        },
      );

      // Live withdrawals stream — feeds the "in progress" card and the
      // history status tags. Cached so it survives the Loading->Loaded
      // flip regardless of which stream emits first.
      await _withdrawalsSubscription?.cancel();
      _withdrawalsCache = const [];
      _withdrawalsSubscription = _repository.watchWithdrawals(uid).listen(
        (list) {
          _withdrawalsCache = list;
          if (isClosed) return;
          final current = state;
          if (current is PriestWalletLoaded) {
            emit(current.copyWith(withdrawals: list));
          }
        },
        onError: (_) {
          // Transient — keep showing the last good list.
        },
      );
    } on TimeoutException {
      if (isClosed) return;
      emit(const PriestWalletError(
        "Taking too long. Check your connection.",
      ));
    } catch (_) {
      if (isClosed) return;
      emit(const PriestWalletError("Failed to load wallet."));
    }
  }

  // Pull-to-refresh entry point. Silently no-ops if we're not in
  // Loaded state. Failures during refresh swallow — the wallet
  // stays mounted with the existing data.
  Future<void> refreshTransactions(String uid) async {
    final current = state;
    if (current is! PriestWalletLoaded) return;

    try {
      final transactions = await _repository.getTransactions(uid);
      if (isClosed) return;
      emit(current.copyWith(transactions: transactions));
    } catch (_) {
      // Silent — the existing list stays visible.
    }
  }

  // Triggers the CF, then reloads the transaction list so the new
  // withdrawal entry appears without waiting for a manual refresh.
  // Generates the idempotency token here so the page (or any other
  // caller) doesn't have to know about it.
  //
  // Rethrows so the page can branch on the error reason; cubit
  // state-machine error vs. a one-shot snackbar is the page's call.
  Future<void> requestWithdrawal(int amount, String uid) async {
    final current = state;
    if (current is! PriestWalletLoaded || current.isWithdrawing) return;

    try {
      if (isClosed) return;
      emit(current.copyWith(isWithdrawing: true));

      final clientRequestId = _repository.generateClientRequestId();
      final result = await _repository.requestWithdrawal(
        amount: amount,
        clientRequestId: clientRequestId,
      );

      // Re-fetch transactions inline. The balance has already moved
      // via the live stream by the time the CF returns, but the
      // transactions list won't have caught up yet.
      final transactions = await _repository.getTransactions(uid);

      if (isClosed) return;

      // Optimistically surface the just-created withdrawal at the top of
      // the list NOW, instead of waiting for the watchWithdrawals stream
      // to emit. Without this, `spotlightWithdrawal` (the in-progress
      // card) keeps showing the PREVIOUS withdrawal until the stream
      // catches up — which is why it only updated once the admin moved
      // it to processing. The stream replaces this with the real record
      // (same id) a moment later. Read the freshest list off `state` so
      // a stream emit that landed during the await isn't dropped.
      // Emit onto the FRESHEST loaded state (not the stale `current`
      // captured before the awaits) so a summary-stream update that
      // landed mid-request — new balance / totalWithdrawn / bankDetails
      // — isn't reverted. Falls back to `current` only if state somehow
      // left Loaded.
      final latest = state;
      final fresh = latest is PriestWalletLoaded ? latest : current;
      final optimistic = WithdrawalRecord(
        id: result.withdrawalId,
        amount: amount,
        status: WithdrawalStatus.pending,
        createdAt: DateTime.now(),
      );
      final mergedWithdrawals = [
        optimistic,
        ...fresh.withdrawals.where((w) => w.id != optimistic.id),
      ];

      emit(fresh.copyWith(
        balance: result.newBalance,
        transactions: transactions,
        withdrawals: mergedWithdrawals,
        isWithdrawing: false,
      ));
    } on TimeoutException {
      if (isClosed) return;
      emit(current.copyWith(isWithdrawing: false));
      rethrow;
    } on WithdrawalException {
      if (isClosed) return;
      emit(current.copyWith(isWithdrawing: false));
      rethrow;
    } catch (_) {
      if (isClosed) return;
      emit(current.copyWith(isWithdrawing: false));
      rethrow;
    }
  }

  // Called by the wallet page after the bank-details page returns
  // with saved details, so the hero CTA flips to active immediately
  // without waiting for the next priest-doc snapshot. The stream
  // will eventually catch up with the same value.
  void updateBankDetails(BankDetails details) {
    if (isClosed) return;
    final current = state;
    if (current is PriestWalletLoaded) {
      emit(current.copyWith(
        overwriteBankDetails: true,
        bankDetails: details,
      ));
    }
  }

  // Optimistic local clear after the wallet page commits the
  // delete-bank action. The priest doc stream will also surface the
  // empty-string fields a moment later (PriestWalletSummary maps
  // empty holder → null bankDetails), so this call just makes the
  // hero CTA flip back to "Add Bank Details" without waiting on
  // the round-trip.
  void clearBankDetails() {
    if (isClosed) return;
    final current = state;
    if (current is PriestWalletLoaded) {
      emit(current.copyWith(
        overwriteBankDetails: true,
        bankDetails: null,
      ));
    }
  }

  @override
  Future<void> close() async {
    await _summarySubscription?.cancel();
    await _withdrawalsSubscription?.cancel();
    return super.close();
  }
}
