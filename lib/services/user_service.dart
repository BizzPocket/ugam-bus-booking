import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/app_user.dart';
import '../utils/phone_normalize.dart';
import 'supabase_service.dart';

/// CRUD for the per-admin contacts directory (`public.admin_contacts`).
///
/// All reads are scoped to the current admin's `auth.uid()` via RLS — no
/// app-side `owner_id` filter is strictly necessary, but we pass `adminId`
/// explicitly for clarity.
class UserService {
  static final UserService _instance = UserService._internal();
  factory UserService() => _instance;
  UserService._internal();

  SupabaseClient get _client => SupabaseService.instance.client;
  static const _table = 'admin_contacts';

  Future<List<AppUser>> listForAdmin(String adminId) async {
    final rows = await _client
        .from(_table)
        .select()
        .eq('owner_id', adminId)
        .limit(5000);
    return (rows as List)
        .map((r) => AppUser.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList();
  }

  Future<AppUser?> findByAdminAndPhone(String adminId, String phone) async {
    final last10 = normalisePhone(phone);
    final rows = await _client
        .from(_table)
        .select()
        .eq('owner_id', adminId)
        .eq('phone', last10)
        .limit(1);
    if ((rows as List).isEmpty) return null;
    return AppUser.fromMap(Map<String, dynamic>.from(rows.first as Map));
  }

  /// Inserts a new contact. Throws PostgrestException with code '23505'
  /// (unique_violation) when this `(owner_id, phone)` already exists.
  Future<AppUser> create({
    required String adminId,
    required String phone,
    required String name,
    required UserSource source,
    String? note,
  }) async {
    final last10 = normalisePhone(phone);
    final draft = AppUser(
      id: const Uuid().v4(),
      phone: last10,
      name: name.trim(),
      source: source,
      addedByAdminId: adminId,
      note: note,
    );
    final row = await _client
        .from(_table)
        .insert(draft.toMap())
        .select()
        .single();
    return AppUser.fromMap(Map<String, dynamic>.from(row));
  }

  /// Best-effort insert. Returns null on `(owner_id, phone)` conflict.
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
    } on PostgrestException catch (e) {
      if (e.code == '23505') return null;
      rethrow;
    }
  }
}

class UserServiceBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<UserService>(() => UserService(), fenix: true);
  }
}
