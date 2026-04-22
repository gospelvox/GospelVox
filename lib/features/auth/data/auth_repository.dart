// Auth repository — handles Firebase Auth + Firestore role lookup

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

// 15s for sign-in flows because OAuth provider round-trips can be slow on
// 3G networks (common in India). 10s for Firestore reads/writes since those
// hit our own backend with shorter latency.
const Duration _kAuthTimeout = Duration(seconds: 15);
const Duration _kFirestoreTimeout = Duration(seconds: 10);

class AuthRepository {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  User? get currentUser => _auth.currentUser;

  Future<UserCredential> signInWithGoogle() {
    return _signInWithGoogleInternal().timeout(_kAuthTimeout);
  }

  Future<UserCredential> _signInWithGoogleInternal() async {
    final googleUser = await _googleSignIn.signIn();
    final googleAuth = await googleUser!.authentication;

    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    return _auth.signInWithCredential(credential);
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
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();

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
    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'uid': uid,
      'displayName': displayName,
      'email': email,
      'photoUrl': photoUrl,
      'role': role,
      'createdAt': FieldValue.serverTimestamp(),
      'coinBalance': 0,
      'isOnline': false,
    });
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }
}
