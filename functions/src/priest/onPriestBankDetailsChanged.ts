// When a priest CORRECTS their bank details, propagate the fix to any
// of their ON-HOLD withdrawals so the admin actually sees the change.
//
// The problem this solves:
//   A withdrawal snapshots the bank details at request time. If the
//   admin puts it on hold ("wrong account number") and the priest then
//   fixes their bank details, that edit only touches priests/{uid} —
//   the on-hold withdrawal still carries the OLD snapshot and is still
//   "on_hold", so the admin has no signal and, if they look, sees the
//   stale account. The priest "corrected and submitted" but nothing
//   changed on the admin side.
//
// What this does on a bank-field change:
//   • re-snapshots the corrected bank/contact fields onto every
//     on_hold withdrawal of that priest, and
//   • moves them back to "pending" so they re-enter the admin's Pending
//     queue (the clear signal that they're fixed and ready to retry).
//   Money stays debited throughout (on_hold never refunded), so nothing
//   about the balance changes — only where it will be sent.
//
// No notification fires: onWithdrawalStatus ignores the ->pending
// transition, which is correct (the priest already knows they fixed it).

import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";

const db = admin.firestore();

// Fields whose change should trigger a re-snapshot.
const WATCHED = [
  "bankAccountName", "bankAccountNumber", "bankIfscCode", "bankName",
  "bankAccountType", "bankRoutingNumber", "bankSortCode", "bankIban",
  "bankSwiftBic", "bankCountry", "bankCurrency", "upiId",
  "bankContactPhone", "bankContactEmail", "phone", "email",
];

export const onPriestBankDetailsChanged = onDocumentUpdated(
  {document: "priests/{priestId}", region: REGION},
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    // Cheap early-out for the (frequent) non-bank priest updates.
    const changed = WATCHED.some((f) => before[f] !== after[f]);
    if (!changed) return;

    const priestId = event.params.priestId;

    // Single-field query (no composite index); filter status in code.
    const snap = await db
      .collection("withdrawals")
      .where("priestId", "==", priestId)
      .get();
    const onHold = snap.docs.filter((d) => d.data().status === "on_hold");
    if (onHold.length === 0) return;

    // The corrected snapshot — same shape requestWithdrawal writes.
    const snapshot = {
      bankAccountName: after.bankAccountName ?? "",
      bankAccountNumber: after.bankAccountNumber ?? "",
      bankIfscCode: after.bankIfscCode ?? "",
      bankName: after.bankName ?? "",
      bankAccountType: after.bankAccountType ?? "",
      bankRoutingNumber: after.bankRoutingNumber ?? "",
      bankSortCode: after.bankSortCode ?? "",
      bankIban: after.bankIban ?? "",
      bankSwiftBic: after.bankSwiftBic ?? "",
      bankCountry: after.bankCountry ?? "IN",
      currency: after.bankCurrency ?? "",
      upiId: after.upiId ?? "",
      bankContactPhone: after.bankContactPhone ?? after.phone ?? "",
      bankContactEmail: after.bankContactEmail ?? after.email ?? "",
    };

    const batch = db.batch();
    for (const doc of onHold) {
      batch.update(doc.ref, {
        ...snapshot,
        // Back into the admin queue, with the hold cleared.
        status: "pending",
        onHoldReason: admin.firestore.FieldValue.delete(),
        resubmittedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  },
);
