// Aggregates every field the priest enters across the 3-step wizard.
//
// Why a single copyWith-able snapshot: partial steps have no meaning on
// their own (we only ever submit a complete document) and sharing one
// object across the bloc avoids having to sync up N per-step models.

import 'package:cloud_firestore/cloud_firestore.dart';

class PriestRegistrationModel {
  // Step 1 — Personal
  final String fullName;
  final String phone;
  final String email;
  // Local path before upload, Storage URL after. Both can coexist when
  // the user repicks a photo after already uploading once.
  final String? photoPath;
  final String? photoUrl;

  // Step 2 — Ministry
  final String denomination;
  final String subDenomination;
  final String churchName;
  final String diocese;
  final String location;
  final int yearsOfExperience;
  final String bio;
  final List<String> languages;
  final List<String> specializations;

  // Step 3 — Documents
  final String? idProofPath;
  final String? idProofUrl;
  final String? certificatePath;
  final String? certificateUrl;

  const PriestRegistrationModel({
    this.fullName = '',
    this.phone = '',
    this.email = '',
    this.photoPath,
    this.photoUrl,
    this.denomination = '',
    this.subDenomination = '',
    this.churchName = '',
    this.diocese = '',
    this.location = '',
    this.yearsOfExperience = 0,
    this.bio = '',
    this.languages = const [],
    this.specializations = const [],
    this.idProofPath,
    this.idProofUrl,
    this.certificatePath,
    this.certificateUrl,
  });

  PriestRegistrationModel copyWith({
    String? fullName,
    String? phone,
    String? email,
    String? photoPath,
    String? photoUrl,
    String? denomination,
    String? subDenomination,
    String? churchName,
    String? diocese,
    String? location,
    int? yearsOfExperience,
    String? bio,
    List<String>? languages,
    List<String>? specializations,
    String? idProofPath,
    String? idProofUrl,
    String? certificatePath,
    String? certificateUrl,
  }) {
    return PriestRegistrationModel(
      fullName: fullName ?? this.fullName,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      photoPath: photoPath ?? this.photoPath,
      photoUrl: photoUrl ?? this.photoUrl,
      denomination: denomination ?? this.denomination,
      subDenomination: subDenomination ?? this.subDenomination,
      churchName: churchName ?? this.churchName,
      diocese: diocese ?? this.diocese,
      location: location ?? this.location,
      yearsOfExperience: yearsOfExperience ?? this.yearsOfExperience,
      bio: bio ?? this.bio,
      languages: languages ?? this.languages,
      specializations: specializations ?? this.specializations,
      idProofPath: idProofPath ?? this.idProofPath,
      idProofUrl: idProofUrl ?? this.idProofUrl,
      certificatePath: certificatePath ?? this.certificatePath,
      certificateUrl: certificateUrl ?? this.certificateUrl,
    );
  }

  // Canonical Firestore shape for priests/{uid}. Status/stat defaults
  // are set here so neither moderation tooling nor the priest dashboard
  // has to null-check these fields on freshly-created docs.
  Map<String, dynamic> toFirestore(String uid) => {
        'uid': uid,
        'fullName': fullName,
        'phone': phone,
        'email': email,
        'photoUrl': photoUrl ?? '',
        'denomination': denomination,
        'subDenomination': subDenomination,
        'churchName': churchName,
        'diocese': diocese,
        'location': location,
        'yearsOfExperience': yearsOfExperience,
        'bio': bio,
        'languages': languages,
        'specializations': specializations,
        'idProofUrl': idProofUrl ?? '',
        'certificateUrl': certificateUrl ?? '',
        'status': 'pending',
        'isActivated': false,
        'isOnline': false,
        'walletBalance': 0,
        'totalEarnings': 0,
        'totalSessions': 0,
        'rating': 0.0,
        'reviewCount': 0,
        'createdAt': FieldValue.serverTimestamp(),
      };

  // Draft shape — text fields only. File paths are cache paths that
  // don't survive an app restart, so persisting them would just point
  // at files the OS has since evicted.
  Map<String, dynamic> toDraft() => {
        'fullName': fullName,
        'phone': phone,
        'email': email,
        'denomination': denomination,
        'subDenomination': subDenomination,
        'churchName': churchName,
        'diocese': diocese,
        'location': location,
        'yearsOfExperience': yearsOfExperience,
        'bio': bio,
        'languages': languages,
        'specializations': specializations,
      };

  factory PriestRegistrationModel.fromDraft(Map<String, dynamic> data) {
    return PriestRegistrationModel(
      fullName: data['fullName'] as String? ?? '',
      phone: data['phone'] as String? ?? '',
      email: data['email'] as String? ?? '',
      denomination: data['denomination'] as String? ?? '',
      subDenomination: data['subDenomination'] as String? ?? '',
      churchName: data['churchName'] as String? ?? '',
      diocese: data['diocese'] as String? ?? '',
      location: data['location'] as String? ?? '',
      yearsOfExperience:
          (data['yearsOfExperience'] as num?)?.toInt() ?? 0,
      bio: data['bio'] as String? ?? '',
      languages: List<String>.from(data['languages'] as List? ?? const []),
      specializations:
          List<String>.from(data['specializations'] as List? ?? const []),
    );
  }
}
