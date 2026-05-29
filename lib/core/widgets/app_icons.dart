// Central icon registry for Gospel Vox.
//
// Every icon used across the app is referenced through this file
// (e.g. AppIcons.wallet) and rendered via the AppIcon widget. This
// means swapping the underlying icon pack — Material → FontAwesome
// → Iconsax → HugeIcons — is a single-file change instead of a
// 35-file sweep.
//
// Styling choice:
// - FontAwesome Solid for content, status, and action icons. Solid
//   weights read as more premium / distinct than Material's
//   rounded outlines.
// - Explicit *Outline variants kept regular for places that
//   semantically need an empty state (starOutline next to
//   starFilled, bellOutline for "no new notifications", etc.).
// - Material Rounded retained only for tight system UI (AppBar
//   back, list-tile chevrons, modal close, FAB add) where the
//   tighter optical weight fits cramped layouts better.
//
// IconData instances are inlined as const (raw codepoints + font
// family) rather than going through FontAwesomeIcons.X.data —
// that getter isn't const, which would force every `const Icon`
// call site to drop const and cost rebuild perf.

import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class AppIcons {
  AppIcons._();

  // Constants below are auto-generated from FontAwesome 7.2.0
  // codepoints. To swap or add icons, edit tmp_gen_icons.js (or
  // copy a fresh codepoint from the font_awesome_flutter source).

  // ─── Content / domain ────────────────────────────────────────
  static const IconData wallet = IconData(0xf555, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData bible = IconData(0xf647, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData bank = IconData(0xf19c, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData church = IconData(0xf51d, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData user = IconData(0xf007, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData userOutline = IconData(0xf007, fontFamily: 'FontAwesomeRegular', fontPackage: 'font_awesome_flutter');
  static const IconData users = IconData(0xf0c0, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData location = IconData(0xf3c5, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData document = IconData(0xf15c, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData coins = IconData(0xf51e, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData video = IconData(0xf03d, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData calendar = IconData(0xf783, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData prayer = IconData(0xf684, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData gem = IconData(0xf3a5, fontFamily: 'FontAwesomeRegular', fontPackage: 'font_awesome_flutter');
  static const IconData celebration = IconData(0xf79f, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData badge = IconData(0xf2c1, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData briefcase = IconData(0xf0b1, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData tag = IconData(0xf02b, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData map = IconData(0xf5a0, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');

  // ─── Status / feedback ───────────────────────────────────────
  static const IconData starFilled = IconData(0xf005, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData starOutline = IconData(0xf005, fontFamily: 'FontAwesomeRegular', fontPackage: 'font_awesome_flutter');
  static const IconData starHalf = IconData(0xf5c0, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData checkCircle = IconData(0xf058, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData checkCircleOutline = IconData(0xf058, fontFamily: 'FontAwesomeRegular', fontPackage: 'font_awesome_flutter');
  static const IconData check = IconData(0xf00c, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData info = IconData(0xf05a, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData error = IconData(0xf06a, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData warning = IconData(0xf071, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData verified = IconData(0xf058, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData shield = IconData(0xf132, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData cancel = IconData(0xf057, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData block = IconData(0xf05e, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData notInterested = IconData(0xf05e, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData hourglass = IconData(0xf252, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData taskDone = IconData(0xf0ae, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData report = IconData(0xf024, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData flag = IconData(0xf024, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData lightbulb = IconData(0xf0eb, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');

  // ─── Actions ─────────────────────────────────────────────────
  static const IconData chat = IconData(0xf075, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData chatOutline = IconData(0xf075, fontFamily: 'FontAwesomeRegular', fontPackage: 'font_awesome_flutter');
  static const IconData chats = IconData(0xf086, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData phone = IconData(0xf095, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData phoneEnd = IconData(0xf3dd, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData phoneMissed = IconData(0xf3dd, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData phoneIncoming = IconData(0xf2a0, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData bell = IconData(0xf0f3, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData bellOutline = IconData(0xf0f3, fontFamily: 'FontAwesomeRegular', fontPackage: 'font_awesome_flutter');
  static const IconData bellOff = IconData(0xf1f6, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData reply = IconData(0xf3e5, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData send = IconData(0xf1d8, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  // Universal share glyph — box with the up-arrow inside, reads as
  // "share with another app" on every platform (matches the iOS
  // share icon and the typical Android "share" affordance).
  static const IconData share = IconData(0xf14d, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData edit = IconData(0xf044, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData delete = IconData(0xf1f8, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData deleteSweep = IconData(0xf2ed, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData copy = IconData(0xf0c5, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData paste = IconData(0xf0ea, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData mic = IconData(0xf130, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData micOff = IconData(0xf131, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData volumeUp = IconData(0xf028, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData volumeOff = IconData(0xf6a9, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData search = IconData(0xf002, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData refresh = IconData(0xf021, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData play = IconData(0xf144, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData pause = IconData(0xf28b, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData stop = IconData(0xf28d, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData touch = IconData(0xf25a, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData link = IconData(0xf0c1, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData swap = IconData(0xf362, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData replay = IconData(0xf2ea, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData trendingUp = IconData(0xe098, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData arrowDown = IconData(0xf063, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData arrowRight = IconData(0xf061, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData externalLink = IconData(0xf35d, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');

  // ─── Security / profile ──────────────────────────────────────
  static const IconData lock = IconData(0xf023, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData lockOpen = IconData(0xf3c1, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData lockClock = IconData(0xf502, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData eye = IconData(0xf06e, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData eyeOff = IconData(0xf070, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData mail = IconData(0xf0e0, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData mailRead = IconData(0xf2b6, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData inbox = IconData(0xf01c, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData logout = IconData(0xf2f5, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData settings = IconData(0xf013, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData adminPanel = IconData(0xf505, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData privacy = IconData(0xf505, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData camera = IconData(0xf030, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData gallery = IconData(0xf302, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData upload = IconData(0xf0ee, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData download = IconData(0xf0ed, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');

  // ─── Misc / utility ──────────────────────────────────────────
  static const IconData clock = IconData(0xf017, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData history = IconData(0xf1da, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData stopwatch = IconData(0xf2f2, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData timerOff = IconData(0xf254, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData magic = IconData(0xe2ca, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData bolt = IconData(0xf0e7, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData gift = IconData(0xf06b, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData receipt = IconData(0xf543, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData savings = IconData(0xf4d3, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData payments = IconData(0xf53a, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData rupee = IconData(0xe1bc, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData percent = IconData(0x25, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData speed = IconData(0xf625, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData help = IconData(0xf059, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData thumbUp = IconData(0xf164, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData category = IconData(0xf5fd, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData podcast = IconData(0xf2ce, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData broadcast = IconData(0xf519, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData qrCode = IconData(0xf029, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData event = IconData(0xf274, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData eventBusy = IconData(0xf273, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData checklist = IconData(0xf0ae, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData home = IconData(0xf015, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData group = IconData(0xe533, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData heart = IconData(0xf004, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData heartOutline = IconData(0xf004, fontFamily: 'FontAwesomeRegular', fontPackage: 'font_awesome_flutter');
  static const IconData howToReg = IconData(0xf4fc, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData apple = IconData(0xf179, fontFamily: 'FontAwesomeBrands', fontPackage: 'font_awesome_flutter');
  static const IconData google = IconData(0xf1a0, fontFamily: 'FontAwesomeBrands', fontPackage: 'font_awesome_flutter');

  // ─── Connectivity ────────────────────────────────────────────
  static const IconData wifi = IconData(0xf1eb, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData wifiOff = IconData(0xf1eb, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData cellTower = IconData(0xe585, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');
  static const IconData cloudOff = IconData(0xf0c2, fontFamily: 'FontAwesomeSolid', fontPackage: 'font_awesome_flutter');

  // ─── Kept Material (system UI — tighter optical fit) ─────────
  static const IconData chevronRight = Icons.chevron_right_rounded;
  static const IconData chevronDown = Icons.keyboard_arrow_down_rounded;
  static const IconData back = Icons.arrow_back_ios_new_rounded;
  static const IconData close = Icons.close_rounded;
  static const IconData more = Icons.more_vert_rounded;
  static const IconData add = Icons.add_rounded;
  static const IconData menu = Icons.menu_rounded;
}

/// Renders an icon from [AppIcons] uniformly across the app.
///
/// Auto-detects whether the icon belongs to FontAwesome or Material
/// (by inspecting [IconData.fontFamily]) and dispatches to the
/// correct underlying widget. Callers stay agnostic, so swapping
/// the icon pack later doesn't ripple through call sites.
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  // Nullable to match Material's Icon API — render-time call sites
  // that pass a possibly-null IconData (e.g. icon? builder, chip
  // configs) don't need to wrap themselves in a null check.
  final IconData? icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  bool get _isFontAwesome {
    final family = icon?.fontFamily ?? '';
    // font_awesome_flutter ships fonts named 'FontAwesomeSolid',
    // 'FontAwesomeBrands', 'FontAwesomeRegular', etc.
    return family.startsWith('FontAwesome');
  }

  @override
  Widget build(BuildContext context) {
    if (_isFontAwesome) {
      // FaIcon intentionally drops the SizedBox+Center that Material's
      // Icon uses, so non-square FA glyphs render at their natural
      // aspect ratio. The trade-off: dropped into a fixed square
      // container (CircleAvatar, decorated Container, action chip),
      // they sit off-center and look bad. We re-add the centering
      // wrapper here so AppIcon matches Material's optical behaviour
      // at every call site — the typical case is square content
      // inside a square slot.
      final double iconSize =
          size ?? IconTheme.of(context).size ?? 24.0;
      return SizedBox(
        width: iconSize,
        height: iconSize,
        child: Center(
          child: FaIcon(
            FaIconData(icon!),
            size: size,
            color: color,
            semanticLabel: semanticLabel,
          ),
        ),
      );
    }
    return Icon(
      icon,
      size: size,
      color: color,
      semanticLabel: semanticLabel,
    );
  }
}
