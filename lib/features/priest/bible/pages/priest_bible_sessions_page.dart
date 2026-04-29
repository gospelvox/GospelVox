// Priest-side list of their own Bible sessions with a "+" button to
// create new ones. Owns its own load lifecycle (no cubit) — the data
// shape is different from the user-side BibleSessionCubit (priest-
// scoped query) and the cubit's tab machine isn't useful here, so
// the duplication earns simpler code.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shimmer/shimmer.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/features/shared/data/bible_session_model.dart';
import 'package:gospel_vox/features/shared/data/bible_session_repository.dart';

class PriestBibleSessionsPage extends StatefulWidget {
  const PriestBibleSessionsPage({super.key});

  @override
  State<PriestBibleSessionsPage> createState() =>
      _PriestBibleSessionsPageState();
}

class _PriestBibleSessionsPageState extends State<PriestBibleSessionsPage> {
  final BibleSessionRepository _repository = BibleSessionRepository();
  List<BibleSessionModel> _sessions = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = "You're signed out.";
      });
      return;
    }

    try {
      final list = await _repository.getPriestSessions(uid);
      if (!mounted) return;
      setState(() {
        _sessions = list;
        _isLoading = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = "Couldn't load sessions. Pull to retry.";
      });
    }
  }

  Future<void> _showCreateSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateBibleSessionSheet(),
    );
    if (!mounted) return;
    if (created == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: AppColors.deepDarkBrown,
        title: Text(
          "Bible Sessions",
          style: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AppColors.deepDarkBrown,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _AddButton(onTap: _showCreateSheet),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppColors.primaryBrown,
        backgroundColor: AppColors.surfaceWhite,
        onRefresh: _load,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return _buildLoading();
    if (_error != null) return _buildError(_error!);
    if (_sessions.isEmpty) return _buildEmpty();
    return _buildList();
  }

  Widget _buildLoading() {
    final base = AppColors.muted.withValues(alpha: 0.14);
    final highlight = AppColors.warmBeige;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
      itemCount: 3,
      itemBuilder: (_, _) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Shimmer.fromColors(
          baseColor: base,
          highlightColor: highlight,
          child: Container(
            height: 180,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildError(String message) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 32),
      children: [
        Icon(
          Icons.error_outline_rounded,
          size: 44,
          color: AppColors.errorRed,
        ),
        const SizedBox(height: 14),
        Text(
          message,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.18),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: 56,
                  color: AppColors.muted.withValues(alpha: 0.25),
                ),
                const SizedBox(height: 16),
                Text(
                  "No sessions yet",
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color:
                        AppColors.deepDarkBrown.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  "Tap + to schedule your first Bible session.\n"
                  "Users will see it on their Bible tab.",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildList() {
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
      itemCount: _sessions.length,
      itemBuilder: (_, i) {
        final session = _sessions[i];
        return _PriestSessionCard(
          session: session,
          onTap: () async {
            final changed =
                await context.push<bool>('/priest/bible/${session.id}');
            if (!mounted) return;
            if (changed == true) await _load();
          },
        );
      },
    );
  }
}

// ─── "+" button ─────────────────────────────────────────────────

class _AddButton extends StatefulWidget {
  final VoidCallback onTap;
  const _AddButton({required this.onTap});

  @override
  State<_AddButton> createState() => _AddButtonState();
}

class _AddButtonState extends State<_AddButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.92),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          width: 36,
          height: 36,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primaryBrown,
          ),
          child: const Icon(Icons.add, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}

// ─── Priest session card ────────────────────────────────────────

class _PriestSessionCard extends StatefulWidget {
  final BibleSessionModel session;
  final VoidCallback onTap;

  const _PriestSessionCard({
    required this.session,
    required this.onTap,
  });

  @override
  State<_PriestSessionCard> createState() => _PriestSessionCardState();
}

class _PriestSessionCardState extends State<_PriestSessionCard> {
  double _scale = 1.0;
  static const Color _kUpcomingGreen = Color(0xFF059669);

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final statusText = session.isUpcoming
        ? session.startsInText
        : session.isCancelled
            ? 'Cancelled'
            : 'Completed';
    final statusColor = session.isUpcoming
        ? _kUpcomingGreen
        : session.isCancelled
            ? AppColors.errorRed
            : AppColors.muted;

