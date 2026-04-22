// Shell that hosts the 4-step priest wizard:
//   0 = Personal, 1 = Ministry, 2 = Documents, 3 = Review.
//
// PageView is locked to NeverScrollable so the only way to advance is
// via the Continue / Review / Submit buttons — per-step validation
// can't be swiped past. Navigation is driven by the cubit's
// `currentStep`: the page listens for changes and animates the
// PageController, which means Edit pencils on the Review page can
// jump to any step without the widget tree having to juggle
// PageController state directly.

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/router/app_router.dart';
import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/registration/bloc/priest_registration_cubit.dart';
import 'package:gospel_vox/features/priest/registration/bloc/priest_registration_state.dart';
import 'package:gospel_vox/features/priest/registration/data/priest_registration_model.dart';
import 'package:gospel_vox/features/priest/registration/widgets/registration_step1.dart';
import 'package:gospel_vox/features/priest/registration/widgets/registration_step2.dart';
import 'package:gospel_vox/features/priest/registration/widgets/registration_step3.dart';
import 'package:gospel_vox/features/priest/registration/widgets/registration_step4_review.dart';
import 'package:gospel_vox/features/priest/registration/widgets/submit_confirmation_sheet.dart';

// Total steps drives the progress bar segments and the PageView.
// Centralised so adding/removing a step touches only this constant.
const int _kTotalSteps = 4;

class PriestRegistrationPage extends StatelessWidget {
  const PriestRegistrationPage({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<PriestRegistrationCubit>(
      create: (_) {
        final user = FirebaseAuth.instance.currentUser;
        return sl<PriestRegistrationCubit>()
          ..startRegistration(
            email: user?.email ?? '',
            displayName: user?.displayName,
          );
      },
      child: const _PriestRegistrationView(),
    );
  }
}

class _PriestRegistrationView extends StatefulWidget {
  const _PriestRegistrationView();

