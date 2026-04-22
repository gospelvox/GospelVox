// Gospel Vox — Global Christian Spiritual Consultation Platform

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/theme/app_theme.dart';
import 'package:gospel_vox/core/utils/bloc_observer.dart';
import 'package:gospel_vox/firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.warmBeige,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
  ));

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  await initDependencies();

  Bloc.observer = AppBlocObserver();

  // Catch Flutter framework errors (layout, painting, gestures)
  FlutterError.onError = (details) {
    debugPrint('[GospelVox] FlutterError: ${details.exception}');
    debugPrint('[GospelVox] Stack: ${details.stack}');
  };

  runApp(const GospelVoxApp());
}

class GospelVoxApp extends StatelessWidget {
  const GospelVoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Gospel Vox',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      routerConfig: appRouter,
    );
  }
}
