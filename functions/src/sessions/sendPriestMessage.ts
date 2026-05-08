// Priest-initiated free message to a past user. Replaces the older
// templated sendFollowUp flow with a freeform 280-char text input,
// while keeping every safety rail server-side. The client never
// writes a message doc directly — every send goes through this CF
// so rate limits, mute checks, and the relationship gate cannot be
// bypassed.
//
// Safety rails (mirrors the spec exactly):
//   • Caller must be an approved + activated priest
//   • Recipient must have at least one COMPLETED session with the
//     caller (no cold-DMing — the relationship is the gate)
//   • Recipient cannot be in caller's mutedBy list (i.e. user has
//     muted this priest); we silently no-op so the priest can't
//     probe the mute state by trial-and-error
//   • Text length 1..280 after trim
//   • Max 3 messages per (priest, user) per IST day
//   • Max 15 messages per priest per IST day across all users
//
// Storage: notifications/{id} with type='priest_message'. Reuses
// the existing collection that the user-side notifications page +
// chat thread already render. No new schema.
//
// Rate-limit storage:
//   • Per-priest daily total → fields on priests/{uid}: messageCounterDate,
//     messageCounterCount. Same shape sendFollowUp uses.
//   • Per-(priest, user) daily count → priests/{uid}/messageCounters/
//     {YYYY-MM-DD}_{userId} doc with {count}. Composite-id keeps reads
//     index-free.

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

const MAX_LENGTH = 280;
const PER_USER_DAILY_LIMIT = 3;
const PER_PRIEST_DAILY_LIMIT = 15;

