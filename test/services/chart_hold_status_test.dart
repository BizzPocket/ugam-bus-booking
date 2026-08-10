import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/chart_hold_status.dart';
import 'package:occubusbooking/services/customer_requests_store.dart';

/// THE REPORTED BUG.
///
/// A customer picked 6 berths (three whole double sofas) on a tour that
/// collects an advance, then dismissed the UPI sheet without paying. Their
/// ticket immediately read "Cancelled" — while the seats were still correctly
/// held on the chart and the organiser correctly showed 0/36 occupied.
///
/// Cause: on the advance path `chart_hold_seats` writes ONLY a `seat_holds`
/// row. The `booking_requests` row is created later, by `chart_finalize_hold`,
/// once the advance is confirmed. `CustomerRequestsStore.refresh()` looked up
/// `booking_request_status_lookup`, got zero rows, and concluded the organiser
/// had deleted the tour — so it called `markCancelled()`.
///
/// "No booking row" is therefore NOT proof of deletion. It is the normal state
/// of a live, unpaid hold. This resolver is the missing distinction.
void main() {
  final now = DateTime(2026, 8, 9, 16, 0);

  CustomerRequestEntry pendingEntry() => CustomerRequestEntry(
        id: 'req-1',
        tourId: 'tour-1',
        tourTitle: '[TEST-A] Chart Booking',
        tourFromCity: 'Ahmedabad',
        tourToCity: 'Dwarka',
        tourDepartureDate: DateTime(2026, 8, 21),
        tourPricePerSeat: 1200,
        customerName: 'Rider',
        customerPhone: '+919000000000',
        partySize: 6,
        doubleSofa: 3,
        singleSofa: 0,
        status: 'pending',
        createdAt: DateTime(2026, 8, 9, 15, 58),
      );

  ChartHoldSnapshot hold({
    required String status,
    required DateTime expiresAt,
  }) =>
      ChartHoldSnapshot(
        requestId: 'req-1',
        busId: 'bus-a',
        status: status,
        expiresAt: expiresAt,
        berths: 6,
      );

  group('a live hold is not a cancellation', () {
    test('an unexpired pending hold resolves to held, never cancelled', () {
      final resolved = resolveMissingBookingRow(
        existing: pendingEntry(),
        hold: hold(
          status: 'pending',
          expiresAt: now.add(const Duration(minutes: 4, seconds: 32)),
        ),
        now: now,
      );

      expect(resolved.status, 'held');
      expect(
        resolved.isCancelled,
        isFalse,
        reason: 'THE BUG: a live unpaid hold rendered as "Cancelled" while its '
            'seats were still blocked on the chart',
      );
      expect(resolved.isHeld, isTrue);
      expect(resolved.holdExpiresAt, isNotNull);
    });

    test('the remaining time drives the countdown', () {
      final resolved = resolveMissingBookingRow(
        existing: pendingEntry(),
        hold: hold(
          status: 'pending',
          expiresAt: now.add(const Duration(minutes: 4, seconds: 32)),
        ),
        now: now,
      );

      expect(
        resolved.holdRemaining(now),
        const Duration(minutes: 4, seconds: 32),
      );
    });

    test('a held booking keeps its seats out of the cancelled bucket', () {
      final resolved = resolveMissingBookingRow(
        existing: pendingEntry(),
        hold: hold(status: 'pending', expiresAt: now.add(const Duration(minutes: 1))),
        now: now,
      );
      expect(resolved.partySize, 6, reason: 'the berth count must survive');
    });
  });

  group('an expired hold is expired, not cancelled', () {
    test('a pending hold whose clock ran out resolves to expired', () {
      final resolved = resolveMissingBookingRow(
        existing: pendingEntry(),
        hold: hold(
          status: 'pending',
          expiresAt: now.subtract(const Duration(seconds: 1)),
        ),
        now: now,
      );

      expect(resolved.status, 'expired');
      expect(resolved.holdExpired, isTrue);
      expect(
        resolved.isCancelled,
        isFalse,
        reason: 'an expired hold is re-bookable; a cancellation is not',
      );
    });

    test('a released hold resolves to expired', () {
      final resolved = resolveMissingBookingRow(
        existing: pendingEntry(),
        hold: hold(
          status: 'released',
          expiresAt: now.add(const Duration(minutes: 4)),
        ),
        now: now,
      );
      expect(resolved.status, 'expired');
    });

    test('remaining time on an expired hold is zero, never negative', () {
      final resolved = resolveMissingBookingRow(
        existing: pendingEntry(),
        hold: hold(
          status: 'pending',
          expiresAt: now.subtract(const Duration(minutes: 3)),
        ),
        now: now,
      );
      expect(resolved.holdRemaining(now), Duration.zero);
    });
  });

  group('genuine deletion still cancels', () {
    test('no booking row and no hold at all means the organiser deleted it', () {
      final resolved = resolveMissingBookingRow(
        existing: pendingEntry(),
        hold: null,
        now: now,
      );

      expect(
        resolved.isCancelled,
        isTrue,
        reason: 'this is the case the original code was written for, and it '
            'must keep working',
      );
      expect(resolved.assignedSeats, isEmpty);
      expect(resolved.tourLocked, isFalse);
    });

    test('an already-rejected entry is never resurrected', () {
      final rejected = pendingEntry().copyWith(status: 'rejected');
      final resolved = resolveMissingBookingRow(
        existing: rejected,
        hold: hold(status: 'pending', expiresAt: now.add(const Duration(minutes: 4))),
        now: now,
      );
      expect(resolved.status, 'rejected');
    });
  });

  group('a finalized hold defers to the booking row', () {
    test('finalized means the booking row exists — leave the entry alone', () {
      // chart_finalize_hold writes the booking_requests row and flips the hold
      // to finalized. If we somehow see finalized here the lookup simply raced;
      // downgrading to cancelled would be wrong.
      final resolved = resolveMissingBookingRow(
        existing: pendingEntry(),
        hold: hold(
          status: 'finalized',
          expiresAt: now.subtract(const Duration(minutes: 1)),
        ),
        now: now,
      );
      expect(resolved.status, 'pending', reason: 'unchanged, not cancelled');
      expect(resolved.isCancelled, isFalse);
    });
  });

  group('paying an advance from My Requests', () {
    CustomerRequestEntry heldEntry({
      String? holdId = 'hold-1',
      int advancePaise = 300000,
      String? vpa = 'ugamtest@upi',
    }) =>
        pendingEntry().copyWith(
          status: 'held',
          holdExpiresAt: now.add(const Duration(minutes: 4)),
          holdId: holdId,
          advancePaise: advancePaise,
          collectVpa: vpa,
        );

    test('a held booking with a payable advance offers Pay now', () {
      expect(heldEntry().canPayAdvance, isTrue);
    });

    test('the advance amount survives so the retry can quote it', () {
      expect(heldEntry().advancePaise, 300000);
      expect(heldEntry().collectVpa, 'ugamtest@upi');
    });

    test('no hold id means there is nothing to pay against', () {
      expect(heldEntry(holdId: null).canPayAdvance, isFalse);
    });

    test('no VPA configured means the organiser cannot be paid online', () {
      expect(heldEntry(vpa: null).canPayAdvance, isFalse);
    });

    test('a zero advance is not payable', () {
      expect(heldEntry(advancePaise: 0).canPayAdvance, isFalse);
    });

    test('an expired hold is no longer payable — it must be re-booked', () {
      final expired = heldEntry().copyWith(status: 'expired');
      expect(expired.canPayAdvance, isFalse);
      expect(expired.holdExpired, isTrue);
    });

    test('a confirmed booking is not payable through the hold path', () {
      expect(pendingEntry().canPayAdvance, isFalse);
    });
  });

  group('summarising a hold for the organiser', () {
    // `tour_pending_seat_holds` already returns the raw seats jsonb; the
    // organiser card just never rendered it, so an unpaid hold showed a name
    // and a phone with no indication of WHICH seats it was sitting on or how
    // long was left. This is what turns that row into something actionable.
    test('names the seats and totals the berths', () {
      final s = summariseHoldSeats([
        {'seatId': 'DU3', 'berths': 2, 'type': 'doubleSofa'},
        {'seatId': 'DU4', 'berths': 2, 'type': 'doubleSofa'},
        {'seatId': 'DU5', 'berths': 2, 'type': 'doubleSofa'},
      ]);
      expect(s.seatIds, ['DU3', 'DU4', 'DU5']);
      expect(s.berths, 6, reason: 'three whole doubles is six people');
    });

    test('a half-taken double counts one berth', () {
      final s = summariseHoldSeats([
        {'seatId': 'DU1', 'berths': 1, 'type': 'doubleSofa'},
        {'seatId': 'SU1', 'berths': 1, 'type': 'singleSofa'},
      ]);
      expect(s.berths, 2);
      expect(s.seatIds, ['DU1', 'SU1']);
    });

    test('a missing berths field defaults to one', () {
      final s = summariseHoldSeats([
        {'seatId': 'ST1'},
      ]);
      expect(s.berths, 1);
    });

    test('junk is survived rather than thrown on', () {
      expect(summariseHoldSeats(null).berths, 0);
      expect(summariseHoldSeats('not a list').seatIds, isEmpty);
      expect(summariseHoldSeats(const []).berths, 0);
    });
  });

  group('ChartHoldSnapshot parsing', () {
    test('reads the RPC row shape', () {
      final snap = ChartHoldSnapshot.fromMap({
        'request_id': 'req-1',
        'bus_id': 'bus-a',
        'status': 'pending',
        'expires_at': '2026-08-09T16:04:32.000Z',
        'berths': 6,
      });
      expect(snap.requestId, 'req-1');
      expect(snap.status, 'pending');
      expect(snap.berths, 6);
      expect(snap.expiresAt, DateTime.parse('2026-08-09T16:04:32.000Z'));
    });

    test('a missing expiry is treated as already expired, not as forever', () {
      final snap = ChartHoldSnapshot.fromMap({
        'request_id': 'req-1',
        'status': 'pending',
      });
      expect(snap.isActiveAt(DateTime(2026, 8, 9, 16)), isFalse);
    });
  });
}
