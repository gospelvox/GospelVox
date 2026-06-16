// Auth repository — handles Firebase Auth + Firestore role lookup

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'package:gospel_vox/core/services/notification_service.dart';
import 'package:gospel_vox/core/services/ring_service.dart';

// 15s for sign-in flows because OAuth provider round-trips can be slow on
// 3G networks (common in India). 10s for Firestore reads/writes since those
// hit our own backend with shorter latency.
const Duration _kAuthTimeout = Duration(seconds: 15);
const Duration _kFirestoreTimeout = Duration(seconds: 10);

class AuthRepository {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  User? get currentUser => _auth.currentUser;

  // Returns null when the user cancels the Google account chooser. The
  // previous implementation force-unwrapped `googleUser!`, throwing a
  // NullCheckError that the cubit's cancel-detection regex didn't match,
  // so a clean cancel surfaced as "Something went wrong".
  Future<UserCredential?> signInWithGoogle() {
    return _signInWithGoogleInternal().timeout(_kAuthTimeout);
  }

  Future<UserCredential?> _signInWithGoogleInternal() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) return null;

    // Up to 3 attempts of token-fetch + Firebase credential exchange
    // to absorb Android's first-tap Play Services warm-up race. The
    // account picker only ran on the signIn() call above, so retrying
    // these inner steps does NOT re-prompt the user.
    //
    // Failures we treat as warm-up (and therefore retry / soft-cancel
    // on exhaustion):
    //   • PlatformException — Play Services sign_in_failed / 12500 / 7
    //   • FirebaseAuthException with code internal-error /
    //     network-request-failed / invalid-credential / unknown
    //   • Repeated null idToken from googleUser.authentication
    //
    // Real errors (account-exists-with-different-credential,
    // user-disabled, etc.) are not in the warm-up set and rethrow
    // immediately so the cubit can map them to a meaningful message.
    Object? lastWarmupError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final googleAuth = await googleUser.authentication;
        if (googleAuth.idToken != null) {
          final credential = GoogleAuthProvider.credential(
            accessToken: googleAuth.accessToken,
            idToken: googleAuth.idToken,
          );
          return await _auth.signInWithCredential(credential);
        }
        // idToken still null on this attempt — fall through to retry.
        lastWarmupError = Exception('Null id token (attempt ${attempt + 1})');
      } catch (e) {
        if (!_isGoogleSignInWarmupError(e)) rethrow;
        lastWarmupError = e;
      }
      if (attempt < 2) {
        await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      }
    }

    // Three attempts of warm-up failures. Soft-cancel so the cubit
    // returns to AuthUnauthenticated (no error toast) — the user's
    // next tap re-runs the flow against now-warm Play Services and
    // typically succeeds.
    if (kDebugMode) {
      debugPrint(
        '[AuthRepository] Google sign-in warm-up exhausted: $lastWarmupError',
      );
    }
    return null;
  }

  bool _isGoogleSignInWarmupError(Object e) {
    if (e is PlatformException) return true;
    if (e is FirebaseAuthException) {
      return e.code == 'internal-error' ||
          e.code == 'network-request-failed' ||
          e.code == 'invalid-credential' ||
          e.code == 'unknown';
    }
    return false;
  }

  // Warms up Google Play Services at app boot so the user's FIRST
  // sign-in tap succeeds, instead of soft-cancelling against cold Play
  // Services and needing a second tap. Strictly a warm-up:
  //   • Skipped entirely when already signed in (no sign-in pending).
  //   • signInSilently only restores a PREVIOUSLY-cached Google session.
  //     signOut() clears that session (_googleSignIn.signOut()), so for
  //     a signed-out user this returns null — the account picker still
  //     shows on the next tap, exactly as before.
  //   • It never calls signInWithCredential, so it can NEVER change
  //     Firebase auth state or silently log anyone in.
  //   • Best-effort: any failure is swallowed; the tap flow keeps its
  //     own retry loop unchanged.
  Future<void> warmUpGoogleSignIn() async {
    if (currentUser != null) return;
    try {
      await _googleSignIn.signInSilently();
    } catch (_) {
      // Warm-up only — a failure here is harmless.
    }
  }

  Future<UserCredential> signInWithApple() {
    return _signInWithAppleInternal().timeout(_kAuthTimeout);
  }

  Future<UserCredential> _signInWithAppleInternal() async {
    final appleCredential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
    );

    final oAuthCredential = OAuthProvider('apple.com').credential(
      idToken: appleCredential.identityToken,
      accessToken: appleCredential.authorizationCode,
    );

    return _auth.signInWithCredential(oAuthCredential);
  }

  Future<UserCredential> signInWithEmail(String email, String password) {
    return _signInWithEmailInternal(email, password).timeout(_kAuthTimeout);
  }

  Future<UserCredential> _signInWithEmailInternal(
      String email, String password) {
    return _auth.signInWithEmailAndPassword(email: email, password: password);
  }

  Future<String?> getUserRole(String uid) {
    return _getUserRoleInternal(uid).timeout(_kFirestoreTimeout);
  }

  Future<String?> _getUserRoleInternal(String uid) async {
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get()
        .timeout(const Duration(seconds: 10));

    if (!doc.exists || doc.data()?['role'] == null) return null;

    return doc.data()!['role'] as String;
  }

  Future<void> createUserDocument({
    required String uid,
    required String displayName,
    required String email,
    required String photoUrl,
    required String role,
  }) {
    return _createUserDocumentInternal(
      uid: uid,
      displayName: displayName,
      email: email,
      photoUrl: photoUrl,
      role: role,
    ).timeout(_kFirestoreTimeout);
  }

  Future<void> _createUserDocumentInternal({
    required String uid,
    required String displayName,
    required String email,
    required String photoUrl,
    required String role,
  }) async {
    // set(merge:true) so we don't clobber an fcmTokens array that
    // NotificationService may have written between sign-in and
    // role-pick. Functionally equivalent to the previous unmerged
    // set on the first-ever sign-in (the doc didn't exist anyway).
    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'uid': uid,
      'displayName': displayName,
      'email': email,
      'photoUrl': photoUrl,
      'role': role,
      'createdAt': FieldValue.serverTimestamp(),
      'coinBalance': 0,
      'isOnline': false,
    }, SetOptions(merge: true));

    // Now that the doc exists, save the FCM token. The
    // NotificationService auth-state listener fires immediately on
    // sign-in and would otherwise have raced this create — its
    // token-save uses update() and silently skips when the doc is
    // missing, so without this explicit follow-up the user wouldn't
    // get push notifications until the next app start.
    try {
      await NotificationService().saveToken();
    } catch (_) {
      // Best-effort. The next app start / token refresh will
      // persist the token even if this call fails.
    }
  }

  Future<void> signOut() async {
    // Kill any in-flight ringtone first — a priest tapping Sign Out
    // mid-incoming-request shouldn't leave the ring/vibration loop
    // running into an unauthenticated state.
    await RingService().stopAll();

    // Mark the priest offline before clearing auth — we still have
    // a valid auth.uid here, and the priest doc rule requires the
    // caller to be the priest themselves. Skipped silently when
    // the doc doesn't exist (regular user signing out) or the write
    // fails for any reason; the watchdog's stale-heartbeat sweep is
    // the safety net either way. We also clear isBusy in case the
    // priest signed out mid-session — the session itself will be
    // cleaned up by the watchdog, but the user-feed reflection of
    // "this priest is busy" should drop immediately.
    final uid = _auth.currentUser?.uid;
    if (uid != null) {
      try {
        await FirebaseFirestore.instance.doc('priests/$uid').update({
          'isOnline': false,
          'isBusy': false,
        }).timeout(const Duration(seconds: 5));
      } catch (_) {
        // Either the user isn't a priest (no doc / no permission)
        // or the network's down. Both are recoverable: the
        // watchdog will catch a stale heartbeat within 5 minutes
        // and flip isOnline=false on its own.
      }
    }

    // Remove the FCM token BEFORE signing out so we can still write
    // to users/{uid} (rules require auth) and so a freshly-signed-in
    // account on the same device doesn't inherit the previous user's
    // pushes during the brief window between signOut and the next
    // token refresh.
    await NotificationService().removeToken();
    await _googleSignIn.signOut();
    await _auth.signOut();
  }
}
