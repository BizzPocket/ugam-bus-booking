import 'package:appwrite/appwrite.dart';
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../config/appwrite_config.dart';
import '../models/app_user.dart';
import 'appwrite_service.dart';

/// Appwrite CRUD for the per-admin contacts directory.
///
/// All reads are scoped to a specific `addedByAdminId` — admins never
/// see each other's saved names. Writes use the compound unique index
/// `(addedByAdminId, phone)` to enforce one row per (admin, phone).
class UserService {
  static final UserService _instance = UserService._internal();
  factory UserService() => _instance;
  UserService._internal();

  Databases get _db => AppwriteService().databases;

  /// Returns all `users` rows owned by [adminId].
  Future<List<AppUser>> listForAdmin(String adminId) async {
    final result = await _db.listDocuments(
      databaseId: AppwriteConfig.databaseId,
      collectionId: AppwriteConfig.usersCollection,
      queries: [
        Query.equal('addedByAdminId', adminId),
        Query.limit(5000),
      ],
    );
    return result.documents
        .map((d) => AppUser.fromAppwrite({
              ...d.data,
              r'$id': d.$id,
            }))
        .toList();
  }

  /// Looks up a single row by (adminId, phone). Returns null when missing.
  Future<AppUser?> findByAdminAndPhone(String adminId, String phone) async {
    final last10 = AppwriteConfig.normalisePhone(phone);
    final result = await _db.listDocuments(
      databaseId: AppwriteConfig.databaseId,
      collectionId: AppwriteConfig.usersCollection,
      queries: [
        Query.equal('addedByAdminId', adminId),
        Query.equal('phone', last10),
        Query.limit(1),
      ],
    );
    if (result.documents.isEmpty) return null;
    final d = result.documents.first;
    return AppUser.fromAppwrite({...d.data, r'$id': d.$id});
  }

  /// Inserts a new row. Throws AppwriteException with code 409 if a row
  /// for this `(adminId, phone)` already exists — callers should treat
  /// that as a no-op.
  Future<AppUser> create({
    required String adminId,
    required String phone,
    required String name,
    required UserSource source,
    String? note,
  }) async {
    final last10 = AppwriteConfig.normalisePhone(phone);
    final draft = AppUser(
      id: const Uuid().v4(),
      phone: last10,
      name: name.trim(),
      source: source,
      addedByAdminId: adminId,
      note: note,
    );
    final created = await _db.createDocument(
      databaseId: AppwriteConfig.databaseId,
      collectionId: AppwriteConfig.usersCollection,
      documentId: ID.unique(),
      data: draft.toAppwrite(),
    );
    return AppUser.fromAppwrite({...created.data, r'$id': created.$id});
  }

  /// Best-effort insert — swallows the 409 conflict that the compound
  /// unique index throws when this `(adminId, phone)` already exists.
  /// Returns the new row on success, null on conflict.
  Future<AppUser?> createIfMissing({
    required String adminId,
    required String phone,
    required String name,
    required UserSource source,
    String? note,
  }) async {
    try {
      return await create(
        adminId: adminId,
        phone: phone,
        name: name,
        source: source,
        note: note,
      );
    } on AppwriteException catch (e) {
      if (e.code == 409) return null;
      rethrow;
    }
  }
}

/// GetX binding helper so callers can `Get.find<UserService>()` without
/// caring about the singleton.
class UserServiceBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<UserService>(() => UserService(), fenix: true);
  }
}
