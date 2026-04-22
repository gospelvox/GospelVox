// Speaker detail page — same page handles pending / active / suspended.
//
// We keep one page for all three states because 80% of the content is
// identical (profile header, sections) and the remaining 20% (which
// action buttons are shown) is a clean conditional at the bottom.
// Forking into three pages would duplicate every field change.
//
// On a successful moderation action the page pops `true` so the list
// page knows to refresh — avoids a stale list sitting behind the
// admin after they've just approved someone.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gospel_vox/core/services/injection_container.dart';
import 'package:gospel_vox/core/theme/admin_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/confirm_changes_sheet.dart';
import 'package:gospel_vox/features/admin/speakers/bloc/speaker_detail_cubit.dart';
import 'package:gospel_vox/features/admin/speakers/bloc/speakers_state.dart';
import 'package:gospel_vox/features/admin/speakers/data/speaker_model.dart';

final NumberFormat _inr = NumberFormat.currency(
  locale: 'en_IN',
  symbol: '\u20B9',
  decimalDigits: 0,
);

class SpeakerDetailPage extends StatelessWidget {
  final String speakerId;
  const SpeakerDetailPage({super.key, required this.speakerId});

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
      ),
      child: BlocProvider<SpeakerDetailCubit>(
        create: (_) =>
            sl<SpeakerDetailCubit>()..loadDetail(speakerId),
        child: const _SpeakerDetailView(),
      ),
    );
  }
}

class _SpeakerDetailView extends StatelessWidget {
  const _SpeakerDetailView();

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<SpeakerDetailCubit, SpeakerDetailState>(
      listener: (ctx, state) {
        if (state is SpeakerDetailActionSuccess) {
          AppSnackBar.success(ctx, state.message);
          // Popping with true signals the list page to refresh.
          // Delay one frame so the snackbar mounts cleanly before
          // the page tears down.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (ctx.mounted) ctx.pop(true);
          });
        } else if (state is SpeakerDetailError && state.speaker != null) {
          // Error with a recoverable speaker — toast it but keep the
          // profile visible so the admin can try again.
          AppSnackBar.error(ctx, state.message);
        }
      },
      builder: (ctx, state) {
        // If the admin kicked off a CF action, we block the hardware
        // back button until the call resolves. Without this, backing
        // out mid-approve would leave the admin on the list with a
        // pending CF call whose result they never see — and the list
        // would still be stale because the `push(true)` signal
        // wouldn't fire.
        final isBusy = state is SpeakerDetailActionInProgress;
        return PopScope(
          canPop: !isBusy,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && isBusy) {
              AppSnackBar.info(
                ctx,
                'Please wait — the action is still being processed.',
              );
            }
          },
          child: Scaffold(
            backgroundColor: AdminColors.background,
            appBar: _buildAppBar(ctx, isBusy: isBusy),
            body: _buildBody(ctx, state),
          ),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context, {
    required bool isBusy,
  }) {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      leading: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (isBusy) {
            // Same rationale as the PopScope — don't let the admin
            // strand a pending CF call by backing out via the arrow.
            AppSnackBar.info(
              context,
              'Please wait — the action is still being processed.',
            );
            return;
          }
          context.pop();
        },
        child: Icon(
          Icons.arrow_back,
          color: isBusy
              ? AdminColors.textLight
              : AdminColors.textPrimary,
          size: 22,
        ),
      ),
      title: Text(
        'Speaker Details',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AdminColors.textPrimary,
        ),
      ),
      centerTitle: false,
    );
  }

  Widget _buildBody(BuildContext context, SpeakerDetailState state) {
    if (state is SpeakerDetailLoading ||
        state is SpeakerDetailInitial) {
      return const _DetailShimmer();
    }

    // Errors that lost the underlying speaker render full-screen.
    // Errors that preserved it (action failures) already showed a
    // snackbar and fall through to render the preserved profile.
    if (state is SpeakerDetailError && state.speaker == null) {
      return _FullScreenError(
        message: state.message,
        onRetry: () {
          // We don't have the uid here at this state — ask the
          // caller to pop back. A retry loop without a uid would
          // just fail again.
          context.pop();
        },
      );
    }

    final speaker = switch (state) {
      SpeakerDetailLoaded s => s.speaker,
      SpeakerDetailActionInProgress s => s.speaker,
      SpeakerDetailActionSuccess s => s.speaker,
      SpeakerDetailError s => s.speaker!,
      _ => null,
    };
    if (speaker == null) return const _DetailShimmer();

    final busyAction = state is SpeakerDetailActionInProgress
        ? state.action
        : null;

    return _DetailContent(
      speaker: speaker,
      busyAction: busyAction,
    );
  }
}

