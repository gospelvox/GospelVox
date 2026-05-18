// Firestore trigger that notifies a reported priest AFTER admin has
// reviewed the complaint against them.
//
// What the priest sees: a sanitized "your account was reviewed by
// admin — outcome: resolved" notice. No reporter identity, no raw
// description, no admin notes. The full context lives only on the
// admin side. This is deliberate — exposing the reporter to the
// reported priest would create a retaliation risk that defeats the
// point of the report queue.
//
// Trigger condition: status flips pending → resolved AND the
// reported party is actually a priest (checked via priests/{uid}
// existence). A user-against-user report skips this branch.

import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

export const onReportResolved = onDocumentUpdated(
  {document: "reports/{reportId}", region: REGION},
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    // Only react to the specific transition into resolved. Any other
    // edit (admin updating notes, re-opening, etc) is a no-op here.
    if (before.status === after.status) return;
    if (after.status !== "resolved") return;

    const reportedUid = after.reportedUser as string | undefined;
    if (!reportedUid) return;

    // Only notify when the reported party is a priest. We make this
    // call explicitly rather than infer from the report shape — the
    // reports collection is a generic ledger; users-against-users
    // can show up here too, and we don't want to ping a regular
    // user with the "your account was reviewed" notice.
    const priestSnap = await db.doc(`priests/${reportedUid}`).get();
    if (!priestSnap.exists) return;

    const title = "A complaint was reviewed";
    const body =
      "Admin reviewed a complaint involving your account. " +
      "Outcome: resolved. Contact support if you need more detail.";

    try {
      await db.collection("notifications").add({
        userId: reportedUid,
        type: "report_resolved",
        title,
        body,
        reportId: event.params.reportId,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (err) {
      console.error(
        `[onReportResolved] Inbox write failed for ${reportedUid}:`,
        err
      );
    }

    try {
      await sendPushNotification({
        userId: reportedUid,
        title,
        body,
        data: {
          type: "report_resolved",
          route: "/priest/notifications",
        },
      });
    } catch {
      // sendPushNotification swallows internally.
    }
  }
);
