import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/models/payment_claim.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';

/// A claim is a rider's ASSERTION that they paid, not money.
///
/// It becomes money only when the agent confirms it, and confirming writes a
/// real `collections` row (`confirm_payment_claim`, migrations 060 + 069) — so
/// from that moment the advance is inside `netCollectedOf` like any other
/// receipt. The controller therefore exposes only the PENDING claim, for the
/// agent to act on. See the note on [MoneyController.pendingClaimForPassenger]
/// for why the "subtract confirmed advances" helpers were removed rather than
/// left unused: they would have double-counted client-side exactly the way
/// audit finding C1 double-counted in the ledger.
void main() {
  late MoneyController money;

  setUp(() {
    money = MoneyController(ledgerSource: LedgerMoneySource());
    money.paymentClaims.value = [
      PaymentClaim(
        id: '1',
        tourId: 't',
        passengerId: 'p1',
        amountRupees: 500,
        status: PaymentClaimStatus.confirmed,
        claimedAt: DateTime(2026, 8, 1),
      ),
      PaymentClaim(
        id: '2',
        tourId: 't',
        passengerId: 'p1',
        amountRupees: 200,
        status: PaymentClaimStatus.pending,
        claimedAt: DateTime(2026, 8, 2),
      ),
    ];
  });

  test('surfaces the rider\'s pending claim for the agent to act on', () {
    expect(money.pendingClaimForPassenger('p1')?.amountRupees, 200);
  });

  test('a confirmed claim is not offered as a pending one', () {
    final pending = money.pendingClaimForPassenger('p1');
    expect(pending?.id, '2', reason: 'the confirmed ₹500 claim is already money');
  });

  test('pendingClaims lists only unverified assertions', () {
    expect(money.pendingClaims.map((c) => c.id), ['2']);
  });

  test('a rider with no claim at all has none pending', () {
    expect(money.pendingClaimForPassenger('nobody'), isNull);
  });
}
