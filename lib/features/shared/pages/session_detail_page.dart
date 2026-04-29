// Per-session detail page. Shared between user and priest sides —
// `isUserSide` flips:
//   • whose name + photo appears at the top
//   • whether we show denomination (priest profile field, only relevant
//     when the user is the viewer)
//   • the financial breakdown (user sees a single charged total, priest
//     sees gross / commission / net)
//   • the rating-section header copy
//
// The "View Chat Transcript" button is only rendered for completed
// chat sessions because voice sessions have no text to show, and an
// in-progress session would expose live data the live-chat screen
// already renders.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

const Color _kCompletedGreen = Color(0xFF059669);
const Color _kDeclinedRed = Color(0xFFDC2626);
const Color _kEarningsGreen = Color(0xFF2E7D4F);

class SessionDetailPage extends StatelessWidget {
  final SessionModel session;
  final bool isUserSide;

  const SessionDetailPage({
    super.key,
    required this.session,
    required this.isUserSide,
  });

  String get _otherName =>
      isUserSide ? session.priestName : session.userName;
  String get _otherPhotoUrl =>
      isUserSide ? session.priestPhotoUrl : session.userPhotoUrl;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(context),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            const SizedBox(height: 28),
            _buildInfoCard(),
            if (_hasRating) ...[
              const SizedBox(height: 20),
              _buildRatingCard(),
            ],
            if (session.isChat && session.status == 'completed') ...[
              const SizedBox(height: 20),
              _ViewTranscriptButton(
                onTap: () => _openTranscript(context),
              ),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  bool get _hasRating =>
      session.userRating != null && session.userRating! > 0;

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      leadingWidth: 60,
      leading: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.pop(),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceWhite,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              Icons.arrow_back_ios_new,
              size: 16,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ),
      ),
      title: Text(
        'Session Details',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final name = _otherName.isNotEmpty ? _otherName : 'Unknown';
    final photoUrl = _otherPhotoUrl;
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Center(
      child: Column(
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFF7F5F2),
              border: Border.all(
                color: AppColors.muted.withValues(alpha: 0.12),
                width: 2,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: photoUrl.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: photoUrl,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => _initialFallback(initial),
                    placeholder: (_, _) => const SizedBox.shrink(),
                  )
                : _initialFallback(initial),
          ),
          const SizedBox(height: 14),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          if (isUserSide && session.priestDenomination.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              session.priestDenomination,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
              ),
            ),
          ],
          const SizedBox(height: 8),
          _StatusBadge(status: session.status),
        ],
      ),
    );
  }

  Widget _initialFallback(String initial) {
    return Center(
      child: Text(
        initial,
        style: GoogleFonts.inter(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    final hasEndReason =
        session.endReason.isNotEmpty && session.status != 'completed';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        children: [
          _DetailRow(
            label: 'Type',
            value: session.isChat ? '💬 Chat' : '🎙 Voice Call',
          ),
          const _RowDivider(),
          _DetailRow(
            label: 'Date',
            value: _formatFullDate(session.createdAt),
          ),
          const _RowDivider(),
          _DetailRow(
            label: 'Duration',
            value: session.durationMinutes > 0
                ? '${session.durationMinutes} min'
                : '—',
          ),
          const _RowDivider(),
          _DetailRow(
            label: 'Rate',
            value: '${session.ratePerMinute} coins/min',
          ),
          const _RowDivider(),
          if (isUserSide)
            _DetailRow(
              label: 'Total Charged',
              value: '${session.totalCharged} coins',
              valueBold: true,
              valueColor: AppColors.deepDarkBrown,
            )
          else ...[
            _DetailRow(
              label: 'Gross Earnings',
              value: '₹${session.totalCharged}',
            ),
            const _RowDivider(),
            _DetailRow(
              label: 'Commission (${session.commissionPercent}%)',
              value:
                  '-₹${session.totalCharged - session.priestEarnings}',
            ),
            const _RowDivider(),
            _DetailRow(
              label: 'Net Earnings',
              value: '₹${session.priestEarnings}',
              valueBold: true,
              valueColor: _kEarningsGreen,
            ),
          ],
          if (hasEndReason) ...[
            const _RowDivider(),
            _DetailRow(
              label: 'End Reason',
              value: _humanizeEndReason(session.endReason),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRatingCard() {
    final stars = session.userRating!.round();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            isUserSide ? 'Your Rating' : "User's Rating",
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) {
              final filled = i < stars;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Icon(
                  filled
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded,
                  size: 28,
                  color: filled
                      ? AppColors.amberGold
                      : AppColors.muted.withValues(alpha: 0.2),
                ),
              );
            }),
          ),
          if (session.userFeedback != null &&
              session.userFeedback!.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F5F2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                session.userFeedback!,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  height: 1.5,
                  color: AppColors.deepDarkBrown,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _openTranscript(BuildContext context) {
    context.push('/session/transcript/${session.id}', extra: {
      'otherName': _otherName,
      'sessionDate': _formatFullDate(session.createdAt),
    });
  }
}

// ─── Status badge (mirrors the list version) ───────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _statusBgColor(status),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        _statusLabel(status),
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: _statusTextColor(status),
        ),
      ),
    );
  }
}

