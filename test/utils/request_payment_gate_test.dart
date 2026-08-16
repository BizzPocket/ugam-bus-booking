import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/request_band.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/utils/request_payment_gate.dart';

void main() {
  const front =
      RequestBand(label: 'બેન્ડ', fromRow: 0, toRow: 3, pricePaise: 160000);

  Tour tour({String? vpa = 'ugamtest@upi'}) => Tour(
        id: 't1',
        title: 'Test',
        fromCity: 'Surat',
        toCity: 'Ambaji',
        departureDate: DateTime(2026, 8, 23),
        // 0 is the real shape of a banded tour: the fare lives on the bus.
        pricePerSeat: 0,
        collectVpa: vpa,
        collectPayeeName: 'Ugam Travels',
      );

  RequestLine line({
    TripType leg = TripType.roundTrip,
    RequestBand? band = front,
    int qty = 1,
  }) =>
      RequestLine(seatType: SeatType.singleSofa, qty: qty, leg: leg, band: band);

  group('Tour.canCollectOnline', () {
    test('needs a VPA for the money to land in', () {
      expect(tour().canCollectOnline, isTrue);
      expect(tour(vpa: null).canCollectOnline, isFalse);
      expect(tour(vpa: '   ').canCollectOnline, isFalse);
    });

    test('does NOT require an advance policy', () {
      // `collectsAdvance` also demands advance_per_berth_paise, because the
      // chart flow quotes a FIXED advance. A banded request quotes the band
      // total instead, so that policy is irrelevant here.
      final t = tour();
      expect(t.collectsAdvance, isFalse, reason: 'no advance policy set');
      expect(t.canCollectOnline, isTrue);
    });
  });

  group('planRequestPayment', () {
    test('asks for the band total when the tour can collect', () {
      final plan = planRequestPayment(
        tour: tour(),
        lines: [line(qty: 2)],
      );

      expect(plan.outcome, RequestPaymentOutcome.payNow);
      expect(plan.amountPaise, 320000);
    });

    test('a one-leg-only request is free and waitlisted', () {
      final plan = planRequestPayment(
        tour: tour(),
        lines: [line(leg: TripType.outboundOnly, qty: 2)],
      );

      expect(plan.outcome, RequestPaymentOutcome.waitlistFree);
      expect(plan.amountPaise, 0);
    });

    test('an unbanded request is free and waitlisted', () {
      // The sold-out / unpriced path: nothing was quoted, so nothing is owed.
      final plan = planRequestPayment(
        tour: tour(),
        lines: [line(band: null)],
      );

      expect(plan.outcome, RequestPaymentOutcome.waitlistFree);
    });

    test('a chargeable request on a tour with NO VPA still goes through, free',
        () {
      // The agent forgot to set a collection handle. Blocking the booking would
      // punish the customer for the organiser's omission and lose the sale —
      // the request is taken and the money is collected on the bus, as it
      // always was.
      final plan = planRequestPayment(
        tour: tour(vpa: null),
        lines: [line(qty: 2)],
      );

      expect(plan.outcome, RequestPaymentOutcome.cannotCollect);
      expect(plan.amountPaise, 0, reason: 'nothing can be collected online');
    });

    test('an empty request owes nothing', () {
      final plan = planRequestPayment(tour: tour(), lines: const []);

      expect(plan.outcome, RequestPaymentOutcome.waitlistFree);
      expect(plan.amountPaise, 0);
    });

    test('a mixed request charges only its full-trip half', () {
      final plan = planRequestPayment(
        tour: tour(),
        lines: [line(qty: 2), line(leg: TripType.returnOnly, qty: 3)],
      );

      expect(plan.outcome, RequestPaymentOutcome.payNow);
      expect(plan.amountPaise, 320000);
    });
  });
}
