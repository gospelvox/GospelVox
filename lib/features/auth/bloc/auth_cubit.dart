// Auth Cubit — manages authentication state

import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/core/services/connectivity_service.dart';
import 'package:gospel_vox/features/auth/bloc/auth_state.dart';
import 'package:gospel_vox/features/auth/data/auth_repository.dart';

const String _kTimeoutMessage =
    'Taking too long. Check your internet connection and try again.';
const String _kNoNetworkMessage =
    'No internet connection. Please check your network.';
const String _kGenericMessage = 'Something went wrong. Please try again.';
const String _kOfflinePrecheckMessage =
    "You're offline. Connect to WiFi or mobile data to sign in.";

class AuthCubit extends Cubit<AuthState> {
  final AuthRepository _authRepository;

  AuthCubit(this._authRepository) : super(AuthInitial());

  Future<void> checkAuthStatus() async {
    try {
      final user = _authRepository.currentUser;

      if (user == null) {
        emit(AuthUnauthenticated());
        return;
      }

      final role = await _authRepository.getUserRole(user.uid);

      if (role == null) {
        emit(AuthNeedsRole(
          uid: user.uid,
          displayName: user.displayName ?? '',
          email: user.email ?? '',
          photoUrl: user.photoURL ?? '',
        ));
        return;
      }

      emit(AuthAuthenticated(uid: user.uid, role: role));
    } on TimeoutException {
      emit(AuthError(_kTimeoutMessage));
    } on SocketException {
      // The platform reported "online" but the actual reach failed —
      // surface that to the banner so the user sees the same offline
      // explanation everywhere instead of just here.
      ConnectivityService().recordReachabilityFailure();
      emit(AuthError(_kNoNetworkMessage));
    } on FirebaseAuthException catch (e) {
      emit(AuthError(_mapFirebaseAuthError(e.code)));
    } catch (e) {
      emit(AuthError(_kGenericMessage));
    }
  }

  // Pre-flight: refuse to even start a sign-in if the device has no
  // network. Without this, Google Sign-In's PlatformException leaks
  // through as a generic "something went wrong" because it doesn't
  // map cleanly to SocketException in every Android version.
  bool _failIfOffline() {
    if (!ConnectivityService().isOnline) {
      emit(AuthError(_kOfflinePrecheckMessage));
      return true;
    }
    return false;
  }

  Future<void> signInWithGoogle({String? selectedRole}) async {
    if (_failIfOffline()) return;
    emit(AuthLoading());

    try {
      final userCredential = await _authRepository.signInWithGoogle();
      // Repo returns null when the user cancels the Google chooser —
      // that's not an error, just bring the UI back to a clean state.
      if (userCredential == null) {
        emit(AuthUnauthenticated());
        return;
      }
      final user = userCredential.user!;

      final role = await _authRepository.getUserRole(user.uid);

      if (role != null) {
        // Existing account. If the user picked a role on the previous
        // screen and it doesn't match, surface a friendly mismatch
        // sheet rather than silently dropping them on the wrong shell.
        if (selectedRole != null && role != selectedRole) {
          emit(AuthRoleMismatch(
            email: user.email ?? '',
            existingRole: role,
            selectedRole: selectedRole,
            provider: 'google',
          ));
          return;
        }
        emit(AuthAuthenticated(uid: user.uid, role: role));
      } else if (selectedRole != null) {
        await _authRepository.createUserDocument(
          uid: user.uid,
          displayName: user.displayName ?? '',
          email: user.email ?? '',
          photoUrl: user.photoURL ?? '',
          role: selectedRole,
        );
        emit(AuthAuthenticated(uid: user.uid, role: selectedRole));
      } else {
        emit(AuthNeedsRole(
          uid: user.uid,
          displayName: user.displayName ?? '',
          email: user.email ?? '',
          photoUrl: user.photoURL ?? '',
        ));
      }
    } on TimeoutException {
      emit(AuthError(_kTimeoutMessage));
    } on SocketException {
      // The platform reported "online" but the actual reach failed —
      // surface that to the banner so the user sees the same offline
      // explanation everywhere instead of just here.
      ConnectivityService().recordReachabilityFailure();
      emit(AuthError(_kNoNetworkMessage));
    } on FirebaseAuthException catch (e) {
      emit(AuthError(_mapFirebaseAuthError(e.code)));
    } catch (e) {
      if (_isSignInCancelled(e)) {
        emit(AuthUnauthenticated());
        return;
      }
      emit(AuthError(_kGenericMessage));
    }
  }

