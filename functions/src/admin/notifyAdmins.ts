// Fan-out helper: notifies EVERY admin of an admin-actionable event
// (a new report, a withdrawal request, a new speaker application, …).
//
// Why per-admin docs addressed to the admin's own uid:
//   The notifications read rule is `auth.uid == resource.data.userId`.
//   By writing one notification per admin with userId = that admin's
//   uid, each admin can read their own copy with NO rules change — it
//   reuses the exact model + rule the user/priest inboxes already use.
//
// Edge cases handled:
//   • No admin accounts found → logs a warning, returns (never throws).
//   • Admin lookup fails (transient Firestore error) → logged, returns;
//     the source CF still succeeds (an admin alert is best-effort).
//   • Duplicate event (Firestore triggers are at-least-once and can
//     retry) → deterministic doc id + create() makes the second write
//     a no-op ALREADY_EXISTS, so an admin is never double-notified and
//     a previously-read notification is never resurrected as unread.
//   • Push failure → swallowed inside sendPushNotification, per admin.
//
// `dedupeKey` MUST be stable for one logical event and unique across
// events. For Firestore triggers pass the trigger `event.id` (stable
// across retries of the same event). For a callable, pass the created
// doc id (e.g. the withdrawal id), which is unique per request.

import * as admin from "firebase-admin";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

interface AdminNotifyInput {
  type: string;
  title: string;
  body: string;
  // In-app deep link the admin inbox routes to on tap.
  route: string;
  // Idempotency key — see file header.
  dedupeKey: string;
  // Optional extra string fields stored on the doc + carried on push.
  data?: Record<string, string>;
}

export async function notifyAdmins(input: AdminNotifyInput): Promise<void> {
  let adminDocs: FirebaseFirestore.QueryDocumentSnapshot[];
  try {
    const snap = await db
      .collection("users")
      .where("role", "==", "admin")
      .get();
    adminDocs = snap.docs;
  } catch (err) {
    console.error("[notifyAdmins] admin lookup failed:", err);
    return;
  }

  if (adminDocs.length === 0) {
    // error-level (not warn): zero matching admins means EVERY admin
    // alert is being silently dropped — an operational outage worth an
    // alert, usually a mis-provisioned users/{adminUid}.role doc.
    console.error(
      `[notifyAdmins] no admin accounts (users where role=='admin') ` +
        `found; dropping "${input.type}"`
    );
    return;
  }

  // Sanitise the dedupe key for use inside a Firestore doc id (ids may
  // not contain '/'). Real keys (report/withdrawal ids, event ids) are
  // already safe; this is a belt-and-suspenders guard.
  const safeKey = input.dedupeKey.replace(/[^A-Za-z0-9_-]/g, "_");
  const extra = input.data ?? {};

  // The loop is intentionally sequential and assumes a SMALL admin set
  // (this app is single-admin / single-digit). If the admin role ever
  // fans out to dozens, switch the inbox writes to a BulkWriter +
  // Promise.allSettled pushes — O(N) serial round-trips would otherwise
  // grow the wall-clock and head-of-line-block later admins.
  for (const adminDoc of adminDocs) {
    const adminUid = adminDoc.id;
    const docId = `admin_${safeKey}_${adminUid}`;

    let created = false;
    try {
      // `...extra` is spread FIRST so caller data can NEVER clobber the
      // reserved fields below (a stray data:{userId:...} or isRead:"true"
      // would otherwise misroute the alert or break the unread query).
      await db.collection("notifications").doc(docId).create({
        ...extra,
        userId: adminUid,
        audience: "admin",
        type: input.type,
        title: input.title,
        body: input.body,
        route: input.route,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      created = true;
    } catch (err) {
      // 6 === gRPC Status.ALREADY_EXISTS — the canonical, version-stable
      // signal (Firestore's own SDK classifies errors by numeric code).
      // The message-substring match is kept only as a defensive fallback
      // in case a future SDK reworded it.
      const code = (err as {code?: number}).code;
      const msg = String((err as Error)?.message ?? err);
      if (code === 6 || msg.includes("ALREADY_EXISTS")) {
        // Duplicate/retried event — this admin was already notified.
        // Skip the push too so a retry can't re-ping their device.
        continue;
      }
      console.error(
        `[notifyAdmins] inbox write failed for admin ${adminUid}:`,
        err
      );
      continue;
    }

    if (created) {
      try {
        await sendPushNotification({
          userId: adminUid,
          title: input.title,
          body: input.body,
          // extra first so it can't override the routing keys either.
          data: {...extra, type: input.type, route: input.route},
        });
      } catch {
        // sendPushNotification never throws; this is just a guard.
      }
    }
  }
}
