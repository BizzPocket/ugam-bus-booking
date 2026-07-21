import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/formatters.dart';

void main() {
  test('negative dust that rounds to zero shows ₹0, not -₹0', () {
    expect(Formatters.formatMoneyInr(-0.004), '₹0');
    expect(Formatters.formatMoneyInr(-0.49), '₹0');
    expect(Formatters.formatMoneyInr(0), '₹0');
  });

  test('real negatives keep the minus after rounding', () {
    expect(Formatters.formatMoneyInr(-1), '-₹1');
    expect(Formatters.formatMoneyInr(-0.5), '-₹1'); // rounds to -1
    expect(Formatters.formatMoneyInr(-123456), '-₹1,23,456');
  });

  test('positives unchanged', () {
    expect(Formatters.formatMoneyInr(123456), '₹1,23,456');
  });
}
