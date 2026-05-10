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

  factory AppUser.fromMap(Map<String, dynamic> map) {
    return AppUser(
      id: (map['id'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      source: UserSource.fromName(map['source']?.toString()),
      addedByAdminId: (map['owner_id'] ?? '').toString(),
      note: map['note']?.toString(),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'phone': phone,
        'name': name,
        'source': source.name,
        'owner_id': addedByAdminId,
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
