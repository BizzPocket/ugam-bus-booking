/// One row in the Appwrite `users` collection.
///
/// Represents "Admin X has Phone Y saved as Name Z." The compound unique
/// key is `(addedByAdminId, phone)` so two different admins can save the
/// same phone under different names without colliding.
///
/// `phone` is always the 10-digit normalised form (see
/// `AppwriteConfig.normalisePhone`). Lookups should normalise before
/// comparing.
class AppUser {
  final String id;
  final String phone;
  final String name;
  final UserSource source;
  final String addedByAdminId;
  final String? note;

  AppUser({
    required this.id,
    required this.phone,
    required this.name,
    required this.source,
    required this.addedByAdminId,
    this.note,
  });

  factory AppUser.fromAppwrite(Map<String, dynamic> doc) {
    return AppUser(
      id: (doc[r'$id'] ?? doc['id'] ?? '').toString(),
      phone: (doc['phone'] ?? '').toString(),
      name: (doc['name'] ?? '').toString(),
      source: UserSource.fromName(doc['source']?.toString()),
      addedByAdminId: (doc['addedByAdminId'] ?? '').toString(),
      note: doc['note']?.toString(),
    );
  }

  Map<String, dynamic> toAppwrite() => {
        'phone': phone,
        'name': name,
        'source': source.name,
        'addedByAdminId': addedByAdminId,
        if (note != null && note!.isNotEmpty) 'note': note,
      };

  AppUser copyWith({String? name, UserSource? source, String? note}) {
    return AppUser(
      id: id,
      phone: phone,
      name: name ?? this.name,
      source: source ?? this.source,
      addedByAdminId: addedByAdminId,
      note: note ?? this.note,
    );
  }
}

enum UserSource {
  device,
  booking,
  manual;

  static UserSource fromName(String? name) {
    return UserSource.values.firstWhere(
      (s) => s.name == name,
      orElse: () => UserSource.manual,
    );
  }
}