export const sendPriestMessage = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const priestUid = request.auth.uid;
    const data = request.data ?? {};
    const targetUserId = data.userId as string | undefined;
    const rawText = data.text as string | undefined;

    if (!targetUserId || typeof targetUserId !== "string") {
      throw new HttpsError("invalid-argument", "Missing userId");
    }
    if (typeof rawText !== "string") {
      throw new HttpsError("invalid-argument", "Missing text");
    }

    const text = rawText.trim();
    if (text.length === 0) {
      throw new HttpsError("invalid-argument", "Message cannot be empty");
    }
    if (text.length > MAX_LENGTH) {
      throw new HttpsError(
        "invalid-argument",
        `Message exceeds ${MAX_LENGTH} characters`
      );
    }
    if (priestUid === targetUserId) {
      throw new HttpsError(
        "invalid-argument",
        "Cannot message yourself"
      );
    }

    // 1. Priest must be approved + activated. Suspended / pending /
    //    rejected priests can't message past users.
    const priestRef = db.doc(`priests/${priestUid}`);
    const priestSnap = await priestRef.get();
    if (!priestSnap.exists) {
      throw new HttpsError(
        "permission-denied",
        "Speaker profile not found"
      );
    }
    const priestData = priestSnap.data() ?? {};
    if (priestData.status !== "approved") {
      throw new HttpsError(
        "permission-denied",
        "Only approved speakers can send messages"
      );
    }
    if (priestData.isActivated !== true) {
      throw new HttpsError(
        "failed-precondition",
        "Activate your account before sending messages"
      );
    }

    // 2. Relationship gate — at least one completed session with this
    //    user OR a documented missed-request from this user. The
    //    missed-request branch is what powers the priest's quick-reply
    //    flow on /priest/missed-requests: the user tried to reach the
    //    priest, so a response is intent-aligned even without a prior
    //    completed session.
    const completedSnap = await db
      .collection("sessions")
      .where("priestId", "==", priestUid)
      .where("userId", "==", targetUserId)
      .where("status", "==", "completed")
      .limit(1)
      .get();

    let hasMissedRequest = false;
    if (completedSnap.empty) {
      const missedSnap = await db
        .collection("notifications")
        .where("userId", "==", priestUid)
        .where("type", "==", "missed_request")
        .where("requesterId", "==", targetUserId)
        .limit(1)
        .get();
      hasMissedRequest = !missedSnap.empty;
    }

    if (completedSnap.empty && !hasMissedRequest) {
      throw new HttpsError(
        "failed-precondition",
        "You can only message users you've had a completed session with"
      );
    }

    // 3. Mute check. Silent no-op on success path so the priest
    //    can't probe who muted them by retrying. We still consume
    //    a rate-limit slot to prevent a muted priest from using the
    //    no-op as a free way to keep blasting (their daily total
    //    will still cap them at 15).
    const userRef = db.doc(`users/${targetUserId}`);
    const userSnap = await userRef.get();
    if (!userSnap.exists) {
      throw new HttpsError("not-found", "User not found");
    }
    const userData = userSnap.data() ?? {};
    const mutedList = (userData.mutedPriestIds as string[] | undefined) ?? [];
    const isMuted = mutedList.includes(priestUid);

    // 4. Rate limits — IST day boundary, same as sendFollowUp.
    const istOffsetMs = (5 * 60 + 30) * 60 * 1000;
    const todayKey = new Date(Date.now() + istOffsetMs)
      .toISOString()
      .slice(0, 10);

    // 4a. Per-priest daily total. Fields on the priest doc, mirroring
    //     sendFollowUp's pattern. Pre-existing followUp fields are
    //     untouched so the older flow keeps working independently.
    const lastTotalDate =
      (priestData.messageCounterDate as string | undefined) ?? "";
    const lastTotalCount =
      (priestData.messageCounterCount as number | undefined) ?? 0;
    const todayTotal = lastTotalDate === todayKey ? lastTotalCount : 0;

    if (todayTotal >= PER_PRIEST_DAILY_LIMIT) {
      throw new HttpsError(
        "resource-exhausted",
        `Daily message limit reached (${PER_PRIEST_DAILY_LIMIT} per day)`
      );
    }

    // 4b. Per-(priest, user) daily count. Composite doc id keeps the
    //     read at one document and avoids any new index requirement.
    const perUserCounterRef = priestRef
      .collection("messageCounters")
      .doc(`${todayKey}_${targetUserId}`);
    const perUserSnap = await perUserCounterRef.get();
    const perUserCount =
      (perUserSnap.data()?.count as number | undefined) ?? 0;

    if (perUserCount >= PER_USER_DAILY_LIMIT) {
      throw new HttpsError(
        "resource-exhausted",
        `Daily limit per user reached (${PER_USER_DAILY_LIMIT} per day)`
      );
    }

    // 5. Atomic write. Counters bump together with the notification
    //    write so a crash mid-batch can't desync the total or per-
    //    user counter from the actual delivery.
    const priestName =
      (priestData.fullName as string | undefined) ?? "Speaker";
    const priestPhotoUrl =
      (priestData.photoUrl as string | undefined) ?? "";

    const batch = db.batch();

    // Notification doc is ALWAYS written — even when the recipient
    // has muted the sender — so the priest's own chat view still
    // shows what they sent. The `delivered` flag is the user-side
    // signal: clients filter notifications where delivered === false
    // (and skip the push for those), so muted messages remain
    // invisible to the user while the priest keeps a record of
    // their attempts. This avoids the otherwise-silent "I sent
    // three messages and nothing shows" UX trap.
    const notifRef = db.collection("notifications").doc();
    batch.set(notifRef, {
      userId: targetUserId,
      type: "priest_message",
      title: priestName,
      body: text,
      priestId: priestUid,
      priestName: priestName,
      priestPhotoUrl: priestPhotoUrl,
      isRead: false,
      delivered: !isMuted,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    batch.set(
      priestRef,
      {
        messageCounterDate: todayKey,
        messageCounterCount: todayTotal + 1,
      },
      {merge: true}
    );

    batch.set(
      perUserCounterRef,
      {
        count: perUserCount + 1,
        priestId: priestUid,
        userId: targetUserId,
        date: todayKey,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      {merge: true}
    );

    await batch.commit();

    // 6. Push delivery — skipped on mute. sendPushNotification swallows
    //    its own errors; we don't await reliability here.
    if (!isMuted) {
      await sendPushNotification({
        userId: targetUserId,
        title: priestName,
        body: text,
        data: {
          type: "priest_message",
          // Deep link straight to the chat with this priest so a tap
          // from the lock screen lands on the conversation, not on
          // a generic profile page.
          route: `/user/chat-history/${priestUid}`,
          priestId: priestUid,
        },
      }).catch(() => {
        // Already logged inside the helper.
      });
    }

    return {
      success: true,
      delivered: !isMuted,
      remainingPerUserToday:
        PER_USER_DAILY_LIMIT - (perUserCount + 1),
      remainingTotalToday: PER_PRIEST_DAILY_LIMIT - (todayTotal + 1),
    };
  }
);
