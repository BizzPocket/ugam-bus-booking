import '../utils/phone_normalize.dart';

class SupabaseConfig {
  static const String url = 'https://rhyqjzulpvaeslbaymex.supabase.co';
  static const String anonKey =
      'sb_publishable_aEvruC4m4U4OXCHOnGIMHw_sv1btxwP';

  /// Maps a phone number to the synthetic email Supabase Auth uses for sign-in.
  /// We don't run a real email infrastructure — the local-part is the last
  /// 10 digits of the phone, and the domain is `occubus.local`.
  static String phoneToSyntheticEmail(String phone) =>
      '${normalisePhone(phone)}@occubus.local';

  SupabaseConfig._();
}
