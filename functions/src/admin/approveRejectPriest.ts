// Admin moderation for speaker applications.
//
// Handles all four admin actions in one callable:
//   approve   — pending → approved, notifies priest
//   reject    — pending → rejected, writes rejectionReason, notifies
//   suspend   — approved → suspended, notifies
//   unsuspend — suspended → approved, notifies
//
// All four need identical guard rails (admin-only, status transition
// validation, audit trail, notification) so sharing one callable
// keeps the contract in one place.  Using one function also means the
// client's repository can treat "what the admin can do to a priest"
// as a single surface.
//
// We bypass Firestore rules via the Admin SDK deliberately — the
// caller's admin role is verified at the top of the function, which
// is safer than trying to express this with declarative rules
// (admin writes to *other* users' documents cut against the normal
// "owner-only write" pattern we use everywhere else).

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

type Action = "approve" | "reject" | "suspend" | "unsuspend";

export const approveRejectPriest = onCall(
  {region: REGION},
  async (request) => {
    // ── 1. Authentication ──
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }
    const callerUid = request.auth.uid;

    // ── 2. Admin authorisation ──
    // Pull the caller's user doc; refuse unless role === "admin".
    // A missing user doc is treated as non-admin.
    const callerSnap = await db.doc(`users/${callerUid}`).get();
    if (!callerSnap.exists || callerSnap.data()?.role !== "admin") {
      throw new HttpsError(
        "permission-denied",
        "Only admins can moderate speaker applications"
      );
    }

    // ── 3. Input validation ──
    const data = request.data ?? {};
    const priestId: string | undefined = data.priestId;
    const action: string | undefined = data.action;
    const rejectionReason: string | undefined = data.rejectionReason;

    if (!priestId || typeof priestId !== "string") {
      throw new HttpsError("invalid-argument", "priestId is required");
    }

    const validActions: Action[] = [
      "approve",
      "reject",
      "suspend",
      "unsuspend",
    ];
    if (!action || !validActions.includes(action as Action)) {
      throw new HttpsError(
        "invalid-argument",
        "action must be approve, reject, suspend, or unsuspend"
      );
    }

    const typedAction = action as Action;

    if (typedAction === "reject") {
      if (
        !rejectionReason ||
        typeof rejectionReason !== "string" ||
        rejectionReason.trim().length < 10
      ) {
        throw new HttpsError(
          "invalid-argument",
          "Rejection reason must be at least 10 characters"
        );
      }
    }

    // ── 4. Fetch priest + check current status ──
    const priestRef = db.doc(`priests/${priestId}`);
    const priestSnap = await priestRef.get();

    if (!priestSnap.exists) {
      throw new HttpsError("not-found", "Speaker not found");
    }

    const currentStatus =
      (priestSnap.data()?.status as string | undefined) ?? "pending";

    // State machine: reject/approve require pending; suspend requires
    // approved; unsuspend requires suspended.  Anything else is a
    // programming error in the admin client we want to catch loudly.
    const allowedTransitions: Record<Action, string[]> = {
      approve: ["pending"],
      reject: ["pending"],
      suspend: ["approved"],
      unsuspend: ["suspended"],
    };

    if (!allowedTransitions[typedAction].includes(currentStatus)) {
      throw new HttpsError(
        "failed-precondition",
        `Cannot ${typedAction} a speaker whose status is "${currentStatus}"`
      );
    }

    // ── 5. Compute target status + update ──
    let newStatus: string;
    switch (typedAction) {
      case "approve":
        newStatus = "approved";
        break;
      case "reject":
        newStatus = "rejected";
        break;
      case "suspend":
        newStatus = "suspended";
        break;
      case "unsuspend":
        newStatus = "approved";
        break;
    }

    const updateData: Record<string, unknown> = {
      status: newStatus,
      reviewedBy: callerUid,
      reviewedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    if (typedAction === "reject" && rejectionReason) {
      updateData.rejectionReason = rejectionReason.trim();
    }

    if (typedAction === "suspend") {
      updateData.suspendedAt = admin.firestore.FieldValue.serverTimestamp();
    }

    if (typedAction === "unsuspend") {
      // Wipe the suspension timestamp so the audit trail doesn't
      // look like the priest is still suspended when queried later.
      updateData.suspendedAt = admin.firestore.FieldValue.delete();
    }

    await priestRef.update(updateData);

    // ── 6. Notify the priest ──
    // Best-effort — a failed notification should not cause the whole
    // moderation action to roll back, so this is in its own try.
    const notification = buildNotification(typedAction, rejectionReason);
    try {
      await db.collection("notifications").add({
        userId: priestId,
        ...notification,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (err) {
      console.error(
        `[approveRejectPriest] Notification failed for ${priestId}:`,
        err
      );
    }

    // ── 7. Push to the priest's device(s). Approve routes them to
    //      the activation flow; everything else lands them on the
    //      dashboard where the new status is reflected.
    await sendPushNotification({
      userId: priestId,
      title: notification.title,
      body: notification.body,
      data: {
        type: notification.type,
        route: typedAction === "approve" ? "/priest/activation" : "/priest",
      },
    });

    return {
      success: true,
      newStatus,
    };
  }
);

// Keeps notification copy out of the big switch above.
function buildNotification(
  action: Action,
  rejectionReason?: string
): {type: string; title: string; body: string} {
  switch (action) {
    case "approve":
      return {
        type: "application_approved",
        title: "Application Approved!",
        body:
          "Your speaker application has been approved. " +
          "Complete activation to start accepting sessions.",
      };
    case "reject":
      return {
        type: "application_rejected",
        title: "Application Update",
        body:
          "Your application was not approved. Reason: " +
          (rejectionReason ?? "Not specified"),
      };
    case "suspend":
      return {
        type: "account_suspended",
        title: "Account Suspended",
        body:
          "Your speaker account has been suspended. " +
          "Please contact support for details.",
      };
    case "unsuspend":
      return {
        type: "account_reactivated",
        title: "Account Reactivated",
        body:
          "Your speaker account has been reactivated. " +
          "You can now accept sessions again.",
      };
  }
}
