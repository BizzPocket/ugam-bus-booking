import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/supabase_config.dart';
import '../models/admin.dart';
import '../utils/phone_normalize.dart';

/// Looks up admins in the `admins` table and signs them into Supabase Auth.
/// Phone matching is normalised to the last 10 digits.
///
/// Admin accounts are created via the Supabase dashboard (not from the app);
/// `createAdmin` is therefore intentionally absent.
class AdminAuthService {
  static final AdminAuthService _instance = AdminAuthService._internal();
  factory AdminAuthService() => _instance;
  AdminAuthService._internal();

  SupabaseClient get _client => Supabase.instance.client;

  /// Returns the admin record for [phone] or null if no row matches.
  /// Throws on network failure.
  Future<Admin?> findByPhone(String phone) async {
    final last10 = normalisePhone(phone);
    final rows = await _client
        .from('admins')
        .select()
        .eq('phone', last10)
        .limit(1);
    if (rows.isEmpty) return null;
    return Admin.fromMap(Map<String, dynamic>.from(rows.first));
  }

  /// Signs the admin in via Supabase Auth using the synthetic email mapping.
  /// Returns the freshly fetched admin row on success. Throws AuthException
  /// on bad credentials or network failure.
  Future<Admin> signIn({required String phone, required String password}) async {
    await _client.auth.signInWithPassword(
      email: SupabaseConfig.phoneToSyntheticEmail(phone),
      password: password,
    );
    final uid = _client.auth.currentUser!.id;
    final row = await _client
        .from('admins')
        .select()
        .eq('id', uid)
        .single();
    return Admin.fromMap(Map<String, dynamic>.from(row));
  }

  /// Sign out — clears the Supabase session.
  Future<void> signOut() async => _client.auth.signOut();

  /// True when at least one admin row exists. Returns false when not
  /// authenticated (RLS denies the read) or when truly empty.
  Future<bool> anyAdminExists() async {
    final rows = await _client.from('admins').select('id').limit(1);
    return rows.isNotEmpty;
  }
}