  @override
  State<_PriestRegistrationView> createState() =>
      _PriestRegistrationViewState();
}

class _PriestRegistrationViewState extends State<_PriestRegistrationView> {
  final PageController _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _animateToStep(int step) {
    if (!_pageController.hasClients) return;
    // Large jumps (e.g. Review → Step 1 via Edit) use jumpToPage to
    // avoid a long, janky scroll animation; small steps animate.
    final currentPage = _pageController.page?.round() ?? 0;
    if ((step - currentPage).abs() > 1) {
      _pageController.jumpToPage(step);
    } else {
      _pageController.animateToPage(
        step,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _handleStep1Done(
    String fullName,
    String phone,
    String email,
    String? photoPath,
  ) {
    context.read<PriestRegistrationCubit>().completeStep1(
          fullName: fullName,
          phone: phone,
          email: email,
          photoPath: photoPath,
        );
  }

  void _handleStep2Done(
    String denomination,
    String subDenomination,
    String churchName,
    String diocese,
    String location,
    int years,
    String bio,
    List<String> languages,
    List<String> specializations,
  ) {
    context.read<PriestRegistrationCubit>().completeStep2(
          denomination: denomination,
          subDenomination: subDenomination,
          churchName: churchName,
          diocese: diocese,
          location: location,
          yearsOfExperience: years,
          bio: bio,
          languages: languages,
          specializations: specializations,
        );
  }

  void _handleStep3Done(
    String? idProofPath,
    String? certificatePath,
  ) {
    context.read<PriestRegistrationCubit>().completeStep3(
          idProofPath: idProofPath,
          certificatePath: certificatePath,
        );
  }

  void _handleEditFromReview(int stepIndex) {
    context.read<PriestRegistrationCubit>().goToEditFromReview(stepIndex);
  }

  Future<void> _handleFinalSubmit() async {
    // The gravity check. Priest has seen every field, ticked "all
    // accurate" — one last explicit confirmation before we actually
    // upload anything.
    final confirmed = await showSubmitConfirmationSheet(context);
    if (!confirmed || !mounted) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      AppSnackBar.error(context, 'You are not signed in.');
      return;
    }
    await context
        .read<PriestRegistrationCubit>()
        .submitRegistration(uid: user.uid);
  }

  void _goBack() {
    context.read<PriestRegistrationCubit>().goBack();
  }

  Future<void> _showExitConfirmation() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => Dialog(
        backgroundColor: AppColors.surfaceWhite,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Exit registration?',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your progress is saved — you can continue where you left off next time.',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx, false),
                    child: Text(
                      'Stay',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx, true),
                    child: Text(
                      'Exit',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AppColors.errorRed,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (confirmed == true && mounted) {
      await FirebaseAuth.instance.signOut();
      clearCachedRole();
      if (!mounted) return;
      context.go('/select-role');
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<PriestRegistrationCubit, PriestRegistrationState>(
      listenWhen: (prev, curr) {
        // Only react to step changes or terminal state transitions;
        // we don't want to animate-to-page on every upload progress
        // tick.
        if (curr is PriestRegSuccess) return true;
        if (curr is PriestRegError) return true;
        if (prev is PriestRegInProgress && curr is PriestRegInProgress) {
          return prev.currentStep != curr.currentStep;
        }
        if (curr is PriestRegInProgress) return true;
        return false;
      },
      listener: (ctx, state) async {
        if (state is PriestRegSuccess) {
          ctx.go('/priest/pending');
          return;
        }
        if (state is PriestRegError) {
          AppSnackBar.error(ctx, state.message);
          _animateToStep(state.returnToStep);
          await ctx.read<PriestRegistrationCubit>().resumeAfterError();
          return;
        }
        if (state is PriestRegInProgress) {
          _animateToStep(state.currentStep);
        }
      },
      builder: (ctx, state) {
        final currentStep =
            state is PriestRegInProgress ? state.currentStep : 0;
        final isUploading =
            state is PriestRegInProgress && state.isUploading;
        final uploadingLabel = state is PriestRegInProgress
            ? state.uploadingLabel
            : null;
        final uploadProgress =
            state is PriestRegInProgress ? state.uploadProgress : 0.0;

        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || isUploading) return;
            if (currentStep > 0) {
              _goBack();
            } else {
              _showExitConfirmation();
            }
          },
          child: Scaffold(
            backgroundColor: AppColors.background,
            body: Stack(
              children: [
                Column(
                  children: [
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding:
                            const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            _CircleIconButton(
                              icon: currentStep == 0
                                  ? Icons.close
                                  : Icons.arrow_back_ios_new,
                              onTap: currentStep == 0
                                  ? _showExitConfirmation
                                  : _goBack,
                            ),
                            Text(
                              'Step ${currentStep + 1} of $_kTotalSteps',
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppColors.muted,
                              ),
                            ),
                            // Keeps the step counter visually centered
                            // against the circular back button.
                            const SizedBox(width: 40),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(20, 20, 20, 0),
                      child: Row(
                        children:
                            List.generate(_kTotalSteps, (i) {
                          return Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(
                                right: i < _kTotalSteps - 1 ? 6 : 0,
                              ),
                              child: AnimatedContainer(
                                duration:
                                    const Duration(milliseconds: 320),
                                height: 4,
                                decoration: BoxDecoration(
                                  borderRadius:
                                      BorderRadius.circular(2),
                                  color: i <= currentStep
                                      ? AppColors.primaryBrown
                                      : AppColors.muted
                                          .withValues(alpha: 0.15),
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                    Expanded(
                      child: _buildPageView(ctx, state),
                    ),
                  ],
                ),
                if (isUploading)
                  _UploadOverlay(
                    label: uploadingLabel ?? 'Uploading...',
                    progress: uploadProgress,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildPageView(
    BuildContext ctx,
    PriestRegistrationState state,
  ) {
    final user = FirebaseAuth.instance.currentUser;
    final data = state is PriestRegInProgress ? state.data : null;
    final safeData = data;

    return PageView(
      controller: _pageController,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        RegistrationStep1(
          prefilledEmail: user?.email ?? '',
          prefilledName: user?.displayName,
          initialName: safeData?.fullName ?? '',
          initialPhone: safeData?.phone ?? '',
          initialEmail: safeData?.email ?? (user?.email ?? ''),
          initialPhotoPath: safeData?.photoPath,
          onNext: _handleStep1Done,
        ),
        RegistrationStep2(
          priestName: safeData?.fullName ?? '',
          initialDenomination: safeData?.denomination ?? '',
          initialSubDenomination: safeData?.subDenomination ?? '',
          initialChurchName: safeData?.churchName ?? '',
          initialDiocese: safeData?.diocese ?? '',
          initialLocation: safeData?.location ?? '',
          initialYears: safeData?.yearsOfExperience ?? 0,
          initialBio: safeData?.bio ?? '',
          initialLanguages: safeData?.languages ?? const [],
          initialSpecializations: safeData?.specializations ?? const [],
          onNext: _handleStep2Done,
        ),
        RegistrationStep3(
          initialIdProofPath: safeData?.idProofPath,
          initialCertificatePath: safeData?.certificatePath,
          onSubmit: _handleStep3Done,
          onBack: _goBack,
        ),
        // Review step uses the cubit's model as its source of truth.
        // If we're briefly transitioning through a non-InProgress
        // state (Submitting/Success) we fall back to an empty model
        // rather than crash; the overlay covers the page anyway.
        RegistrationStep4Review(
          data: safeData ?? const PriestRegistrationModel(),
          onEdit: _handleEditFromReview,
          onSubmit: _handleFinalSubmit,
        ),
      ],
    );
  }
}

class _CircleIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  State<_CircleIconButton> createState() => _CircleIconButtonState();
}

class _CircleIconButtonState extends State<_CircleIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                blurRadius: 6,
                offset: const Offset(0, 2),
                color: Colors.black.withValues(alpha: 0.05),
              ),
            ],
          ),
          child: Icon(
            widget.icon,
            size: 16,
            color: AppColors.deepDarkBrown,
          ),
        ),
      ),
    );
  }
}

// Blocks all input while uploads run. Determinate bar with a live
// percentage — users tolerate long waits if they can see they're
// actually progressing.
class _UploadOverlay extends StatelessWidget {
  final String label;
  final double progress;

  const _UploadOverlay({required this.label, required this.progress});

  @override
  Widget build(BuildContext context) {
    final percent = (progress.clamp(0.0, 1.0) * 100).toInt();

    return Positioned.fill(
      child: AbsorbPointer(
        child: Container(
          color: Colors.black.withValues(alpha: 0.4),
          child: Center(
            child: Container(
              width: 280,
              padding: const EdgeInsets.symmetric(
                horizontal: 28,
                vertical: 36,
              ),
              decoration: BoxDecoration(
                color: AppColors.surfaceWhite,
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                    color: Colors.black.withValues(alpha: 0.1),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox(
                          width: 64,
                          height: 64,
                          child: CircularProgressIndicator(
                            value: progress,
                            color: AppColors.primaryBrown,
                            backgroundColor: AppColors.muted
                                .withValues(alpha: 0.12),
                            strokeWidth: 4,
                            strokeCap: StrokeCap.round,
                          ),
                        ),
                        Text(
                          '$percent%',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.deepDarkBrown,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Please keep the app open and\nstay connected to internet',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppColors.muted,
                      height: 1.5,
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
