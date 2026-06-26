// Shared post-credit logic for a successful coin purchase.
//
// Extracted from the old Razorpay-based verifyCoinPurchase so the
// new Play-billing path produces the SAME Firestore writes, the
// SAME notification copy, and the SAME push as before. The only
// observable difference is the wallet_transactions row carries the
// new {provider, purchaseToken, productId} fields via `ledgerExtra`.
//
// Atomicity guarantees (unchanged):
//   • Balance update + ledger row + inbox notification land in one
//     Firestore batch.commit(). A partial failure rolls all three
//     back together — the ledger row is what blocks idempotency
//     replays, so it must always agree with the balance.
//   • The OS-level push is fired AFTER the batch commits and is
//     best-effort: a push failure does not undo the credit.

import * as admin from "firebase-admin";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

export interface CreditCoinsArgs {
  uid: string;
  coins: number;
  packId: string;
  // The INR price recorded on the pack doc — used for the ledger
  // `amountPaid` field and the notification body so customer-facing
  // copy stays identical to the legacy Razorpay path. NOT the
  // user's actual local-currency Play charge, which we can't read
  // out of the Android Publisher API.
  amountPaidRupees: number;
  // Additional fields merged into the wallet_transactions row.
  // Used to stamp {provider:'play', purchaseToken, productId}
  // without forcing those into the function signature — keeps this
  // helper provider-agnostic if a future IAP path lands here too.
  ledgerExtra?: Record<string, unknown>;
  // The Play purchase token. When present we write a
  // `purchases/{purchaseToken}` doc via batch.create() as part of
  // the SAME atomic credit batch — its doc id IS the token, so two
  // concurrent calls carrying the same token cannot both commit:
  // the second create collides on the doc id and the whole batch
  // fails with ALREADY_EXISTS, leaving exactly one credit. This is
  // the deterministic dedupe the bare wallet_transactions query
  // (a non-atomic read) could not provide. Mirrors the
  // verifyActivationPurchase / verifyAndJoinBibleSession pattern.
  purchaseToken?: string;
}

export interface CreditCoinsResult {
  newBalance: number;
}

export async function creditCoins(
  args: CreditCoinsArgs,
): Promise<CreditCoinsResult> {
  const {
    uid,
    coins,
    packId,
    amountPaidRupees,
    ledgerExtra,
    purchaseToken,
  } = args;

  const batch = db.batch();

  // Atomic idempotency guard. batch.create() requires the doc to
  // NOT already exist; if a concurrent call already credited this
  // token, this create fails the entire batch (ALREADY_EXISTS), so
  // the balance is never incremented twice for one purchase. Doc id
  // IS the purchase token. Skipped only if no token was supplied
  // (keeps the helper usable by a non-Play caller).
  if (purchaseToken) {
    const purchaseRef = db.doc(`purchases/${purchaseToken}`);
    batch.create(purchaseRef, {
      userId: uid,
      kind: "coin_purchase",
      provider: "play",
      packId,
      coins,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  const userRef = db.doc(`users/${uid}`);
  batch.update(userRef, {
    coinBalance: admin.firestore.FieldValue.increment(coins),
  });

  const txRef = db.collection("wallet_transactions").doc();
  batch.set(txRef, {
    userId: uid,
    type: "purchase",
    packId,
    coins,
    amountPaid: amountPaidRupees,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    ...(ledgerExtra ?? {}),
  });

  const notifRef = db.collection("notifications").doc();
  batch.set(notifRef, {
    userId: uid,
    type: "coins_purchased",
    title: "Coins Added",
    body:
      `Your purchase of ${coins} coins for ₹${amountPaidRupees} ` +
      "is complete. Tap to open your wallet.",
    isRead: false,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  await batch.commit();

  const updatedUser = await userRef.get();
  const newBalance = Number(updatedUser.data()?.coinBalance ?? 0);

  // Push so the user sees the receipt even if the wallet page is
  // backgrounded after the Play sheet's redirect. Body includes the
  // new balance so the OS banner is self-explanatory without opening
  // the app — same numbers the in-app doc shows.
  await sendPushNotification({
    userId: uid,
    title: "Coins Added",
    body:
      `${coins} coins credited for ₹${amountPaidRupees}. ` +
      `Wallet balance: ${newBalance} coins.`,
    data: {
      type: "coins_purchased",
      route: "/user",
    },
  });

  return {newBalance};
}
