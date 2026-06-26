// GetIt service locator setup for dependency injection

import 'package:cloud_functions/cloud_functions.dart';
import 'package:get_it/get_it.dart';

import 'package:gospel_vox/core/config/iap_products.dart';
import 'package:gospel_vox/core/services/iap_service.dart';
import 'package:gospel_vox/features/admin/dashboard/bloc/dashboard_cubit.dart';
import 'package:gospel_vox/features/admin/dashboard/data/dashboard_repository.dart';
import 'package:gospel_vox/features/admin/revenue/bloc/revenue_cubit.dart';
import 'package:gospel_vox/features/admin/revenue/data/revenue_repository.dart';
import 'package:gospel_vox/features/admin/settings/bloc/coin_packs_cubit.dart';
import 'package:gospel_vox/features/admin/settings/bloc/settings_cubit.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_packs_repository.dart';
import 'package:gospel_vox/features/admin/settings/data/settings_repository.dart';
import 'package:gospel_vox/features/admin/reports/bloc/admin_reports_cubit.dart';
import 'package:gospel_vox/features/admin/reports/data/admin_reports_repository.dart';
import 'package:gospel_vox/features/admin/sessions/bloc/admin_sessions_cubit.dart';
import 'package:gospel_vox/features/admin/sessions/data/admin_sessions_repository.dart';
import 'package:gospel_vox/features/admin/speakers/bloc/speaker_detail_cubit.dart';
import 'package:gospel_vox/features/admin/speakers/bloc/speakers_cubit.dart';
import 'package:gospel_vox/features/admin/speakers/data/speakers_repository.dart';
import 'package:gospel_vox/features/admin/users/bloc/admin_users_cubit.dart';
import 'package:gospel_vox/features/admin/users/data/admin_users_repository.dart';
import 'package:gospel_vox/features/admin/withdrawals/bloc/admin_withdrawals_cubit.dart';
import 'package:gospel_vox/features/admin/withdrawals/data/admin_withdrawals_repository.dart';
import 'package:gospel_vox/features/auth/bloc/auth_cubit.dart';
import 'package:gospel_vox/features/auth/data/auth_repository.dart';
import 'package:gospel_vox/features/priest/activation/bloc/activation_cubit.dart';
import 'package:gospel_vox/features/priest/activation/data/activation_repository.dart';
import 'package:gospel_vox/features/priest/registration/bloc/priest_registration_cubit.dart';
import 'package:gospel_vox/features/priest/registration/data/priest_registration_repository.dart';
import 'package:gospel_vox/features/priest/session/bloc/incoming_request_cubit.dart';
import 'package:gospel_vox/features/priest/wallet/bloc/priest_wallet_cubit.dart';
import 'package:gospel_vox/features/priest/wallet/data/priest_wallet_repository.dart';
import 'package:gospel_vox/features/shared/bloc/bible_session_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/chat_session_cubit.dart';
import 'package:gospel_vox/features/shared/bloc/session_history_cubit.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';
import 'package:gospel_vox/features/shared/data/session_history_repository.dart';
import 'package:gospel_vox/features/shared/data/session_repository.dart';
import 'package:gospel_vox/features/user/home/bloc/home_cubit.dart';
import 'package:gospel_vox/features/user/home/data/home_repository.dart';
import 'package:gospel_vox/features/user/session/bloc/session_request_cubit.dart';
import 'package:gospel_vox/features/user/wallet/bloc/wallet_cubit.dart';
import 'package:gospel_vox/features/user/wallet/data/wallet_repository.dart';

final sl = GetIt.instance;

// Adapter from WalletRepository's coin-flavoured verify call to the
// product-agnostic IapVerifier contract IapService expects. Keeps
// the per-product wiring in one place rather than threading
// IapVerifyResult through WalletRepository (which has no business
// knowing about the IapService abstraction layer).
//
// Accepts the optional `sessionId` from the IapVerifier typedef and
// ignores it — coin purchases are per-SKU and don't carry any
// session context. The parameter is here purely so this closure
// type-matches the typedef after the Bible flow added it.
IapVerifier _coinVerifier(WalletRepository wallet) {
  return ({required productId, required purchaseToken, String? sessionId}) async {
    final result = await wallet.verifyCoinPurchase(
      productId: productId,
      purchaseToken: purchaseToken,
    );
    return IapVerifyResult(
      consumeMode: IapConsumeMode.consume,
      newBalance: result.newBalance,
    );
  };
}

