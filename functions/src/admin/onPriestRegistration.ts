// Firestore trigger: a new speaker submitted their application. The
// registration repo writes priests/{uid} in a single .set() with
// status:'pending', so the first write to the doc IS the application —
// onDocumentCreated catches it.
//
// Why onDocumentCreated and NOT onDocumentWritten/onUpdated:
//   priests/{uid} is written on every heartbeat (lastHeartbeat / online
//   state). onDocumentWritten would bill an invocation on each of those
//   for every online speaker — pure waste. onDocumentCreated fires only
//   when the doc first appears, which is exactly the application moment.
//
// Edge note: a rejected speaker who later re-submits overwrites their
// existing doc (an update, not a create), so this trigger won't re-alert
// for that rare case — but they still surface in the admin dashboard's
// pending-speakers count. New applications (the dominant case) are fully
// covered.

import {onDocumentCreated} from "firebase-functions/v2/firestore";
import {REGION} from "../config/constants";
import {notifyAdmins} from "./notifyAdmins";

export const onPriestRegistration = onDocumentCreated(
  {document: "priests/{priestId}", region: REGION},
  async (event) => {
    const priestId = event.params.priestId;
    // The one-time seed script (scripts/seed-firestore.js) creates a
    // "_placeholder" doc to keep the collection non-empty on first
    // deploy — never a real application, so skip it.
    if (priestId === "_placeholder") return;

    const data = event.data?.data();
    if (!data) return;

    // Only a genuine pending application. A doc that somehow lands in
    // another status on create isn't an application awaiting review.
    if ((data.status as string | undefined) !== "pending") return;

    const name = (data.fullName as string | undefined)?.trim();

    await notifyAdmins({
      type: "admin_new_registration",
      title: "New speaker application",
      body:
        `${name && name.length > 0 ? name : "A new speaker"} applied to ` +
        "join. Tap to review their application.",
      route: "/admin/speakers",
      dedupeKey: event.id,
      data: {priestId},
    });
  }
);