// ─── Main content ───────────────────────────────────────────────

class _DetailContent extends StatelessWidget {
  final SpeakerModel speaker;
  final String? busyAction;

  const _DetailContent({required this.speaker, required this.busyAction});

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(20, 20, 20, bottomPad + 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ProfileHeader(speaker: speaker),

          if (speaker.status == 'approved') ...[
            const SizedBox(height: 20),
            _StatsCard(speaker: speaker),
          ],

          const SizedBox(height: 20),
          _DetailSection(
            title: 'PERSONAL',
            items: [
              _DetailRow(
                icon: Icons.mail_outline,
                label: 'Email',
                value: speaker.email.isEmpty ? '—' : speaker.email,
              ),
              _DetailRow(
                icon: Icons.phone_outlined,
                label: 'Phone',
                value: speaker.phone.isEmpty
                    ? '—'
                    : '+91 ${speaker.phone}',
              ),
              _DetailRow(
                icon: Icons.work_outline,
                label: 'Experience',
                value: '${speaker.yearsOfExperience} years',
              ),
            ],
          ),

          const SizedBox(height: 16),
          _DetailSection(
            title: 'MINISTRY',
            items: [
              _DetailRow(
                icon: Icons.church_outlined,
                label: 'Church',
                value: speaker.churchName.isEmpty
                    ? '—'
                    : speaker.churchName,
              ),
              if (speaker.diocese.isNotEmpty)
                _DetailRow(
                  icon: Icons.map_outlined,
                  label: 'Diocese',
                  value: speaker.diocese,
                ),
              if (speaker.subDenomination.isNotEmpty)
                _DetailRow(
                  icon: Icons.category_outlined,
                  label: 'Sub-denomination',
                  value: speaker.subDenomination,
                ),
            ],
          ),

          if (speaker.specializations.isNotEmpty) ...[
            const SizedBox(height: 16),
            _ChipSection(
              title: 'SPECIALIZATIONS',
              items: speaker.specializations,
            ),
          ],

          if (speaker.languages.isNotEmpty) ...[
            const SizedBox(height: 16),
            _ChipSection(title: 'LANGUAGES', items: speaker.languages),
          ],

          if (speaker.bio.isNotEmpty) ...[
            const SizedBox(height: 16),
            _DetailSection(
              title: 'BIO',
              child: Text(
                speaker.bio,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AdminColors.textBody,
                  height: 1.6,
                ),
              ),
            ),
          ],

          if (speaker.status == 'pending') ...[
            const SizedBox(height: 16),
            _DetailSection(
              title: 'DOCUMENTS',
              child: Column(
                children: [
                  _DocumentRow(
                    title: 'ID Proof',
                    url: speaker.idProofUrl,
                    hasDocument: speaker.hasIdProof,
                  ),
                  const SizedBox(height: 12),
                  _DocumentRow(
                    title: 'Ordination Certificate',
                    url: speaker.certificateUrl,
                    hasDocument: speaker.hasCertificate,
                  ),
                ],
              ),
            ),
          ],

          if (speaker.status == 'approved') ...[
            const SizedBox(height: 16),
            _DetailSection(
              title: 'WALLET',
              items: [
                _DetailRow(
                  icon: Icons.account_balance_wallet_outlined,
                  label: 'Current Balance',
                  value: _inr.format(speaker.walletBalance),
                ),
                _DetailRow(
                  icon: Icons.trending_up,
                  label: 'Total Earned',
                  value: _inr.format(speaker.totalEarnings),
                ),
                _DetailRow(
                  icon: Icons.toggle_on_outlined,
                  label: 'Activated',
                  value: speaker.isActivated ? 'Yes' : 'No',
                ),
              ],
            ),
          ],