    final warning = session.linkWarning;

    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.98),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.muted.withValues(alpha: 0.06),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (warning != null) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color:
                        AppColors.amberGold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.amberGold.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 14,
                        color: AppColors.amberGold,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          warning,
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppColors.amberGold
                                .withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Text(
                session.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                session.category.isNotEmpty
                    ? "${session.category} · ${session.description}"
                    : session.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 14,
                runSpacing: 6,
                children: [
                  _meta(
                    Icons.calendar_today_outlined,
                    session.formattedDate,
                  ),
                  _meta(
                    Icons.access_time_rounded,
                    session.formattedTime,
                  ),
                  _meta(
                    Icons.people_outline_rounded,
                    "${session.registrationCount} registered",
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        statusText,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: statusColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    "₹${session.price}",
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _meta(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: AppColors.muted.withValues(alpha: 0.5)),
        const SizedBox(width: 5),
        Text(
          text,
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w400,
            color: AppColors.muted,
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
// CREATE BIBLE SESSION BOTTOM SHEET
// ════════════════════════════════════════════════════════════════

class _CreateBibleSessionSheet extends StatefulWidget {
  const _CreateBibleSessionSheet();

  @override
  State<_CreateBibleSessionSheet> createState() =>
      _CreateBibleSessionSheetState();
}

class _CreateBibleSessionSheetState
    extends State<_CreateBibleSessionSheet> {
  final BibleSessionRepository _repository = BibleSessionRepository();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _maxCtrl = TextEditingController();
  final _linkCtrl = TextEditingController();

  static const _categories = [
    "Deep Study",
    "Daily Living",
    "Youth",
    "Prayer",
    "Practical Guide",
    "Worship",
    "Testimony",
  ];
  String? _category;
  DateTime? _date;
  TimeOfDay? _time;
  bool _creating = false;
  String? _formError;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _priceCtrl.dispose();
    _maxCtrl.dispose();
    _linkCtrl.dispose();
    super.dispose();
  }

  bool get _isValid {
    if (_titleCtrl.text.trim().length < 5) return false;
    if (_descCtrl.text.trim().length < 20) return false;
    if (_category == null) return false;
    if (_date == null || _time == null) return false;
    final price = int.tryParse(_priceCtrl.text.trim());
    if (price == null || price < 10 || price > 5000) return false;
    return true;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now.add(const Duration(days: 7)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.light(
            primary: AppColors.primaryBrown,
            onPrimary: Colors.white,
            onSurface: AppColors.deepDarkBrown,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _date = picked);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 19, minute: 0),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: ColorScheme.light(
            primary: AppColors.primaryBrown,
            onPrimary: Colors.white,
            onSurface: AppColors.deepDarkBrown,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _time = picked);
    }
  }

  String _formatTime(TimeOfDay t) {
    final h = t.hour > 12 ? t.hour - 12 : (t.hour == 0 ? 12 : t.hour);
    final period = t.hour >= 12 ? 'PM' : 'AM';
    return '$h:${t.minute.toString().padLeft(2, '0')} $period';
  }

  Future<void> _showLinkGuide() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _MeetLinkGuideSheet(),
    );
  }

  Future<void> _create() async {
    if (!_isValid || _creating) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _formError = "You're signed out.");
      return;
    }

    final scheduledAt = DateTime(
      _date!.year,
      _date!.month,
      _date!.day,
      _time!.hour,
      _time!.minute,
    );
    if (scheduledAt.isBefore(DateTime.now())) {
      setState(() => _formError = "Pick a future date and time.");
      return;
    }

    final link = _linkCtrl.text.trim();
    if (link.isNotEmpty) {
      final uri = Uri.tryParse(link);
      if (uri == null || !uri.hasScheme) {
        setState(() => _formError = "Please paste a valid link.");
        return;
      }
    }

    setState(() {
      _creating = true;
      _formError = null;
    });

    try {
      // Pull priest profile for name + photo. Falling back to auth
      // displayName if the priests/{uid} doc isn't fully populated
      // (shouldn't happen post-approval, but the fallback keeps the
      // form usable rather than silently failing).
      final priestDoc = await FirebaseFirestore.instance
          .doc('priests/${user.uid}')
          .get();
      final priestData = priestDoc.data() ?? const {};
      final name = (priestData['fullName'] as String?) ??
          user.displayName ??
          'Speaker';
      final photo = (priestData['photoUrl'] as String?) ??
          user.photoURL ??
          '';

      final price = int.parse(_priceCtrl.text.trim());
      final maxRaw = _maxCtrl.text.trim();
      final maxAttendees = maxRaw.isEmpty ? 0 : (int.tryParse(maxRaw) ?? 0);

      await _repository.createSession(
        priestId: user.uid,
        priestName: name,
        priestPhotoUrl: photo,
        title: _titleCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        category: _category!,
        scheduledAt: scheduledAt,
        durationMinutes: 60,
        maxParticipants: maxAttendees,
        price: price,
        meetingLink: link,
      );

      if (!mounted) return;
      Navigator.of(context).pop(true);
      AppSnackBar.success(
        context,
        "Session published — users can register now.",
      );
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _formError = e.code == 'permission-denied'
            ? "You're not approved to create sessions yet."
            : "Couldn't create session. Please try again.";
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _creating = false;
        _formError = "Couldn't create session. Please try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        decoration: const BoxDecoration(
          color: AppColors.surfaceWhite,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.muted.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  "New Bible Session",
                  style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.deepDarkBrown,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Title
              const _FormLabel("SESSION TITLE", required: true),
              const SizedBox(height: 8),
              _FormField(
                controller: _titleCtrl,
                hint: "e.g. Understanding the Book of John",
                maxLength: 100,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),

              // Description
              const _FormLabel("DESCRIPTION", required: true),
              const SizedBox(height: 8),
              _FormField(
                controller: _descCtrl,
                hint:
                    "What will this session cover? What should attendees expect?",
                maxLines: 3,
                maxLength: 300,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),

              // Category
              const _FormLabel("CATEGORY", required: true),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _categories
                    .map((c) => _CategoryChip(
                          label: c,
                          selected: _category == c,
                          onTap: () => setState(() => _category = c),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 16),

              // Date + Time
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _FormLabel("DATE", required: true),
                        const SizedBox(height: 8),
                        _DateTimeField(
                          icon: Icons.calendar_today_outlined,
                          value: _date != null
                              ? "${_date!.month}/${_date!.day}/${_date!.year}"
                              : null,
                          hint: "Select date",
                          onTap: _pickDate,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const _FormLabel("TIME", required: true),
                        const SizedBox(height: 8),
                        _DateTimeField(
                          icon: Icons.access_time_rounded,
                          value: _time != null
                              ? _formatTime(_time!)
                              : null,
                          hint: "Select time",
                          onTap: _pickTime,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Meet link (optional)
              Row(
                children: [
                  const _FormLabel("GOOGLE MEET LINK"),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: _showLinkGuide,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFF3B82F6)
                            .withValues(alpha: 0.1),
                      ),
                      child: const Icon(
                        Icons.info_outline_rounded,
                        size: 12,
                        color: Color(0xFF3B82F6),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _FormField(
                controller: _linkCtrl,
                hint: "https://meet.google.com/...",
                keyboardType: TextInputType.url,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 4),
              Text(
                "You can add or update this anytime before the session starts.",
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 16),

              // Price
              const _FormLabel("PRICE (₹)", required: true),
              const SizedBox(height: 8),
              _FormField(
                controller: _priceCtrl,
                hint: "e.g. 50",
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                prefixText: "₹ ",
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 4),
              Text(
                "Min ₹10 · Max ₹5,000",
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted.withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(height: 16),

              // Max attendees
              const _FormLabel("MAX ATTENDEES"),
              const SizedBox(height: 8),
              _FormField(
                controller: _maxCtrl,
                hint: "Unlimited if left empty",
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),

              const _InfoTip(
                "Free to cancel within 24 hours of publishing. After "
                "that, cancellations are reported to admin. Repeated "
                "cancellations may affect your account.",
              ),

              if (_formError != null) ...[
                const SizedBox(height: 16),
                Text(
                  _formError!,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.errorRed,
                  ),
                ),
              ],

              const SizedBox(height: 24),

              _PressableButton(
                onTap: (_isValid && !_creating) ? _create : null,
                child: Container(
                  width: double.infinity,
                  height: 52,
                  decoration: BoxDecoration(
                    color: _isValid
                        ? AppColors.primaryBrown
                        : AppColors.muted.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: _isValid
                        ? [
                            BoxShadow(
                              color: AppColors.primaryBrown
                                  .withValues(alpha: 0.2),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ]
                        : const [],
                  ),
                  child: Center(
                    child: _creating
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : Text(
                            "Publish Session",
                            style: GoogleFonts.inter(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: _isValid
                                  ? Colors.white
                                  : AppColors.muted,
                            ),
                          ),
                  ),
                ),
              ),
              SizedBox(
                height: MediaQuery.of(context).padding.bottom + 16,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Form primitives ────────────────────────────────────────────

class _FormLabel extends StatelessWidget {
  final String text;
  final bool required;
  const _FormLabel(this.text, {this.required = false});

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: text,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.muted,
              letterSpacing: 0.8,
            ),
          ),
          if (required)
            TextSpan(
              text: " *",
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.errorRed,
              ),
            ),
        ],
      ),
    );
  }
}

