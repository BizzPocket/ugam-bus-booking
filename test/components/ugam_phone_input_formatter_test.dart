import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_input.dart';

/// The phone field applies [IndianMobileFormatter]. When a customer pastes a
/// number that carries the `+91` country code, only the 10 significant digits
/// must survive — the country code must not push the real digits out.
void main() {
  const formatter = IndianMobileFormatter();

  TextEditingValue apply(String pasted) => formatter.formatEditUpdate(
        TextEditingValue.empty,
        TextEditingValue(
          text: pasted,
          selection: TextSelection.collapsed(offset: pasted.length),
        ),
      );

  group('IndianMobileFormatter', () {
    test('pasted "+91 9193271480" keeps only the 10 digits', () {
      final result = apply('+91 9193271480');
      expect(result.text, '9193271480');
      expect(result.selection.baseOffset, 10);
    });

    test('strips country code from "919193271480"', () {
      expect(apply('919193271480').text, '9193271480');
    });

    test('strips spaces, dashes and parens', () {
      expect(apply('(919) 327-1480').text, '9193271480');
    });

    test('leaves a clean 10-digit number untouched', () {
      final value = TextEditingValue(
        text: '9193271480',
        selection: const TextSelection.collapsed(offset: 10),
      );
      // Identical in/out means the cursor position is preserved verbatim.
      expect(formatter.formatEditUpdate(TextEditingValue.empty, value), value);
    });

    test('allows partial input while typing (fewer than 10 digits)', () {
      expect(apply('919').text, '919');
    });
  });
}