          if (speaker.status == 'rejected' &&
              (speaker.rejectionReason ?? '').isNotEmpty) ...[
            const SizedBox(height: 16),
            _DetailSection(
              title: 'REJECTION REASON',
              child: Text(
                speaker.rejectionReason!,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  color: AdminColors.error,
                  height: 1.5,
                ),
              ),
            ),
          ],

          const SizedBox(height: 28),
          _ActionButtons(speaker: speaker, busyAction: busyAction),
        ],
      ),
    );
  }
}

// ─── Profile header ────────────────────────────────────────────

class _ProfileHeader extends StatelessWidget {
  final SpeakerModel speaker;
  const _ProfileHeader({required this.speaker});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AdminColors.inputBackground,
              border: Border.all(color: AdminColors.divider, width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: speaker.hasPhoto
                ? CachedNetworkImage(
                    imageUrl: speaker.photoUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => _placeholder(),
                    errorWidget: (_, _, _) => _placeholder(),
                  )
                : _placeholder(),
          ),
          const SizedBox(height: 14),
          Text(
            speaker.fullName.isEmpty
                ? 'Unnamed speaker'
                : speaker.fullName,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AdminColors.textPrimary,
            ),
          ),
          if (speaker.denomination.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              speaker.denomination,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AdminColors.textMuted,
              ),
            ),
          ],
          if (speaker.location.isNotEmpty) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.location_on_outlined,
                  size: 14,
                  color: AdminColors.textLight,
                ),
                const SizedBox(width: 4),
                Text(
                  speaker.location,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AdminColors.textLight,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          _FullStatusBadge(status: speaker.status),
        ],
      ),
    );
  }

  Widget _placeholder() => const Center(
        child: Icon(
          Icons.person,
          size: 36,
          color: AdminColors.textLight,
        ),
      );
}

// ─── Status badge (header variant, bigger) ─────────────────────

class _FullStatusBadge extends StatelessWidget {
  final String status;
  const _FullStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label) = switch (status) {
      'approved' => (AdminColors.successBg, AdminColors.success, 'Active'),
      'suspended' => (AdminColors.errorBg, AdminColors.error, 'Suspended'),
      'rejected' => (AdminColors.errorBg, AdminColors.error, 'Rejected'),
      _ => (AdminColors.warningBg, AdminColors.warning, 'Pending Review'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: fg,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// ─── Stats card (approved only) ────────────────────────────────

class _StatsCard extends StatelessWidget {
  final SpeakerModel speaker;
  const _StatsCard({required this.speaker});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: AdminColors.cardDecoration,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Expanded(
            child: _StatItem(
              label: 'Sessions',
              value: speaker.totalSessions.toString(),
            ),
          ),
          const _StatDivider(),
          Expanded(
            child: _StatItem(
              label: 'Earnings',
              value: _inr.format(speaker.totalEarnings),
            ),
          ),
          const _StatDivider(),
          Expanded(
            child: _StatItem(
              label: 'Rating',
              value: speaker.rating > 0
                  ? speaker.rating.toStringAsFixed(1)
                  : '—',
            ),
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  const _StatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AdminColors.textPrimary,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w400,
            color: AdminColors.textLight,
          ),
        ),
      ],
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 36,
      color: AdminColors.borderLight,
    );
  }
}

// ─── Section card ──────────────────────────────────────────────

class _DetailSection extends StatelessWidget {
  final String title;
  final List<Widget>? items;
  final Widget? child;

  const _DetailSection({required this.title, this.items, this.child})
      : assert(items != null || child != null);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AdminColors.textLight,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: AdminColors.cardDecoration,
          child: items != null
              ? Column(
                  children: [
                    for (int i = 0; i < items!.length; i++) ...[
                      if (i > 0)
                        const Divider(
                          height: 20,
                          thickness: 1,
                          color: AdminColors.borderLight,
                        ),
                      items![i],
                    ],
                  ],
                )
              : child!,
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AdminColors.textLight),
        const SizedBox(width: 12),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w400,
            color: AdminColors.textMuted,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AdminColors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Chip sections (specializations, languages) ────────────────

