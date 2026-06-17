// Read-only helper: list every account's email + role + provider so you can
// pick which existing accounts to hand to store reviewers. Changes NOTHING.
//
// Run from the functions/ folder:   node list-roles.js

const admin = require('firebase-admin');
const serviceAccount = require('./service-account-key.json');

admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });

(async () => {
  // Pull every users/{uid} doc (this is where the role lives).
  const snap = await admin.firestore().collection('users').get();

  const rows = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    let providers = '';
    try {
      const u = await admin.auth().getUser(doc.id);
      providers = u.providerData.map((p) => p.providerId).join(',');
    } catch (_) {
      providers = '(no auth account)';
    }
    rows.push({
      role: d.role || '(none)',
      email: d.email || '(no email)',
      providers,
      uid: doc.id,
    });
  }

  // Group by role so priests and users are easy to spot.
  rows.sort((a, b) => (a.role + a.email).localeCompare(b.role + b.email));

  console.log('\nROLE      | PROVIDERS            | EMAIL');
  console.log('----------|----------------------|--------------------------------');
  for (const r of rows) {
    console.log(
      `${r.role.padEnd(9)} | ${r.providers.padEnd(20)} | ${r.email}`
    );
  }
  console.log(`\nTotal: ${rows.length} accounts`);
  process.exit(0);
})();
