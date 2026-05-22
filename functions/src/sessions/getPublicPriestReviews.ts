// Callable that returns a priest's public reviews to any signed-in
// user.
//
// Why it exists: reviews are stored on session docs (sessions/{id}
// with userRating + userFeedback), and the Firestore rules restrict
// `sessions` reads to participants. So a different user opening a
// priest's profile cannot query the sessions collection — the read
// is rejected, and the Reviews section comes back empty.
//
// This function runs as the Firebase Admin (bypassing rules), reads
// the priest's rated sessions server-side, and returns a sanitised
// projection that contains only the public review fields. That makes
// it safe to expose to any caller: they see the same data they would
// see scrolling the priest's public profile anyway, but they can't
// pull any private session metadata via this endpoint.
//
// Auth: requires `request.auth` so anonymous traffic can't scrape
// reviews in bulk. Any signed-in app user can call it.

import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";

const db = admin.firestore();

// Hard cap so a single call can't ask for the entire history of a
// busy priest. 200 is well above any realistic profile preview.
const MAX_LIMIT = 200;
const DEFAULT_LIMIT = 50;

// How many session docs we scan before slicing — needs to be bigger
// than the limit because not every session has a userRating.
const SESSION_SCAN_LIMIT = 300;

interface PublicReview {
  sessionId: string;
  userName: string;
  userPhotoUrl: string;
  rating: number;
  feedback: string;
  endedAt: string | null;
  priestReply: string | null;
}

export const getPublicPriestReviews = onCall(
  {region: REGION},
  async (request): Promise<{reviews: PublicReview[]; total: number}> => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }

    const priestId = request.data?.priestId as string | undefined;
    if (!priestId || typeof priestId !== "string") {
      throw new HttpsError("invalid-argument", "Missing priestId");
    }

    const rawLimit = request.data?.limit as number | undefined;
    const limit = Math.min(
      MAX_LIMIT,
      Math.max(1, typeof rawLimit === "number" ? rawLimit : DEFAULT_LIMIT)
    );

    const snap = await db
      .collection("sessions")
      .where("priestId", "==", priestId)
      .limit(SESSION_SCAN_LIMIT)
      .get();

    const rated = snap.docs
      .map((d) => ({id: d.id, data: d.data()}))
      .filter((r) => typeof r.data.userRating === "number");

    // Sort: written feedback first (most informative as a preview),
    // then newest-first within each group.
    const endedAtMs = (data: FirebaseFirestore.DocumentData): number => {
      const ended = data.endedAt as admin.firestore.Timestamp | undefined;
      if (ended) return ended.toMillis();
      const created = data.createdAt as
        | admin.firestore.Timestamp
        | undefined;
      return created ? created.toMillis() : 0;
    };
    const hasText = (data: FirebaseFirestore.DocumentData): boolean => {
      const t = (data.userFeedback as string | undefined) ?? "";
      return t.trim().length > 0;
    };

    rated.sort((a, b) => {
      const wa = hasText(a.data) ? 0 : 1;
      const wb = hasText(b.data) ? 0 : 1;
      if (wa !== wb) return wa - wb;
      return endedAtMs(b.data) - endedAtMs(a.data);
    });

    const reviews: PublicReview[] = rated.slice(0, limit).map((r) => {
      const replyMap = r.data.priestReply as
        | {text?: string}
        | undefined;
      const replyText = (replyMap?.text ?? "").trim();
      const rating = Math.max(
        1,
        Math.min(5, r.data.userRating as number)
      );
      const ended = r.data.endedAt as
        | admin.firestore.Timestamp
        | undefined;
      return {
        sessionId: r.id,
        userName: (r.data.userName as string | undefined) ?? "",
        userPhotoUrl:
          (r.data.userPhotoUrl as string | undefined) ?? "",
        rating,
        feedback:
          ((r.data.userFeedback as string | undefined) ?? "").trim(),
        // ISO string is universal across clients; Flutter parses it
        // with DateTime.tryParse on the read path.
        endedAt: ended ? ended.toDate().toISOString() : null,
        priestReply: replyText.length > 0 ? replyText : null,
      };
    });

    return {reviews, total: rated.length};
  }
);
