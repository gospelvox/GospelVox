// Priest's read-write surface for the reviews left on their rated
// sessions. Built around three columns of information that the priest
// scans top-to-bottom:
//
//   • Summary header — average star, total count, distribution bars.
//     Lets the priest see "where am I" at a glance.
//   • Filter row — All / With written feedback. The "With feedback"
//     filter is the high-value scan: a star-only rating gives the
//     priest no actionable signal; written reviews are what they
//     come here to read and reply to.
//   • List — newest-first, each row carries the stars, the written
//     feedback (if any), the user's first name, the date, and the
//     priest's reply (or a Reply CTA if absent). Tapping Reply opens
//     the bottom-sheet composer; tapping the priest's own existing
//     reply (when still inside the 24h window) re-opens it for edit.
//
// Query strategy: a single-`where` query (priestId == uid) with
// limit(500) and CLIENT-SIDE sort + filter. We deliberately avoid
// the orderBy('endedAt') variant because the resulting composite
// index does not ship with the project — this mirrors the existing
// pattern in admin_reports_repository.dart. 500 is a generous cap
// for any priest in the foreseeable future, and the page is rarely
// opened compared to the dashboard so the slightly larger payload
// is acceptable.
//
// Why no cubit: the page reads once on mount, exposes a Reply action
// that goes through a Cloud Function (which then mutates the same
// session doc the page is showing), and re-fetches on success. A
// single piece of mutable state (List<SessionModel>) doesn't justify
// the cubit/state/event boilerplate the rest of the app uses for
// genuinely interactive flows.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_back_button.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/priest/reviews/widgets/review_reply_sheet.dart';
import 'package:gospel_vox/features/shared/data/session_model.dart';
import 'package:gospel_vox/core/widgets/app_icons.dart';

// Unified view-model for a single review on the priest's reviews page.
//
// Reviews come from TWO sources:
//   • chat/voice — `sessions/{id}` (source-of-truth for the reply too).
//   • bible — `bible_sessions/{sid}/registrations/{regId}` for the
//     write; the priest reads it via the denormalised mirror on
//     `priests/{uid}.recentReviews` (with source == "bible").
//
// We wrap both into PriestReviewItem so the card + reply sheet render
// uniformly. The `source` discriminator routes the reply call to the
// right CF parameters.
enum ReviewSource { session, bible }

class PriestReviewItem {
  // For session reviews this is the flat sessionId. For bible reviews
  // it's the sentinel "bible_<sid>_<regId>" that matches the entry's
  // sessionId field in priests/{uid}.recentReviews — used as a stable
  // key for ListView keys and for the reply mirror.
  final String id;
  final ReviewSource source;
  // Only populated for bible reviews. The CF reply path needs both
  // to address the source-of-truth registration doc.
  final String? bibleSessionId;
  final String? regId;
  final String userName;
  final String userPhotoUrl;
  final double rating;
  final String feedback;
  final DateTime? endedAt;
  final ReviewReply? priestReply;

  const PriestReviewItem({
    required this.id,
    required this.source,
    this.bibleSessionId,
    this.regId,
    required this.userName,
    required this.userPhotoUrl,
    required this.rating,
    required this.feedback,
    required this.endedAt,
    required this.priestReply,
  });

  bool get hasFeedback => feedback.trim().isNotEmpty;
  int get stars {
    final r = rating.round();
    if (r < 0) return 0;
    if (r > 5) return 5;
    return r;
  }

  factory PriestReviewItem.fromSession(SessionModel s) {
    return PriestReviewItem(
      id: s.id,
      source: ReviewSource.session,
      bibleSessionId: null,
      regId: null,
      userName: s.userName,
      userPhotoUrl: s.userPhotoUrl,
      rating: s.userRating ?? 0,
      feedback: s.userFeedback ?? '',
      endedAt: s.endedAt ?? s.createdAt,
      priestReply: s.priestReply,
    );
  }