Future<void> initDependencies() async {
  // Auth
  sl.registerLazySingleton<AuthRepository>(() => AuthRepository());
  sl.registerFactory<AuthCubit>(() => AuthCubit(sl<AuthRepository>()));

  // Admin dashboard
  sl.registerLazySingleton<DashboardRepository>(() => DashboardRepository());
  sl.registerFactory<DashboardCubit>(
      () => DashboardCubit(sl<DashboardRepository>()));

  // Admin revenue
  sl.registerLazySingleton<RevenueRepository>(() => RevenueRepository());
  sl.registerFactory<RevenueCubit>(
      () => RevenueCubit(sl<RevenueRepository>()));

  // Admin settings
  sl.registerLazySingleton<SettingsRepository>(() => SettingsRepository());
  sl.registerFactory<SettingsCubit>(
      () => SettingsCubit(sl<SettingsRepository>()));

  // Coin packs
  sl.registerLazySingleton<CoinPacksRepository>(() => CoinPacksRepository());
  sl.registerFactory<CoinPacksCubit>(
      () => CoinPacksCubit(sl<CoinPacksRepository>()));

  // In-app purchase service. Single instance owns the global
  // purchase stream — see iap_service.dart for the rationale.
  // No-arg constructor: the service is verifier-agnostic by design
  // and each product domain registers its own verifier through
  // `registerVerifier(...)` further down. `init()` is called from
  // main.dart after this function returns. Registration order
  // between IapService and the repositories that register
  // verifiers is irrelevant because `registerLazySingleton` is
  // lazy — what matters is that all `registerVerifier` calls
  // happen here, before any UI mounts and starts buying.
  sl.registerLazySingleton<IapService>(() => IapService());

  // User wallet
  sl.registerLazySingleton<WalletRepository>(() => WalletRepository());
  sl.registerFactory<WalletCubit>(
      () => WalletCubit(sl<WalletRepository>(), sl<IapService>()));

  // Wire the coin verifier into IapService for every Play SKU in
  // the catalogue. Resolving both singletons here forces their
  // construction; the registerVerifier calls populate the
  // dispatch map before `init()` runs in main(), so the very
  // first restored purchase finds its verifier ready.
  //
  // Each coin pack registers the SAME verifier closure — the
  // server's verifyCoinPurchase CF resolves the coin count from
  // the productId itself, so the closure is product-agnostic.
  {
    final iap = sl<IapService>();
    final walletRepo = sl<WalletRepository>();
    final verifier = _coinVerifier(walletRepo);
    for (final sku in IapProducts.allCoinPacks) {
      iap.registerVerifier(sku, verifier);
    }
  }

  // User home — repo is a singleton (stateless), but the cubit is a
  // factory because each home-tab mount should own its own stream
  // subscription; a singleton would leak past sign-out.
  sl.registerLazySingleton<HomeRepository>(() => HomeRepository());
  sl.registerFactory<HomeCubit>(() => HomeCubit(sl<HomeRepository>()));

  // Admin speakers — repo singleton (stateless), cubits are factories
  // so each page instance gets a fresh state machine.
  sl.registerLazySingleton<SpeakersRepository>(
      () => SpeakersRepository());
  sl.registerFactory<SpeakersCubit>(
      () => SpeakersCubit(sl<SpeakersRepository>()));
  sl.registerFactory<SpeakerDetailCubit>(
      () => SpeakerDetailCubit(sl<SpeakersRepository>()));

  // Admin users / sessions / reports / withdrawals — same shape as
  // speakers: stateless repo (singleton) + factory cubit so each
  // page mount starts with a fresh state machine, and the sessions
  // cubit's long-lived stream subscription dies with the page.
  sl.registerLazySingleton<AdminUsersRepository>(
      () => AdminUsersRepository());
  sl.registerFactory<AdminUsersCubit>(
      () => AdminUsersCubit(sl<AdminUsersRepository>()));

  sl.registerLazySingleton<AdminSessionsRepository>(
      () => AdminSessionsRepository());
  sl.registerFactory<AdminSessionsCubit>(
      () => AdminSessionsCubit(sl<AdminSessionsRepository>()));

  sl.registerLazySingleton<AdminReportsRepository>(
      () => AdminReportsRepository());
  sl.registerFactory<AdminReportsCubit>(
      () => AdminReportsCubit(sl<AdminReportsRepository>()));

  sl.registerLazySingleton<AdminWithdrawalsRepository>(
      () => AdminWithdrawalsRepository());
  sl.registerFactory<AdminWithdrawalsCubit>(
      () => AdminWithdrawalsCubit(sl<AdminWithdrawalsRepository>()));

  // Priest registration — repo is a singleton (it's stateless), but
  // the cubit is a factory because each registration session should
  // start with a fresh state machine.
  sl.registerLazySingleton<PriestRegistrationRepository>(
      () => PriestRegistrationRepository());
  sl.registerFactory<PriestRegistrationCubit>(
      () => PriestRegistrationCubit(sl<PriestRegistrationRepository>()));

  // Priest activation — same shape: stateless repo + fresh cubit per
  // paywall mount so a back-and-forth re-entry starts clean. The
  // cubit owns its own IapService subscription (Pattern A, mirrors
  // wallet_cubit), so the factory passes the IapService singleton
  // in alongside the repository.
  sl.registerLazySingleton<ActivationRepository>(
      () => ActivationRepository());
  sl.registerFactory<ActivationCubit>(
      () => ActivationCubit(
            sl<ActivationRepository>(),
            sl<IapService>(),
          ));

  // Wire the activation verifier into IapService. Mirrors the coin
  // verifier block above. Re-resolves sl<IapService>() — it's the
  // same singleton — to keep the registration block local to the
  // activation registrations rather than threading the iap handle
  // 60 lines down from the coin block.
  {
    final iap = sl<IapService>();
    final activationRepo = sl<ActivationRepository>();
    iap.registerVerifier(
      IapProducts.priestActivation,
      // `sessionId` accepted to match the IapVerifier typedef and
      // ignored — activation is a single non-consumable SKU with no
      // session context. The CF cross-checks the priest's identity
      // via the auth token, not via any client-supplied id.
      ({required productId, required purchaseToken, String? sessionId}) =>
          activationRepo.verifyActivationPurchase(
        productId: productId,
        purchaseToken: purchaseToken,
      ),
    );
  }

  // Priest wallet — stateless repo (singleton) + factory cubit so
  // each wallet page mount gets a fresh balance subscription. The
  // bank-details page also resolves the repo from `sl` directly to
  // save bank fields without needing the cubit.
  sl.registerLazySingleton<PriestWalletRepository>(
      () => PriestWalletRepository());
  sl.registerFactory<PriestWalletCubit>(
      () => PriestWalletCubit(sl<PriestWalletRepository>()));

  // Sessions — the repository is shared between user and priest
  // sides because both halves read from the same sessions collection
  // and we don't want two parallel models drifting. Cubits are
  // factories so each waiting/incoming page mount owns its own
  // timers + stream subscription.
  sl.registerLazySingleton<SessionRepository>(() => SessionRepository());
  sl.registerFactory<SessionRequestCubit>(
      () => SessionRequestCubit(sl<SessionRepository>()));
  sl.registerFactory<IncomingRequestCubit>(
      () => IncomingRequestCubit(sl<SessionRepository>()));

  // Chat session — factory so each chat screen mount owns its own
  // timers + stream subscriptions. Sharing a singleton would mean
  // the stopwatch from a previous session would carry into the
  // next one.
  sl.registerFactory<ChatSessionCubit>(
      () => ChatSessionCubit(sl<SessionRepository>()));

  // Session history — stateless repo (singleton) + factory cubit so
  // each history-list mount gets a fresh state machine. Used by both
  // the user "Me" tab and the priest dashboard's quick actions.
  sl.registerLazySingleton<SessionHistoryRepository>(
      () => SessionHistoryRepository());
  sl.registerFactory<SessionHistoryCubit>(
      () => SessionHistoryCubit(sl<SessionHistoryRepository>()));

  // Bible sessions — stateless repo (singleton) + factory cubit. The
  // user-side Bible tab owns the cubit's lifecycle inside the shell;
  // priest-side pages talk to the repo directly because they don't
  // need the cubit's tab machine.
  sl.registerLazySingleton<BibleSessionRepository>(
      () => BibleSessionRepository());
  sl.registerFactory<BibleSessionCubit>(
      () => BibleSessionCubit(sl<BibleSessionRepository>()));

  // Wire the Bible verifier into IapService. Mirrors the coin +
  // activation blocks above. The bible flow is the only product
  // type that consumes the optional `sessionId` parameter on the
  // IapVerifier typedef — sourced from Play's obfuscatedAccountId,
  // which the bible detail page set via PurchaseParam
  // .applicationUserName at buy time. A null/empty sessionId here
  // means a Bible purchase arrived with no session context (the
  // detail page didn't set applicationUserName, or the purchase
  // was somehow stripped of it). Throwing FirebaseFunctionsException
  // 'invalid-argument' makes _verifyAndEmit treat the failure as
  // terminal (clears the queue via _safeComplete) so the purchase
  // doesn't loop forever on every app launch — preferable to a
  // CF rejection that would just confuse the user with a generic
  // server error.
  {
    final iap = sl<IapService>();
    final bibleRepo = sl<BibleSessionRepository>();
    iap.registerVerifier(
      IapProducts.bibleSession199,
      ({required productId, required purchaseToken, String? sessionId}) async {
        if (sessionId == null || sessionId.isEmpty) {
          throw FirebaseFunctionsException(
            code: 'invalid-argument',
            message: 'sessionId required for bible purchase',
          );
        }
        return await bibleRepo.verifyBibleSessionPurchase(
          sessionId: sessionId,
          productId: productId,
          purchaseToken: purchaseToken,
        );
      },
    );
  }

  // Note: AgoraService is intentionally NOT registered here. The
  // RTC engine holds native audio resources that must be lifecycle-
  // bound to the page that uses them; reusing a singleton across
  // calls produces audio glitches and "channel already joined"
  // errors. VoiceCallPage / PriestVoiceCallPage construct a fresh
  // AgoraService inline inside their BlocProvider and the
  // VoiceCallCubit disposes it on close.

  // Note: VoiceCallCubit is intentionally NOT registered here. It
  // takes the per-page AgoraService as a constructor param, so it
  // can't be sourced from a global factory the way ChatSessionCubit
  // can — the voice pages build it directly inside BlocProvider.
}
