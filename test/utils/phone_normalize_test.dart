import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/phone_normalize.dart';

void main() {
  group('normalisePhone', () {
    test('strips spaces, +91 prefix, returns last 10 digits', () {
      expect(normalisePhone('+91 93271 48044'), '9327148044');
    });
    test('returns input unchanged if already 10 digits', () {
      expect(normalisePhone('9327148044'), '9327148044');
    });
    test('returns full string when fewer than 10 digits', () {
      expect(normalisePhone('123'), '123');
    });
    test('strips dashes and parens', () {
      expect(normalisePhone('(932) 714-8044'), '9327148044');
    });
  });
}
