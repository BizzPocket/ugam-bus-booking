import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/round_trip_combine.dart';

RequestLine _l(SeatType t, TripType leg, {int qty = 1}) =>
    RequestLine(seatType: t, qty: qty, leg: leg);

void main() {
  const dbl = SeatType.doubleSofa;
  const sgl = SeatType.singleSofa;

  group('hasCombinableRoundTripPairs', () {
    test('a same-type GO + RET pair is combinable', () {
      expect(
        hasCombinableRoundTripPairs(
            [_l(dbl, TripType.outboundOnly), _l(dbl, TripType.returnOnly)]),
        isTrue,
      );
    });

    test('a round-trip line alone is NOT combinable', () {
      expect(hasCombinableRoundTripPairs([_l(dbl, TripType.roundTrip)]), isFalse);
    });

    test('GO + RET of DIFFERENT types is NOT combinable', () {
      expect(
        hasCombinableRoundTripPairs(
            [_l(dbl, TripType.outboundOnly), _l(sgl, TripType.returnOnly)]),
        isFalse,
      );
    });

    test('a lone GO-only line is NOT combinable', () {
      expect(hasCombinableRoundTripPairs([_l(dbl, TripType.outboundOnly)]),
          isFalse);
    });
  });

  group('combineRoundTripPairs', () {
    test('GO double + RET double → ONE round-trip double', () {
      final out = combineRoundTripPairs(
          [_l(dbl, TripType.outboundOnly), _l(dbl, TripType.returnOnly)]);
      expect(out.length, 1);
      expect(out.single.seatType, dbl);
      expect(out.single.leg, TripType.roundTrip);
      expect(out.single.qty, 1);
    });

    test('uneven quantities: 2 GO + 1 RET → 1 round-trip + 1 GO leftover', () {
      final out = combineRoundTripPairs([
        _l(dbl, TripType.outboundOnly, qty: 2),
        _l(dbl, TripType.returnOnly, qty: 1),
      ]);
      final byLeg = {for (final l in out) l.leg: l.qty};
      expect(byLeg[TripType.roundTrip], 1);
      expect(byLeg[TripType.outboundOnly], 1);
      expect(byLeg.containsKey(TripType.returnOnly), isFalse);
    });

    test('only combines within the SAME type; other types pass through', () {
      final out = combineRoundTripPairs([
        _l(dbl, TripType.outboundOnly),
        _l(dbl, TripType.returnOnly),
        _l(sgl, TripType.outboundOnly),
      ]);
      final dblLines = out.where((l) => l.seatType == dbl).toList();
      final sglLines = out.where((l) => l.seatType == sgl).toList();
      expect(dblLines.single.leg, TripType.roundTrip);
      expect(sglLines.single.leg, TripType.outboundOnly); // unchanged
    });

    test('a round-trip line passes through unchanged', () {
      final out = combineRoundTripPairs([_l(dbl, TripType.roundTrip)]);
      expect(out.single.leg, TripType.roundTrip);
      expect(out.single.qty, 1);
    });

    test('combining halves the double UNIT count (2 one-way → 1 round-trip)', () {
      final before = [_l(dbl, TripType.outboundOnly), _l(dbl, TripType.returnOnly)];
      expect(unitCountsOf(before).doubleSofa, 2);
      final after = combineRoundTripPairs(before);
      expect(unitCountsOf(after).doubleSofa, 1);
    });
  });

  group('summaryTripTypeOf', () {
    test('all round-trip → roundTrip', () {
      expect(summaryTripTypeOf([_l(dbl, TripType.roundTrip)]),
          TripType.roundTrip);
    });
    test('all GO-only → outboundOnly', () {
      expect(summaryTripTypeOf([_l(dbl, TripType.outboundOnly)]),
          TripType.outboundOnly);
    });
    test('mixed one-way legs → roundTrip', () {
      expect(
        summaryTripTypeOf(
            [_l(dbl, TripType.outboundOnly), _l(sgl, TripType.returnOnly)]),
        TripType.roundTrip,
      );
    });
  });
}
