// Tests the sessionWatchdog Cloud Function by creating fake stale
// session documents covering each critical billing path, then
// verifying the watchdog handled them correctly.
//
// Usage:
//   node functions/test-watchdog.js create   — create 3 fake sessions
//   node functions/test-watchdog.js verify   — check watchdog results
//   node functions/test-watchdog.js cleanup  — delete the test sessions
//
// Setup (one-time):
//   1. Firebase Console → Project Settings → Service Accounts
//   2. "Generate new private key"
//   3. Save as functions/service-account-key.json (already gitignored)

const path = require("path");
const fs = require("fs");
const admin = require("firebase-admin");

const KEY_PATH = path.join(__dirname, "service-account-key.json");
const STATE_PATH = path.join(__dirname, ".test-watchdog-state.json");

if (!fs.existsSync(KEY_PATH)) {
  console.error(`
❌ Missing service account key.

Download it once:
  1. Open: https://console.firebase.google.com/project/gospelvox-a2208/settings/serviceaccounts/adminsdk
  2. Click "Generate new private key" → downloads a JSON file
  3. Save it as: ${KEY_PATH}

Then re-run this script. The file is already in .gitignore — won't get committed.
`);
  process.exit(1);
}

admin.initializeApp({
  credential: admin.credential.cert(require(KEY_PATH)),
});
const db = admin.firestore();

// Build a Timestamp at "secondsAgo" seconds in the past. Used to
// fake old heartbeats and session start times so the watchdog
// query picks them up.
function ts(secondsAgo) {
  return admin.firestore.Timestamp.fromMillis(
    Date.now() - secondsAgo * 1000
  );
}

// Auto-discover one user with role=user and one approved+activated
// priest. Saves you having to copy UIDs by hand.
async function findTestAccounts() {
  const users = await db
    .collection("users")
    .where("role", "==", "user")
    .limit(1)
    .get();
  if (users.empty) {
    throw new Error("No user with role=user found in users collection");
  }
  const user = users.docs[0];

  const priests = await db
    .collection("priests")
    .where("status", "==", "approved")
    .where("isActivated", "==", true)
    .limit(1)
    .get();
  if (priests.empty) {
    throw new Error(
      "No approved+activated priest found in priests collection"
    );
  }
  const priest = priests.docs[0];

  return {
    userId: user.id,
    userName: user.data().displayName || "Test User",
    userPhotoUrl: user.data().photoUrl || "",
    priestId: priest.id,
    priestName: priest.data().fullName || "Test Speaker",
    priestPhotoUrl: priest.data().photoUrl || "",
    priestDenomination: priest.data().denomination || "Catholic",
  };
}

