// Firestore trigger: a user filed a report (reports/{id} is created
// client-side; there is no callable in the report path). Alerts every
// admin so the moderation queue isn't something they have to remember
// to pull-to-refresh to discover.
//
// onDocumentCreated (not onWritten) keeps this cheap — it fires once,
// when the report lands, and never on the later status edits the admin
// themselves make when resolving it.

import {onDocumentCreated} from "firebase-functions/v2/firestore";
import {REGION} from "../config/constants";
import {notifyAdmins} from "./notifyAdmins";

export const onReportCreated = onDocumentCreated(
  {document: "reports/{reportId}", region: REGION},
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const reporter = (data.reporterName as string | undefined)?.trim();
    const reported = (data.reportedUserName as string | undefined)?.trim();

    await notifyAdmins({
      type: "admin_new_report",
      title: "New report filed",
      body:
        `${reporter && reporter.length > 0 ? reporter : "A user"} reported ` +
        `${reported && reported.length > 0 ? reported : "a speaker"}. ` +
        "Tap to review.",
      route: "/admin/reports",
      // event.id is stable across at-least-once retries of THIS event,
      // so a retry can't double-alert; distinct reports get distinct
      // event ids and each alerts once.
      dedupeKey: event.id,
      data: {reportId: event.params.reportId},
    });
  }
);
