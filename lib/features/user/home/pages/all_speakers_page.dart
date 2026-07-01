// "All speakers" — the destination behind the home page's
// `Available now → See all` link. Renders the full filtered list of
// priests in the same 2-column grid + card design used on home, so
// users land on a layout they recognise.
//
// Spawns its own HomeCubit instance via the DI container so the page
// is self-contained — popping back to home doesn't disturb the home
// page's own cubit, and the cubit's stream is disposed automatically
// with this BlocProvider.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';
import 'package:gospel_vox/features/shared/data/session_preflight.dart';
import 'package:gospel_vox/features/user/home/bloc/home_cubit.dart';
import 'package:gospel_vox/features/user/home/bloc/home_state.dart';
import 'package:gospel_vox/features/user/home/widgets/priest_card.dart';
import 'package:gospel_vox/features/user/home/widgets/speaker_filter_bar.dart';
import 'package:gospel_vox/core/widgets/app_loading_widget.dart';

class AllSpeakersPage extends StatelessWidget {
  // Chip to pre-select on open, passed via the /user/speakers?filter=
  // query param from Home's "See all". Null / unknown → "All".
  final String? initialFilter;

  const AllSpeakersPage({super.key, this.initialFilter});

  @override
  Widget build(BuildContext context) {
    return BlocProvider<HomeCubit>(
      create: (_) => sl<HomeCubit>()..watchPriests(),
      child: _AllSpeakersView(initialFilter: initialFilter),
    );
  }
}

class _AllSpeakersView extends StatefulWidget {
  final String? initialFilter;

  const _AllSpeakersView({this.initialFilter});

  @override
  State<_AllSpeakersView> createState() => _AllSpeakersViewState();
}

class _AllSpeakersViewState extends State<_AllSpeakersView> {
  // Mirrors Home's local chip filter. Seeded from the route param so
  // the page opens on the same filter the user tapped on Home; an
  // unknown/absent value falls back to "All". The user can still switch
  // chips here without going back.
  late String _activeFilter = (widget.initialFilter != null &&
          isKnownSpeakerFilter(widget.initialFilter!))
      ? widget.initialFilter!
      : 'All';

  // Mirrors home_page._startSession — runs SessionPreflight so an
  // insufficient-balance user lands on the RechargeSheet instead of
  // bouncing off a generic CF error after the waiting screen.
  Future<void> _startSession(SpeakerModel priest, String type) async {
    final canStart = await SessionPreflight.check(
      context,
      type: type,
      priestName: priest.fullName,
    );
    if (!canStart || !mounted) return;
    context.push('/session/waiting', extra: <String, dynamic>{
      'priestId': priest.uid,
      'priestName': priest.fullName,
      'priestPhotoUrl': priest.photoUrl,
      'priestDenomination': priest.denomination,
      'type': type,
    });
  }

  // Mirrors home_page._subscribeToNotifyMe — array-union write to the
  // user's own doc; the notifyAvailableSubscribers CF fans out a
  // one-shot push when the priest flips online and clears the entry.
  Future<void> _subscribeToNotifyMe(SpeakerModel priest) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      await FirebaseFirestore.instance
          .doc('users/$uid')
          .update({
            'notifySubscriptions':
                FieldValue.arrayUnion([priest.uid]),
          })
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      AppSnackBar.success(
        context,
        "You'll be notified when ${priest.fullName} is available",
      );
    } on FirebaseException catch (e) {
      debugPrint(
        '[AllSpeakers] notify-me subscribe failed: ${e.code} ${e.message}',
      );
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't subscribe. Try again.");
    } catch (e) {
      debugPrint('[AllSpeakers] notify-me subscribe unexpected: $e');
      if (!mounted) return;
      AppSnackBar.error(context, "Couldn't subscribe. Try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: const Padding(
          padding: EdgeInsets.only(left: 8),
          child: Align(
            child: AppBackButton(),
          ),
        ),
        title: Text(
          'All speakers',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            color: AppColors.deepDarkBrown,
          ),
        ),
        centerTitle: false,
      ),
      body: BlocBuilder<HomeCubit, HomeState>(
        builder: (ctx, state) {
          if (state is HomeLoading || state is HomeInitial) {
            return const Center(
              child: AppLoader(),
            );
          }
          if (state is HomeError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  state.message,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: AppColors.muted,
                  ),
                ),
              ),
            );
          }
          final loaded = state as HomeLoaded;
          // Apply the active chip on top of the cubit's search output —
          // same predicate Home uses, so this list matches what the
          // user saw on the Home grid before tapping "See all".
          final priests =
              filterSpeakersByChip(loaded.filteredPriests, _activeFilter);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 4),
              SpeakerFilterBar(
                active: _activeFilter,
                onSelected: (label) =>
                    setState(() => _activeFilter = label),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: priests.isEmpty
                    ? _buildEmpty(loaded)
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                        physics: const BouncingScrollPhysics(
                          parent: AlwaysScrollableScrollPhysics(),
                        ),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: priests.length,
                        itemBuilder: (_, i) {
                          final priest = priests[i];
                          return PriestCard(
                            priest: priest,
                            gradient: kPriestGradients[
                                i % kPriestGradients.length],
                            onTap: () =>
                                context.push('/user/priest/${priest.uid}'),
                            onCall: () => _startSession(priest, 'voice'),
                            onChat: () => _startSession(priest, 'chat'),
                            onNotify: () => _subscribeToNotifyMe(priest),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  // Empty state. Distinguishes "the catalogue is genuinely empty" from
  // "this chip just has nobody right now" (e.g. tapped Online when no
  // priest is available) so the message guides the user back to a
  // useful filter instead of implying the app has no speakers at all.
  Widget _buildEmpty(HomeLoaded state) {
    final hasChip = _activeFilter != 'All';
    final catalogueEmpty = state.filteredPriests.isEmpty;

    final String message;
    if (catalogueEmpty) {
      message = 'No speakers available yet';
    } else if (hasChip) {
      message = 'No speakers in ${_activeFilter.toLowerCase()} right now';
    } else {
      message = 'No speakers available yet';
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 14,
            color: AppColors.muted,
          ),
        ),
      ),
    );
  }
}
