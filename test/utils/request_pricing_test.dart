import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/request_band.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/request_pricing.dart';

void main() {
  // The real front band off the live bus: rows 0-3 at Rs 1,600 per BERTH.
  const front =
      RequestBand(label: 'બેન્ડ', fromRow: 0, toRow: 3, pricePaise: 160000);

  RequestLine line({
    SeatType type = SeatType.singleSofa,
    int qty = 1,
    TripType leg = TripType.roundTrip,
    RequestBand? band = front,
  }) =>
      RequestLine(seatType: type, qty: qty, leg: leg, band: band);

  group('requestLineChargePaise', () {
    test('charges a single sofa at the band price per berth', () {
      expect(requestLineChargePaise(line(qty: 2)), 320000);
    });

    test('charges a whole double sofa as TWO berths of the band price', () {
      // Bus.berthPriceFor: inside a band every berth costs the band price
      // regardless of seat type, so one double sofa unit is 2 x Rs 1,600.
      expect(
        requestLineChargePaise(line(type: SeatType.doubleSofa, qty: 1)),
        320000,
      );
    });

    test('charges nothing for a go-only line', () {
      // One-leg riders are free and join the waiting list. Even carrying a
      // band, the line must not be billed.
      expect(
        requestLineChargePaise(line(leg: TripType.outboundOnly)),
        0,
      );
    });

    test('charges nothing for a return-only line', () {
      expect(requestLineChargePaise(line(leg: TripType.returnOnly)), 0);
    });

    test('charges nothing for a full-trip line with no band', () {
      // Nothing was quoted, so nothing can be collected. A legacy request must
      // never acquire a price it was never shown.
      expect(requestLineChargePaise(line(band: null)), 0);
    });

    test('charges nothing for a zero-quantity line', () {
      expect(requestLineChargePaise(line(qty: 0)), 0);
    });
  });

  group('requestChargePaise', () {
    test('sums only the chargeable lines of a mixed request', () {
      // 2 single sofas full trip (2 x 1600) + 1 double sofa full trip
      // (2 berths x 1600) = Rs 6,400. The go-only line adds nothing.
      final total = requestChargePaise([
        line(qty: 2),
        line(type: SeatType.doubleSofa, qty: 1),
        line(qty: 3, leg: TripType.outboundOnly),
      ]);

      expect(total, 640000);
    });

    test('is zero for a request that is entirely one-leg', () {
      final total = requestChargePaise([
        line(qty: 2, leg: TripType.outboundOnly),
        line(qty: 1, leg: TripType.returnOnly),
      ]);

      expect(total, 0);
    });

    test('is zero for an empty request', () {
      expect(requestChargePaise(const []), 0);
    });
  });

  group('waiting-list split', () {
    test('a one-leg line is waitlisted, not charged', () {
      expect(isWaitlistLine(line(leg: TripType.outboundOnly)), isTrue);
      expect(isWaitlistLine(line(leg: TripType.returnOnly)), isTrue);
    });

    test('a banded full-trip line is not waitlisted', () {
      expect(isWaitlistLine(line()), isFalse);
    });

    test('an unbanded full-trip line IS waitlisted', () {
      // This is the sold-out path: capacity ran out, so no band could be
      // offered, and the rider joins the list unpaid rather than being turned
      // away.
      expect(isWaitlistLine(line(band: null)), isTrue);
    });
  });
}
