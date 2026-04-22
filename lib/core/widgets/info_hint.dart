// Compact, premium-feeling info affordance for form fields.
//
// Design decisions, informed by usability research (Nielsen Norman,
// Apple HIG, mature B2C app teardowns):
//
// 1. Pill container. A bare glyph is ambiguous; a small tinted circle
//    around the icon unambiguously reads as "tappable".
// 2. Filled icon in a brand colour instead of a muted outline — raises
//    signal-to-noise without shouting.
// 3. Unread dot. Small amber notification dot at the corner. This is
//    the single most reliably noticed UI affordance (Apple badge
//    pattern, Slack unread indicators, Gmail new-mail dots). It
//    disappears the moment this specific hint is tapped and never
//    comes back — we don't nag the priest across sessions.
// 4. Breathing halo on unread hints. A soft radial pulse scaled up
//    and faded out; organic, not frantic. Hints start their pulse at
//    different offsets so multiple icons on the same screen don't
//    throb in sync.
// 5. No hard gate on Continue. Coercive "you must tap this before
//    proceeding" patterns are resented. The dot + halo do the
//    nudging; the priest ultimately decides.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';

// One per-hint bool in SharedPreferences, prefixed so we can sweep
// all read-state entries later (e.g. on sign-out) without touching
// unrelated keys.
const String _kPrefsPrefix = 'info_hint_read_';

// In-session cache of which IDs have been read, so we don't hit
// SharedPreferences on every single rebuild of every single hint.
final Map<String, bool> _readCache = <String, bool>{};

// Notifier any hint can listen to so tapping one doesn't force its
// siblings to re-query prefs — useful if we ever add "mark all read"
// affordances later.
final ValueNotifier<int> _readRevision = ValueNotifier<int>(0);

class InfoHint extends StatefulWidget {
  // Stable key, used as the SharedPreferences bucket and as the seed
  // for pulse phase offset. Don't change existing IDs casually —
  // doing so resurrects dots for everyone.
  final String id;
  final String text;

  const InfoHint({
    super.key,
    required this.id,
    required this.text,
  });

  @override
  State<InfoHint> createState() => _InfoHintState();
}

class _InfoHintState extends State<InfoHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _halo;
  final GlobalKey<TooltipState> _tooltipKey = GlobalKey<TooltipState>();

  bool _isRead = false;
  bool _prefsLoaded = false;

  String get _prefsKey => '$_kPrefsPrefix${widget.id}';

  @override
  void initState() {
    super.initState();

    // Desync multiple hints' halos by seeding the controller with a
    // stable offset derived from the id — deterministic but varied.
    _halo = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _halo.value = ((widget.id.hashCode.abs() % 1000) / 1000.0);

    _readRevision.addListener(_onRevisionChanged);
    _loadReadState();
  }

  Future<void> _loadReadState() async {
    // Hit the in-session cache first — no frame-one flicker when the
    // same hint id appears on multiple pages.
    final cached = _readCache[widget.id];
    if (cached != null) {
      if (mounted) {
        setState(() {
          _isRead = cached;
          _prefsLoaded = true;
        });
        _syncHalo();
      }
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final read = prefs.getBool(_prefsKey) ?? false;
      _readCache[widget.id] = read;
      if (!mounted) return;
      setState(() {
        _isRead = read;
        _prefsLoaded = true;
      });
      _syncHalo();
    } catch (_) {
      // Don't crash the wizard if prefs is unreachable.
      if (mounted) setState(() => _prefsLoaded = true);
    }
  }

  void _onRevisionChanged() {
    // Another InfoHint was marked read; double-check ours in case
    // we share an id (we don't, but defensive).
    final cached = _readCache[widget.id];
    if (cached != null && cached != _isRead && mounted) {
      setState(() => _isRead = cached);
      _syncHalo();
    }
  }

  void _syncHalo() {
    if (_isRead) {
      _halo.stop();
      _halo.value = 0;
    } else if (!_halo.isAnimating) {
      _halo.repeat();
    }
  }

  Future<void> _markRead() async {
    if (_isRead) return;
    _readCache[widget.id] = true;
    setState(() => _isRead = true);
    _syncHalo();
    _readRevision.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, true);
    } catch (_) {
      // Cache flip already did the job in-memory.
    }
  }

  @override
  void dispose() {
    _readRevision.removeListener(_onRevisionChanged);
    _halo.dispose();
    super.dispose();
  }

  void _handleTap() {
    // Tooltip tap trigger doesn't forward the tap to our own
    // onTap, so we manually open the tooltip AND mark read.
    _tooltipKey.currentState?.ensureTooltipVisible();
    _markRead();
  }

  @override
  Widget build(BuildContext context) {
    // While prefs are still loading we render the read-looking
    // version to avoid a flash of dot-then-no-dot on startup.
    final showUnread = _prefsLoaded && !_isRead;

    final pillBg = AppColors.primaryBrown
        .withValues(alpha: showUnread ? 0.12 : 0.06);
    final iconAlpha = showUnread ? 1.0 : 0.75;

    final hintButton = Tooltip(
      key: _tooltipKey,
      message: widget.text,
      // We drive visibility manually from the GestureDetector below
      // (tapping also marks the hint as read). No triggerMode set —
      // the default long-press remains available as a secondary
      // affordance without double-handling the tap.
      showDuration: const Duration(seconds: 6),
      preferBelow: false,
      verticalOffset: 22,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      margin: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: AppColors.deepDarkBrown,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            blurRadius: 16,
            offset: const Offset(0, 6),
            color: Colors.black.withValues(alpha: 0.2),
          ),
        ],
      ),
      textStyle: GoogleFonts.inter(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: Colors.white.withValues(alpha: 0.95),
        height: 1.5,
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: SizedBox(
          // Hit zone slightly larger than the visual pill — easier
          // to tap on a small phone without looking.
          width: 36,
          height: 36,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // Breathing halo (unread only). Lives under the pill,
              // scales up and fades out. Parent doesn't clip so it
              // can bleed outside the 36×36 hit zone gracefully.
              if (showUnread)
                AnimatedBuilder(
                  animation: _halo,
                  builder: (_, _) {
                    final t =
                        Curves.easeOut.transform(_halo.value);
                    final scale = 1.0 + (t * 0.55);
                    final opacity = (1.0 - t) * 0.28;
                    return IgnorePointer(
                      child: Transform.scale(
                        scale: scale,
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primaryBrown
                                .withValues(alpha: opacity),
                          ),
                        ),
                      ),
                    );
                  },
                ),

              // Pill — the main visible target.
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: pillBg,
                ),
                child: Icon(
                  Icons.info_rounded,
                  size: 14,
                  color: AppColors.primaryBrown
                      .withValues(alpha: iconAlpha),
                ),
              ),

              // Amber unread indicator — the "there's something here
              // you haven't seen" cue lifted straight from every
              // modern notification UI.
              if (showUnread)
                Positioned(
                  top: 5,
                  right: 5,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.amberGold,
                      border: Border.all(
                        color: AppColors.background,
                        width: 1.3,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return hintButton;
  }
}