  Future<void> signInWithApple({String? selectedRole}) async {
    if (_failIfOffline()) return;
    emit(AuthLoading());

    try {
      final userCredential = await _authRepository.signInWithApple();
      final user = userCredential.user!;

      final role = await _authRepository.getUserRole(user.uid);

      if (role != null) {
        if (selectedRole != null && role != selectedRole) {
          emit(AuthRoleMismatch(
            email: user.email ?? '',
            existingRole: role,
            selectedRole: selectedRole,
            provider: 'apple',
          ));
          return;
        }
        emit(AuthAuthenticated(uid: user.uid, role: role));
      } else if (selectedRole != null) {
        await _authRepository.createUserDocument(
          uid: user.uid,
          displayName: user.displayName ?? '',
          email: user.email ?? '',
          photoUrl: user.photoURL ?? '',
          role: selectedRole,
        );
        emit(AuthAuthenticated(uid: user.uid, role: selectedRole));
      } else {
        emit(AuthNeedsRole(
          uid: user.uid,
          displayName: user.displayName ?? '',
          email: user.email ?? '',
          photoUrl: user.photoURL ?? '',
        ));
      }
    } on TimeoutException {
      emit(AuthError(_kTimeoutMessage));
    } on SocketException {
      // The platform reported "online" but the actual reach failed —
      // surface that to the banner so the user sees the same offline
      // explanation everywhere instead of just here.
      ConnectivityService().recordReachabilityFailure();
      emit(AuthError(_kNoNetworkMessage));
    } on FirebaseAuthException catch (e) {
      emit(AuthError(_mapFirebaseAuthError(e.code)));
    } catch (e) {
      if (_isSignInCancelled(e)) {
        emit(AuthUnauthenticated());
        return;
      }
      emit(AuthError(_kGenericMessage));
    }
  }

  Future<void> signInWithEmail(String email, String password) async {
    if (_failIfOffline()) return;
    emit(AuthLoading());

    try {
      final userCredential =
          await _authRepository.signInWithEmail(email, password);
      final user = userCredential.user!;

      final role = await _authRepository.getUserRole(user.uid);

      if (role == null) {
        // No Firestore profile → not an admin account. Admin docs must
        // be provisioned manually (Firebase console or seed script);
        // auto-promoting any FB-Auth user that signs in here would be
        // a vertical-privilege escalation if the hidden form leaks.
        await _authRepository.signOut();
        emit(AuthError(
            'Admin account not found. Contact the administrator.'));
      } else if (role != 'admin') {
        await _authRepository.signOut();
        emit(AuthError('This account does not have admin access.'));
      } else {
        emit(AuthAuthenticated(uid: user.uid, role: 'admin'));
      }
    } on TimeoutException {
      emit(AuthError(_kTimeoutMessage));
    } on SocketException {
      // The platform reported "online" but the actual reach failed —
      // surface that to the banner so the user sees the same offline
      // explanation everywhere instead of just here.
      ConnectivityService().recordReachabilityFailure();
      emit(AuthError(_kNoNetworkMessage));
    } on FirebaseAuthException catch (e) {
      emit(AuthError(_mapFirebaseAuthError(e.code)));
    } catch (e) {
      emit(AuthError(_kGenericMessage));
    }
  }

