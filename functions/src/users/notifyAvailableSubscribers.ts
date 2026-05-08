// Pushes a "Speaker is now available" notification to every user
// who tapped "Notify me" on this priest's card while they were
// offline. Triggered on priests/{priestId} updates; we react only
// when isOnline genuinely flips false→true (skipping heartbeat
// refreshes and other field churn).
//
// Subscription storage:
//   users/{uid}.notifySubscriptions = [priestId, priestId, …]
// chosen over a dedicated subcollection because:
//   • The user's own update rule already permits arbitrary fields
//     except the small blocklist (coinBalance / role / walletBalance
//     / isActivated). notifySubscriptions is not in the blocklist,
//     so the client can write it without any rule changes.
//   • A subcollection would need its own rule and a composite
//     query to find subscribers; an array+`array-contains` works
//     index-free.
//
// Fire-once semantics: after pushing we arrayRemove the priestId
// from the user's array. If the user wants future ON events they
// can tap "Notify me" again — same pattern Tinder/Instagram use
// for "remind me when X is live". This avoids the ambiguity of
// "did my subscription get cleared by the previous fire or is it
// still live?" and keeps the array small.
//
// We deliberately skip the push if the priest is already busy on
// arrival (active session): claiming "they're available!" when
// the next dial would bounce with priest-busy is misleading.

import {onDocumentUpdated} from "firebase-functions/v2/firestore";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";
import {sendPushNotification} from "../notifications/sendPush";

const db = admin.firestore();

export const notifyAvailableSubscribers = onDocumentUpdated(
  {document: "priests/{priestId}", region: REGION},
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!before || !after) return;

    // Only react to a genuine "came online" transition. Heartbeat
    // ticks and isBusy flips share this trigger but should be
    // no-ops for this CF.
    const wentOnline =
      before.isOnline !== true && after.isOnline === true;
    if (!wentOnline) return;

    // If the priest came online INTO a busy state (e.g. created a
    // pending session at the same time, atypical but possible),
    // skip — the subscriber would just bounce off priest-busy.
    if (after.isBusy === true) return;

    const priestId = event.params.priestId;
    const priestName = (after.fullName as string | undefined) || "Speaker";

    // Find every user with this priest in their notify-list.
    // array-contains needs no composite index; subscriber counts
    // per priest are small enough that one query is plenty.
    const subscribersSnap = await db
      .collection("users")
      .where("notifySubscriptions", "array-contains", priestId)
      .get();

    if (subscribersSnap.empty) {
      console.log(
        `[notifyAvailableSubscribers] No subscribers for ${priestId}`
      );
      return;
    }

    console.log(
      `[notifyAvailableSubscribers] Pinging ${subscribersSnap.size} ` +
        `subscriber(s) that ${priestId} is available`
    );

    // Fan out push + clear in parallel. Each subscriber is
    // independent; the arrayRemove is atomic so concurrent updates
    // (e.g. user re-subscribes mid-fire) don't corrupt the array.
    const ops = subscribersSnap.docs.map(async (userDoc) => {
      const userId = userDoc.id;
      try {
        await sendPushNotification({
          userId: userId,
          title: `${priestName} is now available`,
          body: "Tap to start a session",
          data: {
            type: "priest_available",
            priestId: priestId,
            route: `/user/priest/${priestId}`,
          },
        });
      } catch (e) {
        console.error(
          `[notifyAvailableSubscribers] Push failed for ${userId}:`,
          e
        );
      }
      // Clear the subscription regardless of push success/failure.
      // Leaving it in place after a failed push would mean the
      // user gets pinged twice next time the priest cycles online.
      try {
        await userDoc.ref.update({
          notifySubscriptions:
            admin.firestore.FieldValue.arrayRemove(priestId),
        });
      } catch (e) {
        console.error(
          `[notifyAvailableSubscribers] Subscription clear failed for ${userId}:`,
          e
        );
      }
    });

    await Promise.all(ops);
  }
);
