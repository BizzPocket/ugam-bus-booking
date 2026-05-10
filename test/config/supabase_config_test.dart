import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/config/supabase_config.dart';

void main() {
  group('phoneToSyntheticEmail', () {
    test('uses last 10 digits + @occubus.local', () {
      expect(
        SupabaseConfig.phoneToSyntheticEmail('+91 93271 48044'),
        '9327148044@occubus.local',
      );
    });
    test('handles already-normalised input', () {
      expect(
        SupabaseConfig.phoneToSyntheticEmail('9327148044'),
        '9327148044@occubus.local',
      );
    });
  });
  test('url and anon key constants are non-empty', () {
    expect(SupabaseConfig.url, isNotEmpty);
    expect(SupabaseConfig.anonKey, isNotEmpty);
  });
}