class _ChipSection extends StatelessWidget {
  final String title;
  final List<String> items;
  const _ChipSection({required this.title, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AdminColors.textLight,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: AdminColors.cardDecoration,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: items
                .map(
                  (item) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AdminColors.background,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      item,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AdminColors.textBody,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
      ],
    );
  }
}

// ─── Document row ──────────────────────────────────────────────

class _DocumentRow extends StatelessWidget {
  final String title;
  final String url;
  final bool hasDocument;

  const _DocumentRow({
    required this.title,
    required this.url,
    required this.hasDocument,
  });

  Future<void> _launch(BuildContext context) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      AppSnackBar.error(context, 'Invalid document link.');
      return;
    }
    try {
      // External application mode so Firebase Storage download
      // URLs render in the system browser rather than a stripped-
      // down in-app view.
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!ok && context.mounted) {
        AppSnackBar.error(
          context,
          'Could not open the document.',
        );
      }
    } catch (_) {
      if (context.mounted) {
        AppSnackBar.error(context, 'Could not open the document.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AdminColors.background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            hasDocument
                ? Icons.description_outlined
                : Icons.close_rounded,
            size: 20,
            color: hasDocument
                ? AdminColors.textMuted
                : AdminColors.error,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AdminColors.textPrimary,
                  ),
                ),
                if (!hasDocument)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Not uploaded',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        color: AdminColors.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (hasDocument)
            _ViewButton(onTap: () => _launch(context)),
        ],
      ),
    );
  }
}

class _ViewButton extends StatefulWidget {
  final VoidCallback onTap;
  const _ViewButton({required this.onTap});

  @override
  State<_ViewButton> createState() => _ViewButtonState();
}

