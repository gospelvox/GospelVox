import {onCall, HttpsError} from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import {REGION} from "../config/constants";

const db = admin.firestore();

// Single source of truth for create-time validation. Replaces the
// previous direct-from-client Firestore write so we can enforce:
//
//   1. Server-validated input shape (title length, description
//      length, duration whitelist, price band ₹49–₹499). Same
//      checks the client form already enforces — the CF is the
//      authoritative copy in case a tampered client tries to slip
//      past them.
//
//   2. Overlap detection against the priest's existing UPCOMING +
//      LIVE sessions. The priest UI prevents most accidental
//      double-booking by hiding the create CTA, but two near-
//      simultaneous taps from different devices, or a session
//      created on day 1 that wasn't started by day 2 when the
//      priest tries to schedule another, both need a server-side
//      block. Overlap math is `newStart < existEnd && newEnd >
//      existStart` (the canonical half-open-interval intersection),
//      where each end = start + durationMinutes.
//
//   3. Approved + activated priest check. Firestore rules already
//      enforce this on the direct write, but the CF call goes
//      through the Admin SDK (rules bypass), so we re-check here
//      to keep the same guarantee.
//
// Returns {sessionId} so the client can navigate / link to the
// freshly-created session without a second read.
export const createBibleSession = onCall(
  {region: REGION},
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Must be logged in");
    }
    const priestUid = request.auth.uid;

    const data = request.data as {
      title?: string;
      description?: string;
      category?: string;
      scheduledAt?: string;
      durationMinutes?: number;
      price?: number;
      maxParticipants?: number;
      meetingLink?: string;
      priestName?: string;
      priestPhotoUrl?: string;
    };

    // ── 1. Input validation ─────────────────────────────────────
    const title = (data.title ?? "").trim();
    const description = (data.description ?? "").trim();
    const category = (data.category ?? "").trim();
    const scheduledAtRaw = data.scheduledAt ?? "";
    const durationMinutes = Number(data.durationMinutes ?? 0);
    const price = Number(data.price ?? 0);
    const maxParticipants = Number(data.maxParticipants ?? 0);
    const meetingLink = (data.meetingLink ?? "").trim();

    if (title.length < 5 || title.length > 100) {
      throw new HttpsError(
        "invalid-argument",
        "Title must be 5–100 characters",
      );
    }
    if (description.length < 20 || description.length > 300) {
      throw new HttpsError(
        "invalid-argument",
        "Description must be 20–300 characters",
      );
    }
    if (category === "") {
      throw new HttpsError("invalid-argument", "Category is required");
    }
    if (![30, 45, 60, 90, 120].includes(durationMinutes)) {
      throw new HttpsError(
        "invalid-argument",
        "Duration must be 30, 45, 60, 90, or 120 minutes",
      );
    }
    if (!Number.isInteger(price) || price < 49 || price > 499) {
      throw new HttpsError(
        "invalid-argument",
        "Price must be between ₹49 and ₹499",
      );
    }
    if (!Number.isInteger(maxParticipants) || maxParticipants < 0) {
      throw new HttpsError(
        "invalid-argument",
        "Max participants must be 0 (unlimited) or a positive integer",
      );
    }
    if (meetingLink !== "" && !meetingLink.startsWith("https://")) {
      throw new HttpsError(
        "invalid-argument",
        "Meeting link must start with https://",
      );
    }

    // Client sends an ISO-8601 string (toUtc().toIso8601String()).
    // Parse explicitly so a malformed payload throws here instead
    // of being treated as an "invalid date" Timestamp later.
    const startTime = new Date(scheduledAtRaw);
    if (Number.isNaN(startTime.getTime())) {
      throw new HttpsError(
        "invalid-argument",
        "Invalid scheduled date",
      );
    }
    if (startTime.getTime() < Date.now()) {
      throw new HttpsError(
        "invalid-argument",
        "Scheduled time must be in the future",
      );
    }
    const endTime = new Date(
      startTime.getTime() + durationMinutes * 60 * 1000,
    );

    // ── 2. Priest must be approved + activated ──────────────────
    const priestDoc = await db.doc(`priests/${priestUid}`).get();
    if (!priestDoc.exists) {
      throw new HttpsError(
        "not-found",
        "Priest profile not found",
      );
    }
    const priestData = priestDoc.data() ?? {};
    if (priestData.status !== "approved") {
      throw new HttpsError(
        "permission-denied",
        "Your priest profile is not approved yet",
      );
    }
    if (priestData.isActivated !== true) {
      throw new HttpsError(
        "permission-denied",
        "Your account is not activated",
      );
    }

    // ── 3. Overlap detection ────────────────────────────────────
    // Single-field equality on priestId + status `in` clause keeps
    // us inside the auto-index. Filtering by 'upcoming' OR 'live'
    // — but NOT 'cancelled' or 'completed' — because a terminal
    // session no longer occupies a slot. The where-in clause caps
    // at 30 values per Firestore limits; we have 2.
    const existingSnap = await db
      .collection("bible_sessions")
      .where("priestId", "==", priestUid)
      .where("status", "in", ["upcoming", "live"])
      .get();

    for (const doc of existingSnap.docs) {
      const existing = doc.data();
      const existStartTs =
        existing.scheduledAt as admin.firestore.Timestamp | undefined;
      const existStart = existStartTs?.toDate();
      if (!existStart) continue;
      const existDuration = Number(existing.durationMinutes ?? 60);
      const existEnd = new Date(
        existStart.getTime() + existDuration * 60 * 1000,
      );

      // Half-open interval intersection — two windows [aStart,aEnd)
      // and [bStart,bEnd) overlap iff aStart < bEnd && bStart < aEnd.
      if (startTime < existEnd && endTime > existStart) {
        const existTitle = String(existing.title ?? "another session");
        const existWhen = existStart.toLocaleString("en-IN", {
          timeZone: "Asia/Kolkata",
          dateStyle: "medium",
          timeStyle: "short",
        });
        throw new HttpsError(
          "already-exists",
          `This time overlaps with "${existTitle}" at ${existWhen}. ` +
            "Please choose a different time.",
        );
      }
    }

    // ── 4. Create ───────────────────────────────────────────────
    // Fields with defaults from the priest doc when the client
    // didn't supply them. The CF is the authoritative writer, so
    // anything the client sends for priestName/priestPhotoUrl is
    // accepted but falls back to the priests/{uid} doc on miss.
    const sessionRef = db.collection("bible_sessions").doc();
    await sessionRef.set({
      priestId: priestUid,
      priestName:
        (data.priestName ?? "").trim() !== ""
          ? data.priestName
          : String(priestData.fullName ?? ""),
      priestPhotoUrl:
        (data.priestPhotoUrl ?? "") !== ""
          ? data.priestPhotoUrl
          : String(priestData.photoUrl ?? ""),
      title,
      description,
      category,
      scheduledAt: admin.firestore.Timestamp.fromDate(startTime),
      durationMinutes,
      price,
      maxParticipants,
      meetingLink,
      status: "upcoming",
      registrationCount: 0,
      remindersSent: {},
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return {sessionId: sessionRef.id};
  },
);
