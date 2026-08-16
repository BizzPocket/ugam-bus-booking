import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/customer_requests_store.dart';

/// The device-local ticket has to remember two things after a banded request is
/// submitted: what is owed, and what the customer has already claimed to have
/// paid. Without the second, "Pay now" keeps offering itself to someone who has
/// already paid, and they pay twice.
CustomerRequestEntry _entry({
  String status = 'pending',
  int advancePaise = 320000,
  int claimedPaise = 0,
  String? collectVpa = 'ugamtest@upi',
  String? holdId,
}) =>
    CustomerRequestEntry(
      id: 'r1',
      tourId: 't1',
      tourTitle: 'Test',
      tourFromCity: 'Surat',
      tourToCity: 'Ambaji',
      tourDepartureDate: DateTime(2026, 8, 23),
      tourPricePerSeat: 0,
      customerName: 'Asha',
      customerPhone: '+919824011223',
      partySize: 2,
      doubleSofa: 0,
      singleSofa: 2,
      createdAt: DateTime(2026, 8, 16),
      status: status,
      advancePaise: advancePaise,
      claimedPaise: claimedPaise,
      collectVpa: collectVpa,
      holdId: holdId,
    );

void main() {
  group('canPayCharge', () {
    test('an unpaid banded request offers payment', () {
      expect(_entry().canPayCharge, isTrue);
    });

    test('a fully claimed request does NOT offer payment again', () {
      expect(_entry(claimedPaise: 320000).canPayCharge, isFalse);
    });

    test('a partly claimed request still offers the rest', () {
      expect(_entry(claimedPaise: 100000).canPayCharge, isTrue);
      expect(_entry(claimedPaise: 100000).outstandingPaise, 220000);
    });

    test('a free request offers nothing to pay', () {
      expect(_entry(advancePaise: 0).canPayCharge, isFalse);
    });

    test('a tour with no VPA offers nothing to pay', () {
      expect(_entry(collectVpa: null).canPayCharge, isFalse);
    });

    test('a cancelled request offers nothing to pay', () {
      expect(_entry(status: 'cancelled').canPayCharge, isFalse);
    });

    test('a seat-hold ticket is left to the hold path, not this one', () {
      // Chart-mode holds already have their own countdown + retry
      // (canPayAdvance). Offering both would put two Pay buttons on one card.
      expect(_entry(holdId: 'h1').canPayCharge, isFalse);
    });
  });

  group('paymentRecorded', () {
    test('is true once the claim covers what was owed', () {
      expect(_entry(claimedPaise: 320000).paymentRecorded, isTrue);
      expect(_entry(claimedPaise: 0).paymentRecorded, isFalse);
    });
  });

  group('serialization', () {
    test('claimedPaise survives a round-trip', () {
      final back = CustomerRequestEntry.fromJson(
        _entry(claimedPaise: 150000).toJson(),
      );

      expect(back.claimedPaise, 150000);
      expect(back.advancePaise, 320000);
      expect(back.collectVpa, 'ugamtest@upi');
    });

    test('a ticket written before this field defaults to nothing claimed', () {
      final back = CustomerRequestEntry.fromJson(const {
        'id': 'r1',
        'tour_id': 't1',
        'tour_title': 'Test',
        'tour_from_city': 'Surat',
        'tour_to_city': 'Ambaji',
        'tour_departure_date': '2026-08-23T00:00:00.000',
        'tour_price_per_seat': 0,
        'customer_name': 'Asha',
        'customer_phone': '+919824011223',
        'party_size': 2,
        'double_sofa': 0,
        'single_sofa': 2,
        'created_at': '2026-08-16T00:00:00.000',
        'status': 'pending',
      });

      expect(back.claimedPaise, 0);
    });
  });
}
