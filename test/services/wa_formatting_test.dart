import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/wa_formatting.dart';

void main() {
  group('only PAIRED marks format', () {
    test('a lone asterisk between digits is literal, not bold', () {
      // "10*20" is the reason this cannot simply strip every asterisk: WhatsApp
      // renders it as typed, so warning about it would train senders to ignore
      // the warning entirely.
      expect(WaFormatting.hasMarks('10*20'), isFalse);
      expect(WaFormatting.toPlain('10*20'), '10*20');
    });

    test('a marker wrapping spaces does not format', () {
      expect(WaFormatting.hasMarks('* x *'), isFalse);
      expect(WaFormatting.hasMarks('bus * leaves * soon'), isFalse);
    });

    test('a marker left open at end of line cannot reach the next line', () {
      expect(WaFormatting.hasMarks('*a\nb*'), isFalse);
    });

    test('an unpaired marker survives toPlain untouched', () {
      expect(WaFormatting.toPlain('cost is 10*20 metres'), 'cost is 10*20 metres');
    });
  });

  group('each style is recognised', () {
    test('bold, italic, strikethrough, monospace', () {
      expect(WaFormatting.marksIn('*b*'), [WaStyle.bold]);
      expect(WaFormatting.marksIn('_i_'), [WaStyle.italic]);
      expect(WaFormatting.marksIn('~s~'), [WaStyle.strikethrough]);
      expect(WaFormatting.marksIn('`m`'), [WaStyle.monospace]);
    });

    test('triple backtick is one monospace run, not a stray backtick pair', () {
      expect(WaFormatting.parse('```code```'), [
        const WaSpan('code', {WaStyle.monospace}),
      ]);
    });
  });

  group('parse splits text the way WhatsApp renders it', () {
    test('surrounding text keeps its place', () {
      expect(WaFormatting.parse('a *b* c'), [
        const WaSpan('a '),
        const WaSpan('b', {WaStyle.bold}),
        const WaSpan(' c'),
      ]);
    });

    test('nested marks compose into one span', () {
      expect(WaFormatting.parse('*_x_*'), [
        const WaSpan('x', {WaStyle.bold, WaStyle.italic}),
      ]);
    });

    test('plain text is a single unstyled span', () {
      expect(WaFormatting.parse('plain'), [const WaSpan('plain')]);
      expect(WaFormatting.parse(''), isEmpty);
    });
  });

  group('toPlain, for the sender who did not mean it', () {
    test('the accidental-bold announcement arrives literally', () {
      // The shape that prompted this: an agent emphasising a departure time.
      const typed = 'બસ *સવારે 6* વાગ્યે ઉપડશે';
      expect(WaFormatting.marksIn(typed), [WaStyle.bold]);
      expect(WaFormatting.toPlain(typed), 'બસ સવારે 6 વાગ્યે ઉપડશે');
    });

    test('removing markers never removes a word', () {
      const typed = '~જૂનો સમય~ નવો સમય 7 વાગ્યે';
      expect(WaFormatting.toPlain(typed), 'જૂનો સમય નવો સમય 7 વાગ્યે');
    });

    test('plain text is returned unchanged and has no marks', () {
      const typed = 'બસ 7 વાગ્યે ઉપડશે.. સમયસર પહોંચી જવું..';
      expect(WaFormatting.toPlain(typed), typed);
      expect(WaFormatting.hasMarks(typed), isFalse);
    });
  });
}
