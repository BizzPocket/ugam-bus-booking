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

  group('isPlausibleIndianMobile', () {
    test('accepts real-looking mobiles (start 6-9, 10 digits)', () {
      expect(isPlausibleIndianMobile('9327148044'), isTrue);
      expect(isPlausibleIndianMobile('+91 97277 10359'), isTrue);
      expect(isPlausibleIndianMobile('6012345678'), isTrue);
    });
    test('rejects wrong length', () {
      expect(isPlausibleIndianMobile('123'), isFalse);
      expect(isPlausibleIndianMobile('97277103590'), isTrue); // 11 digits -> last 10 start 7
      expect(isPlausibleIndianMobile('12345'), isFalse);
    });
    test('rejects invalid leading digit (<6)', () {
      expect(isPlausibleIndianMobile('5327148044'), isFalse);
      expect(isPlausibleIndianMobile('0327148044'), isFalse);
    });
    test('rejects all-identical and trivial sequences', () {
      expect(isPlausibleIndianMobile('9999999999'), isFalse);
      expect(isPlausibleIndianMobile('8888888888'), isFalse);
      expect(isPlausibleIndianMobile('9876543210'), isFalse);
    });
  });
}
