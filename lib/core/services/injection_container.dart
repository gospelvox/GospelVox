// GetIt service locator setup for dependency injection

import 'package:get_it/get_it.dart';

import 'package:gospel_vox/features/admin/dashboard/bloc/dashboard_cubit.dart';
import 'package:gospel_vox/features/admin/dashboard/data/dashboard_repository.dart';
import 'package:gospel_vox/features/admin/settings/bloc/coin_packs_cubit.dart';
import 'package:gospel_vox/features/admin/settings/bloc/settings_cubit.dart';
import 'package:gospel_vox/features/admin/settings/data/coin_packs_repository.dart';
import 'package:gospel_vox/features/admin/settings/data/settings_repository.dart';
import 'package:gospel_vox/features/admin/speakers/bloc/speaker_detail_cubit.dart';
import 'package:gospel_vox/features/admin/speakers/bloc/speakers_cubit.dart';
import 'package:gospel_vox/features/admin/speakers/data/speakers_repository.dart';
import 'package:gospel_vox/features/auth/bloc/auth_cubit.dart';
import 'package:gospel_vox/features/auth/data/auth_repository.dart';
import 'package:gospel_vox/features/priest/activation/bloc/activation_cubit.dart';
import 'package:gospel_vox/features/priest/activation/data/activation_repository.dart';
import 'package:gospel_vox/features/priest/registration/bloc/priest_registration_cubit.dart';
import 'package:gospel_vox/features/priest/registration/data/priest_registration_repository.dart';
import 'package:gospel_vox/features/user/home/bloc/home_cubit.dart';
import 'package:gospel_vox/features/user/home/data/home_repository.dart';
import 'package:gospel_vox/features/user/wallet/bloc/wallet_cubit.dart';
import 'package:gospel_vox/features/user/wallet/data/wallet_repository.dart';

final sl = GetIt.instance;

Future<void> initDependencies() async {
  // Auth
  sl.registerLazySingleton<AuthRepository>(() => AuthRepository());
  sl.registerFactory<AuthCubit>(() => AuthCubit(sl<AuthRepository>()));

  // Admin dashboard
  sl.registerLazySingleton<DashboardRepository>(() => DashboardRepository());
  sl.registerFactory<DashboardCubit>(
      () => DashboardCubit(sl<DashboardRepository>()));

  // Admin settings
  sl.registerLazySingleton<SettingsRepository>(() => SettingsRepository());
  sl.registerFactory<SettingsCubit>(
      () => SettingsCubit(sl<SettingsRepository>()));

  // Coin packs
  sl.registerLazySingleton<CoinPacksRepository>(() => CoinPacksRepository());
  sl.registerFactory<CoinPacksCubit>(
      () => CoinPacksCubit(sl<CoinPacksRepository>()));

  // User wallet
  sl.registerLazySingleton<WalletRepository>(() => WalletRepository());
  sl.registerFactory<WalletCubit>(() => WalletCubit(sl<WalletRepository>()));

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

  // Priest registration — repo is a singleton (it's stateless), but
  // the cubit is a factory because each registration session should
  // start with a fresh state machine.
  sl.registerLazySingleton<PriestRegistrationRepository>(
      () => PriestRegistrationRepository());
  sl.registerFactory<PriestRegistrationCubit>(
      () => PriestRegistrationCubit(sl<PriestRegistrationRepository>()));

  // Priest activation — same shape: stateless repo + fresh cubit per
  // paywall mount so a back-and-forth re-entry starts clean.
  sl.registerLazySingleton<ActivationRepository>(
      () => ActivationRepository());
  sl.registerFactory<ActivationCubit>(
      () => ActivationCubit(sl<ActivationRepository>()));

  // Note: RazorpayService is intentionally NOT registered here.
  // Its callbacks hold references to BuildContext, so a singleton
  // would leak the first page that uses it. Each widget that needs
  // Razorpay constructs its own instance in initState and disposes
  // it in dispose — see WalletPage for the pattern.
}
