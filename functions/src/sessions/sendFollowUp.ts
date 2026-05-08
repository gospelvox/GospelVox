// Priest-initiated follow-up nudge after a completed session.
//
// This is NOT a chat feature. It is a one-shot, server-controlled
// templated notification. The client sends a template ID (1-4) and
// the CF resolves to the actual text — the client can never inject
// custom message content. All rate limits live here:
//   • only the priest who owned the session can send
//   • only on status === "completed" sessions (declined/expired had
//     no conversation, so a follow-up there would be confusing)
//   • only within 48 hours of the session's end
//   • only once per session (followUpSent flag)
//   • max 5 per priest per day, tracked via a counter on the priest
//     doc — no composite index required (the earlier count() query
//     needed one and was failing on first deploy)
//
// On success: marks the session, writes a notifications/{id} doc for
// the user's in-app inbox, and fires a push with a deep link to the
// priest's profile page so the user can start a NEW PAID session.

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

// Templates live SERVER-SIDE only. The client UI shows the same text
// for the priest to preview before tapping send, but only the ID is
// transmitted — there is no path for a priest to send custom text.
const TEMPLATES: Record<number, string> = {
  1: "I hope our conversation was helpful. Feel free to reach out anytime you need guidance.",
  2: "I'm available now if you'd like to continue our conversation.",
  3: "I noticed our session ended early. I'm here whenever you're ready to continue.",
  4: "May God bless you. I'm here if you need someone to talk to.",
};

const FOLLOW_UP_WINDOW_HOURS = 48;
const DAILY_LIMIT_PER_PRIEST = 5;

export const sendFollowUp = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const priestUid = request.auth.uid;
    const data = request.data ?? {};
    const sessionId = data.sessionId as string | undefined;
    const templateId = data.templateId as number | undefined;

    if (!sessionId || typeof sessionId !== "string") {
      throw new HttpsError("invalid-argument", "Missing sessionId");
    }
    if (
      !templateId ||
      typeof templateId !== "number" ||
      templateId < 1 ||
      templateId > 4
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Invalid template. Choose 1-4."
      );
    }

    const sessionRef = db.doc(`sessions/${sessionId}`);
    const sessionDoc = await sessionRef.get();

    if (!sessionDoc.exists) {
      throw new HttpsError("not-found", "Session not found");
    }

    const session = sessionDoc.data()!;

    if (session.priestId !== priestUid) {
      throw new HttpsError(
        "permission-denied",
        "You can only follow up on your own sessions"
      );
    }

    // Tightened from the original spec: only "completed" status
    // qualifies. Declined / expired / cancelled sessions never had
    // a conversation, so a templated "I hope our chat was helpful"
    // would be jarring to the user.
    if (session.status !== "completed") {
      throw new HttpsError(
        "failed-precondition",
        "Can only follow up on completed sessions"
      );
    }

    const endedAtTs = session.endedAt as
      | admin.firestore.Timestamp
      | undefined;
    const createdAtTs = session.createdAt as
      | admin.firestore.Timestamp
      | undefined;
    const endedAt = endedAtTs?.toDate() ?? createdAtTs?.toDate();
    if (!endedAt) {
      throw new HttpsError(
        "failed-precondition",
        "Session has no end time"
      );
    }

    const hoursSinceEnd =
      (Date.now() - endedAt.getTime()) / (1000 * 60 * 60);
    if (hoursSinceEnd > FOLLOW_UP_WINDOW_HOURS) {
      throw new HttpsError(
        "failed-precondition",
        `Follow-up window expired (${FOLLOW_UP_WINDOW_HOURS} hours)`
      );
    }

    if (session.followUpSent === true) {
      throw new HttpsError(
        "already-exists",
        "Follow-up already sent for this session"
      );
    }

    // Daily quota check via a counter on priests/{uid}. The earlier
    // implementation ran a count() query against the sessions
    // collection, which required a composite index — we hit the
    // index-missing failure in production. The counter doc approach
    // needs no index and is one extra single-doc read per send.
    //
    // Date is stored as a YYYY-MM-DD string in IST (UTC+5:30) so the
    // counter rolls over at midnight India time — Gospel Vox is an
    // India-only product, and a UTC boundary would reset the quota
    // at 5:30am IST, which is jarring for a priest still active near
    // midnight.
    const priestRef = db.doc(`priests/${priestUid}`);
    const priestSnap = await priestRef.get();
    const priestData = priestSnap.data() ?? {};

    const istOffsetMs = (5 * 60 + 30) * 60 * 1000;
    const todayKey = new Date(Date.now() + istOffsetMs)
      .toISOString()
      .slice(0, 10);
    const lastCounterDate =
      (priestData.followUpCounterDate as string | undefined) ?? "";
    const lastCounterCount =
      (priestData.followUpCounterCount as number | undefined) ?? 0;

    // Only count today's sends — yesterday's count rolls off when
    // the date key changes.
    const todayCount = lastCounterDate === todayKey ? lastCounterCount : 0;

    if (todayCount >= DAILY_LIMIT_PER_PRIEST) {
      throw new HttpsError(
        "resource-exhausted",
        `Daily follow-up limit reached (${DAILY_LIMIT_PER_PRIEST} per day)`
      );
    }

    const templateText = TEMPLATES[templateId];
    const userId = session.userId as string;
    const priestName =
      (session.priestName as string | undefined) ?? "Your speaker";
    const priestPhotoUrl =
      (session.priestPhotoUrl as string | undefined) ?? "";

    // Atomic write: marking followUpSent, creating the inbox doc,
    // and bumping the priest's daily counter happen together so a
    // crash between them can't leave the session marked as sent
    // without the user ever seeing it (or the counter advancing
    // without an actual send).
    const batch = db.batch();

    batch.update(sessionRef, {
      followUpSent: true,
      followUpTemplate: templateId,
      followUpSentAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    const notifRef = db.collection("notifications").doc();
    batch.set(notifRef, {
      userId: userId,
      type: "follow_up",
      title: `${priestName} sent you a message`,
      body: templateText,
      priestId: priestUid,
      priestName: priestName,
      priestPhotoUrl: priestPhotoUrl,
      sessionId: sessionId,
      isRead: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    // Counter on the priest doc. set(merge:true) — not update() — so
    // the very first send on a freshly-created priest account works
    // even if these two fields don't exist yet.
    batch.set(
      priestRef,
      {
        followUpCounterDate: todayKey,
        followUpCounterCount: todayCount + 1,
      },
      {merge: true}
    );

    await batch.commit();

    // Push is best-effort. The notification doc above is the source
    // of truth — the user will see it in the in-app inbox even if
    // the OS-level push fails (token expired, FCM hiccup, etc).
    await sendPushNotification({
      userId: userId,
      title: `${priestName} sent you a message`,
      body: templateText,
      data: {
        type: "follow_up",
        route: `/user/priest/${priestUid}`,
        priestId: priestUid,
      },
    }).catch(() => {
      // Swallow — sendPushNotification already logs internally.
    });

    return {success: true, templateId};
  }
);
