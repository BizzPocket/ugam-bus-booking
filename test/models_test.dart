import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/age_group.dart';
import 'package:occubusbooking/models/booking.dart';
import 'package:occubusbooking/models/payment_status.dart';
import 'package:occubusbooking/models/booking_input.dart';

void main() {
  group('Models Tests', () {
    test('Bus capacity and seat counting works', () {
      final bus = Bus(
        id: 'B1',
        name: 'Test Bus',
        totalCapacity: 40,
        seatConfiguration: SeatConfiguration(
          singleSofaBottom: 10,
          singleSofaUpper: 10,
          doubleSofaBottom: 10,
          doubleSofaUpper: 10,
        ),
      );

      expect(bus.totalCapacity, 40);
      expect(bus.getAvailableSeatsByType(SeatType.singleSofa), 20);
      expect(bus.getAvailableSeatsByType(SeatType.doubleSofa), 20);
    });

    test('Booking copyWith works', () {
      final booking = Booking(
        id: '123',
        customerName: 'Zeel',
        mobileNumber: '1234567890',
        busId: 'B1',
        seatNumbers: ['1A', '1B'],
        seatTypes: [SeatType.singleSofa, SeatType.doubleSofa],
        ageGroup: AgeGroup.young,
      );

      expect(booking.paymentStatus, PaymentStatus.notPaid);
      
      final updatedBooking = booking.copyWith(paymentStatus: PaymentStatus.paid);
      
      expect(updatedBooking.paymentStatus, PaymentStatus.paid);
      expect(updatedBooking.customerName, 'Zeel');
    });

    test('ParsedBookingInput validation', () {
      final valid = ParsedBookingInput(
        customerName: 'Ariel',
        seatCount: 2,
        seatTypes: [SeatType.singleSofa, SeatType.singleSofa],
        ageGroup: AgeGroup.young,
      );
      expect(valid.validate(), true);

      final invalid = ParsedBookingInput(
        customerName: '',
        seatCount: 2,
        seatTypes: [],
      );
      expect(invalid.validate(), false);
    });
  });
}
