// One-off: set app_config/settings.minSessionMinutes = 1.
//
// Lowers the "minimum balance required to START a call/chat" from
// 5 minutes' worth of coins to 1 minute. This single field is read by
// BOTH:
//   • the client preflight (lib/features/shared/data/session_preflight.dart)
//   • the server backstop   (functions/src/sessions/createSessionRequest.ts)
// so changing it here updates both — no app build, no function deploy.
//
// Uses { merge: true } so every other field already in
// app_config/settings (chatRatePerMinute, voiceRatePerMinute,
// commissionPercent, fees, limits, …) is left completely untouched.
//
// Reversible: rerun with NEW_VALUE set back to 5 (or delete the field).

const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');

const PROJECT_ID = 'gospelvox-a2208';
const NEW_VALUE = 1;

// Prefer the service-account key (same one scripts/seed-firestore.js
// uses). Fall back to Application Default Credentials (e.g. after
// `gcloud auth application-default login`) so the script can still run
// without the key file present.
const keyPath = path.join(__dirname, 'service-account-key.json');
if (fs.existsSync(keyPath)) {
  admin.initializeApp({
    credential: admin.credential.cert(require(keyPath)),
    projectId: PROJECT_ID,
  });
  console.log('Auth: service-account-key.json');
} else {
  admin.initializeApp({ projectId: PROJECT_ID });
  console.log('Auth: Application Default Credentials (no key file found)');
}

const db = admin.firestore();

async function run() {
  const ref = db.doc('app_config/settings');

  const before = await ref.get();
  const prev = before.exists ? before.data().minSessionMinutes : undefined;
  console.log(
    'Current minSessionMinutes:',
    prev === undefined ? '(unset → code defaults to 5)' : prev,
  );

  await ref.set(
    {
      minSessionMinutes: NEW_VALUE,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  const after = await ref.get();
  const data = after.data() || {};
  console.log('New minSessionMinutes:', data.minSessionMinutes);
  console.log('');
  console.log('Resulting start minimums (rate × 1 minute):');
  console.log('  Voice call:', (data.voiceRatePerMinute ?? '?'), 'coins');
  console.log('  Chat      :', (data.chatRatePerMinute ?? '?'), 'coins');
  console.log('✅ Done.');
}

run()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error('❌ Failed:', e.message || e);
    process.exit(1);
  });
