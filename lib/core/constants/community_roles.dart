// Christian community roles. Collected as a mandatory single-select on
// Step 1 of priest registration and editable later from the priest's
// own My Profile page.
//
// Kept in ONE place (not duplicated like the specialization/language
// lists) so the registration dropdown and the My Profile editor can
// never drift apart.
//
// Order and spelling are intentionally verbatim from the product spec —
// do not "tidy" the casing of entries like 'Child evangelist' / 'Song
// writer' / 'Tele-evangelist' without a product decision.
//
// 'Other' is the escape hatch: selecting it reveals a free-text field
// and the typed value is what gets stored. The literal 'Other' token is
// never written to Firestore.
library;

// Sentinel for the "type your own" option. Compared by identity against
// the picked value everywhere a role is resolved.
const String kCommunityRoleOther = 'Other';

const List<String> kCommunityRoles = [
  'Priest',
  'Cardinal',
  'Apostle',
  'Evangelist',
  'Pastor',
  'Teaching Pastor',
  'Bible Teacher',
  'Theology Teacher',
  'Spiritual Advisor',
  'Street Evangelist',
  'Mentor',
  'Councillor',
  'Child evangelist',
  'Lady Preacher',
  'Prophet',
  'Song writer',
  'Tele-evangelist',
  kCommunityRoleOther,
];

// True when [value] is one of the predefined roles (excluding 'Other').
//
// Used when re-opening the form to decide whether a saved role should
// pre-select a list item, or — being a custom value the priest typed —
// reopen the dropdown on 'Other' with the value back in the text field.
bool isKnownCommunityRole(String value) =>
    value != kCommunityRoleOther && kCommunityRoles.contains(value);
