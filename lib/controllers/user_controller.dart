import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/phone_normalize.dart';
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
///                 sync (permission prompt, device read, batch upsert) —
///                 but only the FIRST time this admin signs in on this
///                 device. After that the sync (and its permission prompt)
///                 is skipped on every subsequent login, gated by a local
///                 `contacts_synced_<adminId>` flag.
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
    final last10 = normalisePhone(phone);
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

  /// SharedPreferences key marking that this admin has already synced their
  /// device phonebook on THIS device. Once set, we never re-read the address
  /// book or re-prompt for contacts permission for that admin again.
  static String _syncedKey(String adminId) => 'contacts_synced_$adminId';

  /// Pulls the device address book and inserts any phones not yet present in
  /// this admin's `users` rows. Runs once per (admin, device): the first time
  /// the admin signs in on a new device we prompt + read + upsert, then set a
  /// local flag so every later login skips this entirely (no re-prompt, no
  /// re-scan). No-op if permission denied.
  Future<void> syncDevicePhonebook() async {
    final adminId = _currentAdminId;
    if (adminId == null) return;
    if (isSyncing.value) return;

    final prefs = await SharedPreferences.getInstance();
    final syncedKey = _syncedKey(adminId);
    // First-device-sync only — already done here means never touch the
    // phonebook (or its permission prompt) again for this admin.
    if (prefs.getBool(syncedKey) ?? false) return;

    isSyncing.value = true;
    try {
      final entries = await _contactSync.pullDeviceContacts();
      // Mark done regardless of outcome (granted, denied, or empty book) so a
      // denied/empty first attempt doesn't re-prompt on every future login.
      await prefs.setBool(syncedKey, true);
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
        } on PostgrestException catch (err) {
          if (err.code != '23505') {
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

  /// Saves a customer the admin entered by hand (e.g. someone NOT in their
  /// phone contacts, typed into the "Add request" form) into their directory,
  /// so the name autocompletes next time. No-op on a passenger session, when
  /// not logged in, or when the phone is already known. Best-effort: never
  /// throws into the caller.
  Future<void> rememberContact({
    required String name,
    required String phone,
  }) async {
    final adminId = _currentAdminId;
    if (adminId == null || !_auth.isAdmin) return;
    final last10 = normalisePhone(phone);
    if (last10.length != 10) return;
    if (_byPhone.containsKey(last10)) return; // already saved
    try {
      final created = await _userService.createIfMissing(
        adminId: adminId,
        phone: last10,
        name: name.trim(),
        source: UserSource.manual,
      );
      if (created != null) {
        users.add(created);
        _byPhone[created.phone] = created.name;
      }
    } catch (e) {
      debugPrint('UserController: rememberContact failed — $e');
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
    final last10 = normalisePhone(phone);
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
