import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/wa_template_params.dart';

// The REAL announcement the agent could not send (28 Jul 2026). It reads as a
// perfectly ordinary two-paragraph Gujarati message and is only 448 characters
// — well under Meta's 1024 limit — so nothing on screen explained the refusal.
// The disqualifying detail is the blank line between the paragraphs: Meta
// rejects ANY new-line inside a template parameter with
// "(#132000) Param text cannot have new-line/tab characters or more than 4
// consecutive spaces". Shortening the text appeared to "fix" it only because
// cutting a paragraph also removes the break.
const _realFailingMessage =
    'આવતી કાલે સવારે બાપા ના દર્શન કરી અને નાસ્તા પાણી કરી ને 7 વાગ્યા પહેલા બસ '
    'પર પહોંચી જવું.. કોઈએ ખોટો સમય ખોટી કરવો નઈ.. નહિતર બાંદ્રા સુધી પોત પોતાની '
    'જાતે આવવું પડશે.. બસ નો વહીવટ કરતા હોય એમને સાથ સહકાર આપવો..'
    '\n\n'
    'જય વાલમ બસ ગામ ના પાદર માં ખાલી થશે અન સમાધિ દર્શન કરી ને બપોરે પ્રસાદ લઈ ન '
    'વહેલાસર સમય ખોટી કર્યા વગર ગામ ના પાદર પર પહોંચી જવું.. બસ 1.30 વાગ્યે '
    'ઉપાડી લેવામાં આવશે.. જેમને બાંદ્રા રાત્રિ ની સભા લેવી હોય એમને છૂટ છે.. '
    'રૂબરૂ ફોન કરવો..';

void main() {
  group('the real failing announcement', () {
    test('is rejected for its paragraph break, not its length', () {
      final issues = WaTemplateParams.validateOne(_realFailingMessage);

      expect(issues.map((v) => v.issue), [WaParamIssue.newline]);
      expect(
        _realFailingMessage.length,
        lessThan(WaTemplateParams.maxBodyChars),
        reason: 'length was never the problem — 448 chars is legal',
      );
    });

    test('auto-fix makes it Meta-legal without losing a word', () {
      final fixed = WaTemplateParams.sanitize(_realFailingMessage);

      expect(WaTemplateParams.validateOne(fixed), isEmpty);
      expect(WaTemplateParams.canAutoFix(_realFailingMessage), isTrue);
      // Nothing is truncated: the paragraph break becomes one space.
      expect(fixed, contains('સહકાર આપવો.. જય વાલમ બસ'));
      expect(fixed.length, _realFailingMessage.length - 1);
    });

    test('single-paragraph text passes — why it "sometimes works"', () {
      const oneParagraph = 'બસ 7 વાગ્યે ઉપડશે.. સમયસર પહોંચી જવું..';
      expect(WaTemplateParams.validateOne(oneParagraph), isEmpty);
    });
  });

  group('each Meta rule', () {
    test('blank / whitespace-only is rejected and shortcuts the rest', () {
      expect(
        WaTemplateParams.validateOne('   ').map((v) => v.issue),
        [WaParamIssue.empty],
      );
      expect(
        WaTemplateParams.validateOne('\n\n').map((v) => v.issue),
        [WaParamIssue.empty],
        reason: 'emptiness makes the newline finding redundant',
      );
    });

    test('tabs are rejected', () {
      expect(
        WaTemplateParams.validateOne('bus\tleaves').map((v) => v.issue),
        [WaParamIssue.tab],
      );
    });

    test('exactly 4 spaces is legal, 5 is not', () {
      expect(WaTemplateParams.validateOne('a${' ' * 4}b'), isEmpty);
      expect(
        WaTemplateParams.validateOne('a${' ' * 5}b').map((v) => v.issue),
        [WaParamIssue.consecutiveSpaces],
      );
    });

    test('over 1024 characters is rejected and is NOT auto-fixable', () {
      final long = 'ક' * (WaTemplateParams.maxBodyChars + 1);
      expect(
        WaTemplateParams.validateOne(long).map((v) => v.issue),
        [WaParamIssue.tooLong],
      );
      expect(
        WaTemplateParams.canAutoFix(long),
        isFalse,
        reason: 'truncating an agent\'s announcement is never automatic',
      );
    });

    test('several rules broken at once are all reported', () {
      final issues = WaTemplateParams.validateOne('a\nb\tc${' ' * 6}d');
      expect(issues.map((v) => v.issue), [
        WaParamIssue.newline,
        WaParamIssue.tab,
        WaParamIssue.consecutiveSpaces,
      ]);
    });
  });

  group('multi-parameter templates', () {
    test('violations carry the index of the offending parameter', () {
      final issues = WaTemplateParams.validateAll([
        'Rameshbhai',
        'Dwarka\nYatra',
        'Bus 1',
      ]);
      expect(issues, [
        const WaParamViolation(issue: WaParamIssue.newline, paramIndex: 1, count: 1),
      ]);
    });

    test('a clean parameter list is valid', () {
      expect(
        WaTemplateParams.isValid(['Rameshbhai', 'Dwarka Yatra', 'Bus 1']),
        isTrue,
      );
    });
  });
}
