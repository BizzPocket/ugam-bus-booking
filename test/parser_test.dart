import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/booking_input_parser.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/age_group.dart';

void main() {
  group('BookingInputParser Tests', () {
    final parser = BookingInputParser();

    test('Parses complex valid input correctly', () {
      final input = 'Ramesh 4 singleSofa 2 doubleSofa 2 elder';
      final parsed = parser.parse(input);

      expect(parsed.customerName, 'Ramesh');
      expect(parsed.seatCount, 4);
      expect(parsed.seatTypes.length, 4);
      expect(parsed.seatTypes.where((t) => t == SeatType.singleSofa).length, 2);
      expect(parsed.seatTypes.where((t) => t == SeatType.doubleSofa).length, 2);
      expect(parsed.ageGroup, AgeGroup.elder);
    });

    test('Parses input with mixed casing and extra spaces', () {
      final input = '  jOhn   2  SingleSofa  2  Young  ';
      final parsed = parser.parse(input);

      expect(parsed.customerName, 'jOhn');
      expect(parsed.seatCount, 2);
      expect(parsed.seatTypes.every((t) => t == SeatType.singleSofa), true);
      expect(parsed.ageGroup, AgeGroup.young);
    });

    test('Throws FormatException on invalid input', () {
      expect(() => parser.parse('Just Name'), throwsFormatException);
      expect(() => parser.parse('Name 2 invalidType'), throwsFormatException);
    });

    test('Handles optional age group', () {
      final input = 'Jane 1 doubleSofa';
      final parsed = parser.parse(input);

      expect(parsed.customerName, 'Jane');
      expect(parsed.seatCount, 1);
      expect(parsed.seatTypes.first, SeatType.doubleSofa);
      expect(parsed.ageGroup, null);
    });
  });
}
