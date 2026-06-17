import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';

/// The canonical "can this tour still take a NEW booking/request?" gate.
/// Every book/add-request entry point (customer list, customer detail,
/// customer booking form, admin/handler Add Request) must route through this
/// single source of truth — so a locked/completed tour is closed everywhere.
void main() {
  Tour tourWith(TourStatus status) => Tour(
        title: 'Dwarka Yatra',
        fromCity: 'Surat',
        toCity: 'Dwarka',
        departureDate: DateTime(2026, 7, 1),
        pricePerSeat: 1200,
        status: status,
      );

  group('TourStatus.acceptsBookings', () {
    test('open lifecycle states accept new bookings', () {
      expect(TourStatus.planning.acceptsBookings, isTrue);
      expect(TourStatus.collecting.acceptsBookings, isTrue);
      expect(TourStatus.busBooked.acceptsBookings, isTrue);
      expect(TourStatus.assigning.acceptsBookings, isTrue);
    });

    test('locked and completed are closed to new bookings', () {
      expect(TourStatus.locked.acceptsBookings, isFalse);
      expect(TourStatus.completed.acceptsBookings, isFalse);
    });
  });

  group('Tour.acceptsBookings delegates to status', () {
    test('open while assigning, closed once locked', () {
      expect(tourWith(TourStatus.assigning).acceptsBookings, isTrue);
      expect(tourWith(TourStatus.locked).acceptsBookings, isFalse);
      expect(tourWith(TourStatus.completed).acceptsBookings, isFalse);
    });
  });
}