class _ViewButtonState extends State<_ViewButton> {
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
        scale: _pressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AdminColors.divider),
          ),
          child: Text(
            'View',
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AdminColors.brandBrown,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Action buttons row ────────────────────────────────────────

class _ActionButtons extends StatelessWidget {
  final SpeakerModel speaker;
  final String? busyAction;

  const _ActionButtons({required this.speaker, required this.busyAction});

  @override
  Widget build(BuildContext context) {
    switch (speaker.status) {
      case 'pending':
        return _PendingActions(speaker: speaker, busyAction: busyAction);
      case 'approved':
        return _ApprovedActions(
          speaker: speaker,
          busyAction: busyAction,
        );
      case 'suspended':
        return _SuspendedActions(
          speaker: speaker,
          busyAction: busyAction,
        );
      default:
        // Rejected speakers have no actions — they must reapply.
        return const SizedBox.shrink();
    }
  }
}

class _PendingActions extends StatelessWidget {
  final SpeakerModel speaker;
  final String? busyAction;

  const _PendingActions({required this.speaker, required this.busyAction});

  Future<void> _approve(BuildContext context) async {
    final confirmed = await ConfirmChangesSheet.show(
      context: context,
      title: 'Approve Speaker',
      confirmLabel: 'Approve',
      changes: [
        ChangeItem(
          field: speaker.fullName.isEmpty
              ? 'Speaker'
              : speaker.fullName,
          oldValue: 'Pending Review',
          newValue: 'Approved',
        ),
      ],
    );
    if (!confirmed || !context.mounted) return;
    await context.read<SpeakerDetailCubit>().approve();
  }

  Future<void> _reject(BuildContext context) async {
    final reason = await _RejectReasonSheet.show(context);
    if (reason == null || !context.mounted) return;
    await context.read<SpeakerDetailCubit>().reject(reason);
  }

  @override
  Widget build(BuildContext context) {
    final isBusy = busyAction != null;
    return Row(
      children: [
        Expanded(
          child: _OutlineActionButton(
            label: 'Reject',
            color: AdminColors.error,
            enabled: !isBusy,
            onTap: () => _reject(context),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: _FilledActionButton(
            label: 'Approve Speaker',
            color: AdminColors.success,
            busy: busyAction == 'approving',
            enabled: !isBusy,
            onTap: () => _approve(context),
          ),
        ),
      ],
    );
  }
}

class _ApprovedActions extends StatelessWidget {
  final SpeakerModel speaker;
  final String? busyAction;

  const _ApprovedActions({required this.speaker, required this.busyAction});

  Future<void> _suspend(BuildContext context) async {
    final confirmed = await ConfirmChangesSheet.show(
      context: context,
      title: 'Suspend Speaker',
      confirmLabel: 'Suspend',
      isDangerous: true,
      changes: [
        ChangeItem(
          field: speaker.fullName.isEmpty
              ? 'Speaker'
              : speaker.fullName,
          oldValue: 'Active',
          newValue: 'Suspended',
        ),
      ],
    );
    if (!confirmed || !context.mounted) return;
    await context.read<SpeakerDetailCubit>().suspend();
  }

  @override
  Widget build(BuildContext context) {
    return _OutlineActionButton(
      label: 'Suspend Speaker',
      color: AdminColors.error,
      enabled: busyAction == null,
      busy: busyAction == 'suspending',
      onTap: () => _suspend(context),
      fullWidth: true,
    );
  }
}

class _SuspendedActions extends StatelessWidget {
  final SpeakerModel speaker;
  final String? busyAction;

  const _SuspendedActions({required this.speaker, required this.busyAction});

  Future<void> _reactivate(BuildContext context) async {
    final confirmed = await ConfirmChangesSheet.show(
      context: context,
      title: 'Reactivate Speaker',
      confirmLabel: 'Reactivate',
      changes: [
        ChangeItem(
          field: speaker.fullName.isEmpty
              ? 'Speaker'
              : speaker.fullName,
          oldValue: 'Suspended',
          newValue: 'Active',
        ),
      ],
    );
    if (!confirmed || !context.mounted) return;
    await context.read<SpeakerDetailCubit>().unsuspend();
  }

  @override
  Widget build(BuildContext context) {
    return _FilledActionButton(
      label: 'Reactivate Speaker',
      color: AdminColors.success,
      busy: busyAction == 'unsuspending',
      enabled: busyAction == null,
      onTap: () => _reactivate(context),
      fullWidth: true,
    );
  }
}

class _FilledActionButton extends StatefulWidget {
  final String label;
  final Color color;
  final bool busy;
  final bool enabled;
  final VoidCallback onTap;
  final bool fullWidth;

  const _FilledActionButton({
    required this.label,
    required this.color,
    required this.busy,
    required this.enabled,
    required this.onTap,
    this.fullWidth = false,
  });

  @override
  State<_FilledActionButton> createState() => _FilledActionButtonState();
}

class _FilledActionButtonState extends State<_FilledActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !widget.busy;
    final color =
        enabled ? widget.color : widget.color.withValues(alpha: 0.5);

    final btn = GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel:
          enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled ? widget.onTap : null,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : const [],
          ),
          alignment: Alignment.center,
          child: widget.busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                )
              : Text(
                  widget.label,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );

    return widget.fullWidth
        ? SizedBox(width: double.infinity, child: btn)
        : btn;
  }
}

class _OutlineActionButton extends StatefulWidget {
  final String label;
  final Color color;
  final bool enabled;
  // Swaps the label for a matching-colour spinner while an action is
  // running. Without this, the Suspend flow looked frozen next to the
  // Approve/Reactivate buttons which animate.
  final bool busy;
  final VoidCallback onTap;
  final bool fullWidth;

  const _OutlineActionButton({
    required this.label,
    required this.color,
    required this.enabled,
    required this.onTap,
    this.busy = false,
    this.fullWidth = false,
  });

  @override
  State<_OutlineActionButton> createState() => _OutlineActionButtonState();
}

class _OutlineActionButtonState extends State<_OutlineActionButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !widget.busy;
    final borderColor =
        enabled ? widget.color : widget.color.withValues(alpha: 0.4);
    final textColor = borderColor;

    final btn = GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel:
          enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled ? widget.onTap : null,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor, width: 1.5),
          ),
          alignment: Alignment.center,
          child: widget.busy
              ? SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    color: widget.color,
                    strokeWidth: 2.5,
                  ),
                )
              : Text(
                  widget.label,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
        ),
      ),
    );

    return widget.fullWidth
        ? SizedBox(width: double.infinity, child: btn)
        : btn;
  }
}

