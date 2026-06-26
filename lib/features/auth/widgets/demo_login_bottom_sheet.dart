// Demo / test email+password login as a modal bottom sheet.
//
// Triggered by long-pressing the "GospelVox" wordmark on the role-selection
// page. Intended for store reviewers (Play / App Store) who need a fixed
// credential to get in without Google/Apple Sign-In. It signs in via
// AuthCubit.signInWithEmailDemo, which routes to whatever role the
// pre-provisioned demo account holds (user or priest).
//
// Self-contained: like the admin sheet, it owns its own routing + error
// toasts (the role-selection page has no auth listener of its own).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/auth/bloc/auth_cubit.dart';
import 'package:gospel_vox/features/auth/bloc/auth_state.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

class DemoLoginBottomSheet extends StatefulWidget {
  const DemoLoginBottomSheet({super.key});

  @override
  State<DemoLoginBottomSheet> createState() => _DemoLoginBottomSheetState();
}

class _DemoLoginBottomSheetState extends State<DemoLoginBottomSheet> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();

  String? _emailError;
  String? _passwordError;
  bool _obscurePassword = true;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _emailController.addListener(_onFieldChanged);
    _passwordController.addListener(_onFieldChanged);
    _emailFocusNode.addListener(_onEmailFocusChanged);
    _passwordFocusNode.addListener(_onPasswordFocusChanged);
  }

  @override
  void dispose() {
    _emailController.removeListener(_onFieldChanged);
    _passwordController.removeListener(_onFieldChanged);
    _emailFocusNode.removeListener(_onEmailFocusChanged);
    _passwordFocusNode.removeListener(_onPasswordFocusChanged);
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  void _onEmailFocusChanged() {
    if (!_emailFocusNode.hasFocus) {
      final error = _validateEmail(_emailController.text);
      if (error != _emailError) setState(() => _emailError = error);
    }
  }

  void _onPasswordFocusChanged() {
    if (!_passwordFocusNode.hasFocus) {
      final error = _validatePassword(_passwordController.text);
      if (error != _passwordError) setState(() => _passwordError = error);
    }
  }

  bool _isValidEmail(String email) {
    final regex = RegExp(r'^[\w\+\-\.]+@([\w-]+\.)+[\w-]{2,}$');
    return regex.hasMatch(email.trim());
  }

  String? _validateEmail(String email) {
    final trimmed = email.trim();
    if (trimmed.isEmpty) return 'Email is required';
    if (!_isValidEmail(trimmed)) return 'Enter a valid email';
    return null;
  }

  String? _validatePassword(String password) {
    if (password.isEmpty) return 'Password is required';
    if (password.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  bool get _canSubmit =>
      !_isSubmitting &&
      _emailController.text.trim().isNotEmpty &&
      _passwordController.text.isNotEmpty;

  void _submit() {
    final emailError = _validateEmail(_emailController.text);
    final passwordError = _validatePassword(_passwordController.text);

    setState(() {
      _emailError = emailError;
      _passwordError = passwordError;
    });

    if (emailError != null || passwordError != null) return;

    HapticFeedback.mediumImpact();
    FocusScope.of(context).unfocus();
    context.read<AuthCubit>().signInWithEmailDemo(
          _emailController.text.trim(),
          _passwordController.text,
        );
  }

  @override
  Widget build(BuildContext context) {
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return BlocListener<AuthCubit, AuthState>(
      // Self-contained, like the admin sheet: drive the spinner, show errors,
      // and route by the account's real role on success. context.go replaces
      // the entire route stack, so this bottom sheet is dismissed
      // automatically — calling Navigator.pop() first would deactivate
      // elements mid-frame and trip the "inactive element" assertion.
      listener: (context, state) {
        if (state is AuthLoading) {
          if (!_isSubmitting) setState(() => _isSubmitting = true);
        } else if (state is AuthError) {
          setState(() => _isSubmitting = false);
          AppSnackBar.error(context, state.message);
        } else if (state is AuthAuthenticated) {
          setState(() => _isSubmitting = false);
          switch (state.role) {
            case 'priest':
              context.go('/priest');
            case 'admin':
              context.go('/admin');
            default:
              context.go('/user');
          }
        } else if (state is AuthUnauthenticated) {
          if (_isSubmitting) setState(() => _isSubmitting = false);
        }
      },
      child: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: EdgeInsets.only(bottom: viewInsets),
          child: Container(
            decoration: const BoxDecoration(
              color: AppColors.warmBeige,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.muted.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const AppIcon(
                        AppIcons.lock,
                        color: AppColors.primaryBrown,
                        size: 24,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Test Login',
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sign in with the demo email and password',
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _emailController,
                    focusNode: _emailFocusNode,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_isSubmitting,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: AppColors.deepDarkBrown,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Email',
                      hintText: 'playreview@gospelvox.com',
                      prefixIcon: const AppIcon(AppIcons.mail),
                      errorText: _emailError,
                    ),
                    onSubmitted: (_) => _passwordFocusNode.requestFocus(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordController,
                    focusNode: _passwordFocusNode,
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !_isSubmitting,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: AppColors.deepDarkBrown,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const AppIcon(AppIcons.lock),
                      suffixIcon: IconButton(
                        icon: AppIcon(
                          _obscurePassword ? AppIcons.eyeOff : AppIcons.eye,
                        ),
                        onPressed: () => setState(
                            () => _obscurePassword = !_obscurePassword),
                      ),
                      errorText: _passwordError,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 24),
                  _SubmitButton(
                    enabled: _canSubmit,
                    isLoading: _isSubmitting,
                    onTap: _submit,
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      'For testing only.',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SubmitButton extends StatefulWidget {
  final bool enabled;
  final bool isLoading;
  final VoidCallback onTap;

  const _SubmitButton({
    required this.enabled,
    required this.isLoading,
    required this.onTap,
  });

  @override
  State<_SubmitButton> createState() => _SubmitButtonState();
}

class _SubmitButtonState extends State<_SubmitButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final canTap = widget.enabled;

    return GestureDetector(
      onTapDown: canTap ? (_) => setState(() => _pressed = true) : null,
      onTapUp: canTap ? (_) => setState(() => _pressed = false) : null,
      onTapCancel: canTap ? () => setState(() => _pressed = false) : null,
      onTap: canTap ? widget.onTap : null,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: canTap ? 1.0 : 0.5,
          child: Container(
            width: double.infinity,
            height: 56,
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: widget.isLoading
                  ? const SizedBox(
                      width: 32,
                      height: 32,
                      child: AppLoader(),
                    )
                  : Text(
                      'Sign In',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
