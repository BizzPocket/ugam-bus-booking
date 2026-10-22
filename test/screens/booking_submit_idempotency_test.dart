import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/screens/customer_booking_request_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// On 2G a booking submit can land on the server and still time out on the
/// rider's phone. The retry must be the SAME request, not a second one (and a
/// second organiser push).
void main() {
  group('pendingRequestIdFor', () {
    test('a first submit mints a fresh id', () {
      expect(pendingRequestIdFor(null, 'sig'), isNull);
    });

    test('re-sending the same content after a failure re-uses the id', () {
      expect(pendingRequestIdFor((id: 'r1', signature: 'sig'), 'sig'), 'r1');
    });

    test('an edited form is a different request and gets a new id', () {
      expect(pendingRequestIdFor((id: 'r1', signature: 'sig'), 'sig2'), isNull);
    });
  });

  group('isSubmitAlreadyLanded', () {
    const pkey = PostgrestException(
      message: 'duplicate key value violates unique constraint '
          '"booking_requests_pkey"',
      code: '23505',
    );

    test('our own id already existing on a RE-send is the landed first try',
        () {
      expect(isSubmitAlreadyLanded(pkey, isResend: true), isTrue);
    });

    test('never on a first send — nothing of ours could be there yet', () {
      expect(isSubmitAlreadyLanded(pkey, isResend: false), isFalse);
    });

    test('a different unique violation is a real error', () {
      const other = PostgrestException(
        message: 'duplicate key value violates unique constraint '
            '"passengers_tour_phone_key"',
        code: '23505',
      );
      expect(isSubmitAlreadyLanded(other, isResend: true), isFalse);
    });

    test('a refusal (bookings closed) is never treated as landed', () {
      const closed = PostgrestException(
        message: 'Bookings are closed for this tour.',
        code: '23514',
      );
      expect(isSubmitAlreadyLanded(closed, isResend: true), isFalse);
    });
  });
}
