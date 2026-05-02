import 'dart:convert';
import 'dart:math';

import 'package:appwrite/appwrite.dart';
import 'package:crypto/crypto.dart';

import '../config/appwrite_config.dart';
import '../models/admin.dart';
import 'appwrite_service.dart';

/// Looks up admins in the Appwrite `admins` collection and verifies passwords
/// against a stored SHA-256(salt + password) hex hash.
///
/// Phone matching is normalised to the last 10 digits, so admins can store
/// either `9327148044` or `+91 93271 48044` and login still succeeds when the
/// user types either form.
class AdminAuthService {
  static final AdminAuthService _instance = AdminAuthService._internal();
  factory AdminAuthService() => _instance;
  AdminAuthService._internal();

  Databases get _db => AppwriteService().databases;

  static final _rng = Random.secure();

  /// Returns the admin record for [phone] or null if no match.
  /// Throws on network/Appwrite failure so callers can show a real error
  /// rather than silently treating a network blip as "not an admin".
  Future<Admin?> findByPhone(String phone) async {
    final last10 = AppwriteConfig.normalisePhone(phone);
    final docs = await _db.listDocuments(
      databaseId: AppwriteConfig.databaseId,
      collectionId: AppwriteConfig.adminsCollection,
      queries: [Query.equal('phone', last10)],
    );
    if (docs.documents.isEmpty) return null;
    return Admin.fromAppwrite(docs.documents.first.data
      ..[r'$id'] = docs.documents.first.$id
      ..[r'$createdAt'] = docs.documents.first.$createdAt);
  }

  /// True when the supplied [password] matches the stored hash for [admin].
  bool verifyPassword(Admin admin, String password) {
    final candidate = _hash(admin.salt, password);
    return _constantTimeEquals(candidate, admin.passwordHash);
  }

  /// Returns true if at least one admin record exists. Used to decide whether
  /// the first-run setup screen needs to be shown.
  Future<bool> anyAdminExists() async {
    final docs = await _db.listDocuments(
      databaseId: AppwriteConfig.databaseId,
      collectionId: AppwriteConfig.adminsCollection,
      queries: [Query.limit(1)],
    );
    return docs.documents.isNotEmpty;
  }

  /// Creates a new admin record with a freshly generated salt and the
  /// SHA-256 of `salt + password`. Returns the created admin (with id).
  Future<Admin> createAdmin({
    required String phone,
    required String name,
    required String password,
    String? whatsappNumber,
  }) async {
    final salt = _generateSaltHex();
    final passwordHash = _hash(salt, password);
    final phoneLast10 = AppwriteConfig.normalisePhone(phone);
    final whatsappLast10 = whatsappNumber == null || whatsappNumber.isEmpty
        ? null
        : AppwriteConfig.normalisePhone(whatsappNumber);

    final draft = Admin(
      id: '',
      phone: phoneLast10,
      name: name,
      passwordHash: passwordHash,
      salt: salt,
      whatsappNumber: whatsappLast10,
    );

    final created = await _db.createDocument(
      databaseId: AppwriteConfig.databaseId,
      collectionId: AppwriteConfig.adminsCollection,
      documentId: ID.unique(),
      data: draft.toAppwrite(),
    );

    return Admin.fromAppwrite(created.data
      ..[r'$id'] = created.$id
      ..[r'$createdAt'] = created.$createdAt);
  }

  // ── Hashing helpers ───────────────────────────────────────

  String _generateSaltHex() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return _toHex(bytes);
  }

  String _hash(String saltHex, String password) {
    final saltBytes = _fromHex(saltHex);
    final pwBytes = utf8.encode(password);
    final input = <int>[...saltBytes, ...pwBytes];
    return sha256.convert(input).toString();
  }

  String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  List<int> _fromHex(String hex) {
    final out = <int>[];
    for (var i = 0; i + 2 <= hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
