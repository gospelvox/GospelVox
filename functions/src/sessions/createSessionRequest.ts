import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

// Creates a pending session between a user and a priest. This is
// the ONLY entry point for session creation — the Flutter client
// never writes to the sessions collection directly, because we need
// to atomically:
//   • lock the per-minute rate from app_config (so later admin rate
//     edits can't retro-bill)
//   • verify the user has at least one minute's worth of coins
//   • verify the priest is actually online and not already busy
//   • verify the user doesn't already have a pending request
//     (otherwise a rapid double-tap could spawn two sessions)
//
// The function also writes a notification doc so the priest's
// sendNotification CF can wake up their push channel in parallel.
export const createSessionRequest = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const uid = request.auth.uid;
    const data = request.data ?? {};
    const priestId = data.priestId as string | undefined;
    const type = data.type as string | undefined;

    if (!priestId || !type) {
      throw new HttpsError(
        "invalid-argument",
        "Missing priestId or type"
      );
    }
    if (type !== "chat" && type !== "voice") {
      throw new HttpsError(
        "invalid-argument",
        "Type must be 'chat' or 'voice'"
      );
    }
    if (priestId === uid) {
      throw new HttpsError(
        "invalid-argument",
        "Cannot request a session with yourself"
      );
    }

    // 1. User + balance
    const userSnap = await db.doc(`users/${uid}`).get();
    if (!userSnap.exists) {
      throw new HttpsError("not-found", "User not found");
    }
    const userData = userSnap.data() ?? {};
    const coinBalance = Number(userData.coinBalance ?? 0);

    // 2. Rates + commission (locked into the doc so admin edits
    //    after this moment can't rewrite what the user owes)
    const settingsSnap = await db.doc("app_config/settings").get();
    const settings = settingsSnap.data() ?? {};
    const ratePerMinute =
      type === "chat"
        ? Number(settings.chatRatePerMinute ?? 10)
        : Number(settings.voiceRatePerMinute ?? 15);
    const commissionPercent = Number(settings.commissionPercent ?? 20);

    // 3. Affordability — at least one minute's worth
    if (coinBalance < ratePerMinute) {
      throw new HttpsError(
        "failed-precondition",
        "insufficient-balance"
      );
    }

    // 4. Priest exists, is online, and isn't busy
    const priestSnap = await db.doc(`priests/${priestId}`).get();
    if (!priestSnap.exists) {
      throw new HttpsError("not-found", "Speaker not found");
    }
    const priestData = priestSnap.data() ?? {};

    if (!priestData.isOnline) {
      throw new HttpsError(
        "failed-precondition",
        "priest-offline"
      );
    }
    if (priestData.isBusy === true) {
      throw new HttpsError(
        "failed-precondition",
        "priest-busy"
      );
    }

    // 5. Priest already mid-session? Block so two users can't call
    //    the same priest at once.
    const activeSessions = await db
      .collection("sessions")
      .where("priestId", "==", priestId)
      .where("status", "==", "active")
      .limit(1)
      .get();

    if (!activeSessions.empty) {
      throw new HttpsError(
        "failed-precondition",
        "priest-busy"
      );
    }

    // 6. Reconcile any prior pending requests from this user.
    //    Rule: tapping Chat again always wins — we expire whatever
    //    came before and create a fresh session. This trades the
    //    "rapid double-tap dedupe" (which the UI prevents anyway
    //    by pushing a single waiting route) for a vastly better
    //    recovery story when the client's cancel didn't land
    //    (app killed, Firestore rules rejected, etc.).
    const pendingRequests = await db
      .collection("sessions")
      .where("userId", "==", uid)
      .where("status", "==", "pending")
      .get();

    if (!pendingRequests.empty) {
      const cleanupBatch = db.batch();
      for (const doc of pendingRequests.docs) {
        cleanupBatch.update(doc.ref, {
          status: "expired",
          endedAt: admin.firestore.FieldValue.serverTimestamp(),
          endReason: "superseded_by_new_request",
        });
      }
      await cleanupBatch.commit();
      console.log(
        `[createSessionRequest] Expired ${pendingRequests.size} ` +
          `prior pending session(s) for user ${uid}`
      );
    }

    // 7. Finally, create the session doc. All denormalised display
    //    fields come from the already-fetched priest + user snaps
    //    so the UI can render both ends without a second read.
    const sessionRef = db.collection("sessions").doc();
    await sessionRef.set({
      userId: uid,
      priestId: priestId,
      type: type,
      status: "pending",
      ratePerMinute: ratePerMinute,
      commissionPercent: commissionPercent,
      userBalance: coinBalance,
      durationMinutes: 0,
      totalCharged: 0,
      priestEarnings: 0,

      userName: userData.displayName ?? "",
      userPhotoUrl: userData.photoUrl ?? "",

      priestName: priestData.fullName ?? "",
      priestPhotoUrl: priestData.photoUrl ?? "",
      priestDenomination: priestData.denomination ?? "",

      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      lastHeartbeat: admin.firestore.FieldValue.serverTimestamp(),
    });

    // 8. Drop a notification for the priest. sendNotification reads
    //    this collection and dispatches the push; keeping it as a
    //    separate write so this CF stays fast on the critical path.
    await db.collection("notifications").add({
      userId: priestId,
      type: "session_request",
      title: `New ${type} request`,
      body: `${userData.displayName || "A user"} wants to ${
        type === "chat" ? "chat with" : "call"
      } you`,
      sessionId: sessionRef.id,
      isRead: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // 9. Push the priest's device(s) so they hear the request even
    //    if their app is backgrounded. Best-effort — sendPush
    //    swallows its own failures so this never blocks return.
    //
    //    Route is "/priest" (the dashboard) NOT "/priest/incoming".
    //    The incoming-request page requires a SessionModel passed via
    //    extras — a notification tap can only carry string data, so
    //    navigating directly would land on the "Session unavailable"
    //    placeholder. The dashboard's pending-request stream listener
    //    detects the same session and auto-routes to /priest/incoming
    //    with the full hydrated model.
    await sendPushNotification({
      userId: priestId,
      title: `New ${type} request`,
      body: `${userData.displayName || "A user"} wants to ${
        type === "chat" ? "chat with" : "call"
      } you`,
      data: {
        type: "session_request",
        sessionId: sessionRef.id,
        route: "/priest",
      },
    });

    return {sessionId: sessionRef.id};
  }
);
