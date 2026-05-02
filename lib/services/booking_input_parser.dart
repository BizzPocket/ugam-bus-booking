import '../models/booking_input.dart';
import '../models/seat_type.dart';
import '../models/age_group.dart';

class BookingInputParser {
  /// Recognises the standardized booking-request message produced by
  /// `WhatsAppService.buildBookingRequestMessage` (Phase 4). When the
  /// input matches the template, returns the structured request;
  /// otherwise falls back to the legacy short-form parser via
  /// [parse]. The standardized format is identified by the
  /// `[Tour ID: UGM-XXXXXX]` footer.
  ParsedBookingInput parseAny(String input) {
    final tourCodeMatch =
        RegExp(r'\[Tour ID:\s*(UGM-[A-Z0-9]+)\]').firstMatch(input);
    if (tourCodeMatch != null) {
      return _parseStandardisedRequest(input, tourCodeMatch.group(1)!);
    }
    return parse(input);
  }

  ParsedBookingInput _parseStandardisedRequest(String input, String tourCode) {
    // Strip Markdown bold (*…*) so the regexes match whether the
    // customer's WhatsApp app preserved it or not.
    final cleaned = input.replaceAll('*', '');

    String? extract(RegExp re) {
      final m = re.firstMatch(cleaned);
      if (m == null) return null;
      return m.group(1)?.trim();
    }

    final name = extract(RegExp(r'Name:\s*(.+)', multiLine: true)) ?? '';
    final seatLine = extract(RegExp(r'Seats:\s*(.+)', multiLine: true));
    final note = extract(RegExp(r'^📝\s*(.+)', multiLine: true));

    if (name.isEmpty || seatLine == null) {
      throw ParseException(
        'Booking request was missing the Name or Seats line.',
        ParseErrorType.invalidFormat,
      );
    }

    final seatTypes = <SeatType>[];
    for (final part in seatLine.split('+')) {
      final m = RegExp(r'(\d+)\s*(Single|Double)\s*Sofa',
              caseSensitive: false)
          .firstMatch(part.trim());
      if (m == null) continue;
      final count = int.parse(m.group(1)!);
      final type = m.group(2)!.toLowerCase() == 'single'
          ? SeatType.singleSofa
          : SeatType.doubleSofa;
      for (var i = 0; i < count; i++) {
        seatTypes.add(type);
      }
    }

    if (seatTypes.isEmpty) {
      throw ParseException(
        'Could not read any seat counts from the request.',
        ParseErrorType.invalidSeatType,
      );
    }

    // Use the cleaned-up name (drop trailing punctuation, take first
    // line only — customer phones sometimes append a signature).
    final firstLineName = name.split('\n').first.trim();

    return ParsedBookingInput(
      customerName: firstLineName,
      seatCount: seatTypes.length,
      seatTypes: seatTypes,
      tourCode: tourCode,
      note: note,
    );
  }

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