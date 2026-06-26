// Per-session detail page. Read-only summary of a single session:
// header, info card, rating (when present), transcript shortcut
// (chat completed only), and a user-side "Chat Again" CTA.
//
// `isUserSide` flips:
//   • whose name + photo appears at the top
//   • whether we show denomination (priest profile field, only
//     relevant when the user is the viewer)
//   • the financial breakdown (user sees a single charged total,
//     priest sees gross / commission / net)
//   • the rating-section header copy
//
// The priest's templated "Send Follow-up" flow used to live here
// but was replaced by freeform priest messaging — priests now go
// to My Users → tap user → text input. As a result this page is
// purely informational on the priest side; there are no priest-
// initiated actions.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/utils/date_format.dart' as df;
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/shared/data/session_preflight.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

const Color _kCompletedGreen = Color(0xFF059669);
const Color _kDeclinedRed = Color(0xFFDC2626);
const Color _kEarningsGreen = AppColors.successGreen;

class SessionDetailPage extends StatefulWidget {
  final SessionModel session;
  final bool isUserSide;

  const SessionDetailPage({
    super.key,
    required this.session,
    required this.isUserSide,
  });

  @override
  State<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends State<SessionDetailPage> {
  SessionModel get _session => widget.session;
  bool get _isUserSide => widget.isUserSide;

  String get _otherName =>
      _isUserSide ? _session.priestName : _session.userName;
  String get _otherPhotoUrl =>
      _isUserSide ? _session.priestPhotoUrl : _session.userPhotoUrl;

  bool get _hasRating =>
      _session.userRating != null && _session.userRating! > 0;

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
            if (_session.isChat && _session.status == 'completed') ...[
              const SizedBox(height: 20),
              _ViewTranscriptButton(
                onTap: () => _openTranscript(context),
              ),
            ],
            // User-side re-engagement entry point. Fires the new
            // session request directly — no profile detour. Runs the
            // 5-minute balance preflight first; if short, the user
            // sees the recharge sheet pre-filled with the deficit
            // amount instead of bouncing off the CF after a round-
            // trip. The waiting screen handles every server-side
            // outcome (insufficient-balance, priest-offline,
            // priest-busy, accepted, expired). "Chat Again" always
            // launches a chat session, even if the original session
            // was voice — users wanting voice can still tap into
            // the priest profile.
            if (_isUserSide && _session.status == 'completed') ...[
              const SizedBox(height: 16),
              _ChatAgainButton(
                priestName: _session.priestName,
                onTap: () => _startChatAgain(context),
              ),
            ],
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      centerTitle: false,
      leadingWidth: 60,
      leading: const Padding(
        padding: EdgeInsets.only(left: 16),
        child: AppBackButton(),
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
              color: AppColors.fieldFill,
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
          if (_isUserSide && _session.priestDenomination.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              _session.priestDenomination,
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
          _StatusBadge(status: _session.status),
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
    final hasEndReason = _session.endReason.isNotEmpty &&
        _session.status != 'completed';

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
            value: _session.isChat ? '💬 Chat' : '🎙 Voice Call',
          ),
          const _RowDivider(),
          _DetailRow(
            label: 'Date',
            value: _formatFullDate(_session.createdAt),
          ),
          const _RowDivider(),
          _DetailRow(
            label: 'Duration',
            value: _session.durationMinutes > 0
                ? '${_session.durationMinutes} min'
                : '—',
          ),
          const _RowDivider(),
          _DetailRow(
            label: 'Rate',
            value: '${_session.ratePerMinute} coins/min',
          ),
          const _RowDivider(),
          if (_isUserSide)
            _DetailRow(
              label: 'Total Charged',
              value: '${_session.totalCharged} coins',
              valueBold: true,
              valueColor: AppColors.deepDarkBrown,
            )
          else ...[
            _DetailRow(
              label: 'Gross Earnings',
              value: '₹${_session.totalCharged}',
            ),
            const _RowDivider(),
            _DetailRow(
              label: 'Commission (${_session.commissionPercent}%)',
              value:
                  '-₹${_session.totalCharged - _session.priestEarnings}',
            ),
            const _RowDivider(),
            _DetailRow(
              label: 'Net Earnings',
              value: '₹${_session.priestEarnings}',
              valueBold: true,
              valueColor: _kEarningsGreen,
            ),
          ],
          if (hasEndReason) ...[
            const _RowDivider(),
            _DetailRow(
              label: 'End Reason',
              value: _humanizeEndReason(_session.endReason),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRatingCard() {
    final stars = _session.userRating!.round();

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
            _isUserSide ? 'Your Rating' : "User's Rating",
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
                child: AppIcon(
                  filled
                      ? AppIcons.starFilled
                      : AppIcons.starOutline,
                  size: 28,
                  color: filled
                      ? AppColors.amberGold
                      : AppColors.muted.withValues(alpha: 0.2),
                ),
              );
            }),
          ),
          if (_session.userFeedback != null &&
              _session.userFeedback!.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.fieldFill,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _session.userFeedback!,
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
    context.push('/session/transcript/${_session.id}', extra: {
      'otherName': _otherName,
      'sessionDate': _formatFullDate(_session.createdAt),
    });
  }

  // "Chat Again" tap path. Runs the preflight balance gate, then
  // hands off to the waiting screen. Pulled out of the inline
  // closure because the preflight is async and the closure inside
  // the build was getting tangled.
  Future<void> _startChatAgain(BuildContext context) async {
    final canStart = await SessionPreflight.check(
      context,
      type: 'chat',
      priestName: _session.priestName,
    );
    if (!canStart || !context.mounted) return;
    context.push('/session/waiting', extra: <String, dynamic>{
      'priestId': _session.priestId,
      'priestName': _session.priestName,
      'priestPhotoUrl': _session.priestPhotoUrl,
      'priestDenomination': _session.priestDenomination,
      'type': 'chat',
    });
  }
}

// ─── Chat Again button (user side, completed sessions) ────

class _ChatAgainButton extends StatefulWidget {
  final String priestName;
  final VoidCallback onTap;

  const _ChatAgainButton({
    required this.priestName,
    required this.onTap,
  });

  @override
  State<_ChatAgainButton> createState() => _ChatAgainButtonState();
}

class _ChatAgainButtonState extends State<_ChatAgainButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final name = widget.priestName.isNotEmpty
        ? widget.priestName
        : 'this speaker';

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
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.primaryBrown.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.primaryBrown.withValues(alpha: 0.15),
              ),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                AppIcon(
                  AppIcons.chatOutline,
                  size: 16,
                  color: AppColors.primaryBrown,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    'Chat Again with $name',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryBrown,
                    ),
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
                AppIcon(
                  AppIcons.chatOutline,
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
    case 'request_timeout':
    case 'watchdog_pending_timeout':
      // Same human-visible outcome — the priest never responded in
      // time. The two server-side codes distinguish which path
      // expired the request (user-side CF vs. cron safety net) for
      // debugging, but the user opening their session detail just
      // wants the plain story.
      return 'Speaker did not respond in time';
    case 'superseded_by_new_request':
      return 'Replaced by a newer request';
    default:
      return reason;
  }
}

String _formatFullDate(DateTime? date) => df.formatFullDateTime(date);
