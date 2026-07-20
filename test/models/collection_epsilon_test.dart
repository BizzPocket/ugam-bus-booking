import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/collection.dart';

/// Regression tests for the audit "float defective" fix (Cluster A):
/// money is a double and prices get divided (bus ÷ seats, sofa ÷ 2, one-leg
/// × 0.5), so sub-rupee dust is unavoidable. Collection's balance classifiers
/// must tolerate that dust with a shared epsilon, otherwise a fully-paid rider
/// is stuck reading "return due"/"owing" forever with an un-clearable ₹0 chip.
void main() {
  Collection c({
    required double due,
    required double received,
    double refunded = 0,
  }) => Collection(
        tourId: 't',
        busId: 'b',
        passengerId: 'p',
        amountDue: due,
        amountReceived: received,
        amountRefunded: refunded,
      );

  group('Collection balance is epsilon-tolerant (0.005 band)', () {
    test('a positive residual within the band reads square, not return-due', () {
      // A sub-rupee overshoot (float dust) must not trap the rider on a warm
      // "change to return ₹0" chip they can never clear.
      final col = c(due: 500, received: 500.003);
      expect(col.balance.abs() < 0.005, isTrue);
      expect(col.isSquare, isTrue);
      expect(col.isReturnDue, isFalse);
      expect(col.isShortfall, isFalse);
      expect(col.changeToReturn, 0);
      expect(col.stillToCollect, 0);
    });

    test('exact-zero balance is square', () {
      final col = c(due: 500, received: 500);
      expect(col.isSquare, isTrue);
      expect(col.changeToReturn, 0);
      expect(col.stillToCollect, 0);
    });

    test('a real overpayment beyond the band still reads return-due', () {
      final col = c(due: 500, received: 600);
      expect(col.isReturnDue, isTrue);
      expect(col.isSquare, isFalse);
      expect(col.changeToReturn, closeTo(100, 1e-9));
    });

    test('a real shortfall beyond the band still reads owing', () {
      final col = c(due: 500, received: 300);
      expect(col.isShortfall, isTrue);
      expect(col.isSquare, isFalse);
      expect(col.stillToCollect, closeTo(200, 1e-9));
    });

    test('a sub-rupee shortfall (dust) is NOT flagged as owing', () {
      final col = c(due: 833.333, received: 833.33);
      expect(col.balance.abs() < 0.005, isTrue);
      expect(col.isSquare, isTrue);
      expect(col.stillToCollect, 0);
    });
  });
}
