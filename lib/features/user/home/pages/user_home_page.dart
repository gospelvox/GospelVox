// Home screen for the user role

import 'package:flutter/material.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

class UserHomePage extends StatelessWidget {
  const UserHomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.warmBeige,
      body: Center(
        child: Text('User Home'),
      ),
    );
  }
}