  // Test/demo email+password sign-in for store reviewers (Play/App Store).
  // Unlike [signInWithEmail] (admin-only), this respects whatever role the
  // pre-provisioned demo account already has and routes straight there, so a
  // single hidden form can log in as a demo user OR a demo priest. The
  // account's Firestore `users/{uid}` doc must already exist with a role —
  // we never create one here, so this can't be used to self-provision a role.
  Future<void> signInWithEmailDemo(String email, String password) async {
    if (_failIfOffline()) return;
    emit(AuthLoading());

    try {
      final userCredential =
          await _authRepository.signInWithEmail(email, password);
      final user = userCredential.user!;

      final role = await _authRepository.getUserRole(user.uid);

      if (role == null) {
        // Not a provisioned demo account — sign back out so we don't leave
        // a half-authenticated session with no role to route to.
        await _authRepository.signOut();
        emit(AuthError('Demo account is not set up. Contact the developer.'));
        return;
      }

      emit(AuthAuthenticated(uid: user.uid, role: role));
    } on TimeoutException {
      emit(AuthError(_kTimeoutMessage));
    } on SocketException {
      ConnectivityService().recordReachabilityFailure();
      emit(AuthError(_kNoNetworkMessage));
    } on FirebaseAuthException catch (e) {
      emit(AuthError(_mapFirebaseAuthError(e.code)));
    } catch (e) {
      emit(AuthError(_kGenericMessage));
    }
  }

  Future<void> selectRole(String role, AuthNeedsRole needsRoleState) async {
    emit(AuthLoading());

    try {
      await _authRepository.createUserDocument(
        uid: needsRoleState.uid,
        displayName: needsRoleState.displayName,
        email: needsRoleState.email,
        photoUrl: needsRoleState.photoUrl,
        role: role,
      );

      emit(AuthAuthenticated(uid: needsRoleState.uid, role: role));
    } on TimeoutException {
      emit(AuthError(_kTimeoutMessage));
    } on SocketException {
      // The platform reported "online" but the actual reach failed —
      // surface that to the banner so the user sees the same offline
      // explanation everywhere instead of just here.
      ConnectivityService().recordReachabilityFailure();
      emit(AuthError(_kNoNetworkMessage));
    } catch (e) {
      emit(AuthError('Failed to create account. Please try again.'));
    }
  }

  Future<void> signOut() async {
    try {
      await _authRepository.signOut();
      emit(AuthUnauthenticated());
    } catch (e) {
      emit(AuthError(_kGenericMessage));
    }
  }

  // Used by the role-mismatch sheet's "Use a different account"
  // button. Signs out the current account first so the social
  // provider's account picker re-prompts, then re-runs the same
  // sign-in flow with the same selectedRole.
  Future<void> signInWithDifferentAccount({
    required String selectedRole,
    required String provider,
  }) async {
    try {
      await _authRepository.signOut();
    } catch (_) {
      // Best-effort cleanup; proceed to the picker either way.
    }

    if (provider == 'apple') {
      await signInWithApple(selectedRole: selectedRole);
    } else {
      await signInWithGoogle(selectedRole: selectedRole);
    }
  }

  bool _isSignInCancelled(Object e) {
    final message = e.toString();
    return message.contains('sign_in_canceled') ||
        message.contains('canceled') ||
        message.contains('cancelled') ||
        message.contains('AuthorizationErrorCode.canceled') ||
        message.contains('PlatformException(sign_in_canceled');
  }

  String _mapFirebaseAuthError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'No account found with this email.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect password.';
      case 'invalid-email':
        return 'Invalid email address.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'network-request-failed':
        // Mirror to the banner so the user sees the offline state
        // even when only Firebase's own probe failed (DNS / captive
        // portal cases where the OS says wifi is fine).
        ConnectivityService().recordReachabilityFailure();
        return 'Network error. Check connection.';
      case 'too-many-requests':
        return 'Too many attempts. Try again in a moment.';
      case 'operation-not-allowed':
        return 'This sign-in method is not enabled.';
      default:
        return _kGenericMessage;
    }
  }
}
