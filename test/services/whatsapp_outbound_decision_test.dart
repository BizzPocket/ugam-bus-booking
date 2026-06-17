import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/services/whatsapp_outbound.dart';

Tour _tour(TourStatus status) => Tour(
      title: 'Devam Yatra',
      fromCity: 'Surat',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 6, 16),
      pricePerSeat: 0,
      status: status,
    );

Passenger _pax({List<SeatAssignment> seats = const []}) => Passenger(
      id: 'p1',
      tourId: 't1',
      name: 'Rasik',
      phone: '+919879600000',
      assignedSeats: seats,
    );

const _seat = [SeatAssignment(busId: 'b1', seatId: 'DL1')];

void main() {
  group('WhatsAppOutbound.shouldSendFullAllotment', () {
    // "Notify again" on a LOCKED tour must deliver the full seat-allotment
    // (chart image + boarding place + departure + handler), NOT the lighter
    // pre-lock "seats confirmed" greeting.
    test('locked tour with assigned seats → full allotment', () {
      expect(
        WhatsAppOutbound.shouldSendFullAllotment(
            _tour(TourStatus.locked), _pax(seats: _seat)),
        isTrue,
      );
    });

    test('completed tour with assigned seats → full allotment', () {
      expect(
        WhatsAppOutbound.shouldSendFullAllotment(
            _tour(TourStatus.completed), _pax(seats: _seat)),
        isTrue,
      );
    });

    // Before lock, seat numbers are provisional and stay hidden — re-notify
    // sends only the greeting, never the chart.
    test('assigning tour with assigned seats → greeting only', () {
      expect(
        WhatsAppOutbound.shouldSendFullAllotment(
            _tour(TourStatus.assigning), _pax(seats: _seat)),
        isFalse,
      );
    });

    test('locked tour but NO seats → greeting only (no chart to send)', () {
      expect(
        WhatsAppOutbound.shouldSendFullAllotment(
            _tour(TourStatus.locked), _pax()),
        isFalse,
      );
    });
  });
}
