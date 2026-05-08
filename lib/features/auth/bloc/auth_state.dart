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

// Surfaces when an authenticated account already exists with a role
// that differs from the one the user picked on the role selection
// screen (e.g. "Member" tapped, but the Google account is registered
// as a Speaker). The user remains authenticated — the UI shows a
// bottom sheet that lets them either continue as their existing
// role, or sign out and pick a different account.
class AuthRoleMismatch extends AuthState {
  final String email;
  final String existingRole;
  final String selectedRole;
  // 'google' or 'apple' — drives which sign-in flow re-runs when the
  // user taps "Use a different account".
  final String provider;

  AuthRoleMismatch({
    required this.email,
    required this.existingRole,
    required this.selectedRole,
    required this.provider,
  });
}
