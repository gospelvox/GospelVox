// States for the admin user-management list. Sealed so the builder
// has to render every variant — a missing case surfaces at analyze
// time rather than as a blank screen in prod.

import 'package:gospel_vox/features/admin/users/data/admin_user_model.dart';

sealed class AdminUsersState {}

class AdminUsersInitial extends AdminUsersState {}

class AdminUsersLoading extends AdminUsersState {}

class AdminUsersLoaded extends AdminUsersState {
  // Full list as fetched, kept around so search can re-filter
  // without re-hitting Firestore.
  final List<AdminUserModel> users;
  // What the list currently shows after applying searchQuery.
  final List<AdminUserModel> filtered;
  final String searchQuery;

  AdminUsersLoaded({
    required this.users,
    required this.filtered,
    this.searchQuery = '',
  });

  AdminUsersLoaded copyWith({
    List<AdminUserModel>? users,
    List<AdminUserModel>? filtered,
    String? searchQuery,
  }) {
    return AdminUsersLoaded(
      users: users ?? this.users,
      filtered: filtered ?? this.filtered,
      searchQuery: searchQuery ?? this.searchQuery,
    );
  }
}

class AdminUsersError extends AdminUsersState {
  final String message;
  AdminUsersError(this.message);
}
