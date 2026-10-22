import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/seat_chart_booking_service.dart';

/// A refused multi-bus claim/hold arrives as `{ok: false, error: "..."}`. The
/// parsers kept `conflicts` and dropped `error`, so the confirm screen could
/// only ever show its generic "couldn't book" line — never the server's reason.
void main() {
  const refusal = {
    'ok': false,
    'error': 'Booking is closed for this tour',
    'conflicts': [],
  };

  test('multi CLAIM refusal carries the server error', () {
    final r = ChartMultiClaimResult.fromRpc(refusal);
    expect(r.ok, isFalse);
    expect(r.errorMessage, 'Booking is closed for this tour');
  });

  test('multi HOLD refusal carries the server error', () {
    final r = ChartMultiHoldResult.fromRpc(refusal);
    expect(r.ok, isFalse);
    expect(r.errorMessage, 'Booking is closed for this tour');
  });

  test('a lost-seat conflict still parses alongside', () {
    final r = ChartMultiHoldResult.fromRpc({
      'ok': false,
      'conflicts': [
        {'bus_id': 'b1', 'seat_id': 'U3'},
      ],
    });
    expect(r.lostSeats, isTrue);
    expect(r.errorMessage, isNull);
  });
}
