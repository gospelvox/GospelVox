// Data access for the admin user-management list.
//
// Two design choices worth flagging for future readers:
//
// 1. The query deliberately omits `orderBy('createdAt')`. Pairing
//    that with `where('role', ...)` would require a composite
//    Firestore index that no deploy script currently creates — on
//    first run in prod the query throws FAILED_PRECONDITION. We
//    sort client-side instead. Same pattern the speakers repo uses
//    so the two flows stay consistent.
//
// 2. Search runs client-side over the loaded list. Firestore has
//    no native text search; pulling the same set and filtering by
//    substring is cheap at V1 scale and avoids wiring Algolia /
//    Typesense before we know the scaling shape.

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:gospel_vox/features/admin/users/data/admin_user_model.dart';

class AdminUsersRepository {
  Future<List<AdminUserModel>> getUsers() async {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where('role', isEqualTo: 'user')
        .get()
        .timeout(const Duration(seconds: 10));

    final users = snap.docs
        .map((doc) => AdminUserModel.fromFirestore(doc.id, doc.data()))
        .toList();

    // Newest first. Nulls (pending server timestamp on a freshly-
    // created user) sink to the bottom so we don't punish a brand-
    // new sign-up with an off-screen position.
    users.sort((a, b) {
      final aTime = a.createdAt;
      final bTime = b.createdAt;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime);
    });

    return users;
  }
}