class _FormField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  final int? maxLength;
  final TextInputType? keyboardType;
  final String? prefixText;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;

  const _FormField({
    required this.controller,
    required this.hint,
    this.maxLines = 1,
    this.maxLength,
    this.keyboardType,
    this.prefixText,
    this.inputFormatters,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      maxLength: maxLength,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      onChanged: onChanged,
      style: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.deepDarkBrown,
      ),
      cursorColor: AppColors.primaryBrown,
      decoration: InputDecoration(
        hintText: hint,
        prefixText: prefixText,
        prefixStyle: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppColors.deepDarkBrown,
        ),
        hintStyle: GoogleFonts.inter(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: AppColors.muted.withValues(alpha: 0.6),
        ),
        filled: true,
        fillColor: AppColors.warmBeige.withValues(alpha: 0.5),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        // Hide the bottom-right counter — it's noise alongside our
        // own helper text and adds vertical bulk.
        counterText: '',
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: AppColors.muted.withValues(alpha: 0.15),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: AppColors.primaryBrown,
            width: 1.5,
          ),
        ),
      ),
    );
  }
}

class _DateTimeField extends StatelessWidget {
  final IconData icon;
  final String? value;
  final String hint;
  final VoidCallback onTap;

  const _DateTimeField({
    required this.icon,
    required this.value,
    required this.hint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.warmBeige.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppColors.muted.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: AppColors.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                hasValue ? value! : hint,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight:
                      hasValue ? FontWeight.w600 : FontWeight.w400,
                  color: hasValue
                      ? AppColors.deepDarkBrown
                      : AppColors.muted.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primaryBrown.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.2),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight:
                selected ? FontWeight.w600 : FontWeight.w400,
            color:
                selected ? AppColors.primaryBrown : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

class _InfoTip extends StatelessWidget {
  final String message;
  const _InfoTip(this.message);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.amberGold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.amberGold.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 14,
            color: AppColors.amberGold,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: AppColors.amberGold.withValues(alpha: 0.9),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PressableButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;

  const _PressableButton({required this.child, required this.onTap});

  @override
  State<_PressableButton> createState() => _PressableButtonState();
}

class _PressableButtonState extends State<_PressableButton> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return GestureDetector(
      onTapDown: disabled ? null : (_) => setState(() => _scale = 0.97),
      onTapUp: disabled ? null : (_) => setState(() => _scale = 1.0),
      onTapCancel: disabled ? null : () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 100),
        child: widget.child,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════
// MEET LINK GUIDE BOTTOM SHEET
// ════════════════════════════════════════════════════════════════

class _MeetLinkGuideSheet extends StatelessWidget {
  const _MeetLinkGuideSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.muted.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color:
                        const Color(0xFF3B82F6).withValues(alpha: 0.08),
                  ),
                  child: const Icon(
                    Icons.videocam_rounded,
                    size: 22,
                    color: Color(0xFF3B82F6),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "How to Create a Meeting Link",
                        style: GoogleFonts.inter(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppColors.deepDarkBrown,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "It takes less than a minute!",
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const _GuideStep(
              number: 1,
              title: "Open Google Meet",
              description:
                  "Open the Google Meet app on your phone, or visit "
                  "meet.google.com in your browser.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 2,
              title: "Create a New Meeting",
              description:
                  "Tap the 'New meeting' button or '+' icon.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 3,
              title: "Choose 'Create a meeting for later'",
              description:
                  "This gives you a link without starting the meeting "
                  "right now.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 4,
              title: "Copy the Link",
              description:
                  "You'll see a link like meet.google.com/abc-defg-hij. "
                  "Tap 'Copy' or long-press to copy it.",
            ),
            const SizedBox(height: 16),
            const _GuideStep(
              number: 5,
              title: "Paste Here",
              description:
                  "Come back to Gospel Vox and paste the link in the "
                  "'Google Meet Link' field.",
            ),
            const SizedBox(height: 20),
            const _InfoTip(
              "You don't need to add the link right now! You can "
              "create the session first and add the link later from "
              "the session details page.",
            ),
            const SizedBox(height: 20),
            _PressableButton(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: AppColors.primaryBrown,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    "Got it!",
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: MediaQuery.of(context).padding.bottom + 12,
            ),
          ],
        ),
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  final int number;
  final String title;
  final String description;

  const _GuideStep({
    required this.number,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primaryBrown.withValues(alpha: 0.08),
          ),
          child: Center(
            child: Text(
              "$number",
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppColors.primaryBrown,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                description,
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
      ],
    );
  }
}
