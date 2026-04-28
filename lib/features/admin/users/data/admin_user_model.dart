// Shape of a users/{uid} doc as the admin sees it. Only the fields
// the admin user-list/detail surfaces actually need are pulled —
// the doc itself carries more (push tokens, FCM topics, etc.) that
// are irrelevant here and would just bloat the model.

import 'package:cloud_firestore/cloud_firestore.dart';

class AdminUserModel {
  final String uid;
  final String displayName;
  final String email;
  final String photoUrl;
  final String role;
  final int coinBalance;
  final DateTime? createdAt;

  const AdminUserModel({
    required this.uid,
    required this.displayName,
    required this.email,
    required this.photoUrl,
    required this.role,
    required this.coinBalance,
    this.createdAt,
  });

  // Hand-rolled because `createdAt` is a serverTimestamp that can
  // briefly land as null between the client write and the server
  // stamping it.
  factory AdminUserModel.fromFirestore(
    String docId,
    Map<String, dynamic> data,
  ) {
    return AdminUserModel(
      uid: docId,
      displayName: data['displayName'] as String? ?? '',
      email: data['email'] as String? ?? '',
      photoUrl: data['photoUrl'] as String? ?? '',
      role: data['role'] as String? ?? 'user',
      coinBalance: (data['coinBalance'] as num?)?.toInt() ?? 0,
      createdAt: data['createdAt'] is Timestamp
          ? (data['createdAt'] as Timestamp).toDate()
          : null,
    );
  }

  bool get hasPhoto => photoUrl.isNotEmpty;

  // First letter of name for the avatar fallback. Trimmed because
  // leading whitespace would render as a blank avatar otherwise.
  String get initial {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.substring(0, 1).toUpperCase();
  }

  // "Apr 27, 2025". Hand-rolled rather than via intl so the format
  // matches the rest of the app, which avoids the locale dependency.
  String get joinDate {
    final d = createdAt;
    if (d == null) return '';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}
