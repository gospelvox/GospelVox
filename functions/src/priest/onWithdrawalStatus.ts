// Firestore trigger that keeps the priest informed at every step of a
// withdrawal — the transparency backbone of the rebuild. Whenever the
// admin advances a withdrawal's status, this writes the priest an
// in-app notification (+ best-effort push) describing exactly what
// happened, including the bank reference once the payout is sent.
//
// Why a trigger (not a callable from the admin client):
//   The admin marks status with a direct, rules-checked write. But the
//   notifications collection is create-only from the admin SDK
//   (clients can't write it by rules), so the priest-facing message
//   has to originate server-side. Reacting to the status change keeps
//   the admin write and the notification decoupled and reliable.
//
// Fires only on a real status transition. The "pending" creation
// already sends its own "submitted" notice from requestWithdrawal, so
// this skips pending and only speaks for processing / paid / on_hold /
// blocked.

import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

// ₹ for INR (or unspecified legacy rows); a currency-code prefix
// otherwise. Matches the priest status screen's own formatting.
function formatAmount(amount: number, currency: string): string {
  if (!currency || currency === "INR") return `₹${amount}`;
  return `${currency} ${amount}`;
}

export const onWithdrawalStatus = onDocumentUpdated(
  {document: "withdrawals/{withdrawalId}", region: REGION},
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    // Only react to an actual status change.
    if (before.status === after.status) return;

    const priestId = after.priestId as string | undefined;
    if (!priestId) return;

    const amount = Number(after.amount ?? 0);
    const currency = (after.currency as string | undefined) ?? "";
    const money = formatAmount(amount, currency);
    const reference =
      (after.paymentReference as string | undefined)?.trim();
    const reason = (after.onHoldReason as string | undefined)?.trim();

    let type: string;
    let title: string;
    let body: string;

    switch (after.status) {
      case "processing":
        // A reverse (paid -> processing) is the admin's "marked Sent by
        // mistake" recovery — the priest just saw "Sent", so explain the
        // correction instead of "we're preparing it".
        if (before.status === "paid") {
          type = "withdrawal_reverted";
          title = "Withdrawal back in processing";
          body =
            `A correction was made to your ${money} withdrawal — it's ` +
            "back in processing and will be sent again shortly.";
        } else {
          type = "withdrawal_processing";
          title = "Withdrawal is being processed";
          body =
            `We're preparing your ${money} payout and sending it to ` +
            "your bank.";
        }
        break;
      case "paid":
        type = "withdrawal_sent";
        title = "Withdrawal sent";
        body = reference ?
          `${money} has been sent to your bank. Reference: ` +
            `${reference}. If you haven't received it, contact your ` +
            "bank with this reference." :
          `${money} has been sent to your bank.`;
        break;
      case "on_hold":
        type = "withdrawal_on_hold";
        title = "Action needed on your withdrawal";
        body = reason ?
          `Your ${money} withdrawal is on hold: ${reason}. Please ` +
            "check and update your bank details." :
          `Your ${money} withdrawal is on hold. Please check and ` +
            "update your bank details.";
        break;
      case "blocked":
        type = "withdrawal_cancelled";
        title = "Withdrawal cancelled";
        body =
          `Your ${money} withdrawal was cancelled and the amount was ` +
          "refunded to your wallet.";
        break;
      default:
        // pending or any unrecognised status — nothing to announce.
        return;
    }

    // The in-app inbox doc is the source of truth (push is best-effort,
    // mirroring sendPush's contract). Note `userId: priestId` — the
    // notifications rules let a priest read rows keyed by their uid.
    try {
      await db.collection("notifications").add({
        userId: priestId,
        type,
        title,
        body,
        withdrawalId: event.params.withdrawalId,
        isRead: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch (err) {
      console.error(
        `[onWithdrawalStatus] Inbox write failed for ${priestId}:`,
        err,
      );
    }

    try {
      await sendPushNotification({
        userId: priestId,
        title,
        body,
        data: {type, route: "/priest/withdrawals"},
      });
    } catch {
      // sendPushNotification swallows internally.
    }
  },
);
