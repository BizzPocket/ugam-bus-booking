import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/services/customer_requests_store.dart';

CustomerRequestEntry _entry({
  String status = 'pending',
  List<SeatAssignment> assignedSeats = const [],
  bool tourLocked = false,
  bool isConfirmed = false,
  DateTime? cancelRequestedAt,
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
      isConfirmed: isConfirmed,
      cancelRequestedAt: cancelRequestedAt,
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

  group('CustomerRequestEntry.canEdit', () {
    const seated = [
      SeatAssignment(busId: 'b1', seatId: 'DU1'),
      SeatAssignment(busId: 'b1', seatId: 'DL1'),
    ];

    // Punam books three berths a fortnight out. The agent seats the party the
    // same evening — that is normal, seating is not a late step here. Two days
    // later she calls to say one traveller dropped out. Before this, holding a
    // seat closed the edit door, so that change could only happen by phone and
    // by hand on the admin side.
    test('a rider already on the chart can still fix their own booking', () {
      final e = _entry(assignedSeats: seated, isConfirmed: true);
      expect(e.hasSeatsAssigned, isTrue);
      expect(e.canEdit, isTrue);
    });

    // The card already reads "Cancellation requested" and the agent is deciding
    // on it. Offering "Edit request" underneath that asks her to argue with
    // herself, and edits the booking the agent is looking at.
    test('asking to cancel takes the edit door away', () {
      final e = _entry(
        assignedSeats: seated,
        isConfirmed: true,
        cancelRequestedAt: DateTime(2026, 6, 14),
      );
      expect(e.cancellationRequested, isTrue);
      expect(e.canEdit, isFalse);
    });

    // Once the agent locks the tour, seat numbers have gone out on WhatsApp.
    // A change from here goes through them, not around them.
    test('a locked tour sends the change back to the organiser', () {
      expect(_entry(assignedSeats: seated, tourLocked: true).canEdit, isFalse);
      // ...including the not-yet-seated rider on that locked tour.
      expect(_entry(tourLocked: true).canEdit, isFalse);
    });

    test('a cancelled or declined ticket is not editable', () {
      expect(_entry(status: 'cancelled').canEdit, isFalse);
      expect(_entry(status: 'rejected').canEdit, isFalse);
    });
  });
}
