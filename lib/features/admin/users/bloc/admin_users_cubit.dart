// Loads the user list and applies client-side search filtering.
// Refresh-while-loaded keeps the previous results visible so the
// RefreshIndicator's spinner is the only loading UI — avoids the
// list jumping away under the admin's finger mid-pull.

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:gospel_vox/features/admin/users/bloc/admin_users_state.dart';
import 'package:gospel_vox/features/admin/users/data/admin_user_model.dart';
import 'package:gospel_vox/features/admin/users/data/admin_users_repository.dart';

class AdminUsersCubit extends Cubit<AdminUsersState> {
  final AdminUsersRepository _repository;

  AdminUsersCubit(this._repository) : super(AdminUsersInitial());

  Future<void> loadUsers() async {
    try {
      if (state is! AdminUsersLoaded) {
        emit(AdminUsersLoading());
      }
      final users = await _repository.getUsers();
      if (isClosed) return;

      // Re-apply the active search term so a refresh doesn't
      // silently drop the admin back into the unfiltered list.
      final current = state;
      final query =
          current is AdminUsersLoaded ? current.searchQuery : '';
      emit(AdminUsersLoaded(
        users: users,
        filtered: _filterUsers(users, query),
        searchQuery: query,
      ));
    } on TimeoutException {
      if (isClosed) return;
      if (state is AdminUsersLoaded) return; // keep current data
      emit(AdminUsersError('Taking too long. Check your connection.'));
    } catch (_) {
      if (isClosed) return;
      if (state is AdminUsersLoaded) return;
      emit(AdminUsersError('Failed to load users.'));
    }
  }

  void search(String query) {
    final current = state;
    if (current is! AdminUsersLoaded) return;
    if (isClosed) return;
    emit(current.copyWith(
      filtered: _filterUsers(current.users, query),
      searchQuery: query,
    ));
  }

  // Case-insensitive substring on display name OR email — admin
  // pasting a partial address works without needing exact case.
  List<AdminUserModel> _filterUsers(
    List<AdminUserModel> users,
    String query,
  ) {
    if (query.isEmpty) return users;
    final q = query.toLowerCase();
    return users
        .where((u) =>
            u.displayName.toLowerCase().contains(q) ||
            u.email.toLowerCase().contains(q))
        .toList();
  }
}
