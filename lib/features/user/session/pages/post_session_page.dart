// User's post-session summary + rating screen. Reached via
// context.go so the back stack can't bounce into the now-ended
// chat. The rating write is best-effort and fire-and-forget —
// we want the Done button to land on home even if Firestore is
// momentarily unreachable, rather than blocking the user on a
// non-critical metric.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';

class PostSessionPage extends StatefulWidget {
  final SessionSummary summary;
  final SessionModel session;
  final String endReason;

  const PostSessionPage({
    super.key,
    required this.summary,
    required this.session,
    this.endReason = 'user_ended',
  });

  @override
  State<PostSessionPage> createState() => _PostSessionPageState();
}

class _PostSessionPageState extends State<PostSessionPage>
    with SingleTickerProviderStateMixin {
  final TextEditingController _feedbackController = TextEditingController();
  int _rating = 0;
  bool _saving = false;
  late final AnimationController _entranceController;

  @override
  void initState() {
    super.initState();
    // Very gentle fade-up so the summary doesn't slam in — reinforces
    // that the session has gracefully ended rather than crashed.
    _entranceController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    )..forward();
  }

  @override
  void dispose() {
    _feedbackController.dispose();
    _entranceController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);

    // Save rating + feedback if the user actually picked something.
    // Writing with no rating would overwrite existing data in the
    // edge case where both sides end the session simultaneously.
    if (_rating > 0) {
      try {
        await FirebaseFirestore.instance
            .doc('sessions/${widget.session.id}')
            .update({
              'userRating': _rating,
              'userFeedback': _feedbackController.text.trim(),
            })
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        // Swallow — the user has already ended and rated; blocking
        // their return home on a failed metric write would feel
        // worse than silently missing the rating.
      }
    }

    if (!mounted) return;
    context.go('/user');
  }

  String get _endCopy {
    switch (widget.endReason) {
      case 'balance_zero':
        return 'Your balance ran out — the session ended automatically.';
      case 'priest_ended':
        return 'The speaker ended the session.';
      case 'external':
      case 'completed':
        return 'The session has ended.';
      default:
        return 'Your session with ${widget.session.priestName} has ended.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    final session = widget.session;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return PopScope(
      // Can't go back to a session that's already settled on the
      // server. Done is the only exit.
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
                        color:
                            AppColors.primaryBrown.withValues(alpha: 0.08),
                      ),
                      child: Icon(
                        Icons.check_rounded,
                        size: 32,
                        color: AppColors.primaryBrown,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: Text(
                      'Session Complete',
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
                        icon: Icons.toll_rounded,
                        label: 'Coins Spent',
                        value: '${s.totalCharged} coins',
                        valueColor: AppColors.errorRed,
                      ),
                      _SummaryRow(
                        icon: Icons.speed_rounded,
                        label: 'Rate',
                        value: '${session.ratePerMinute} coins/min',
                      ),
                      _SummaryRow(
                        icon: Icons.account_balance_wallet_outlined,
                        label: 'Remaining Balance',
                        value: '${s.newBalance} coins',
                        valueColor: AppColors.primaryBrown,
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  Center(
                    child: Text(
                      'Rate your experience',
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _StarRow(
                    rating: _rating,
                    onChanged: (value) => setState(() => _rating = value),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F5F2),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: TextField(
                      controller: _feedbackController,
                      maxLines: 3,
                      maxLength: 200,
                      textCapitalization: TextCapitalization.sentences,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(200),
                      ],
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        color: AppColors.deepDarkBrown,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Share your experience (optional)…',
                        hintStyle: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted.withValues(alpha: 0.5),
                        ),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.all(16),
                        counterStyle: GoogleFonts.inter(
                          fontSize: 10,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  _DoneButton(
                    saving: _saving,
                    onTap: _finish,
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

  const _SummaryRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
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
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: valueColor ?? AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Star rating ──────────────────────────────────────────

class _StarRow extends StatelessWidget {
  final int rating;
  final ValueChanged<int> onChanged;

  const _StarRow({required this.rating, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(5, (i) {
        final filled = i < rating;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(i + 1),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: AnimatedScale(
              scale: filled ? 1.05 : 1.0,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: Icon(
                filled
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                size: 36,
                color: filled
                    ? AppColors.amberGold
                    : AppColors.muted.withValues(alpha: 0.25),
              ),
            ),
          ),
        );
      }),
    );
  }
}

// ─── Done button ──────────────────────────────────────────

class _DoneButton extends StatefulWidget {
  final bool saving;
  final VoidCallback onTap;

  const _DoneButton({required this.saving, required this.onTap});

  @override
  State<_DoneButton> createState() => _DoneButtonState();
}

class _DoneButtonState extends State<_DoneButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) {
        if (!widget.saving) setState(() => _scale = 0.97);
      },
      onPointerUp: (_) => setState(() => _scale = 1.0),
      onPointerCancel: (_) => setState(() => _scale = 1.0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.saving ? null : widget.onTap,
        child: AnimatedScale(
          scale: _scale,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: Container(
            width: double.infinity,
            height: 54,
            decoration: BoxDecoration(
              color: AppColors.primaryBrown.withValues(
                alpha: widget.saving ? 0.5 : 1.0,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: widget.saving
                  ? null
                  : [
                      BoxShadow(
                        color: AppColors.primaryBrown
                            .withValues(alpha: 0.2),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
            ),
            child: Center(
              child: widget.saving
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : Text(
                      'Done',
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
