import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/handler_tour_ref.dart';

void main() {
  Map<String, dynamic> refJson({
    required String status,
    String? departureDate = '2026-06-16',
  }) => {
        'request_id': 'req-1',
        'tour_id': 'tour-1',
        'tour_title': 'Guru Purnima',
        'from_city': 'Surat',
        'to_city': 'Bheda',
        'departure_date': departureDate,
        'status': status,
      };

  test('parses the RPC handler-ref payload', () {
    final r = HandlerTourRef.fromJson(refJson(status: 'locked'));
    expect(r.requestId, 'req-1');
    expect(r.tourId, 'tour-1');
    expect(r.status, 'locked');
  });

  group('isLive', () {
    // Same rule as SeatTicket: a handler manages the tour throughout its
    // lifecycle, so any non-completed status is live regardless of how long
    // ago it departed. The departure date must never hide an active tour.
    test('a locked handler tour is live even after departure passed', () {
      final r = HandlerTourRef.fromJson(
        refJson(status: 'locked', departureDate: '2020-01-01'),
      );
      expect(r.isLive, isTrue);
    });

    test('an assigning handler tour is live', () {
      expect(HandlerTourRef.fromJson(refJson(status: 'assigning')).isLive,
          isTrue);
    });

    test('a completed handler tour is history, not live', () {
      final r = HandlerTourRef.fromJson(
        refJson(status: 'completed', departureDate: '2099-01-01'),
      );
      expect(r.isLive, isFalse);
    });
  });
}