  // Build from a `recentReviews` array entry written by the
  // onBibleSessionRated CF (and updated by replyToReview when the
  // priest replies). Tolerant of missing fields — older mirror
  // entries pre-deploy may not carry every field.
  static PriestReviewItem? tryFromBibleRecentEntry(Map<String, dynamic> e) {
    final src = e['source'];
    if (src != 'bible') return null;
    final bibleSessionId = e['bibleSessionId'] as String?;
    final sentinelId = e['sessionId'] as String?;
    if (bibleSessionId == null || sentinelId == null) return null;

    // The sentinel is "bible_<sid>_<regId>" — last segment is regId
    // (== user uid per the rules). Parsed defensively so a malformed
    // entry simply skips its reply support rather than crashing.
    String? regId;
    if (sentinelId.startsWith('bible_${bibleSessionId}_')) {
      regId = sentinelId.substring('bible_${bibleSessionId}_'.length);
      if (regId.isEmpty) regId = null;
    }

    DateTime? parseTime(dynamic v) {
      if (v is Timestamp) return v.toDate();
      if (v is String) return DateTime.tryParse(v);
      return null;
    }

    final replyText = ((e['priestReply'] as String?) ?? '').trim();
    ReviewReply? reply;
    if (replyText.isNotEmpty) {
      reply = ReviewReply(
        text: replyText,
        createdAt: parseTime(e['priestReplyCreatedAt']) ??
            parseTime(e['priestReplyAt']),
        updatedAt: parseTime(e['priestReplyAt']),
      );
    }

    final ratingNum = e['rating'];
    final rating = ratingNum is num ? ratingNum.toDouble() : 0.0;

    return PriestReviewItem(
      id: sentinelId,
      source: ReviewSource.bible,
      bibleSessionId: bibleSessionId,
      regId: regId,
      userName: (e['userName'] as String?) ?? '',
      userPhotoUrl: (e['userPhotoUrl'] as String?) ?? '',
      rating: rating,
      feedback: (e['feedback'] as String?) ?? '',
      endedAt: parseTime(e['endedAt']),
      priestReply: reply,
    );
  }
}

class PriestReviewsPage extends StatefulWidget {
  const PriestReviewsPage({super.key});

  @override
  State<PriestReviewsPage> createState() => _PriestReviewsPageState();
}

enum _Filter { all, withFeedback }

