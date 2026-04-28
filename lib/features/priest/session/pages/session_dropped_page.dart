// Shown to the priest when a session ends but they DIDN'T tap the
// End button. The priest's instinctive worry is "did I do something
// wrong?" — the screen exists to reassure them with calm copy +
// concrete proof of their earnings, then send them back to the
// dashboard cleanly.
//
// Routing: priest_chat_session_page picks between this page and
// /session/priest-summary based on the endReason. "priest_ended"
// goes to summary; everything else (balance_zero, watchdog_timeout,
// user_ended, external) lands here.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/features/user/home/widgets/no_priests_widget.dart';

// Forest green for the earnings line — already used by the priest
// summary page so the brand vocabulary stays consistent.
const Color _kPaidGreen = Color(0xFF2E7D4F);

class SessionDroppedPage extends StatefulWidget {
  final SessionModel session;
  final int earnedAmount;
  final int duration;
  final String endReason;

  const SessionDroppedPage({
    super.key,
    required this.session,
    required this.earnedAmount,
    required this.duration,
    this.endReason = 'external',
  });

  @override
  State<SessionDroppedPage> createState() => _SessionDroppedPageState();
}

class _SessionDroppedPageState extends State<SessionDroppedPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  // Each piece of the screen fades in on its own offset window so
  // the eye lands on the icon → headline → reason → numbers → CTA
  // in that order. Single controller drives all of them so we don't
  // ship six controllers' worth of overhead for one screen.
  late final Animation<double> _iconScale;
  late final Animation<double> _iconFade;
  late final Animation<double> _titleFade;
  late final Animation<double> _subtitleFade;
  late final Animation<double> _cardFade;
  late final Animation<Offset> _cardSlide;
  late final Animation<double> _tipFade;
  late final Animation<double> _buttonFade;
  late final Animation<Offset> _buttonSlide;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    // easeOutBack on the icon gives a tiny "bounce" at the end —
    // makes the screen feel finished/polished instead of inert.
    _iconScale = CurvedAnimation(
      parent: _ctl,
      curve: const Interval(0.0, 0.4, curve: Curves.easeOutBack),
    );
    _iconFade = CurvedAnimation(
      parent: _ctl,
      curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
    );
    _titleFade = CurvedAnimation(
      parent: _ctl,
      curve: const Interval(0.10, 0.50, curve: Curves.easeOutCubic),
    );
    _subtitleFade = CurvedAnimation(
      parent: _ctl,
      curve: const Interval(0.15, 0.55, curve: Curves.easeOutCubic),
    );
    _cardFade = CurvedAnimation(
      parent: _ctl,
      curve: const Interval(0.25, 0.70, curve: Curves.easeOutCubic),
    );
    _cardSlide = Tween<Offset>(
      begin: const Offset(0, 0.05),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _ctl,
        curve: const Interval(0.25, 0.70, curve: Curves.easeOutCubic),
      ),
    );
    _tipFade = CurvedAnimation(
      parent: _ctl,
      curve: const Interval(0.35, 0.80, curve: Curves.easeOutCubic),
    );
    _buttonFade = CurvedAnimation(
      parent: _ctl,
      curve: const Interval(0.50, 1.0, curve: Curves.easeOutCubic),
    );
    _buttonSlide = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _ctl,
        curve: const Interval(0.50, 1.0, curve: Curves.easeOutCubic),
      ),
    );

    _ctl.forward();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  // The reason is what makes this screen NOT feel like generic
  // boilerplate. Each branch names the specific cause so the
  // priest doesn't have to guess.
  String get _reasonText {
    final userName = widget.session.userName.isNotEmpty
        ? widget.session.userName
        : 'The user';
    switch (widget.endReason) {
      case 'balance_zero':
        return "$userName's coin balance ran out. "
            "You've been paid for the full session duration.";
      case 'watchdog_timeout':
        return 'The connection was lost and the session timed out. '
            "This usually happens when the user's app closes "
            'unexpectedly.';
      case 'user_ended':
        return '$userName ended the session. '
            "You've been paid for the time spent.";
      case 'network_disconnected':
        // Surfaced by VoiceCallCubit's 30-second disconnect timer:
        // Agora reported the channel as down for half a minute
        // straight, so we ended the call instead of leaving the
        // priest staring at "Reconnecting…" indefinitely.
        return 'The call was disconnected due to network issues. '
            "We waited 30 seconds for the connection to recover "
            "before ending the session. Your earnings for the time "
            "before the drop have been credited.";
      case 'connection_failed':
        // Surfaced by the 60-second remote-join supervisor: the
        // local user joined the Agora channel but the remote party
        // never showed up. Usually means their app couldn't reach
        // Agora (offline / firewall / mid-update).
        return "$userName joined the call but couldn't connect "
            'their audio. The session ended automatically after '
            '60 seconds. No charge has been applied.';
      default:
        return 'The session ended unexpectedly. '
            'Your earnings for the time spent have been credited.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return PopScope(
      // No accidental back-swipes off this screen — the priest
      // commits via the explicit "Back to Dashboard" button so we
      // can guarantee where they land.
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, bottomInset + 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Spacer(flex: 2),
                FadeTransition(
                  opacity: _iconFade,
                  child: ScaleTransition(
                    scale: _iconScale,
                    child: Center(child: _buildIcon()),
                  ),
                ),
                const SizedBox(height: 28),
                FadeTransition(
                  opacity: _titleFade,
                  child: Center(
                    child: Text(
                      'Session Ended',
                      style: GoogleFonts.inter(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                FadeTransition(
                  opacity: _subtitleFade,
                  child: Text(
                    _reasonText,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.6,
                      color: AppColors.muted,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                FadeTransition(
                  opacity: _cardFade,
                  child: SlideTransition(
                    position: _cardSlide,
                    child: _SummaryCard(
                      userName: widget.session.userName,
                      duration: widget.duration,
                      earned: widget.earnedAmount,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                FadeTransition(
                  opacity: _tipFade,
                  child: const InfoTipBlock(
                    'Your earnings have been added to your wallet. '
                    "The session ended due to a connection issue on "
                    "the user's side — this does not affect your "
                    'account.',
                  ),
                ),
                const Spacer(flex: 3),
                FadeTransition(
                  opacity: _buttonFade,
                  child: SlideTransition(
                    position: _buttonSlide,
                    child: _BackToDashboardButton(
                      onTap: () => context.go('/priest'),
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

  Widget _buildIcon() {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.amberGold.withValues(alpha: 0.1),
      ),
      child: Icon(
        Icons.call_end_rounded,
        size: 36,
        color: AppColors.amberGold,
      ),
    );
  }
}

// ─── Summary card (user / duration / earnings) ───────────

class _SummaryCard extends StatelessWidget {
  final String userName;
  final int duration;
  final int earned;

  const _SummaryCard({
    required this.userName,
    required this.duration,
    required this.earned,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          _InfoRow(
            icon: Icons.person_outline_rounded,
            label: 'User',
            value: userName.isNotEmpty ? userName : '—',
          ),
          const _Divider(),
          _InfoRow(
            icon: Icons.access_time_rounded,
            label: 'Duration',
            value: _formatDuration(duration),
          ),
          const _Divider(),
          _InfoRow(
            icon: Icons.account_balance_wallet_outlined,
            label: 'You Earned',
            value: '₹$earned',
            valueColor: _kPaidGreen,
            valueBold: true,
          ),
        ],
      ),
    );
  }
}

String _formatDuration(int minutes) {
  if (minutes <= 0) return '< 1 min';
  if (minutes == 1) return '1 min';
  return '$minutes min';
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final bool valueBold;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.valueBold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: AppColors.muted.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
              ),
            ),
          ),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: valueBold ? 16 : 14,
              fontWeight: valueBold ? FontWeight.w700 : FontWeight.w500,
              color: valueColor ?? AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: AppColors.muted.withValues(alpha: 0.06),
    );
  }
}

// ─── Back to Dashboard button ────────────────────────────

class _BackToDashboardButton extends StatefulWidget {
  final VoidCallback onTap;
  const _BackToDashboardButton({required this.onTap});

  @override
  State<_BackToDashboardButton> createState() =>
      _BackToDashboardButtonState();
}

class _BackToDashboardButtonState extends State<_BackToDashboardButton> {
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
            height: 54,
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
            child: Center(
              child: Text(
                'Back to Dashboard',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
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
