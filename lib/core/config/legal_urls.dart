// Public legal + support endpoints, centralised so every surface that
// links to them (About, user Settings, priest Settings, priest
// registration acknowledgement) reads the same value. Hosted pages
// must exist at these URLs before the Play Store submission goes live
// — Google rejects builds whose listed Privacy Policy URL 404s.
//
// Updating the page content is a separate concern from the app build;
// the URLs themselves stay stable across releases so older app
// versions never end up pointing at a dead link.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:gospel_vox/core/widgets/app_snackbar.dart';

class LegalUrls {
  LegalUrls._();

  // Hosted on Firebase Hosting at the project's free .web.app domain
  // until the gospelvox.com custom domain is connected. The pages
  // themselves live in `public/` and are served by the hosting block
  // in firebase.json — the rewrites there map these clean paths to
  // the underlying .html files. When the custom domain is connected
  // later (Firebase Console → Hosting → Add custom domain), swap the
  // host portion here and ship a point release; the paths stay the
  // same so nothing else needs to change.
  static const String privacyPolicy =
      'https://gospelvox-a2208.web.app/privacy-policy';
  static const String termsOfService =
      'https://gospelvox-a2208.web.app/terms';
  // Refund policy URL. Play Store policy requires a clear refund
  // statement for in-app digital purchases (coin packs, priest
  // activation fee, Bible session payments). The hosted page should
  // state plainly whether refunds are offered, the conditions under
  // which they apply, and the support contact for refund requests.
  // Surfaced from Settings → Legal on every role and from the About
  // page so a reviewer can find it without poking around.
  static const String refundPolicy =
      'https://gospelvox-a2208.web.app/refund-policy';
  static const String helpCenter =
      'https://gospelvox-a2208.web.app/help';
  static const String accountDeletion =
      'https://gospelvox-a2208.web.app/delete-account';
  static const String supportEmail = 'support@gospelvox.com';
}

// Opens an external URL in the system browser. Surfaces a snackbar on
// launch failure so a tap that does nothing visible at least explains
// itself. Mirrors the helper already in priest_settings_page; lifted
// here so the user-side surfaces share the same behaviour.
Future<void> launchLegalUrl(BuildContext context, String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) {
    if (context.mounted) {
      AppSnackBar.error(context, "Couldn't open the link.");
    }
    return;
  }
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      AppSnackBar.error(context, "Couldn't open the link.");
    }
  } catch (_) {
    if (context.mounted) {
      AppSnackBar.error(context, "Couldn't open the link.");
    }
  }
}

// Opens the device's default mail composer to support@gospelvox.com.
// Falls back to a snackbar when no mail app is registered (some
// tablets / emulator builds).
Future<void> launchSupportEmail(BuildContext context) async {
  final uri = Uri(
    scheme: 'mailto',
    path: LegalUrls.supportEmail,
    queryParameters: <String, String>{
      'subject': 'Gospel Vox Support Request',
    },
  );
  try {
    final ok = await launchUrl(uri);
    if (!ok && context.mounted) {
      AppSnackBar.error(
        context,
        'No email app available on this device.',
      );
    }
  } catch (_) {
    if (context.mounted) {
      AppSnackBar.error(
        context,
        'No email app available on this device.',
      );
    }
  }
}