class _PriestReviewsPageState extends State<PriestReviewsPage> {
  bool _loading = true;
  List<PriestReviewItem> _reviews = const [];
  double _avg = 0;
  int _count = 0;
  // Distribution: index 0 = 1-star count, index 4 = 5-star count.
  // Computed off the same fetched list so the bars match what the
  // priest can see scrolling — the priests/{uid}.rating average we
  // also read covers any older sessions that fell outside the 500
  // window.
  List<int> _distribution = const [0, 0, 0, 0, 0];
  _Filter _filter = _Filter.all;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      setState(() => _loading = false);
      return;
    }

    try {
      // We need TWO sources to render every review the priest has:
      //   1. chat/voice — read directly from `sessions/{id}` so we
      //      get full reply timestamps for the 24h Edit gate.
      //   2. bible — denormalised onto `priests/{uid}.recentReviews`
      //      by the onBibleSessionRated CF. Read it from the SAME
      //      priest-doc fetch we already do for the aggregate.
      final snapFuture = FirebaseFirestore.instance
          .collection('sessions')
          .where('priestId', isEqualTo: uid)
          .limit(500)
          .get();
      final priestFuture =
          FirebaseFirestore.instance.doc('priests/$uid').get();

      final results = await Future.wait([
        snapFuture,
        priestFuture,
      ]).timeout(const Duration(seconds: 12));

      final snap = results[0] as QuerySnapshot<Map<String, dynamic>>;
      final priestSnap =
          results[1] as DocumentSnapshot<Map<String, dynamic>>;

      final sessionReviews = snap.docs
          .map((d) => SessionModel.fromFirestore(d.id, d.data()))
          .where((s) => s.userRating != null)
          .map(PriestReviewItem.fromSession)
          .toList();

      final priestData = priestSnap.data() ?? const <String, dynamic>{};
      final recentReviews =
          (priestData['recentReviews'] as List?) ?? const [];
      final bibleReviews = recentReviews
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .map(PriestReviewItem.tryFromBibleRecentEntry)
          .whereType<PriestReviewItem>()
          .toList();

      final reviews = [...sessionReviews, ...bibleReviews];

      // Newest-first by endedAt. Items with no timestamp drop to the
      // bottom so a partial doc doesn't visually disappear.
      reviews.sort((a, b) {
        final ta = a.endedAt;
        final tb = b.endedAt;
        if (ta == null && tb == null) return 0;
        if (ta == null) return 1;
        if (tb == null) return -1;
        return tb.compareTo(ta);
      });

      final dist = <int>[0, 0, 0, 0, 0];
      for (final r in reviews) {
        final s = r.stars;
        if (s >= 1 && s <= 5) dist[s - 1] += 1;
      }

      // Prefer the server-aggregated values — they cover reviews older
      // than our 500-doc window AND include bible sessions counted by
      // the onBibleSessionRated CF. Fall back to a fresh local
      // computation if the priest doc is missing them (very first
      // review just landed and the trigger hasn't run yet).
      final docAvg =
          (priestData['rating'] as num?)?.toDouble() ?? 0;
      final docCount =
          (priestData['reviewCount'] as num?)?.toInt() ?? 0;

      final localCount = reviews.length;
      final localAvg = localCount == 0
          ? 0.0
          : reviews.map((r) => r.rating).reduce((a, b) => a + b) /
              localCount;

      if (!mounted) return;
      setState(() {
        _reviews = reviews;
        _avg = docCount > 0
            ? docAvg
            : double.parse(localAvg.toStringAsFixed(1));
        _count = docCount > 0 ? docCount : localCount;
        _distribution = dist;
        _loading = false;
        _error = null;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Taking too long. Check your connection.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your reviews. Try again.';
      });
    }
  }

  List<PriestReviewItem> get _visible {
    switch (_filter) {
      case _Filter.all:
        return _reviews;
      case _Filter.withFeedback:
        return _reviews.where((r) => r.hasFeedback).toList();
    }
  }

  Future<void> _openReplySheet(PriestReviewItem review) async {
    HapticFeedback.lightImpact();
    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => ReviewReplySheet(review: review),
    );
    if (result == true && mounted) {
      // Re-fetch so the new reply renders in place. A targeted single
      // doc refresh would be cheaper but the page is small enough
      // that a full reload reads as instant and keeps the code
      // simpler.
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: _buildAppBar(context),
      body: _loading
          ? const _ReviewsShimmer()
          : _error != null
              ? _buildError()
              : _buildBody(),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.background,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      leadingWidth: 56,
      leading: const Padding(
        padding: EdgeInsets.only(left: 12),
        child: Align(
          child: AppBackButton(),
        ),
      ),
      title: Text(
        'My Reviews',
        style: GoogleFonts.inter(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
      ),
      centerTitle: false,
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              AppIcons.cloudOff,
              size: 40,
              color: AppColors.muted.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 14),
            Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 18),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => _loading = true);
                _load();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Try again',
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

  Widget _buildBody() {
    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.primaryBrown,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          _SummaryHeader(
            avg: _avg,
            count: _count,
            distribution: _distribution,
          ),
          if (_count > 0) ...[
            const SizedBox(height: 18),
            _FilterRow(
              current: _filter,
              total: _reviews.length,
              withFeedback:
                  _reviews.where((r) => r.hasFeedback).length,
              onChanged: (f) => setState(() => _filter = f),
            ),
            const SizedBox(height: 14),
          ],
          if (_count == 0)
            const Padding(
              padding: EdgeInsets.only(top: 32),
              child: _EmptyState(),
            )
          else if (_visible.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 28),
              child: Center(
                child: Text(
                  'No written feedback yet on this filter.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
              ),
            )
          else
            for (final r in _visible) ...[
              _ReviewCard(
                review: r,
                onReplyTap: () => _openReplySheet(r),
              ),
              const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

// ─── Summary header ──────────────────────────────────────

class _SummaryHeader extends StatelessWidget {
  final double avg;
  final int count;
  final List<int> distribution;

  const _SummaryHeader({
    required this.avg,
    required this.count,
    required this.distribution,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                count == 0 ? '—' : avg.toStringAsFixed(1),
                style: GoogleFonts.inter(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  letterSpacing: -0.5,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 6),
              _RatingStarsRow(rating: avg),
              const SizedBox(height: 6),
              Text(
                count == 1 ? '1 review' : '$count reviews',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppColors.muted,
                ),
              ),
            ],
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (int star = 5; star >= 1; star--) ...[
                  _DistributionBar(
                    star: star,
                    countForStar: distribution[star - 1],
                    total: distribution.fold<int>(0, (a, b) => a + b),
                  ),
                  if (star > 1) const SizedBox(height: 6),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DistributionBar extends StatelessWidget {
  final int star;
  final int countForStar;
  final int total;

  const _DistributionBar({
    required this.star,
    required this.countForStar,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = total == 0 ? 0.0 : countForStar / total;
    return Row(
      children: [
        SizedBox(
          width: 14,
          child: Text(
            '$star',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
            ),
          ),
        ),
        const SizedBox(width: 4),
        AppIcon(
          AppIcons.starFilled,
          size: 11,
          color: AppColors.amberGold,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Stack(
            children: [
              Container(
                height: 6,
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              FractionallySizedBox(
                widthFactor: fraction.clamp(0.0, 1.0),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: AppColors.amberGold,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 26,
          child: Text(
            '$countForStar',
            textAlign: TextAlign.right,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.muted,
            ),
          ),
        ),
      ],
    );
  }
}

class _RatingStarsRow extends StatelessWidget {
  final double rating;
  const _RatingStarsRow({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final position = i + 1;
        final IconData icon;
        if (rating >= position) {
          icon = AppIcons.starFilled;
        } else if (rating >= position - 0.5) {
          icon = AppIcons.starHalf;
        } else {
          icon = AppIcons.starOutline;
        }
        return AppIcon(
          icon,
          size: 14,
          color: AppColors.amberGold,
        );
      }),
    );
  }
}

// ─── Filter row ──────────────────────────────────────────

class _FilterRow extends StatelessWidget {
  final _Filter current;
  final int total;
  final int withFeedback;
  final ValueChanged<_Filter> onChanged;

  const _FilterRow({
    required this.current,
    required this.total,
    required this.withFeedback,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _FilterChip(
          label: 'All',
          count: total,
          selected: current == _Filter.all,
          onTap: () => onChanged(_Filter.all),
        ),
        const SizedBox(width: 8),
        _FilterChip(
          label: 'With feedback',
          count: withFeedback,
          selected: current == _Filter.withFeedback,
          onTap: () => onChanged(_Filter.withFeedback),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primaryBrown
              : AppColors.surfaceWhite,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: selected
                    ? Colors.white.withValues(alpha: 0.22)
                    : AppColors.muted.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: GoogleFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : AppColors.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Review card ─────────────────────────────────────────

class _ReviewCard extends StatelessWidget {
  final PriestReviewItem review;
  final VoidCallback onReplyTap;

  const _ReviewCard({
    required this.review,
    required this.onReplyTap,
  });

  @override
  Widget build(BuildContext context) {
    final stars = review.stars;
    final feedback = review.feedback.trim();
    final date = _fmtDate(review.endedAt);
    final reply = review.priestReply;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 12,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _UserAvatar(
                photoUrl: review.userPhotoUrl,
                name: review.userName,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _firstName(review.userName),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.deepDarkBrown,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        _StarsCompact(rating: stars),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            date,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: AppColors.muted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (feedback.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              feedback,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.5,
                color: AppColors.deepDarkBrown,
              ),
            ),
          ],
          // Reply surfaces only when there's something to reply about —
          // a star-only rating with no text doesn't need a public
          // response, and pushing the priest to draft one would feel
          // forced. They can still see the rating contribute to the
          // average above.
          if (feedback.isNotEmpty) ...[
            const SizedBox(height: 12),
            if (reply == null)
              _ReplyCta(onTap: onReplyTap)
            else
              _ReplyBlock(reply: reply, onEdit: onReplyTap),
          ],
        ],
      ),
    );
  }

  static String _firstName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Someone';
    final firstSpace = trimmed.indexOf(' ');
    return firstSpace <= 0 ? trimmed : trimmed.substring(0, firstSpace);
  }

  static String _fmtDate(DateTime? d) {
    if (d == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${months[d.month - 1]} ${d.day}';
  }
}

class _StarsCompact extends StatelessWidget {
  final int rating;
  const _StarsCompact({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final filled = i < rating;
        return AppIcon(
          filled ? AppIcons.starFilled : AppIcons.starOutline,
          size: 13,
          color: filled
              ? AppColors.amberGold
              : AppColors.muted.withValues(alpha: 0.35),
        );
      }),
    );
  }
}

class _UserAvatar extends StatelessWidget {
  final String photoUrl;
  final String name;

  const _UserAvatar({required this.photoUrl, required this.name});

  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty
        ? '?'
        : name.trim()[0].toUpperCase();
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.fieldFill,
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.12),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: photoUrl.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: photoUrl,
              fit: BoxFit.cover,
              errorWidget: (_, _, _) => _initial(letter),
              placeholder: (_, _) => const SizedBox.shrink(),
            )
          : _initial(letter),
    );
  }

  Widget _initial(String letter) {
    return Center(
      child: Text(
        letter,
        style: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: AppColors.muted,
        ),
      ),
    );
  }
}