// ─── Reject reason bottom sheet ────────────────────────────────
//
// Admin rejection UX is designed around the observation that 90% of
// rejections fall into a handful of categories ("ID missing", "fake
// data", "bio incomplete"). Forcing the admin to re-type those every
// time was both tedious and a source of inconsistent copy that the
// priest would later read.
//
// The sheet now offers preset reason chips (multi-select). Tapping a
// chip toggles it into the composed reason; admins can also type
// freely in a notes field below for specifics. Final text is:
//   [selected presets joined] [. optional notes]
// Validated to min 10 chars before we fire the CF.

const List<_PresetReason> _kPresetReasons = [
  _PresetReason(
    key: 'id_missing',
    short: 'ID proof missing',
    full: 'ID proof was not uploaded',
  ),
  _PresetReason(
    key: 'certificate_missing',
    short: 'Certificate missing',
    full: 'Ordination certificate is missing',
  ),
  _PresetReason(
    key: 'photo_unclear',
    short: 'Photo unclear',
    full: 'Profile photo is unclear or not a real portrait',
  ),
  _PresetReason(
    key: 'bio_incomplete',
    short: 'Bio incomplete',
    full: 'Bio is incomplete or lacks relevant detail',
  ),
  _PresetReason(
    key: 'fake_data',
    short: 'Fake / meaningless data',
    full: 'Submitted details appear fake or meaningless',
  ),
  _PresetReason(
    key: 'invalid_email',
    short: 'Invalid email',
    full: 'Email address appears invalid',
  ),
  _PresetReason(
    key: 'invalid_phone',
    short: 'Invalid phone',
    full: 'Phone number appears invalid',
  ),
  _PresetReason(
    key: 'docs_unclear',
    short: 'Documents unclear',
    full: 'Uploaded documents are unclear or unreadable',
  ),
  _PresetReason(
    key: 'ministry_insufficient',
    short: 'Ministry info insufficient',
    full: 'Ministry information is insufficient for verification',
  ),
];

class _PresetReason {
  final String key;
  // Compact label for the chip itself.
  final String short;
  // Full sentence that joins into the final reason string.
  final String full;
  const _PresetReason({
    required this.key,
    required this.short,
    required this.full,
  });
}

class _RejectReasonSheet extends StatefulWidget {
  const _RejectReasonSheet();

  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const _RejectReasonSheet(),
    );
  }

  @override
  State<_RejectReasonSheet> createState() => _RejectReasonSheetState();
}

class _RejectReasonSheetState extends State<_RejectReasonSheet> {
  final TextEditingController _notesController = TextEditingController();
  final Set<String> _selectedKeys = <String>{};
  String? _error;

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  // Stitches together the final reason. Presets come first (as a
  // comma-joined sentence), manual notes follow after a period so
  // the resulting message reads naturally when shown to the priest.
  String _composeReason() {
    final presetParts = _kPresetReasons
        .where((r) => _selectedKeys.contains(r.key))
        .map((r) => r.full)
        .toList();
    final notes = _notesController.text.trim();

    if (presetParts.isEmpty && notes.isEmpty) return '';
    if (presetParts.isEmpty) return notes;

    final buf = StringBuffer(presetParts.join('. '));
    if (notes.isNotEmpty) {
      buf.write('. ');
      buf.write(notes);
    }
    return buf.toString();
  }

  void _toggle(String key) {
    setState(() {
      if (_selectedKeys.contains(key)) {
        _selectedKeys.remove(key);
      } else {
        _selectedKeys.add(key);
      }
      if (_error != null) _error = null;
    });
  }

