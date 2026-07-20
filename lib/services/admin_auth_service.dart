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
  static final AdminAuthService _instance = AdminAuthService.internal();
  factory AdminAuthService() => _instance;

  /// Generative constructor, kept accessible (not private) so tests can
  /// subclass with a throwing/fake override for a single method — e.g. to
  /// exercise `AuthController`'s wrong-password path without hitting
  /// Supabase. Production code should still go through the
  /// `AdminAuthService()` factory above, which returns the shared singleton.
  AdminAuthService.internal();

  SupabaseClient get _client => Supabase.instance.client;

  /// Returns the admin record for [phone] or null if no row matches.
  /// Throws on network failure.
  ///
  /// Uses a SECURITY DEFINER RPC because this call happens BEFORE sign-in
  /// (anon role) — `admins` RLS hides every row from anon, so a direct
  /// table select would always return empty and the login screen would
  /// misclassify every admin as a passenger. The RPC only exposes
  /// id/phone/name; the rest of the row stays gated by RLS until the user
  /// authenticates.
  Future<Admin?> findByPhone(String phone) async {
    final last10 = normalisePhone(phone);
    final result = await _client
        .rpc('admin_lookup_by_phone', params: {'p_phone': last10});
    if (result == null) return null;
    final rows = result as List;
    if (rows.isEmpty) return null;
    return Admin.fromMap(Map<String, dynamic>.from(rows.first as Map));
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

  /// Persists the admin's editable settings (name, WhatsApp, business,
  /// payment, notification prefs) to their own `admins` row and returns the
  /// freshly-stored record. Writes through the `admins_update_self` RLS
  /// policy (id = auth.uid()), so it only ever touches the caller's own row.
  /// Throws on network/permission failure.
  Future<Admin> updateAdmin(Admin admin) async {
    final row = await _client
        .from('admins')
        .update(admin.toUpdateMap())
        .eq('id', admin.id)
        .select()
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
