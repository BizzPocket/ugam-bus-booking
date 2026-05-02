import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/booking_input_parser.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/age_group.dart';

void main() {
  group('BookingInputParser Tests', () {
    final parser = BookingInputParser();

    // Parser format: `Name [ageGroup] seatCount seatType seatType ...`
    // ageGroup (when supplied) sits between the name and the count, and
    // the number of seat-type tokens must equal seatCount.

    test('Parses complex valid input correctly', () {
      final input = 'Ramesh elder 4 singleSofa singleSofa doubleSofa doubleSofa';
      final parsed = parser.parse(input);

      expect(parsed.customerName, 'Ramesh');
      expect(parsed.seatCount, 4);
      expect(parsed.seatTypes.length, 4);
      expect(parsed.seatTypes.where((t) => t == SeatType.singleSofa).length, 2);
      expect(parsed.seatTypes.where((t) => t == SeatType.doubleSofa).length, 2);
      expect(parsed.ageGroup, AgeGroup.elder);
    });

    test('Parses input with mixed casing and extra spaces', () {
      final input = '  jOhn  young  2  SingleSofa  SingleSofa  ';
      final parsed = parser.parse(input);

      expect(parsed.customerName, 'jOhn');
      expect(parsed.seatCount, 2);
      expect(parsed.seatTypes.every((t) => t == SeatType.singleSofa), true);
      expect(parsed.ageGroup, AgeGroup.young);
    });

    test('Throws ParseException on invalid input', () {
      expect(
        () => parser.parse('Just Name'),
        throwsA(isA<ParseException>()),
      );
      expect(
        () => parser.parse('Name 2 invalidType'),
        throwsA(isA<ParseException>()),
      );
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
