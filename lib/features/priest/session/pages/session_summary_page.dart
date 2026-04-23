// Priest's post-session summary. Mirrors the user's PostSessionPage
// structure but recasts the numbers from the priest's perspective:
// gross earnings, commission deducted, net earnings, and wallet
// top-up amount. No rating UI here — the priest doesn't rate the
// user in the current product.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

// Forest green for the net-earnings emphasis. Local constant because
// AppColors has no dedicated success-green token.
const Color _kNetGreen = Color(0xFF2E7D4F);

class SessionSummaryPage extends StatefulWidget {
  final SessionSummary summary;
  final SessionModel session;
  final String endReason;

  const SessionSummaryPage({
    super.key,
    required this.summary,
    required this.session,
    this.endReason = 'priest_ended',
  });

  @override
  State<SessionSummaryPage> createState() => _SessionSummaryPageState();
}

class _SessionSummaryPageState extends State<SessionSummaryPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entranceController;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    )..forward();
  }

  @override
  void dispose() {
    _entranceController.dispose();
    super.dispose();
  }

  String get _endCopy {
    switch (widget.endReason) {
      case 'balance_zero':
        return "The user's balance ran out — the session ended "
            'automatically.';
      case 'user_ended':
        return 'The user ended the session.';
      case 'external':
      case 'completed':
        return 'The session has ended.';
      default:
        return 'The session has ended.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    final session = widget.session;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    // Gross = totalCharged from user. Commission is derived from the
    // priestEarnings the server already computed, so we don't re-do
    // the math client-side (server is authoritative).
    final gross = s.totalCharged;
    final net = s.priestEarnings;
    final commission = (gross - net).clamp(0, gross);
    final commissionPercent = session.commissionPercent;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(
          child: FadeTransition(
            opacity: _entranceController,
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(24, 0, 24, bottomInset + 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 32),
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _kNetGreen.withValues(alpha: 0.1),
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        size: 32,
                        color: _kNetGreen,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: Text(
                      'Session Summary',
                      style: GoogleFonts.inter(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      _endCopy,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        height: 1.5,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  _SummaryCard(
                    rows: [
                      _SummaryRow(
                        icon: Icons.access_time_rounded,
                        label: 'Duration',
                        value: _formatDuration(s.durationMinutes),
                      ),
                      _SummaryRow(
                        icon: Icons.speed_rounded,
                        label: 'Session Rate',
                        value: '${session.ratePerMinute} coins/min',
                      ),
                      _SummaryRow(
                        icon: Icons.toll_rounded,
                        label: 'Gross Earnings',
                        value: '$gross coins',
                      ),
                      _SummaryRow(
                        icon: Icons.percent_rounded,
                        label: 'Commission ($commissionPercent%)',
                        value: '-$commission coins',
                        valueColor: AppColors.errorRed,
                      ),
                      _SummaryRow(
                        icon: Icons.savings_outlined,
                        label: 'Net Earnings',
                        value: '$net coins',
                        valueColor: _kNetGreen,
                        emphasized: true,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _WalletAddedBanner(netCoins: net),
                  const SizedBox(height: 32),
                  _BackButton(
                    onTap: () => context.go('/priest'),
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

String _formatDuration(int minutes) {
  if (minutes <= 0) return '< 1 min';
  if (minutes == 1) return '1 min';
  return '$minutes min';
}

// ─── Summary card ─────────────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final List<_SummaryRow> rows;
  const _SummaryCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i < rows.length - 1) {
        children.add(
          Container(
            height: 1,
            color: AppColors.muted.withValues(alpha: 0.06),
          ),
        );
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final bool emphasized;

  const _SummaryRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    this.emphasized = false,
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
            color: emphasized
                ? (valueColor ?? AppColors.deepDarkBrown)
                : AppColors.muted.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
                color: emphasized
                    ? AppColors.deepDarkBrown
                    : AppColors.muted,
              ),
            ),
          ),
          Text(
            value,
            style: GoogleFonts.inter(
              fontSize: emphasized ? 16 : 14,
              fontWeight: FontWeight.w700,
              color: valueColor ?? AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Wallet added banner ──────────────────────────────────

// Makes the "1 coin = ₹1" relationship explicit so the priest
// intuitively knows what landed in their real wallet, not just
// the abstract coin number above.
class _WalletAddedBanner extends StatelessWidget {
  final int netCoins;
  const _WalletAddedBanner({required this.netCoins});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _kNetGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _kNetGreen.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.account_balance_wallet_rounded,
            size: 20,
            color: _kNetGreen,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Added to wallet',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: _kNetGreen,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '₹$netCoins',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: _kNetGreen,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Back button ──────────────────────────────────────────

class _BackButton extends StatefulWidget {
  final VoidCallback onTap;
  const _BackButton({required this.onTap});

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
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
