// Meeting-platform metadata for Bible sessions. This is the SINGLE
// source of truth shared by the priest create form, the add-link
// sheet, the how-to guide, and the user-side placeholder — so they
// never drift, and adding a new platform (e.g. Microsoft Teams) is a
// single entry in [MeetingPlatform.all].
//
// The session doc stores only the platform `id` string
// (BibleSessionModel.meetingPlatform). Everything else — labels,
// hints, guide steps — is looked up here by id, so a doc written
// before this field existed falls back cleanly via [fromId] /
// [detectFromUrl].

class MeetingGuideStep {
  final String title;
  final String description;
  const MeetingGuideStep(this.title, this.description);
}

class MeetingPlatform {
  // Stored on the session doc as `meetingPlatform`.
  final String id;
  // Short display name: "Google Meet" / "Zoom".
  final String label;
  // Field label shown above the link input ("GOOGLE MEET LINK").
  final String linkLabel;
  // Placeholder/hint text inside the link input.
  final String hint;
  // Blurred sample URL shown to users before they pay.
  final String placeholder;
  // Host fragments used for FORGIVING matching — a link whose host
  // contains any of these is considered "this platform". Matching is
  // a soft signal only (used for a gentle warning), never a hard gate.
  final List<String> hostHints;
  final String guideTitle;
  final List<MeetingGuideStep> guideSteps;
  // True for platforms that may need a Meeting ID + Passcode to join
  // (Zoom). When true, the priest forms surface optional Meeting ID /
  // Passcode fields. Google Meet = false (the link is everything).
  final bool usesAccessCodes;

  const MeetingPlatform({
    required this.id,
    required this.label,
    required this.linkLabel,
    required this.hint,
    required this.placeholder,
    required this.hostHints,
    required this.guideTitle,
    required this.guideSteps,
    this.usesAccessCodes = false,
  });

  static const googleMeet = MeetingPlatform(
    id: 'google_meet',
    label: 'Google Meet',
    linkLabel: 'GOOGLE MEET LINK',
    hint: 'Paste from Google Meet (or type the URL)',
    placeholder: 'https://meet.google.com/abc-defg-hij',
    hostHints: ['meet.google.com'],
    guideTitle: 'How to Create a Google Meet Link',
    guideSteps: [
      MeetingGuideStep(
        'Open Google Meet',
        'Open the Google Meet app on your phone, or visit '
            'meet.google.com in your browser.',
      ),
      MeetingGuideStep(
        'Create a New Meeting',
        "Tap the 'New meeting' button or '+' icon.",
      ),
      MeetingGuideStep(
        "Choose 'Create a meeting for later'",
        'This gives you a link without starting the meeting right now.',
      ),
      MeetingGuideStep(
        'Copy the Link',
        "You'll see a link like meet.google.com/abc-defg-hij. "
            "Tap 'Copy' or long-press to copy it.",
      ),
      MeetingGuideStep(
        'Paste Here',
        'Come back to Gospel Vox and paste the link in the link field.',
      ),
    ],
  );

  static const zoom = MeetingPlatform(
    id: 'zoom',
    label: 'Zoom',
    linkLabel: 'ZOOM LINK',
    hint: 'Paste your Zoom invite link (or type the URL)',
    placeholder: 'https://zoom.us/j/1234567890',
    hostHints: ['zoom.us', 'zoom.com'],
    usesAccessCodes: true,
    guideTitle: 'How to Create a Zoom Link',
    guideSteps: [
      MeetingGuideStep(
        'Open Zoom',
        'Open the Zoom app on your phone, or visit zoom.us in your '
            'browser and sign in.',
      ),
      MeetingGuideStep(
        'Schedule a Meeting',
        "Tap 'Schedule' and pick the date and time of your session. "
            "Turn OFF 'Waiting Room', or be ready to admit attendees.",
      ),
      MeetingGuideStep(
        'Copy the FULL Invite Link',
        "Open the meeting and tap 'Copy Invite Link'. The full link "
            "already includes the password, so attendees join in one "
            "tap. It looks like zoom.us/j/1234567890?pwd=…",
      ),
      MeetingGuideStep(
        'Paste Here',
        'Come back to Gospel Vox and paste the link in the link field.',
      ),
      MeetingGuideStep(
        'Optional: Meeting ID & Passcode',
        "If your link doesn't include the password, also fill the "
            "Meeting ID and Passcode fields so attendees can join "
            "manually from the Zoom app.",
      ),
    ],
  );

  // Add a new platform here (e.g. Microsoft Teams) and every selector,
  // guide, and label across the app picks it up automatically.
  static const List<MeetingPlatform> all = [googleMeet, zoom];

  // Resolve a stored id to its metadata. Unknown / null → Google Meet
  // (the historical default before this field existed).
  static MeetingPlatform fromId(String? id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return googleMeet;
  }

  // Best-effort detection from a URL host — used only to back-fill the
  // platform for legacy session docs that predate `meetingPlatform`.
  static MeetingPlatform? detectFromUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return null;
    for (final p in all) {
      if (p.hostHints.any(host.contains)) return p;
    }
    return null;
  }

  // Forgiving: true when the url's host looks like this platform.
  // Used to decide whether to show a soft "double-check" warning, NOT
  // to block saving.
  bool matchesUrl(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    return hostHints.any(host.contains);
  }
}
