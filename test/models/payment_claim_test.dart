import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/payment_claim.dart';

void main() {
  test('PaymentClaim.fromMap converts paise and status', () {
    final c = PaymentClaim.fromMap({
      'id': 'c1',
      'tour_id': 't1',
      'passenger_id': 'p1',
      'amount_paise': 50000,
      'upi_ref': 'UTR1',
      'status': 'pending',
      'claimed_at': '2026-08-08T10:00:00.000Z',
    });
    expect(c.amountRupees, 500);
    expect(c.isPending, isTrue);
    expect(c.upiRef, 'UTR1');
  });
}
