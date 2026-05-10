import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin wrapper around the Supabase client. Exposes the typed client and a
/// `ping()` helper that the login screen uses for connectivity checks.
class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  static SupabaseService get instance => _instance;
  SupabaseService._internal();

  SupabaseClient get client => Supabase.instance.client;

  /// Verifies the project is reachable. Throws on network/auth failure.
  /// Uses a tiny `select` against booking_requests. The anon role's RLS
  /// policy allows INSERT but not SELECT — PostgREST returns an empty
  /// array (not an error) under that constraint, which is still proof
  /// the project is reachable. If the project is paused or offline, the
  /// request throws.
  Future<String> ping() async {
    await client.from('booking_requests').select('id').limit(1);
    return 'OK';
  }
}