class _ReplyCta extends StatelessWidget {
  final VoidCallback onTap;
  const _ReplyCta({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.primaryBrown.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: AppColors.primaryBrown.withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppIcon(
              AppIcons.reply,
              size: 14,
              color: AppColors.primaryBrown,
            ),
            const SizedBox(width: 6),
            Text(
              'Reply',
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primaryBrown,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReplyBlock extends StatelessWidget {
  final ReviewReply reply;
  final VoidCallback onEdit;

  const _ReplyBlock({required this.reply, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final canEdit = reply.isEditable;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFBF7F1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.22),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(
                AppIcons.reply,
                size: 13,
                color: AppColors.primaryBrown,
              ),
              const SizedBox(width: 6),
              Text(
                'Your reply',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                  color: AppColors.primaryBrown,
                ),
              ),
              if (reply.wasEdited) ...[
                const SizedBox(width: 6),
                Text(
                  '· edited',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
              ],
              const Spacer(),
              if (canEdit)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onEdit,
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      'Edit',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryBrown,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            reply.text,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              height: 1.5,
              color: AppColors.deepDarkBrown,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.amberGold.withValues(alpha: 0.12),
              ),
              child: AppIcon(
                AppIcons.starOutline,
                size: 36,
                color: AppColors.amberGold,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'No reviews yet',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.deepDarkBrown,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'After a user rates a session with you, their feedback '
              'will appear here. You can reply to written reviews.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.55,
                color: AppColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewsShimmer extends StatelessWidget {
  const _ReviewsShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.muted.withValues(alpha: 0.08),
      highlightColor: AppColors.muted.withValues(alpha: 0.03),
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Container(
            height: 130,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Container(
                width: 70,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 110,
                height: 32,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          for (int i = 0; i < 3; i++) ...[
            Container(
              height: 120,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }
}

// Tiny shim that exposes the CF callable to the reply sheet so the
// sheet doesn't import cloud_functions itself. Keeps the sheet file
// pure UI + state; networking lives here next to the page that
// orchestrates the refresh.
//
// Dispatch by review source:
//   • session — pass {sessionId, text}. Unchanged from before.
//   • bible   — pass {source: "bible", bibleSessionId, regId, text}.
// The replyToReview CF reads `source` (defaults to "session") and
// routes to the right doc.
class ReplyToReviewService {
  static Future<void> submit({
    required PriestReviewItem review,
    required String text,
  }) async {
    final functions =
        FirebaseFunctions.instanceFor(region: 'asia-south1');
    final payload = <String, dynamic>{'text': text};
    if (review.source == ReviewSource.bible) {
      final bsid = review.bibleSessionId;
      final reg = review.regId;
      if (bsid == null || reg == null) {
        // Defensive — shouldn't reach the UI if either is missing
        // because the chip wouldn't have shown a Reply CTA. Throw a
        // clear error so the sheet surfaces something useful instead
        // of an opaque CF invalid-argument later.
        throw ArgumentError(
          'Cannot reply to bible review — missing bibleSessionId or regId',
        );
      }
      payload['source'] = 'bible';
      payload['bibleSessionId'] = bsid;
      payload['regId'] = reg;
    } else {
      payload['sessionId'] = review.id;
    }
    await functions
        .httpsCallable('replyToReview')
        .call<Map<String, dynamic>>(payload);
  }
}

// Helper bound to the page's context — exposed so the reply sheet
// can surface success/error toasts with the app's branded snackbar
// without duplicating its plumbing here.
extension PriestReviewsSnack on BuildContext {
  void showReviewError(String message) {
    AppSnackBar.error(this, message);
  }

  void showReviewSuccess(String message) {
    AppSnackBar.success(this, message);
  }
}
