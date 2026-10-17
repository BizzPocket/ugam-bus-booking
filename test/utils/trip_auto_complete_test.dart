import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/handler_phase.dart';
import 'package:occubusbooking/utils/trip_auto_complete.dart';

/// The calendar rule that finishes a trip nobody stamped as finished. Every
/// case is a real way a tour runs here: the overnight pilgrimage, the day
/// trip, the one-way drop, a tour the office already closed, and a handler
/// who did stamp everything.
void main() {
  group('multi-day trip (departs 11 Oct, returns 13 Oct)', () {
    final dep = DateTime(2026, 10, 11);
    final ret = DateTime(2026, 10, 13);

    test('GO leg ends when the return day starts', () {
      expect(
        goLegAutoCompleteAt(departure: dep, returnDate: ret),
        DateTime(2026, 10, 13),
      );
    });

    test('the night before the return the bus is still outbound', () {
      expect(
        isGoLegAutoComplete(
          now: DateTime(2026, 10, 12, 23, 59),
          departure: dep,
          returnDate: ret,
        ),
        isFalse,
      );
    });

    test('at midnight of the return day the GO leg is over', () {
      expect(
        isGoLegAutoComplete(
          now: DateTime(2026, 10, 13),
          departure: dep,
          returnDate: ret,
        ),
        isTrue,
      );
    });

    test('the trip runs through the whole return day', () {
      expect(
        isTripAutoComplete(
          now: DateTime(2026, 10, 13, 23, 30),
          departure: dep,
          returnDate: ret,
        ),
        isFalse,
      );
      expect(
        isTripAutoComplete(
          now: DateTime(2026, 10, 14, 0, 1),
          departure: dep,
          returnDate: ret,
        ),
        isTrue,
      );
    });

    test('the time stored on the dates is ignored', () {
      expect(
        goLegAutoCompleteAt(
          departure: DateTime(2026, 10, 11, 5, 30),
          returnDate: DateTime(2026, 10, 13, 3),
        ),
        DateTime(2026, 10, 13),
      );
    });
  });

  group('one-day trip (departs and returns 13 Sep)', () {
    final day = DateTime(2026, 9, 13);

    test('the GO leg does NOT end the morning the bus leaves', () {
      expect(
        isGoLegAutoComplete(
          now: DateTime(2026, 9, 13, 6),
          departure: day,
          returnDate: day,
        ),
        isFalse,
      );
    });

    test('GO and trip both end at the start of the next day', () {
      expect(
        goLegAutoCompleteAt(departure: day, returnDate: day),
        DateTime(2026, 9, 14),
      );
      expect(
        tripAutoCompleteAt(departure: day, returnDate: day),
        DateTime(2026, 9, 14),
      );
    });
  });

  group('one-way tour (departs 24 Sep, no return)', () {
    final dep = DateTime(2026, 9, 24);

    test('GO leg and trip end the day after departure', () {
      expect(goLegAutoCompleteAt(departure: dep), DateTime(2026, 9, 25));
      expect(tripAutoCompleteAt(departure: dep), DateTime(2026, 9, 25));
    });

    test('still running on departure night', () {
      expect(
        isTripAutoComplete(now: DateTime(2026, 9, 24, 22), departure: dep),
        isFalse,
      );
    });
  });

  group('a return date typed before the departure', () {
    // Live: departs 12 Sep, "returns" 15 Jun. Read literally, the archive
    // sweep completed the tour on the first admin open — and a completed tour
    // stops accepting the bus's location.
    final dep = DateTime(2026, 9, 12);
    final typo = DateTime(2026, 6, 15);

    test('is ignored — the tour is treated as one-way', () {
      expect(
        tripAutoCompleteAt(departure: dep, returnDate: typo),
        DateTime(2026, 9, 13),
      );
      expect(
        isTripAutoComplete(
          now: DateTime(2026, 9, 12, 18),
          departure: dep,
          returnDate: typo,
        ),
        isFalse,
      );
    });
  });

  test('month and year boundaries roll over', () {
    expect(
      tripAutoCompleteAt(
        departure: DateTime(2026, 12, 29),
        returnDate: DateTime(2026, 12, 31),
      ),
      DateTime(2027, 1, 1),
    );
  });

  group('TourSchedule', () {
    test('parses the tours row', () {
      final s = TourSchedule.fromMap({
        'departure_date': '2026-10-11',
        'return_date': '2026-10-13',
        'status': 'locked',
      })!;
      expect(s.goLegOver(DateTime(2026, 10, 12, 20)), isFalse);
      expect(s.goLegOver(DateTime(2026, 10, 13, 6)), isTrue);
      expect(s.tripOver(DateTime(2026, 10, 13, 20)), isFalse);
      expect(s.tripOver(DateTime(2026, 10, 14, 1)), isTrue);
    });

    test('a tour the office already completed is over whatever the date', () {
      final s = TourSchedule.fromMap({
        'departure_date': '2026-10-31',
        'return_date': '2026-11-02',
        'status': 'completed',
      })!;
      expect(s.tripOver(DateTime(2026, 10, 31, 9)), isTrue);
    });

    test('no departure date means no calendar at all', () {
      expect(TourSchedule.fromMap({'status': 'locked'}), isNull);
    });
  });

  group('wired into the handler phase', () {
    final s = TourSchedule.fromMap({
      'departure_date': '2026-10-11',
      'return_date': '2026-10-13',
      'status': 'locked',
    })!;
    final departedOnly = HandlerTripState(
      busId: 'bus-1',
      goDepartedAt: DateTime(2026, 10, 11, 17, 44),
    );

    HandlerPhase at(DateTime now, HandlerTripState trip) =>
        resolveHandlerPhase(
          trip: trip,
          hasReturnRiders: true,
          moneySettled: false,
          tourCompleted: s.tripOver(now),
          goLegAutoCompleted: s.goLegOver(now),
        );

    test('departure day: on the road outbound', () {
      expect(at(DateTime(2026, 10, 11, 20), departedOnly), HandlerPhase.enRouteGo);
    });

    test('return morning, arrival never stamped: return boarding', () {
      expect(at(DateTime(2026, 10, 13, 7), departedOnly), HandlerPhase.boardingRet);
    });

    test('the day after the return: down to the cash', () {
      expect(at(DateTime(2026, 10, 14, 9), departedOnly), HandlerPhase.settling);
    });

    test('a handler who stamped everything is not second-guessed', () {
      final stamped = HandlerTripState(
        busId: 'bus-1',
        goDepartedAt: DateTime(2026, 10, 11, 17),
        goArrivedAt: DateTime(2026, 10, 12, 6),
        retDepartedAt: DateTime(2026, 10, 12, 21),
      );
      // Mid-trip the stamps lead, not the calendar.
      expect(at(DateTime(2026, 10, 12, 22), stamped), HandlerPhase.enRouteRet);
      expect(at(DateTime(2026, 10, 13, 2), stamped), HandlerPhase.enRouteRet);
    });
  });
}
