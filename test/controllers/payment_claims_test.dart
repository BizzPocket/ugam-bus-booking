import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/models/payment_claim.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';

void main() {
  test('dueAfterAdvances subtracts only confirmed claims', () {
    final money = MoneyController(ledgerSource: LedgerMoneySource());
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

    expect(money.confirmedAdvanceForPassenger('p1'), 500);
    expect(money.dueAfterAdvances(passengerId: 'p1', liveFare: 2000), 1500);
    expect(money.pendingClaimForPassenger('p1')?.amountRupees, 200);
  });
}
