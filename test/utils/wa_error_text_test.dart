import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/wa_error_text.dart';

/// A WhatsApp send that THREW was reported as either a bare "couldn't send"
/// (the seat-allocation sender — reason dropped) or the raw `$e` (the bus
/// composer). [waThrownAppendix] gives a throw the same cause + fix wording as
/// a returned failure. Keys render raw here: easy_localization is not loaded.
void main() {
  test('a coded Meta failure maps to its cause and fix', () {
    final text =
        waThrownAppendix(Exception('(#131026) Message undeliverable'));
    expect(text, contains('wa_error.not_whatsapp_user.cause'));
    expect(text, contains('wa_error.not_whatsapp_user.fix'));
    expect(text, isNot(contains('Message undeliverable')),
        reason: 'a mapped cause reads as plain language, not an error dump');
  });

  test('an unmapped throw keeps its raw text as the detail', () {
    final text = waThrownAppendix(Exception('socket closed'));
    expect(text, contains('wa_error.unknown.cause'));
    expect(text, contains('socket closed'));
  });

  test('is never empty — a throw is always a failure', () {
    expect(waThrownAppendix(''), isNotEmpty);
  });
}
