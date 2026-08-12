import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// The Notify tracker's "Sent" state rests entirely on this getter.
///
/// *** WHY THIS TEST EXISTS ***
/// The tracker used to derive "Sent" from a session-only `Set<String>` of ids,
/// cleared on restart and on tour switch. After any reload the roster read
/// "Pending" and the counts read 0-sent, while the CTA — which already read
/// this persisted signature — correctly said there was nothing left to send.
/// An organiser trusting the list would re-broadcast PAID WhatsApp messages to
/// riders who had already received them. The tracker now reads this getter, so
/// these are the cases it must get right.
void main() {
  const busId = 'bus-1';

  Passenger rider({
    List<SeatAssignment> seats = const [],
    String? notifiedSig,
  }) =>
      Passenger(
        tourId: 't1',
        name: 'Rider',
        phone: '9900000000',
        assignedSeats: seats,
        seatsNotifiedSig: notifiedSig,
        tripType: TripType.roundTrip,
      );

  /// *** WHY THE "SEAT REMOVED" CASES EXIST ***
  /// [Passenger.seatsChangedSinceNotified] is false the moment a rider holds no
  /// seat, and every Notify surface filtered on `assignedSeats.isNotEmpty`
  /// before showing anyone. So an organiser removing a seat AFTER lock dropped
  /// that rider out of the tracker, the counts and the CTA at once — they were
  /// holding a WhatsApp message naming seat DL3, the seat was gone, and nothing
  /// would ever correct it. They arrive on the day expecting a berth.

  SeatAssignment seat(String id) =>
      SeatAssignment(busId: busId, seatId: id, leg: TripType.roundTrip);

  test('a rider who has never been notified counts as NOT sent', () {
    final p = rider(seats: [seat('SU1')]);
    expect(
      p.seatsChangedSinceNotified,
      isTrue,
      reason: 'a fresh lock must show the whole roster as pending',
    );
  });

  test('a rider whose current seats were notified counts as sent', () {
    final seats = [seat('SU1')];
    final p = rider(seats: seats, notifiedSig: rider(seats: seats).seatSignature);
    expect(p.seatsChangedSinceNotified, isFalse);
  });

  test('editing the seats after notifying flips them back to pending', () {
    final before = rider(seats: [seat('SU1')]);
    // Notified on SU1, then the organiser moved them to SU2.
    final after = rider(
      seats: [seat('SU2')],
      notifiedSig: before.seatSignature,
    );
    expect(
      after.seatsChangedSinceNotified,
      isTrue,
      reason: 'a post-lock seat move must re-flag ONLY that rider',
    );
  });

  test('the signature ignores the order the seats arrive in', () {
    final a = rider(seats: [seat('SU1'), seat('SU2')]);
    final b = rider(seats: [seat('SU2'), seat('SU1')]);
    expect(
      a.seatSignature,
      b.seatSignature,
      reason: 'an unstable order would re-flag every rider on every reload, '
          'which is the paid-message re-broadcast this guards against',
    );
    expect(rider(seats: [seat('SU2'), seat('SU1')],
            notifiedSig: a.seatSignature).seatsChangedSinceNotified,
        isFalse);
  });

  test('a rider holding no seat is never pending', () {
    expect(rider().seatsChangedSinceNotified, isFalse);
  });

  group('a seat withdrawn AFTER the rider was notified', () {
    test('is flagged, even though the rider now holds nothing', () {
      final before = rider(seats: [seat('DL3')]);
      // Notified on DL3, then the organiser took the seat away entirely.
      final after = rider(seats: const [], notifiedSig: before.seatSignature);

      expect(
        after.seatsChangedSinceNotified,
        isFalse,
        reason: 'documents the gap: the old flag cannot see this rider at all',
      );
      expect(
        after.seatsRemovedSinceNotified,
        isTrue,
        reason: 'they hold a message naming a seat that no longer exists',
      );
      expect(after.notifiedSeatsAreStale, isTrue);
    });

    test('clears once the withdrawal itself has been acknowledged', () {
      // markSeatsNotified stamps the CURRENT signature, which for a seatless
      // rider is the empty string — that is what takes them off the list.
      final acked = rider(seats: const [], notifiedSig: '');
      expect(acked.seatsRemovedSinceNotified, isFalse);
      expect(acked.notifiedSeatsAreStale, isFalse);
    });

    test('does not fire for a rider who was never notified', () {
      final neverSeated = rider();
      expect(neverSeated.seatsRemovedSinceNotified, isFalse);
      expect(
        neverSeated.notifiedSeatsAreStale,
        isFalse,
        reason: 'nothing was promised, so nothing needs correcting',
      );
    });

    test('does not fire while the rider still holds a seat', () {
      // A seat MOVE is the other flag's job; only a total withdrawal is this
      // one's, so the two can never both claim the same rider.
      final moved = rider(
        seats: [seat('DL4')],
        notifiedSig: rider(seats: [seat('DL3')]).seatSignature,
      );
      expect(moved.seatsRemovedSinceNotified, isFalse);
      expect(moved.seatsChangedSinceNotified, isTrue);
    });

    test('partial withdrawal stays a seat CHANGE, not a removal', () {
      final before = rider(seats: [seat('DL3'), seat('DL4')]);
      final after = rider(seats: [seat('DL3')], notifiedSig: before.seatSignature);
      expect(after.seatsRemovedSinceNotified, isFalse);
      expect(
        after.seatsChangedSinceNotified,
        isTrue,
        reason: 'a chart can still be drawn, so it is an ordinary re-notify',
      );
    });
  });
}
