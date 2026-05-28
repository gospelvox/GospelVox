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

    // Two parallel reads:
    //   1. chat/voice ratings from the flat `sessions` collection.
    //   2. bible-session ratings denormalised onto the priest doc's
    //      `recentReviews` array by the onBibleSessionRated trigger.
    // We merge both and apply the same sort + limit so a busy priest
    // who runs lots of bible sessions doesn't lose chat reviews from
    // the visible window (and vice versa).
    const [sessionsSnap, priestSnap] = await Promise.all([
      db
        .collection("sessions")
        .where("priestId", "==", priestId)
        .limit(SESSION_SCAN_LIMIT)
        .get(),
      db.doc(`priests/${priestId}`).get(),
    ]);

    type Row = {
      id: string;
      data: FirebaseFirestore.DocumentData;
    };

    const sessionRows: Row[] = sessionsSnap.docs
      .map((d) => ({id: d.id, data: d.data()}))
      .filter((r) => typeof r.data.userRating === "number");

    // Bible review rows come from priests/{id}.recentReviews entries
    // where source == "bible". Each entry already carries userName,
    // userPhotoUrl, rating, feedback, endedAt — close enough to a
    // session doc that we adapt the field names below and reuse the
    // shared sort + projection path.
    const bibleEntries =
      (priestSnap.exists
        ? (priestSnap.data()?.recentReviews as
            | Array<Record<string, unknown>>
            | undefined) ?? []
        : []
      ).filter((e) => e?.source === "bible");

    const bibleRows: Row[] = bibleEntries.map((e) => {
      // The bible mirror stores priestReply as a flat string (the
      // replyToReview CF writes `priestReply: text` onto the
      // recentReviews entry). Wrap it back into the {text} shape that
      // the projection reads, so bible and chat/voice rows take the
      // exact same code path below.
      const replyText = ((e.priestReply as string | undefined) ?? "").trim();
      return {
        id: String(e.sessionId ?? `bible_${e.bibleSessionId ?? "unknown"}`),
        data: {
          userRating: e.rating,
          userFeedback: e.feedback,
          userName: e.userName,
          userPhotoUrl: e.userPhotoUrl,
          endedAt: e.endedAt,
          priestReply: replyText.length > 0 ? {text: replyText} : undefined,
        },
      };
    });

    const allRows: Row[] = [...sessionRows, ...bibleRows];

    // Sort: written feedback first (most informative as a preview),
    // then newest-first within each group.
    const endedAtMs = (data: FirebaseFirestore.DocumentData): number => {
      const ended = data.endedAt as admin.firestore.Timestamp | undefined;
      if (ended && typeof ended.toMillis === "function") {
        return ended.toMillis();
      }
      const created = data.createdAt as
        | admin.firestore.Timestamp
        | undefined;
      if (created && typeof created.toMillis === "function") {
        return created.toMillis();
      }
      return 0;
    };
    const hasText = (data: FirebaseFirestore.DocumentData): boolean => {
      const t = (data.userFeedback as string | undefined) ?? "";
      return t.trim().length > 0;
    };

    allRows.sort((a, b) => {
      const wa = hasText(a.data) ? 0 : 1;
      const wb = hasText(b.data) ? 0 : 1;
      if (wa !== wb) return wa - wb;
      return endedAtMs(b.data) - endedAtMs(a.data);
    });

    const reviews: PublicReview[] = allRows.slice(0, limit).map((r) => {
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
      const endedIso =
        ended && typeof ended.toDate === "function"
          ? ended.toDate().toISOString()
          : null;
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
        endedAt: endedIso,
        priestReply: replyText.length > 0 ? replyText : null,
      };
    });

    return {reviews, total: allRows.length};
  }
);
