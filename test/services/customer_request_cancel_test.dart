import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/services/customer_requests_store.dart';

/// Guards the customer self-cancel gate: a request is cancellable ONLY while
/// purely pending — not organiser-confirmed and with no seats. Migration 034
/// enforces the same rule server-side; this locks the client half.
void main() {
  CustomerRequestEntry entry({
    String status = 'pending',
    bool isConfirmed = false,
    bool seated = false,
  }) =>
      CustomerRequestEntry(
        id: 'r1',
        tourId: 't1',
        tourTitle: 'Tour',
        tourFromCity: 'A',
        tourToCity: 'B',
        tourDepartureDate: DateTime(2026, 8, 1),
        tourPricePerSeat: 100,
        customerName: 'Ravi',
        customerPhone: '9876543210',
        partySize: 1,
        doubleSofa: 0,
        singleSofa: 0,
        status: status,
        isConfirmed: isConfirmed,
        assignedSeats:
            seated ? const [SeatAssignment(busId: 'b1', seatId: 'A1')] : const [],
        createdAt: DateTime(2026, 7, 1),
      );

  group('canCancel', () {
    test('true only when pending, unconfirmed, and unseated', () {
      expect(entry().canCancel, isTrue);
    });

    test('false once the organiser has confirmed (even with no seats)', () {
      expect(entry(isConfirmed: true).canCancel, isFalse);
    });

    test('false once seats are assigned', () {
      expect(entry(seated: true).canCancel, isFalse);
    });

    test('false when accepted', () {
      expect(entry(status: 'accepted').canCancel, isFalse);
    });

    test('false when already cancelled/rejected', () {
      expect(entry(status: 'cancelled').canCancel, isFalse);
      expect(entry(status: 'rejected').canCancel, isFalse);
    });
  });

  group('isCancelled', () {
    test('true for both the admin-decline and customer-cancel states', () {
      expect(entry(status: 'rejected').isCancelled, isTrue);
      expect(entry(status: 'cancelled').isCancelled, isTrue);
    });

    test('false for live states', () {
      expect(entry().isCancelled, isFalse);
      expect(entry(isConfirmed: true).isCancelled, isFalse);
    });
  });

  group('json round-trip', () {
    test('persists isConfirmed + organiserPhone', () {
      final e = CustomerRequestEntry(
        id: 'r2',
        tourId: 't2',
        tourTitle: 'T',
        tourFromCity: 'A',
        tourToCity: 'B',
        tourDepartureDate: DateTime(2026, 8, 1),
        tourPricePerSeat: 100,
        customerName: 'N',
        customerPhone: '9876543210',
        partySize: 2,
        doubleSofa: 1,
        singleSofa: 0,
        isConfirmed: true,
        organiserPhone: '919999999999',
        createdAt: DateTime(2026, 7, 1),
      );
      final back = CustomerRequestEntry.fromJson(e.toJson());
      expect(back.isConfirmed, isTrue);
      expect(back.organiserPhone, '919999999999');
    });
  });
}
