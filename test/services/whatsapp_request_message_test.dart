import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/whatsapp_service.dart';

/// With both sofa counts 0 (a seater-only party) the request and cancellation
/// messages printed "💺 *Seats:* " followed by nothing.
void main() {
  final tour = Tour(
    id: 't1',
    title: 'Ambaji',
    fromCity: 'Surat',
    toCity: 'Ambaji',
    departureDate: DateTime(2026, 9, 1),
    pricePerSeat: 1000,
  );
  final wa = WhatsAppService();

  test('booking request with no sofas prints no empty Seats line', () {
    final msg = wa.buildBookingRequestMessage(
      tour: tour,
      customerName: 'Asha',
      singleSofaCount: 0,
      doubleSofaCount: 0,
    );
    expect(msg, isNot(contains('*Seats:*')));
  });

  test('cancellation with no sofas prints no empty Seats line', () {
    final msg = wa.buildCancellationRequestMessage(
      tour: tour,
      customerName: 'Asha',
      singleSofaCount: 0,
      doubleSofaCount: 0,
    );
    expect(msg, isNot(contains('*Seats:*')));
  });

  test('sofa counts still print', () {
    final msg = wa.buildBookingRequestMessage(
      tour: tour,
      customerName: 'Asha',
      singleSofaCount: 1,
      doubleSofaCount: 2,
    );
    expect(msg, contains('💺 *Seats:* 2 Double Sofa + 1 Single Sofa'));
  });
}
