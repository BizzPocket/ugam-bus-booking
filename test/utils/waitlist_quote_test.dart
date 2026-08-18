import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/request_band.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/request_pricing.dart';

void main() {
  // The live front band: Rs 1,600 per BERTH.
  const front =
      RequestBand(label: 'બેન્ડ', fromRow: 0, toRow: 3, pricePaise: 160000);

  RequestLine line({
    SeatType type = SeatType.singleSofa,
    int qty = 1,
    TripType leg = TripType.outboundOnly,
  }) =>
      RequestLine(seatType: type, qty: qty, leg: leg);

  group('waitlistQuotePaise', () {
    test('a one-leg single sofa is half the band price', () {
      // The organiser picks the band; the rider uses ONE leg of that berth, so
      // they pay half — the same tripFactor the fare engine already applies.
      expect(waitlistQuotePaise(band: front, lines: [line()]), 80000);
    });

    test('a one-leg WHOLE double sofa is half of its two berths', () {
      // Two berths at Rs 1,600, halved for the single leg = Rs 1,600.
      expect(
        waitlistQuotePaise(
          band: front,
          lines: [line(type: SeatType.doubleSofa)],
        ),
        160000,
      );
    });

    test('quantity multiplies', () {
      expect(waitlistQuotePaise(band: front, lines: [line(qty: 3)]), 240000);
    });

    test('a return-only line is priced the same as a go-only one', () {
      expect(
        waitlistQuotePaise(
          band: front,
          lines: [line(leg: TripType.returnOnly)],
        ),
        80000,
      );
    });

    test('a round-trip line in the mix is charged in FULL', () {
      // Half price buys one leg. A rider who also wants the return pays for it.
      final total = waitlistQuotePaise(band: front, lines: [
        line(),                              // go-only  ->  800
        line(leg: TripType.roundTrip),       // full     -> 1600
      ]);

      expect(total, 240000);
    });

    test('an odd band price rounds half AWAY from zero', () {
      // Rs 1,351.35 -> 135135 paise per berth; half is 67567.5. Dart and
      // Postgres both round half away from zero, so the two sides agree.
      const odd =
          RequestBand(label: 'x', fromRow: 0, toRow: 0, pricePaise: 135135);

      expect(waitlistQuotePaise(band: odd, lines: [line()]), 67568);
    });

    test('the rider\'s OWN band is ignored — the organiser picks', () {
      // A waitlisted rider never chose a band, but a line may still carry one
      // from an earlier edit. The organiser's choice is what gets quoted.
      const other =
          RequestBand(label: 'y', fromRow: 5, toRow: 5, pricePaise: 120000);
      final withOwn = RequestLine(
        seatType: SeatType.singleSofa,
        qty: 1,
        leg: TripType.outboundOnly,
        band: other,
      );

      expect(waitlistQuotePaise(band: front, lines: [withOwn]), 80000);
    });

    test('no lines owe nothing', () {
      expect(waitlistQuotePaise(band: front, lines: const []), 0);
    });

    test('a zero-quantity line owes nothing', () {
      expect(waitlistQuotePaise(band: front, lines: [line(qty: 0)]), 0);
    });
  });
}
