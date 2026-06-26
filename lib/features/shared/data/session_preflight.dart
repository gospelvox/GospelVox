// Client-side gate that runs before /session/waiting is pushed.
// Fetches the user's current coin balance + admin-tunable rate and
// minSessionMinutes, computes the deficit, and either:
//   • returns true when the user can comfortably start a session
//     (balance ≥ ratePerMinute × minMinutes), or
//   • opens RechargeSheet pre-filled with the deficit copy and
//     returns false so the caller skips the navigation.
//
// Same check runs server-side in createSessionRequest as a backstop;
// this client check exists so the user gets an immediate, contextual
// "you need ₹X more to start" instead of a generic CF failure
// snackbar after a round-trip.
//
// Pages that already have balance + rate loaded (priest profile,
// chat history) can pass them in via the optional params — saves a
// redundant Firestore read on tap. Session detail, which loads
// neither, just calls without the optionals and pays one ~150ms
// fetch.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:gospel_vox/features/shared/widgets/recharge_sheet.dart';

const int _kFallbackChatRate = 10;
const int _kFallbackVoiceRate = 15;
const int _kFallbackMinMinutes = 5;

class SessionPreflight {
  // type must be 'chat' or 'voice' — same vocabulary createSessionRequest
  // uses, so picking the right rate field stays trivial.
  static Future<bool> check(
    BuildContext context, {
    required String type,
    required String priestName,
    int? prefetchedBalance,
    int? prefetchedRatePerMinute,
  }) async {
    final db = FirebaseFirestore.instance;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return false;

    int balance = prefetchedBalance ?? -1;
    int ratePerMinute = prefetchedRatePerMinute ?? -1;
    int minMinutes = _kFallbackMinMinutes;

    // Fan out only the reads we actually need. If both prefetched
    // values are passed, we still need settings for minMinutes — but
    // a single doc read is cheap.
    final List<Future<DocumentSnapshot<Map<String, dynamic>>>> futures = [];
    final needsBalance = balance < 0;
    final needsRate = ratePerMinute < 0;
    if (needsBalance) {
      futures.add(db.doc('users/$uid').get());
    }
    futures.add(db.doc('app_config/settings').get());

    try {
      final results = await Future.wait(
        futures,
      ).timeout(const Duration(seconds: 6));
      var idx = 0;
      if (needsBalance) {
        final userSnap = results[idx++];
        balance = (userSnap.data()?['coinBalance'] as num?)?.toInt() ?? 0;
      }
      final settingsSnap = results[idx];
      final settings = settingsSnap.data() ?? const <String, dynamic>{};
      if (needsRate) {
        final fallback = type == 'voice'
            ? _kFallbackVoiceRate
            : _kFallbackChatRate;
        ratePerMinute =
            (settings[type == 'voice'
                        ? 'voiceRatePerMinute'
                        : 'chatRatePerMinute']
                    as num?)
                ?.toInt() ??
            fallback;
      }
      minMinutes =
          (settings['minSessionMinutes'] as num?)?.toInt() ??
          _kFallbackMinMinutes;
    } catch (_) {
      // Read failed — let the server be the source of truth. The CF
      // will still enforce the gate; the worst case is the user sees
      // a generic "insufficient balance" instead of a contextual
      // sheet, which is exactly the pre-Fix-3 behaviour.
      return true;
    }

    final required = ratePerMinute * minMinutes;
    if (balance >= required) return true;

    final deficit = required - balance;
    if (!context.mounted) return false;

    // Show the same RechargeSheet the in-chat low-balance card
    // uses, with just the single deficit line as headline. Dropped
    // the verbose "Minimum balance: ₹X (for N minutes)" + the
    // "with $priestName" subtext — both were over-text since the
    // sheet's pack grid + balance pill already imply the action.
    await RechargeSheet.show(
      context,
      currentBalance: balance,
      infoHeadline: 'Add ₹$deficit more to start your session',
      // Keep the user in the start-session flow — the quick 4-pack grid
      // is enough; opening the full wallet here would route them to Home
      // on completion and abandon the session they're trying to begin.
      showSeeAllPlans: false,
    );

    if (!context.mounted) return false;

    // After the sheet closes, re-read the balance once. If a top-up
    // landed the user can proceed without a second tap.
    try {
      final userSnap = await db
          .doc('users/$uid')
          .get()
          .timeout(const Duration(seconds: 5));
      final newBalance =
          (userSnap.data()?['coinBalance'] as num?)?.toInt() ?? balance;
      return newBalance >= required;
    } catch (_) {
      return false;
    }
  }
}
