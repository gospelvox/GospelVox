// Auth states using Dart 3 sealed class pattern

sealed class AuthState {}

class AuthInitial extends AuthState {}

class AuthLoading extends AuthState {}

class AuthAuthenticated extends AuthState {
  final String uid;
  final String role;

  AuthAuthenticated({required this.uid, required this.role});
}

class AuthNeedsRole extends AuthState {
  final String uid;
  final String displayName;
  final String email;
  final String photoUrl;

  AuthNeedsRole({
    required this.uid,
    required this.displayName,
    required this.email,
    required this.photoUrl,
  });
}

class AuthUnauthenticated extends AuthState {}

class AuthError extends AuthState {
  final String message;

  AuthError(this.message);
}
