import 'package:appwrite/appwrite.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../config/appwrite_config.dart';
import '../models/admin.dart';
import '../models/app_user.dart';
import '../services/admin_auth_service.dart';
import '../services/contact_sync_service.dart';
import '../services/user_service.dart';
import 'auth_controller.dart';

/// Maintains the current admin's contact directory in memory and exposes
/// the one method screens actually need: `nameForPhone(phone)`.
///
/// Lifecycle:
///
///   admin login → ensureLoadedForCurrentAdmin() → fetches `users` rows
///                 from Appwrite, then kicks off a background phonebook
///                 sync (permission prompt, device read, batch upsert).
///   booking submit → autoGrowFromBooking() → inserts a row scoped to
///                    the tour creator's admin id, if one doesn't exist.
///   logout → reset()
///
/// Lookups are by 10-digit normalised phone — pass any format, we
/// normalise on the way in.
class UserController extends GetxController {
  final users = <AppUser>[].obs;
  final isSyncing = false.obs;

  /// In-memory phone → name map for O(1) display lookups.
  final _byPhone = <String, String>{};

  /// The Appwrite document `$id` of the currently logged-in admin.
  /// Null when nobody is logged in or when the session is a passenger.
  String? _currentAdminId;

  /// Cache of phone → admin `$id` so the booking auto-grow path can
  /// resolve `tour.createdBy` (a phone) to an admin id without an extra
  /// network call per booking.
  final _adminIdByPhone = <String, String>{};

  UserService get _userService => Get.find<UserService>();
  ContactSyncService get _contactSync => ContactSyncService();
  AuthController get _auth => Get.find<AuthController>();

  /// Returns the admin's saved name for [phone], or null if this admin
  /// hasn't saved this number.
  String? nameForPhone(String phone) {
    final last10 = AppwriteConfig.normalisePhone(phone);
    return _byPhone[last10];
  }

  /// Convenience: name lookup with fallback to the supplied raw name.
  String displayName(String phone, String fallback) =>
      nameForPhone(phone) ?? fallback;

  /// Loads (or reloads) the current admin's `users` rows from Appwrite,
  /// then runs an incremental phonebook sync in the background. Safe to
  /// call repeatedly — does nothing on a passenger session.
  Future<void> ensureLoadedForCurrentAdmin() async {
    if (!_auth.isAdmin) {
      reset();
      return;
    }
    final admin = _auth.currentAdmin.value;
    if (admin == null) return;

    _currentAdminId = admin.id;

    try {
      final list = await _userService.listForAdmin(admin.id);
      users.assignAll(list);
      _rebuildIndex();
    } catch (e) {
      debugPrint('UserController: failed to load users — $e');
    }

    // Phonebook sync runs in the background — we don't block login on it.
    // ignore: unawaited_futures
    syncDevicePhonebook();
  }

  /// Pulls the device address book and inserts any phones not yet
  /// present in this admin's `users` rows. No-op if permission denied.
  Future<void> syncDevicePhonebook() async {
    final adminId = _currentAdminId;
    if (adminId == null) return;
    if (isSyncing.value) return;

    isSyncing.value = true;
    try {
      final entries = await _contactSync.pullDeviceContacts();
      if (entries.isEmpty) return;

      final existing = _byPhone.keys.toSet();
      final newOnes = entries.where((e) => !existing.contains(e.phone));

      for (final e in newOnes) {
        try {
          final created = await _userService.createIfMissing(
            adminId: adminId,
            phone: e.phone,
            name: e.name,
            source: UserSource.device,
          );
          if (created != null) {
            users.add(created);
            _byPhone[created.phone] = created.name;
          }
        } on AppwriteException catch (err) {
          if (err.code != 409) {
            debugPrint('UserController: sync insert failed — ${err.message}');
          }
        }
      }
    } catch (e) {
      debugPrint('UserController: device sync failed — $e');
    } finally {
      isSyncing.value = false;
    }
  }

  /// Inserts a `users` row scoped to the admin who created [tourCreatorPhone]'s
  /// tour. Called from the customer booking flow after a Passenger write.
  /// No-op if the row already exists or if we can't resolve the admin.
  Future<void> autoGrowFromBooking({
    required String tourCreatorPhone,
    required String passengerPhone,
    required String passengerName,
  }) async {
    final adminId = await _resolveAdminIdByPhone(tourCreatorPhone);
    if (adminId == null) return;

    try {
      final created = await _userService.createIfMissing(
        adminId: adminId,
        phone: passengerPhone,
        name: passengerName,
        source: UserSource.booking,
      );
      if (created != null && adminId == _currentAdminId) {
        users.add(created);
        _byPhone[created.phone] = created.name;
      }
    } catch (e) {
      debugPrint('UserController: autoGrowFromBooking failed — $e');
    }
  }

  Future<String?> _resolveAdminIdByPhone(String phone) async {
    final last10 = AppwriteConfig.normalisePhone(phone);
    final cached = _adminIdByPhone[last10];
    if (cached != null) return cached;

    try {
      final Admin? admin = await AdminAuthService().findByPhone(last10);
      if (admin != null) {
        _adminIdByPhone[last10] = admin.id;
        return admin.id;
      }
    } catch (e) {
      debugPrint('UserController: admin lookup failed — $e');
    }
    return null;
  }

  void reset() {
    users.clear();
    _byPhone.clear();
    _currentAdminId = null;
    _adminIdByPhone.clear();
  }

  void _rebuildIndex() {
    _byPhone
      ..clear()
      ..addEntries(users.map((u) => MapEntry(u.phone, u.name)));
  }
}
