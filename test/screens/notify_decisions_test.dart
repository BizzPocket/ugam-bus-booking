import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/screens/notify_screen.dart';
import 'package:occubusbooking/services/whatsapp_cloud_service.dart';

/// The Notify screen decides WHO receives a paid WhatsApp message and WHEN a
/// rider is considered done. Both answers were shipped with no test at all, and
/// both were wrong in ways that end with a real passenger never being told
/// anything. The rules are pure functions precisely so they can be pinned here.
void main() {
  Tour tour(
    String id, {
    TourStatus status = TourStatus.locked,
    List<Passenger> passengers = const [],
    DateTime? createdAt,
  }) =>
      Tour(
        id: id,
        title: id,
        fromCity: 'Rajkot',
        toCity: 'Dwarka',
        departureDate: DateTime(2026, 3, 1),
        pricePerSeat: 1200,
        status: status,
        passengers: passengers,
        createdAt: createdAt ?? DateTime(2026, 1, 1),
      );

  SeatAssignment seat(String seatId) =>
      SeatAssignment(busId: 'bus-1', seatId: seatId, leg: TripType.roundTrip);

  Passenger rider(
    String id, {
    String phone = '9900000001',
    List<SeatAssignment> seats = const [],
    String? notifiedSig,
  }) =>
      Passenger(
        id: id,
        tourId: 't1',
        name: id,
        phone: phone,
        assignedSeats: seats,
        seatsNotifiedSig: notifiedSig,
      );

  // ── GAP 3 — never silently retarget another tour ──────────────────
  group('resolveNotifyTour', () {
    test('a COMPLETED scoped tour resolves to nothing, not to another tour', () {
      // The exact shipping hazard: tour-detail pushes Lock/Notify for a
      // completed tour, completed tours are filtered out of the candidates,
      // and the old `?? activeTours.first` handed back a DIFFERENT trip whose
      // passengers the next tap would have messaged.
      final done = tour('done', status: TourStatus.completed);
      final other = tour('other', createdAt: DateTime(2026, 2, 1));

      final r = resolveNotifyTour(allTours: [done, other], selectedId: 'done');

      expect(r.tour, isNull);
      expect(r.state, NotifyTourState.completed);
      expect(
        r.active.map((t) => t.id),
        ['other'],
        reason: 'the other tour is still a valid destination, just not THIS one',
      );
    });

    test('a scoped tour that is gone entirely resolves to nothing', () {
      final r = resolveNotifyTour(
        allTours: [tour('other')],
        selectedId: 'deleted',
      );
      expect(r.tour, isNull);
      expect(r.state, NotifyTourState.missing);
    });

    test('a scoped tour that IS active resolves to itself', () {
      final wanted = tour('wanted', createdAt: DateTime(2026, 1, 1));
      final newer = tour('newer', createdAt: DateTime(2026, 5, 1));

      final r =
          resolveNotifyTour(allTours: [newer, wanted], selectedId: 'wanted');

      expect(r.tour?.id, 'wanted',
          reason: 'the newest tour sorts first but must never win a scoped ask');
      expect(r.state, NotifyTourState.ok);
    });

    test('unscoped mode still picks the newest active tour', () {
      final older = tour('older', createdAt: DateTime(2026, 1, 1));
      final newer = tour('newer', createdAt: DateTime(2026, 5, 1));

      final r = resolveNotifyTour(allTours: [older, newer], selectedId: null);

      expect(r.tour?.id, 'newer');
      expect(r.state, NotifyTourState.ok);
    });

    test('unscoped mode with nothing active reports no active tours', () {
      final r = resolveNotifyTour(
        allTours: [tour('done', status: TourStatus.completed)],
        selectedId: null,
      );
      expect(r.tour, isNull);
      expect(r.state, NotifyTourState.noActiveTours);
    });

    test('an empty roster is not an excuse to invent a tour', () {
      expect(
        resolveNotifyTour(allTours: const [], selectedId: 't1').tour,
        isNull,
      );
      expect(
        resolveNotifyTour(allTours: const [], selectedId: null).state,
        NotifyTourState.noActiveTours,
      );
    });
  });

  // ── GAP 2 — success belongs to a passenger, not to a phone ────────
  group('notifiedPassengerIds', () {
    WaRecipientResult res(String? id, {required bool ok, String to = '91990000'}) =>
        WaRecipientResult(
          to: to,
          ok: ok,
          passengerId: id,
          error: ok ? null : 'failed',
        );

    WaSendResult batch(List<WaRecipientResult> rs) => WaSendResult(
          sent: rs.where((r) => r.ok).length,
          failed: rs.where((r) => !r.ok).length,
          results: rs,
        );

    test('a family sharing ONE phone is stamped one row at a time', () {
      // Three passenger rows, one handset. Only p1's message went out.
      final result = batch([
        res('p1', ok: true),
        res('p2', ok: false),
      ]);

      expect(
        notifiedPassengerIds(
          result: result,
          requested: {'p1', 'p2', 'p3'},
        ),
        {'p1'},
        reason: 'the old phone match stamped p2 and p3 too, and a rider marked '
            'notified never appears in a "needs notifying" surface again',
      );
    });

    test('a rider never in the batch is never stamped', () {
      final result = batch([res('p1', ok: true), res('stranger', ok: true)]);
      expect(
        notifiedPassengerIds(result: result, requested: {'p1'}),
        {'p1'},
      );
    });

    test('an unattributable success stamps nobody', () {
      // No passengerId came back, so there is no way to know whose message
      // this was. Surfacing them again costs one duplicate; guessing costs a
      // passenger who is never contacted.
      final result = batch([res(null, ok: true)]);
      expect(notifiedPassengerIds(result: result, requested: {'p1'}), isEmpty);
    });

    test('a rider recorded both ok and failed stays pending', () {
      final result = batch([res('p1', ok: true), res('p1', ok: false)]);
      expect(
        notifiedPassengerIds(result: result, requested: {'p1'}),
        isEmpty,
        reason: 'not provably delivered — bias to surfacing, never to silence',
      );
    });

    test('an empty send stamps nobody', () {
      expect(
        notifiedPassengerIds(
          result: WaSendResult.empty,
          requested: {'p1', 'p2'},
        ),
        isEmpty,
      );
    });

    test('every message succeeding stamps the whole batch', () {
      final result = batch([res('p1', ok: true), res('p2', ok: true)]);
      expect(
        notifiedPassengerIds(result: result, requested: {'p1', 'p2'}),
        {'p1', 'p2'},
      );
    });
  });

  // ── GAP 1 — an unseated rider must stay visible ───────────────────
  group('notifyRoster / notifyRowState', () {
    test('a rider unseated AFTER notifying stays on the tracker', () {
      final notifiedSig = rider('x', seats: [seat('DL3')]).seatSignature;
      final stranded = rider('stranded', seats: const [], notifiedSig: notifiedSig);
      final seated = rider('seated', seats: [seat('DL4')]);

      final roster = notifyRoster(tour('t1', passengers: [stranded, seated]));

      expect(
        roster.map((p) => p.id),
        ['stranded', 'seated'],
        reason: 'the old assignedSeats.isNotEmpty filter dropped them silently',
      );
      expect(notifyRowState(stranded), NotifyRowState.seatRemoved);
    });

    test('a stranded rider never reads as notified', () {
      final stranded = rider('s', notifiedSig: 'bus-1:DL3');
      expect(notifyRowState(stranded), isNot(NotifyRowState.notified));
    });

    test('a rider who was never seated and never notified is not on the list',
        () {
      final waiting = rider('waiting');
      final roster = notifyRoster(tour('t1', passengers: [waiting]));
      expect(
        roster,
        isEmpty,
        reason: 'nothing was promised to them, so there is nothing to correct',
      );
    });

    test('classifies seated riders as pending or notified', () {
      final seats = [seat('DL5')];
      final fresh = rider('fresh', seats: seats);
      final done = rider('done', seats: seats, notifiedSig: fresh.seatSignature);

      expect(notifyRowState(fresh), NotifyRowState.pending);
      expect(notifyRowState(done), NotifyRowState.notified);
    });

    test('the roster keeps the tracker counts honest about stranded riders', () {
      final seats = [seat('DL6')];
      final done = rider('done', seats: seats, notifiedSig: rider('x', seats: seats).seatSignature);
      final stranded = rider('stranded', notifiedSig: 'bus-1:DL7');

      final roster = notifyRoster(tour('t1', passengers: [done, stranded]));
      final sent =
          roster.where((p) => notifyRowState(p) == NotifyRowState.notified).length;

      expect(sent, 1);
      expect(
        sent < roster.length,
        isTrue,
        reason: 'the progress card must not claim "everyone has been notified" '
            'while somebody is holding a message about a seat we took back',
      );
    });
  });
}
