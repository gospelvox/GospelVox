import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";

const db = admin.firestore();

// Settles a session. Either party may call it — the CF checks
// participation and is idempotent: if the session is already
// completed it just returns the existing summary, so a duplicate
// call (e.g. both sides tap End at the same time) doesn't double-
// charge the user.
//
// Minimum-charge rule: if the session went active but no billing
// tick ever ran (priest accepted and someone ended within the first
// minute), we still bill one full minute. This matches the product
// contract stated on the priest profile page.
export const endSession = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const sessionId = request.data?.sessionId as string | undefined;
    if (!sessionId) {
      throw new HttpsError("invalid-argument", "Missing sessionId");
    }

    const sessionRef = db.doc(`sessions/${sessionId}`);
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
      throw new HttpsError("not-found", "Session not found");
    }

    const session = sessionSnap.data() ?? {};
    const uid = request.auth.uid;

    if (uid !== session.userId && uid !== session.priestId) {
      throw new HttpsError(
        "permission-denied",
        "Not a participant in this session"
      );
    }

    // Idempotent path: session is already completed. Re-fetch the
    // user doc so the returned newBalance reflects any other writes
    // (e.g. a coin purchase) that happened since the session ended.
    if (session.status === "completed") {
      const userSnap = await db.doc(`users/${session.userId}`).get();
      return {
        durationMinutes: Number(session.durationMinutes ?? 0),
        totalCharged: Number(session.totalCharged ?? 0),
        priestEarnings: Number(session.priestEarnings ?? 0),
        newBalance: Number(userSnap.data()?.coinBalance ?? 0),
      };
    }

    const rate = Number(session.ratePerMinute ?? 10);
    const commission = Number(session.commissionPercent ?? 20);

    let finalDuration = Number(session.durationMinutes ?? 0);
    let finalTotalCharged = Number(session.totalCharged ?? 0);
    let finalPriestEarnings = Number(session.priestEarnings ?? 0);

    // Minimum 1 minute for any active session where no billing tick
    // has run yet. If the user genuinely can't afford that one
    // minute we skip — the CF already flipped them to balance_zero
    // via billingTick in that case, so we wouldn't reach here.
    if (session.status === "active" && finalDuration === 0) {
      const userRef = db.doc(`users/${session.userId}`);
      const userSnap = await userRef.get();
      const currentBalance = Number(userSnap.data()?.coinBalance ?? 0);

      if (currentBalance >= rate) {
        const priestEarning = Math.floor(rate * (1 - commission / 100));
        const priestRef = db.doc(`priests/${session.priestId}`);

        const batch = db.batch();
        batch.update(userRef, {
          coinBalance: admin.firestore.FieldValue.increment(-rate),
        });
        batch.update(priestRef, {
          walletBalance: admin.firestore.FieldValue.increment(priestEarning),
          totalEarnings: admin.firestore.FieldValue.increment(priestEarning),
        });

        const txRef = db.collection("wallet_transactions").doc();
        batch.set(txRef, {
          userId: session.userId,
          type: "session_charge",
          sessionId: sessionId,
          coins: -rate,
          description: `${session.type} session — minimum charge`,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        await batch.commit();

        finalDuration = 1;
        finalTotalCharged += rate;
        finalPriestEarnings += priestEarning;
      }
    }

    await sessionRef.update({
      status: "completed",
      endedAt: admin.firestore.FieldValue.serverTimestamp(),
      durationMinutes: finalDuration,
      totalCharged: finalTotalCharged,
      priestEarnings: finalPriestEarnings,
      endedBy: uid === session.userId ? "user" : "priest",
    });

    // Bump the priest's session count on the priest doc so the
    // dashboard stat reflects this session immediately, without
    // waiting for an aggregation job.
    await db.doc(`priests/${session.priestId}`).update({
      totalSessions: admin.firestore.FieldValue.increment(1),
    });

    const finalUserSnap = await db.doc(`users/${session.userId}`).get();

    return {
      durationMinutes: finalDuration,
      totalCharged: finalTotalCharged,
      priestEarnings: finalPriestEarnings,
      newBalance: Number(finalUserSnap.data()?.coinBalance ?? 0),
    };
  }
);
