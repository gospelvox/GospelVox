// Talks to Firestore + Storage on behalf of the registration cubit.
//
// Why we centralise: the wizard talks to two backends (Storage for files,
// Firestore for the doc) and that orchestration would otherwise leak into
// the cubit. Keeping it here also means tests can swap a fake repo later
// without touching cubit logic.

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:gospel_vox/features/priest/registration/data/priest_registration_model.dart';

class PriestRegistrationRepository {
  // Returns the existing priests/{uid} document if any, else null.
  // Used by the dashboard redirect to decide which screen to show
  // (register / pending / rejected / approved).
  Future<Map<String, dynamic>?> getPriestProfile(String uid) async {
    final doc = await FirebaseFirestore.instance
        .doc('priests/$uid')
        .get()
        .timeout(const Duration(seconds: 10));
    return doc.exists ? doc.data() : null;
  }

  // Pushes a single file to Storage and returns its download URL.
  // The 60-second timeout is intentionally generous: large IDs over
  // patchy mobile networks routinely take 20-40s, and a tighter cap
  // would fail honest uploads.
  Future<String> uploadFile({
    required String uid,
    required String filePath,
    required String storagePath,
  }) async {
    final file = File(filePath);
    final ref =
        FirebaseStorage.instance.ref().child('priests/$uid/$storagePath');

    final uploadTask = ref.putFile(
      file,
      SettableMetadata(contentType: _getContentType(filePath)),
    );

    final snapshot = await uploadTask.timeout(const Duration(seconds: 60));
    return await snapshot.ref.getDownloadURL();
  }

  // Final write — only called after every Storage upload has resolved
  // so the doc never references missing files.
  Future<void> submitRegistration({
    required String uid,
    required PriestRegistrationModel data,
  }) async {
    await FirebaseFirestore.instance
        .doc('priests/$uid')
        .set(data.toFirestore(uid))
        .timeout(const Duration(seconds: 10));
  }

  // Lets us preserve PDF certificates when present (user might pick
  // a scanned PDF from their drive) instead of mis-tagging as JPEG,
  // which would break in-browser preview for admin reviewers.
  String _getContentType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    return 'image/jpeg';
  }
}
