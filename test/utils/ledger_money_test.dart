import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/ledger_money.dart';

void main() {
  group('minorToRupees', () {
    test('converts paise to rupees', () {
      expect(minorToRupees(0), 0);
      expect(minorToRupees(100), 1);
      expect(minorToRupees(27500), 275);
      expect(minorToRupees(-500), -5);
    });

    test('preserves fractional paise as fractional rupees', () {
      expect(minorToRupees(150), 1.5);
      expect(minorToRupees(1), 0.01);
    });
  });

  group('rupeesToMinor', () {
    test('rounds half-up style via round()', () {
      expect(rupeesToMinor(1), 100);
      expect(rupeesToMinor(275.5), 27550);
      expect(rupeesToMinor(0.005), 1);
    });
  });
}