  void _submit() {
    final reason = _composeReason();
    if (reason.length < 10) {
      setState(() {
        _error = _selectedKeys.isEmpty && _notesController.text.isEmpty
            ? 'Select at least one reason or add a note'
            : 'Please provide more detail (minimum 10 characters)';
      });
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    // viewInsets lifts the sheet above the soft keyboard; without it
    // the text field hides under the IME on short phones.
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AdminColors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AdminColors.errorBg,
                      ),
                      child: const Icon(
                        Icons.block_rounded,
                        size: 18,
                        color: AdminColors.error,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Reject Application',
                            style: GoogleFonts.inter(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AdminColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'The speaker will see this and can reapply.',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              color: AdminColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                Text(
                  'Select reason(s)',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AdminColors.textLight,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _kPresetReasons.map((r) {
                            final selected = _selectedKeys.contains(r.key);
                            return _ReasonChip(
                              label: r.short,
                              selected: selected,
                              onTap: () => _toggle(r.key),
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Additional notes (optional)',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AdminColors.textLight,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _notesController,
                          maxLines: 3,
                          maxLength: 200,
                          onChanged: (_) {
                            if (_error != null) {
                              setState(() => _error = null);
                            }
                          },
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w400,
                            color: AdminColors.textPrimary,
                          ),
                          decoration: InputDecoration(
                            hintText:
                                'Add any specific details for the speaker...',
                            hintStyle: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                              color: AdminColors.textLight,
                            ),
                            filled: true,
                            fillColor: AdminColors.inputBackground,
                            border: _border(AdminColors.divider),
                            enabledBorder: _border(AdminColors.divider),
                            focusedBorder: _border(
                              AdminColors.brandBrown,
                              width: 1.5,
                            ),
                            errorBorder: _border(AdminColors.error),
                            focusedErrorBorder: _border(
                              AdminColors.error,
                              width: 1.5,
                            ),
                            contentPadding: const EdgeInsets.all(12),
                            errorText: _error,
                            errorStyle: GoogleFonts.inter(
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              color: AdminColors.error,
                            ),
                            counterText: '',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _SheetBtn(
                        label: 'Cancel',
                        bg: Colors.white,
                        fg: AdminColors.textMuted,
                        border: AdminColors.divider,
                        onTap: () => Navigator.pop(context),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _SheetBtn(
                        label: 'Reject',
                        bg: AdminColors.error,
                        fg: Colors.white,
                        onTap: _submit,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  OutlineInputBorder _border(Color c, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: c, width: width),
    );
  }
}

class _ReasonChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ReasonChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AdminColors.errorBg
              : AdminColors.inputBackground,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AdminColors.error
                : AdminColors.divider,
            width: selected ? 1.3 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              const Icon(
                Icons.check_rounded,
                size: 14,
                color: AdminColors.error,
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? AdminColors.error
                    : AdminColors.textBody,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetBtn extends StatefulWidget {
  final String label;
  final Color bg;
  final Color fg;
  final Color? border;
  final VoidCallback onTap;

  const _SheetBtn({
    required this.label,
    required this.bg,
    required this.fg,
    this.border,
    required this.onTap,
  });

  @override
  State<_SheetBtn> createState() => _SheetBtnState();
}

class _SheetBtnState extends State<_SheetBtn> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 80),
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: widget.bg,
            borderRadius: BorderRadius.circular(12),
            border: widget.border != null
                ? Border.all(color: widget.border!, width: 1.5)
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: widget.fg,
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Shimmer skeleton for the whole detail page ────────────────

class _DetailShimmer extends StatelessWidget {
  const _DetailShimmer();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Shimmer.fromColors(
        baseColor: AdminColors.inputBackground,
        highlightColor: Colors.white,
        child: Column(
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AdminColors.inputBackground,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: 180,
              height: 20,
              decoration: BoxDecoration(
                color: AdminColors.inputBackground,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              width: 120,
              height: 14,
              decoration: BoxDecoration(
                color: AdminColors.inputBackground,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            const SizedBox(height: 24),
            for (int i = 0; i < 3; i++) ...[
              Container(
                width: double.infinity,
                height: 100,
                decoration: BoxDecoration(
                  color: AdminColors.inputBackground,
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ],
        ),
      ),
    );
  }
}

// ─── Full-screen error ─────────────────────────────────────────

class _FullScreenError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _FullScreenError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 48,
              color: AdminColors.error,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AdminColors.textMuted,
              ),
            ),
            const SizedBox(height: 20),
            GestureDetector(
              onTap: onRetry,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AdminColors.brandBrown,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  'Go Back',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
