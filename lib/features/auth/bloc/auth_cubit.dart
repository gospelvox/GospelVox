// Auth Cubit — manages authentication state

import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/auth/bloc/auth_state.dart';
import 'package:gospel_vox/features/auth/data/auth_repository.dart';

const String _kTimeoutMessage =
    'Taking too long. Check your internet connection and try again.';
const String _kNoNetworkMessage =
    'No internet connection. Please check your network.';
const String _kGenericMessage = 'Something went wrong. Please try again.';

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
      emit(AuthError(_kNoNetworkMessage));
    } on FirebaseAuthException catch (e) {
      emit(AuthError(_mapFirebaseAuthError(e.code)));
    } catch (e) {
      emit(AuthError(_kGenericMessage));
    }
  }

  Future<void> signInWithGoogle({String? selectedRole}) async {
    emit(AuthLoading());

    try {
      final userCredential = await _authRepository.signInWithGoogle();
      final user = userCredential.user!;

      final role = await _authRepository.getUserRole(user.uid);

      if (role != null) {
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
    emit(AuthLoading());

    try {
      final userCredential = await _authRepository.signInWithApple();
      final user = userCredential.user!;

      final role = await _authRepository.getUserRole(user.uid);

      if (role != null) {
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
    emit(AuthLoading());

    try {
      final userCredential =
          await _authRepository.signInWithEmail(email, password);
      final user = userCredential.user!;

      final role = await _authRepository.getUserRole(user.uid);

      if (role == null) {
        // First email login → auto-create admin doc.
        await _authRepository.createUserDocument(
          uid: user.uid,
          displayName: user.displayName ?? 'Admin',
          email: user.email ?? email,
          photoUrl: user.photoURL ?? '',
          role: 'admin',
        );
        emit(AuthAuthenticated(uid: user.uid, role: 'admin'));
      } else if (role != 'admin') {
        await _authRepository.signOut();
        emit(AuthError('This account is not an admin. Contact support.'));
      } else {
        emit(AuthAuthenticated(uid: user.uid, role: 'admin'));
      }
    } on TimeoutException {
      emit(AuthError(_kTimeoutMessage));
    } on SocketException {
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
