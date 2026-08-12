import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/handler_phase.dart';

/// The phase resolver is the spine of the new handler surface — the banner, the
/// milestone CTA and which leg every tab defaults to all hang off it — so it is
/// tested as pure logic, with no widget or network in the way.
void main() {
  HandlerTripState trip({
    DateTime? go,
    DateTime? arrived,
    DateTime? ret,
    DateTime? done,
  }) => HandlerTripState(
    busId: 'bus-1',
    goDepartedAt: go,
    goArrivedAt: arrived,
    retDepartedAt: ret,
    completedAt: done,
  );

  final t = DateTime(2026, 8, 12, 21, 30);

  group('resolveHandlerPhase', () {
    test('a bus nobody has touched is boarding the GO leg', () {
      expect(
        resolveHandlerPhase(
          trip: const HandlerTripState.fresh('bus-1'),
          hasReturnRiders: true,
          moneySettled: false,
        ),
        HandlerPhase.boardingGo,
      );
    });

    test('stamping departure moves it en route', () {
      expect(
        resolveHandlerPhase(
          trip: trip(go: t),
          hasReturnRiders: true,
          moneySettled: false,
        ),
        HandlerPhase.enRouteGo,
      );
    });

    test('arriving opens return boarding when there are return riders', () {
      expect(
        resolveHandlerPhase(
          trip: trip(go: t, arrived: t),
          hasReturnRiders: true,
          moneySettled: false,
        ),
        HandlerPhase.boardingRet,
      );
    });

    test('return departure runs the return leg', () {
      expect(
        resolveHandlerPhase(
          trip: trip(go: t, arrived: t, ret: t),
          hasReturnRiders: true,
          moneySettled: false,
        ),
        HandlerPhase.enRouteRet,
      );
    });

    test('ending the trip with cash outstanding lands on settling', () {
      expect(
        resolveHandlerPhase(
          trip: trip(go: t, arrived: t, ret: t, done: t),
          hasReturnRiders: true,
          moneySettled: false,
        ),
        HandlerPhase.settling,
      );
    });

    test('ending the trip square closes it', () {
      expect(
        resolveHandlerPhase(
          trip: trip(go: t, arrived: t, ret: t, done: t),
          hasReturnRiders: true,
          moneySettled: true,
        ),
        HandlerPhase.closed,
      );
    });

    // The reason goArrivedAt exists at all rather than keying off the
    // seat-release RPC: a one-way bus has no return leg to board, and parking
    // it on a return boarding screen would strand the handler.
    test('an outbound-only bus goes straight from arrival to settling', () {
      expect(
        resolveHandlerPhase(
          trip: trip(go: t, arrived: t),
          hasReturnRiders: false,
          moneySettled: false,
        ),
        HandlerPhase.settling,
      );
    });

    test('an outbound-only bus that is square closes on arrival', () {
      expect(
        resolveHandlerPhase(
          trip: trip(go: t, arrived: t),
          hasReturnRiders: false,
          moneySettled: true,
        ),
        HandlerPhase.closed,
      );
    });

    // Money is the only thing between settling and closed, so a handler still
    // holding cash can never see a state that reads as finished.
    test('outstanding cash keeps a completed trip out of closed', () {
      final phase = resolveHandlerPhase(
        trip: trip(go: t, arrived: t, ret: t, done: t),
        hasReturnRiders: true,
        moneySettled: false,
      );
      expect(phase, isNot(HandlerPhase.closed));
      expect(phase, HandlerPhase.settling);
    });
  });

  group('milestoneFor', () {
    test('offers exactly one milestone per moving phase', () {
      expect(milestoneFor(HandlerPhase.boardingGo), HandlerMilestone.departGo);
      expect(milestoneFor(HandlerPhase.enRouteGo), HandlerMilestone.arriveGo);
      expect(
        milestoneFor(HandlerPhase.boardingRet),
        HandlerMilestone.departRet,
      );
      expect(milestoneFor(HandlerPhase.enRouteRet), HandlerMilestone.endTrip);
    });

    test('settling and closed offer no stamp', () {
      expect(milestoneFor(HandlerPhase.settling), isNull);
      expect(milestoneFor(HandlerPhase.closed), isNull);
    });
  });

  group('phase flags', () {
    test('boarding phases are boarding, en-route phases are en route', () {
      expect(HandlerPhase.boardingGo.isBoarding, isTrue);
      expect(HandlerPhase.boardingRet.isBoarding, isTrue);
      expect(HandlerPhase.enRouteGo.isBoarding, isFalse);
      expect(HandlerPhase.enRouteGo.isEnRoute, isTrue);
      expect(HandlerPhase.enRouteRet.isEnRoute, isTrue);
      expect(HandlerPhase.settling.isEnRoute, isFalse);
    });

    test('return-side phases are the two after arrival', () {
      expect(HandlerPhase.boardingRet.isReturnSide, isTrue);
      expect(HandlerPhase.enRouteRet.isReturnSide, isTrue);
      expect(HandlerPhase.boardingGo.isReturnSide, isFalse);
      expect(HandlerPhase.enRouteGo.isReturnSide, isFalse);
    });
  });

  group('HandlerTripState', () {
    test('parses the RPC row', () {
      final s = HandlerTripState.fromMap({
        'bus_id': 'bus-9',
        'go_departed_at': '2026-08-12T16:00:00Z',
        'go_arrived_at': null,
        'ret_departed_at': null,
        'completed_at': null,
      });
      expect(s.busId, 'bus-9');
      expect(s.goDepartedAt, isNotNull);
      expect(s.goArrivedAt, isNull);
    });

    test('a fresh state has no stamps', () {
      const s = HandlerTripState.fresh('bus-2');
      expect(s.goDepartedAt, isNull);
      expect(s.completedAt, isNull);
      expect(s.busId, 'bus-2');
    });
  });
}