async function create() {
  const accounts = await findTestAccounts();
  console.log(`Using user ${accounts.userId} and priest ${accounts.priestId}\n`);

  // Snapshot balances so we can detect deltas after watchdog runs.
  const userDoc = await db.doc(`users/${accounts.userId}`).get();
  const priestDoc = await db.doc(`priests/${accounts.priestId}`).get();
  const userBalanceBefore = userDoc.data()?.coinBalance ?? 0;
  const priestWalletBefore = priestDoc.data()?.walletBalance ?? 0;

  // Defensive guard: scenario 1 needs at least 10 coins for the
  // minimum charge to land. Bump the test user's balance if low.
  if (userBalanceBefore < 10) {
    console.log(
      `⚠️  User balance is ${userBalanceBefore}, bumping to 100 for testing...`
    );
    await db.doc(`users/${accounts.userId}`).update({coinBalance: 100});
  }

  const baseSession = {
    userId: accounts.userId,
    priestId: accounts.priestId,
    type: "chat",
    status: "active",
    ratePerMinute: 10,
    commissionPercent: 20,
    userBalance: 100,
    userName: accounts.userName,
    userPhotoUrl: accounts.userPhotoUrl,
    priestName: accounts.priestName,
    priestPhotoUrl: accounts.priestPhotoUrl,
    priestDenomination: accounts.priestDenomination,
    createdAt: ts(300), // 5 min ago
    startedAt: ts(300),
  };

  // Scenario 1 — STALE + 0 minutes already billed.
  // Watchdog should apply minimum 1-minute charge.
  // Expect: status=completed, durationMinutes=1, totalCharged=10,
  //         priestEarnings=8 (80% of 10).
  const s1 = await db.collection("sessions").add({
    ...baseSession,
    durationMinutes: 0,
    totalCharged: 0,
    priestEarnings: 0,
    lastHeartbeat: ts(300),
    _testTag: "scenario-1-stale-zero-billed",
  });

  // Scenario 2 — STALE + 5 minutes already billed by billingTick.
  // Watchdog must NOT add another minute on top.
  // Expect: status=completed, durationMinutes=5 (UNCHANGED),
  //         totalCharged=50 (UNCHANGED).
  // This is the most important test — failure here means
  // double-billing real users.
  const s2 = await db.collection("sessions").add({
    ...baseSession,
    durationMinutes: 5,
    totalCharged: 50,
    priestEarnings: 40,
    lastHeartbeat: ts(300),
    _testTag: "scenario-2-stale-five-billed",
  });

  // Scenario 3 — FRESH heartbeat. Set to NOW (not 60s ago) so the
  // user has the full 2-minute grace window to navigate to Cloud
  // Scheduler and click Force Run. If we set it to 60s ago and the
  // user takes >60s before the watchdog runs, the heartbeat ages
  // past the cutoff and the watchdog correctly ends it — making
  // the test look like a watchdog bug when it's really just
  // user-pacing latency.
  const s3 = await db.collection("sessions").add({
    ...baseSession,
    durationMinutes: 2,
    totalCharged: 20,
    priestEarnings: 16,
    lastHeartbeat: admin.firestore.Timestamp.now(),
    _testTag: "scenario-3-fresh-not-stale",
  });

  // Persist state so the verify command knows what to check.
  // Updated balances captured AFTER any defensive top-up above.
  const refreshedUser = await db.doc(`users/${accounts.userId}`).get();
  fs.writeFileSync(
    STATE_PATH,
    JSON.stringify(
      {
        s1: s1.id,
        s2: s2.id,
        s3: s3.id,
        userId: accounts.userId,
        priestId: accounts.priestId,
        userBalanceBefore: refreshedUser.data()?.coinBalance ?? 0,
        priestWalletBefore: priestWalletBefore,
        createdAt: new Date().toISOString(),
      },
      null,
      2
    )
  );

  console.log(`✅ Created 3 test sessions:

  Scenario 1 (stale + 0 billed) → ${s1.id}
    Expected: status=completed, durationMinutes=1, totalCharged=10, priestEarnings=8

  Scenario 2 (stale + 5 already billed) → ${s2.id}
    Expected: status=completed, durationMinutes=5 (UNCHANGED), totalCharged=50 (UNCHANGED)

  Scenario 3 (fresh, 1 min ago heartbeat) → ${s3.id}
    Expected: status=active (UNTOUCHED — should NOT be picked up)

NEXT STEPS:
  1. Force-trigger the watchdog from Cloud Scheduler:
     https://console.cloud.google.com/cloudscheduler?project=gospelvox-a2208
     Find "firebase-schedule-sessionWatchdog-asia-south1"
     → click ⋮ menu → "Force run"

  2. Wait ~10 seconds, then run:
     node functions/test-watchdog.js verify
`);
}

