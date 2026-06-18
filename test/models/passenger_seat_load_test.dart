import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

// Trip-aware seat counting: a physical seat spans the whole trip (GO + RET), so
// a round-trip booking weighs a full 1.0 seat while a one-leg booking weighs
// 0.5 — and per-leg berth load (goBerths/retBerths) is the capacity truth.

// The leg now lives per request line, so apply [trip] to each line's leg
// (the new per-line getters ignore the passenger-level tripType).
Passenger _p(List<RequestLine> lines, TripType trip) => Passenger(
      id: 'p',
      tourId: 't',
      name: 'n',
      phone: '+910000000000',
      requestLines: lines.map((l) => l.copyWith(leg: trip)).toList(),
      tripType: trip,
    );

RequestLine _single({int qty = 1}) =>
    RequestLine(seatType: SeatType.singleSofa, position: null, qty: qty);
RequestLine _double({int qty = 1}) =>
    RequestLine(seatType: SeatType.doubleSofa, position: null, qty: qty);

void main() {
  group('seatLoad (per-passenger weight)', () {
    test('round-trip single sofa weighs a full 1.0 seat', () {
      expect(_p([_single()], TripType.roundTrip).seatLoad, 1.0);
    });

    test('one-leg single sofa weighs 0.5 (GO-only and RET-only alike)', () {
      expect(_p([_single()], TripType.outboundOnly).seatLoad, 0.5);
      expect(_p([_single()], TripType.returnOnly).seatLoad, 0.5);
    });

    test('round-trip double sofa weighs 2.0 (two berths, both legs)', () {
      expect(_p([_double()], TripType.roundTrip).seatLoad, 2.0);
    });

    test('one-way double sofa weighs 1.0 (two berths, one leg)', () {
      expect(_p([_double()], TripType.outboundOnly).seatLoad, 1.0);
    });
  });

  group('goBerths / retBerths (per-leg capacity load)', () {
    test('round-trip loads both legs equally', () {
      final p = _p([_single(), _double()], TripType.roundTrip); // 3 berths
      expect(p.goBerths, 3);
      expect(p.retBerths, 3);
    });

    test('GO-only loads the outbound leg only', () {
      final p = _p([_single()], TripType.outboundOnly);
      expect(p.goBerths, 1);
      expect(p.retBerths, 0);
    });

    test('RET-only loads the return leg only', () {
      final p = _p([_double()], TripType.returnOnly);
      expect(p.goBerths, 0);
      expect(p.retBerths, 2);
    });
  });

  // Rows written before the per-line `leg` field carried the leg ONLY on the
  // passenger's `trip_type`; their request_lines have no `leg` key. fromMap must
  // backfill those legless lines from trip_type, or every pre-migration one-way
  // rider silently reads as round-trip (wrong capacity, seat never frees on the
  // completed leg).
  group('legacy leg backfill (Passenger.fromMap)', () {
    Map<String, dynamic> legacyMap(String tripType) => {
          'id': 'p1',
          'tour_id': 't1',
          'name': 'Legacy',
          'phone': '+910000000000',
          'trip_type': tripType,
          // legacy line: NO 'leg' key
          'request_lines': [
            {'seatType': 'singleSofa', 'position': null, 'qty': 1},
          ],
        };

    test('legless line inherits an outbound-only trip_type', () {
      final p = Passenger.fromMap(legacyMap('outboundOnly'));
      expect(p.requestLines.single.leg, TripType.outboundOnly);
      expect(p.goBerths, 1);
      expect(p.retBerths, 0);
    });

    test('legless line inherits a return-only trip_type', () {
      final p = Passenger.fromMap(legacyMap('returnOnly'));
      expect(p.requestLines.single.leg, TripType.returnOnly);
      expect(p.goBerths, 0);
      expect(p.retBerths, 1);
    });

    test('legless line with round-trip trip_type stays round-trip', () {
      final p = Passenger.fromMap(legacyMap('roundTrip'));
      expect(p.requestLines.single.leg, TripType.roundTrip);
    });

    test('an explicit per-line leg always wins over trip_type', () {
      final map = legacyMap('outboundOnly');
      (map['request_lines'] as List)[0]['leg'] = 'returnOnly';
      final p = Passenger.fromMap(map);
      expect(p.requestLines.single.leg, TripType.returnOnly,
          reason: 'new rows serialize an explicit leg; never overridden');
    });
  });
}
