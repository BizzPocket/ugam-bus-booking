import 'package:flutter_contacts/flutter_contacts.dart';

import '../utils/phone_normalize.dart';

/// Reads the device address book and produces a list of `(name, phone)`
/// pairs ready to upsert into the `users` collection.
///
/// Permission handling lives here: callers just await `pullDeviceContacts`
/// and decide what to do with the result. Returns an empty list when
/// permission is denied — there is no thrown error for that case so the
/// rest of the app keeps working.
class ContactSyncService {
  static final ContactSyncService _instance = ContactSyncService._internal();
  factory ContactSyncService() => _instance;
  ContactSyncService._internal();

  /// Returns true if contacts permission is currently granted (no prompt).
  Future<bool> hasPermission() async {
    return FlutterContacts.permissions.has(PermissionType.read);
  }

  /// Reads all device contacts and flattens them into one entry per
  /// (contact, phone). A contact with three phones produces three
  /// entries; duplicates by normalised phone are collapsed (last name
  /// wins).
  ///
  /// Prompts for permission if not yet decided. Returns an empty list when
  /// permission is denied.
  Future<List<DeviceContactEntry>> pullDeviceContacts() async {
    final status = await FlutterContacts.permissions.request(PermissionType.read);
    if (status != PermissionStatus.granted &&
        status != PermissionStatus.limited) {
      return const [];
    }

    final raw = await FlutterContacts.getAll(
      properties: {ContactProperty.phone},
    );

    final byPhone = <String, DeviceContactEntry>{};
    for (final c in raw) {
      final name = (c.displayName ?? '').trim();
      if (name.isEmpty) continue;

      for (final p in c.phones) {
        final last10 = normalisePhone(p.number);
        if (last10.length != 10) continue;
        byPhone[last10] = DeviceContactEntry(phone: last10, name: name);
      }
    }
    return byPhone.values.toList(growable: false);
  }
}

class DeviceContactEntry {
  final String phone;
  final String name;
  const DeviceContactEntry({required this.phone, required this.name});
}
