import '../models/booking_input.dart';
import '../models/seat_type.dart';
import '../models/age_group.dart';

class BookingInputParser {
  ParsedBookingInput parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      throw ParseException('Input cannot be empty', ParseErrorType.emptyInput);
    }

    final tokens = trimmed.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

    if (tokens.length < 3) {
      throw ParseException(
        'Invalid format. Expected: Name SeatCount SeatType [SeatType]',
        ParseErrorType.invalidFormat,
      );
    }

    // Parse customer name (first token, may contain spaces in real scenario)
    final customerName = tokens[0];

    // Check for age group (elder, young, other)
    int nameEndIndex = 1;
    AgeGroup? ageGroup;
    final ageGroupToken = tokens[1].toLowerCase();
    if (ageGroupToken == 'elder' || ageGroupToken == 'young' || ageGroupToken == 'other') {
      ageGroup = AgeGroup.values.firstWhere((e) => e.name == ageGroupToken);
      nameEndIndex = 2;
    }

    // Parse seat count
    final seatCountStr = tokens[nameEndIndex];
    final seatCount = int.tryParse(seatCountStr);
    if (seatCount == null || seatCount <= 0) {
      throw ParseException(
        'Invalid seat count. Must be a positive integer.',
        ParseErrorType.invalidSeatCount,
      );
    }

    // Parse seat types — case-insensitive match against the enum names
    // (`singleSofa`, `doubleSofa`).
    final seatTypes = <SeatType>[];
    for (int i = nameEndIndex + 1; i < tokens.length; i++) {
      final typeStr = tokens[i].toLowerCase();
      try {
        final type = SeatType.values
            .firstWhere((e) => e.name.toLowerCase() == typeStr);
        seatTypes.add(type);
      } catch (e) {
        throw ParseException(
          'Invalid seat type: ${tokens[i]}. Use "singleSofa" or "doubleSofa".',
          ParseErrorType.invalidSeatType,
        );
      }
    }

    if (seatTypes.length != seatCount) {
      throw ParseException(
        'Seat count ($seatCount) does not match number of seat types (${seatTypes.length}).',
        ParseErrorType.seatCountMismatch,
      );
    }

    return ParsedBookingInput(
      customerName: customerName,
      seatCount: seatCount,
      seatTypes: seatTypes,
      ageGroup: ageGroup,
    );
  }

  ValidationResult validate(String input) {
    try {
      parse(input);
      return ValidationResult(isValid: true);
    } catch (e) {
      return ValidationResult(isValid: false, errorMessage: e.toString());
    }
  }
}

class ParseException implements Exception {
  final String message;
  final ParseErrorType type;

  ParseException(this.message, this.type);

  @override
  String toString() => message;
}

enum ParseErrorType {
  emptyInput,
  invalidFormat,
  invalidSeatCount,
  invalidSeatType,
  seatCountMismatch,
}

class ValidationResult {
  final bool isValid;
  final String? errorMessage;

  ValidationResult({required this.isValid, this.errorMessage});

  String formatError() {
    if (isValid) return '';
    return errorMessage ?? 'Validation failed';
  }
}