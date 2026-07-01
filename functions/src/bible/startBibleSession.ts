import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

// Same chunk size as the cancellation / link-added fanouts so memory
// envelope and concurrency profile stay predictable across the bible
// CF family.
const FANOUT_CHUNK_SIZE = 200;

// Called by the priest's client after the heavy "Start Meeting"
// confirmation. The CF is the source of truth for three things the
// client cannot prove on its own:
//
//   1. The session is actually owned by the caller and is in the
//      "upcoming" state with a meeting link set. The priest UI
//      already gates this, but a stale-state UI tap shouldn't be
//      able to put a session into live without a link, because that
//      breaks the new flow's premise (pay-on-live needs a link to
//      hand out).
//
//   2. The priest doesn't already have another live session. The
//      new flow's UX assumption is "one live per priest at a time"
//      — users get a call-like notification, and getting two of
//      those at once from the same priest is incoherent. Enforced
//      here rather than client-side because a second-device tap
//      could race past a client check.
//
//   3. The fanout of in-app inbox docs + call-like pushes to every
//      active registrant. Firestore rules deny client-side
//      notifications.create, so this MUST happen with the Admin
//      SDK or registrants never hear that the session went live.
//
// Returns {notified, status} so the priest UI can surface the count
// in the success snackbar ("Notified N registrants").
export const startBibleSession = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const callerUid = request.auth.uid;
    const {sessionId} = request.data as {sessionId?: string};

    if (!sessionId || typeof sessionId !== "string") {
      throw new HttpsError("invalid-argument", "sessionId required");
    }

    const sessionRef = db.doc(`bible_sessions/${sessionId}`);

    // Read the session ONCE outside the transaction so we have the
    // metadata (title, priestName, price) available for the fanout
    // below. The transaction below re-reads to enforce the
    // precondition atomically — it doesn't trust this initial read
    // for the status check.
    const sessionSnap = await sessionRef.get();
    if (!sessionSnap.exists) {
      throw new HttpsError("not-found", "Session not found");
    }
    const session = sessionSnap.data() ?? {};
    if (session.priestId !== callerUid) {
      throw new HttpsError(
        "permission-denied",
        "You don't own this session",
      );
    }
    const meetingLink =
      typeof session.meetingLink === "string"
        ? (session.meetingLink as string)
        : "";
    if (meetingLink === "") {
      throw new HttpsError(
        "failed-precondition",
        "Add a meeting link before starting the session",
      );
    }

    // Atomic precondition + flip. Wrapping in a transaction kills
    // the TOCTOU window between the live-check and the status
    // update: two simultaneous Start taps on different devices used
    // to both pass the live-check, both promote to live, and both
    // fire the fanout — every registrant got duplicate pushes /
    // inbox docs / call-overlays. The tx forces the loser to
    // re-read and see status='live', which throws
    // failed-precondition.
    //
    // The cross-session "one live per priest" lookup is a
    // single-document query NOT under the tx (Firestore tx reads
    // can't run general where-queries). We re-read it inside the tx
    // immediately before the flip, accepting a much tighter race
    // window (sub-millisecond) than the original
    // read-then-update gap.
    // Compute the lock deadline up front. We use Date.now() (the CF
    // runtime's wall clock) rather than serverTimestamp because we
    // need an actual Timestamp value to write into the priest doc,
    // not a sentinel. The skew between Date.now() and the actual
    // server-stamped startedAt is sub-millisecond — negligible
    // against the session duration.
    //
    // bibleSessionLockedUntil is the safety-net deadline read by
    // SpeakerModel.isInBibleSession on the client AND by
    // createSessionRequest on the server. If everything else fails,
    // once this timestamp passes the priest is automatically treated
    // as released, so a stuck `liveBibleSessionId` can never block
    // them permanently.
    const durationMinRaw = session.durationMinutes as number | undefined;
    const durationMin =
      typeof durationMinRaw === "number" && Number.isFinite(durationMinRaw)
        ? Math.max(1, Math.round(durationMinRaw))
        : 60;
    const lockedUntilMs =
      Date.now() + durationMin * 60 * 1000;
    const lockedUntil = admin.firestore.Timestamp.fromMillis(lockedUntilMs);
    const priestRef = db.doc(`priests/${callerUid}`);

    try {
      await db.runTransaction(async (tx) => {
        const fresh = await tx.get(sessionRef);
        const data = fresh.data() ?? {};
        if (data.status !== "upcoming") {
          throw new HttpsError(
            "failed-precondition",
            `Cannot start a ${data.status} session`,
          );
        }

        const liveCheck = await db
          .collection("bible_sessions")
          .where("priestId", "==", callerUid)
          .where("status", "==", "live")
          .limit(1)
          .get();
        if (!liveCheck.empty) {
          throw new HttpsError(
            "failed-precondition",
            "You already have a live session. " +
              "Complete it before starting another.",
          );
        }

        tx.update(sessionRef, {
          status: "live",
          startedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        // Atomic with the status flip — either both writes commit
        // or neither. This is what makes the lock bulletproof: a
        // live session and a held priest-doc lock can never exist
        // in disagreement.
        //
        // We write to priests/{callerUid} (not just the session) so
        // every UI surface that already reads the priest doc
        // (priest cards, profile, all-speakers list) picks up the
        // "in bible session" state without any extra Firestore
        // reads. createSessionRequest also reads this doc on every
        // ring, so the server-side ring gate is one cheap check
        // away.
        tx.update(priestRef, {
          liveBibleSessionId: sessionId,
          bibleSessionLockedUntil: lockedUntil,
        });
      });
    } catch (err) {
      // Re-throw HttpsError verbatim; wrap anything else.
      if (err instanceof HttpsError) throw err;
      throw new HttpsError(
        "internal",
        "Could not start session — please try again",
      );
    }

    // Fanout — every active registrant gets:
    //   • inbox doc (source of truth, survives push failure)
    //   • call-like OS push ("session is LIVE — join now")
    // Filter cancelled in code so we stay on single-field queries.
    const regsSnap = await db
      .collection(`bible_sessions/${sessionId}/registrations`)
      .get();
    const activeRegs = regsSnap.docs.filter(
      (d) => d.data().status !== "cancelled",
    );

    const title = String(session.title ?? "Bible Session");
    const priestName = String(session.priestName ?? "Speaker");
    const price = Number(session.price ?? 0);

    let notified = 0;
    const inboxBody =
      `"${title}" by ${priestName} is starting now! ` +
      `Pay ₹${price} to join.`;
    const pushBody = `"${title}" is starting — join now!`;

    for (let i = 0; i < activeRegs.length; i += FANOUT_CHUNK_SIZE) {
      const chunk = activeRegs.slice(i, i + FANOUT_CHUNK_SIZE);

      const batch = db.batch();
      for (const reg of chunk) {
        const notifRef = db.collection("notifications").doc();
        batch.set(notifRef, {
          userId: reg.id,
          type: "bible_session_live",
          title: "🕊️ Session is LIVE",
          body: inboxBody,
          sessionId,
          priestId: callerUid,
          data: {sessionId},
          isRead: false,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
      }
      try {
        await batch.commit();
      } catch (err) {
        // The status flip has already landed; if the inbox batch
        // fails mid-fanout, the pushes below still surface the news
        // and the user can refresh the detail page. We deliberately
        // do NOT roll back the status — the session is genuinely
        // live and the priest is on the call.
        console.error(
          "[startBibleSession] notif batch failed for " +
            `${sessionId} (chunk start=${i}):`,
          err,
        );
      }

      await Promise.all(
        chunk.map(async (doc) => {
          notified++;
          await sendPushNotification({
            userId: doc.id,
            title: "🕊️ Session is LIVE",
            body: pushBody,
            data: {
              type: "bible_session_live",
              sessionId,
              priestName,
              sessionTitle: title,
              price: String(price),
              route: `/bible/detail/${sessionId}`,
            },
          });
        }),
      );
    }

    return {notified, status: "live"};
  },
);