async function verify() {
  if (!fs.existsSync(STATE_PATH)) {
    console.error(
      "State file missing. Run `node functions/test-watchdog.js create` first."
    );
    process.exit(1);
  }
  const state = JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));

  let allPass = true;

  // ── Scenario 1 ──
  const s1 = (await db.doc(`sessions/${state.s1}`).get()).data() || {};
  console.log(`\n🔬 Scenario 1 (${state.s1}): stale + 0 billed`);
  const s1ok =
    s1.status === "completed" &&
    s1.durationMinutes === 1 &&
    s1.totalCharged === 10 &&
    s1.priestEarnings === 8 &&
    s1.endReason === "watchdog_timeout";
  if (s1ok) {
    console.log("   ✅ PASS — watchdog applied min 1-min charge correctly");
  } else {
    console.log("   ❌ FAIL — actual:");
    console.log("     ", JSON.stringify({
      status: s1.status,
      durationMinutes: s1.durationMinutes,
      totalCharged: s1.totalCharged,
      priestEarnings: s1.priestEarnings,
      endReason: s1.endReason,
    }));
    allPass = false;
  }

  // ── Scenario 2 (the critical one) ──
  const s2 = (await db.doc(`sessions/${state.s2}`).get()).data() || {};
  console.log(`\n🔬 Scenario 2 (${state.s2}): stale + 5 already billed`);
  const s2ok =
    s2.status === "completed" &&
    s2.durationMinutes === 5 &&
    s2.totalCharged === 50 &&
    s2.priestEarnings === 40 &&
    s2.endReason === "watchdog_timeout";
  if (s2ok) {
    console.log("   ✅ PASS — watchdog ended without double-charging");
  } else {
    console.log("   ❌ FAIL — actual:");
    console.log("     ", JSON.stringify({
      status: s2.status,
      durationMinutes: s2.durationMinutes,
      totalCharged: s2.totalCharged,
      priestEarnings: s2.priestEarnings,
      endReason: s2.endReason,
    }));
    allPass = false;
  }

  // ── Scenario 3 ──
  const s3 = (await db.doc(`sessions/${state.s3}`).get()).data() || {};
  console.log(`\n🔬 Scenario 3 (${state.s3}): fresh, 1 min ago heartbeat`);
  const s3ok = s3.status === "active";
  if (s3ok) {
    console.log("   ✅ PASS — watchdog correctly skipped fresh session");
  } else {
    console.log("   ❌ FAIL — fresh session was wrongly ended:");
    console.log("     ", JSON.stringify({
      status: s3.status,
      endReason: s3.endReason,
    }));
    allPass = false;
  }

  // ── Wallet deltas ──
  const userDoc = await db.doc(`users/${state.userId}`).get();
  const priestDoc = await db.doc(`priests/${state.priestId}`).get();
  const userDelta =
    (userDoc.data()?.coinBalance ?? 0) - state.userBalanceBefore;
  const priestDelta =
    (priestDoc.data()?.walletBalance ?? 0) - state.priestWalletBefore;

  console.log(`\n💰 Wallet deltas (only scenario 1 should move money):`);
  console.log(
    `   User balance change:  ${userDelta} coins   (expected: -10)`
  );
  console.log(
    `   Priest wallet change: +${priestDelta} coins   (expected: +8)`
  );

  if (userDelta !== -10) {
    console.log("   ❌ User balance delta wrong");
    allPass = false;
  }
  if (priestDelta !== 8) {
    console.log("   ❌ Priest wallet delta wrong");
    allPass = false;
  }

  console.log(
    `\n${allPass ? "🎉 ALL PASS — watchdog is working correctly." : "⚠️  FAILURES detected — see above."}\n`
  );

  if (allPass) {
    console.log(
      "Clean up test data with:\n  node functions/test-watchdog.js cleanup\n"
    );
  }
}

async function cleanup() {
  if (!fs.existsSync(STATE_PATH)) {
    console.log("No state file. Nothing to clean.");
    return;
  }
  const state = JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
  await db.doc(`sessions/${state.s1}`).delete();
  await db.doc(`sessions/${state.s2}`).delete();
  await db.doc(`sessions/${state.s3}`).delete();
  fs.unlinkSync(STATE_PATH);
  console.log("🧹 Deleted 3 test session docs and removed local state file.");
  console.log(
    "Note: notification + wallet_transaction docs created by the watchdog"
  );
  console.log(
    "are intentionally left in place as an audit trail. They're harmless."
  );
}

const cmd = process.argv[2];
const fn = {create, verify, cleanup}[cmd];

if (!fn) {
  console.log(`Usage:
  node functions/test-watchdog.js create   — create 3 fake stale sessions
  node functions/test-watchdog.js verify   — check watchdog handled them correctly
  node functions/test-watchdog.js cleanup  — delete the test sessions
`);
  process.exit(1);
}

fn()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });
