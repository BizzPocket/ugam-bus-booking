import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/services/customer_requests_store.dart';

CustomerRequestEntry _entry({
  String status = 'pending',
  List<SeatAssignment> assignedSeats = const [],
  bool tourLocked = false,
}) =>
    CustomerRequestEntry(
      id: 'r1',
      tourId: 't1',
      tourTitle: 'punam',
      tourFromCity: 'surat',
      tourToCity: 'bheda pipaliya',
      tourDepartureDate: DateTime(2026, 6, 16),
      tourPricePerSeat: 0,
      customerName: 'punam',
      customerPhone: '+919328959204',
      partySize: 3,
      doubleSofa: 1,
      singleSofa: 1,
      createdAt: DateTime(2026, 6, 10),
      status: status,
      assignedSeats: assignedSeats,
      tourLocked: tourLocked,
    );

void main() {
  group('CustomerRequestEntry.markCancelled', () {
    // The organiser deleted the request (or its whole tour). The locally
    // cached ticket still holds the seats it had when it was live — if we keep
    // them, `seatsVisible` stays true and the row keeps rendering "seats
    // assigned" with stale numbers, and tapping it opens the layout sheet whose
    // live lookup returns nothing → the dead "No layout" empty state.
    final live = _entry(
      status: 'accepted',
      tourLocked: true,
      assignedSeats: const [
        SeatAssignment(busId: 'b1', seatId: 'DU1'),
        SeatAssignment(busId: 'b1', seatId: 'DU1'),
        SeatAssignment(busId: 'b1', seatId: 'SU1'),
      ],
    );

    test('it was rendering as seats-assigned before cancellation', () {
      expect(live.hasSeatsAssigned, isTrue);
      expect(live.seatsVisible, isTrue);
    });

    test('cancelling clears the orphaned seats and lock state', () {
      final cancelled = live.markCancelled(at: DateTime(2026, 6, 15));

      expect(cancelled.status, 'rejected');
      expect(cancelled.assignedSeats, isEmpty);
      expect(cancelled.tourLocked, isFalse);
      // The row must no longer claim seats nor open the (now dead) layout sheet.
      expect(cancelled.hasSeatsAssigned, isFalse);
      expect(cancelled.seatsVisible, isFalse);
      expect(cancelled.lastRefreshedAt, DateTime(2026, 6, 15));
    });

    test('identity / tour fields survive cancellation', () {
      final cancelled = live.markCancelled(at: DateTime(2026, 6, 15));
      expect(cancelled.id, 'r1');
      expect(cancelled.tourTitle, 'punam');
      expect(cancelled.customerPhone, '+919328959204');
    });
  });
}
