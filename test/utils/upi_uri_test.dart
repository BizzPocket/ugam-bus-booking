import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/upi_uri.dart';

/// The UPI payload is money-carrying and unrecoverable once sent — a wrong
/// amount or a mangled VPA pays the wrong person the wrong sum with no
/// chargeback. These pin the format down.
void main() {
  const payee = UpiPayee(vpa: 'ugam@okhdfcbank', name: 'Ugam Yatra');

  group('VPA validation', () {
    test('accepts real-world handles', () {
      for (final v in const [
        'ugam@okhdfcbank',
        'q123456789@ybl',
        'name.surname@oksbi',
        'shop-1@paytm',
        'a_b@icici',
      ]) {
        expect(isValidVpa(v), isTrue, reason: v);
      }
    });

    test('rejects malformed handles', () {
      for (final v in const [
        '',
        'nobank',
        '@ybl',
        'user@',
        'user@@ybl',
        'user name@ybl',
        'user@9bank', // handle must start with a letter
        'a@ybl', // account part too short
      ]) {
        expect(isValidVpa(v), isFalse, reason: '"$v" should be rejected');
      }
    });

    test('a VPA with surrounding whitespace still validates', () {
      expect(isValidVpa('  ugam@okhdfcbank  '), isTrue);
    });
  });

  group('amount formatting', () {
    test('paise render as two decimal places', () {
      final cases = {
        200000: '2000.00',
        1: '0.01',
        99: '0.99',
        100: '1.00',
        105: '1.05',
        950050: '9500.50',
        123456789: '1234567.89',
      };
      cases.forEach((paise, expected) {
        final r = UpiRequest(payee: payee, amountPaise: paise);
        expect(r.amountString, expected, reason: '$paise paise');
      });
    });

    test('the amount never carries a grouping separator or symbol', () {
      final r = UpiRequest(payee: payee, amountPaise: 12345678);
      expect(r.amountString, '123456.78');
      expect(r.amountString, isNot(contains(',')));
      expect(r.amountString, isNot(contains('₹')));
    });
  });

  group('build', () {
    test('produces a upi://pay payload with the mandatory fields', () {
      final uri = UpiRequest(
        payee: payee,
        amountPaise: 200000,
        note: 'Advance',
        reference: 'req-1',
      ).build();

      expect(uri, startsWith('upi://pay?'));
      final parsed = Uri.parse(uri);
      expect(parsed.queryParameters['pa'], 'ugam@okhdfcbank');
      expect(parsed.queryParameters['pn'], 'Ugam Yatra');
      expect(parsed.queryParameters['am'], '2000.00');
      expect(parsed.queryParameters['cu'], 'INR');
      expect(parsed.queryParameters['tn'], 'Advance');
      expect(parsed.queryParameters['tr'], 'req-1');
    });

    test('an amount is ALWAYS present — an absent one is editable by the payer',
        () {
      final uri = UpiRequest(payee: payee, amountPaise: 50000).build();
      expect(Uri.parse(uri).queryParameters.containsKey('am'), isTrue);
    });

    test('rejects a zero or negative amount rather than emitting an open link',
        () {
      expect(
        () => UpiRequest(payee: payee, amountPaise: 0).build(),
        throwsArgumentError,
      );
      expect(
        () => UpiRequest(payee: payee, amountPaise: -100).build(),
        throwsArgumentError,
      );
    });

    test('rejects an invalid payee', () {
      expect(
        () => UpiRequest(
          payee: const UpiPayee(vpa: 'nope', name: 'X'),
          amountPaise: 100,
        ).build(),
        throwsArgumentError,
      );
    });

    test('Gujarati text survives the round trip', () {
      // The app is en/gu/hi. A raw non-ASCII byte in a hand-built query string
      // truncates the payload in some UPI apps — encoding must be real.
      final uri = UpiRequest(
        payee: const UpiPayee(vpa: 'ugam@okhdfcbank', name: 'ઉગમ યાત્રા'),
        amountPaise: 100000,
        note: 'બસ ભાડું',
      ).build();
      final parsed = Uri.parse(uri);
      expect(parsed.queryParameters['pn'], 'ઉગમ યાત્રા');
      expect(parsed.queryParameters['tn'], 'બસ ભાડું');
    });

    test('an ampersand in the note cannot inject a parameter', () {
      final uri = UpiRequest(
        payee: payee,
        amountPaise: 100000,
        note: 'Fuel & tolls&am=1.00',
      ).build();
      final parsed = Uri.parse(uri);
      // The amount must still be OURS, not the one smuggled through the note.
      expect(parsed.queryParameters['am'], '1000.00');
      expect(parsed.queryParameters['tn'], 'Fuel & tolls&am=1.00');
    });

    test('optional fields are omitted, not emitted empty', () {
      final parsed = Uri.parse(
        UpiRequest(payee: payee, amountPaise: 100, note: '  ').build(),
      );
      expect(parsed.queryParameters.containsKey('tn'), isFalse);
      expect(parsed.queryParameters.containsKey('tr'), isFalse);
      expect(parsed.queryParameters.containsKey('mc'), isFalse);
    });

    test('long note and reference are clipped, not dropped', () {
      final parsed = Uri.parse(
        UpiRequest(
          payee: payee,
          amountPaise: 100,
          note: 'x' * 200,
          reference: 'y' * 200,
        ).build(),
      );
      expect(parsed.queryParameters['tn']!.length, 50);
      expect(parsed.queryParameters['tr']!.length, 35);
    });
  });

  group('the two entry points', () {
    test('vendorPayment carries the expense id as the reference', () {
      final r = vendorPayment(
        vpa: 'owner@ybl',
        vendorName: 'Bus owner',
        amountPaise: 4500000,
        note: 'Bus rent',
        expenseId: 'exp-42',
      );
      expect(r.isValid, isTrue);
      expect(Uri.parse(r.build()).queryParameters['tr'], 'exp-42');
      expect(r.amountString, '45000.00');
    });

    test('collectPayment carries the booking ref — the free attribution', () {
      final r = collectPayment(
        vpa: 'ugam@okhdfcbank',
        payeeName: 'Ugam Yatra',
        amountPaise: 200000,
        note: 'Seat advance',
        bookingRef: 'bk-77',
      );
      expect(Uri.parse(r.build()).queryParameters['tr'], 'bk-77');
    });
  });
}