String _statusLabel(String status) {
  switch (status) {
    case 'completed':
      return 'Completed';
    case 'declined':
      return 'Declined';
    case 'expired':
      return 'Expired';
    case 'cancelled':
      return 'Cancelled';
    case 'active':
      return 'Active';
    case 'pending':
      return 'Pending';
    default:
      return status.isNotEmpty
          ? '${status[0].toUpperCase()}${status.substring(1)}'
          : '—';
  }
}

Color _statusBgColor(String status) {
  switch (status) {
    case 'completed':
    case 'active':
      return _kCompletedGreen.withValues(alpha: 0.08);
    case 'declined':
      return _kDeclinedRed.withValues(alpha: 0.08);
    default:
      return AppColors.muted.withValues(alpha: 0.08);
  }
}

Color _statusTextColor(String status) {
  switch (status) {
    case 'completed':
    case 'active':
      return _kCompletedGreen;
    case 'declined':
      return _kDeclinedRed;
    default:
      return AppColors.muted;
  }
}

// ─── Detail row + divider ──────────────────────────────────

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final bool valueBold;

  const _DetailRow({
    required this.label,
    required this.value,
    this.valueColor,
    this.valueBold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: valueBold ? FontWeight.w700 : FontWeight.w500,
                color: valueColor ?? AppColors.deepDarkBrown,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: AppColors.muted.withValues(alpha: 0.06),
    );
  }
}

// ─── View Transcript button ────────────────────────────────

class _ViewTranscriptButton extends StatefulWidget {
  final VoidCallback onTap;
  const _ViewTranscriptButton({required this.onTap});

  @override
  State<_ViewTranscriptButton> createState() =>
      _ViewTranscriptButtonState();
}

class _ViewTranscriptButtonState extends State<_ViewTranscriptButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _scale = 0.97),
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            width: double.infinity,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.primaryBrown,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primaryBrown.withValues(alpha: 0.2),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 18,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Text(
                  'View Chat Transcript',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Helpers ───────────────────────────────────────────────

String _humanizeEndReason(String reason) {
  switch (reason) {
    case 'user_ended':
      return 'User ended session';
    case 'priest_ended':
      return 'Speaker ended session';
    case 'balance_zero':
      return 'Balance ran out';
    case 'watchdog_timeout':
      return 'Connection dropped';
    case 'network_disconnected':
      return 'Network disconnected';
    case 'connection_failed':
      return 'Failed to connect';
    default:
      return reason;
  }
}

String _formatFullDate(DateTime? date) {
  if (date == null) return '—';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hour = date.hour > 12
      ? date.hour - 12
      : (date.hour == 0 ? 12 : date.hour);
  final period = date.hour >= 12 ? 'PM' : 'AM';
  final minute = date.minute.toString().padLeft(2, '0');
  return '${months[date.month - 1]} ${date.day}, ${date.year} · '
      '$hour:$minute $period';
}
