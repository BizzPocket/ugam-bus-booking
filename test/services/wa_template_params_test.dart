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

  group('counting characters the way the sender sees them', () {
    test('an emoji is one character, not two UTF-16 code units', () {
      expect('🙏'.length, 2, reason: 'the miscount that refused a legal message');
      expect(WaTemplateParams.characterCount('🙏'), 1);
    });

    test('a ZWJ family emoji is one character, not seven runes', () {
      const family = '👨‍👩‍👧‍👦';
      expect(family.runes.length, greaterThan(1),
          reason: 'runes were the previous, still-wrong measure');
      expect(WaTemplateParams.characterCount(family), 1);
    });

    test('a Gujarati consonant carrying a matra is one character', () {
      // 'ક' + 'ા' renders as a single glyph the sender counts once.
      expect('કા'.runes.length, 2);
      expect(WaTemplateParams.characterCount('કા'), 1);
    });

    test('plain ASCII is unaffected', () {
      expect(WaTemplateParams.characterCount('Bus 1'), 5);
    });
  });

  group('the rendered-body budget', () {
    test('a legal parameter still busts the limit once the template is added',
        () {
      // THE defect a per-parameter check cannot see. 900 characters is a
      // perfectly legal {{1}}, but bus_msg wraps it in a greeting and a closing
      // blessing — and Meta measures the assembled body, returning
      // "132005 Translated text is too long" for every recipient.
      final param = 'ક' * 900;
      expect(WaTemplateParams.validateOne(param), isEmpty,
          reason: 'the parameter alone is under 1024 and looks fine');

      final issues = WaTemplateParams.validateRendered(
        params: [param],
        staticBodyChars: 200,
      );
      expect(issues.map((v) => v.issue), [WaParamIssue.renderedTooLong]);
      expect(issues.single.count, 1100);
      expect(issues.single.paramIndex, WaParamViolation.whole,
          reason: 'the message is too long, not any one parameter');
    });

    test('the same text fits when the template body is short', () {
      final param = 'ક' * 900;
      expect(
        WaTemplateParams.validateRendered(params: [param], staticBodyChars: 100),
        isEmpty,
      );
    });

    test('exactly 1024 rendered is legal, 1025 is not', () {
      expect(
        WaTemplateParams.validateRendered(
          params: ['ક' * 24],
          staticBodyChars: 1000,
        ),
        isEmpty,
      );
      expect(
        WaTemplateParams.validateRendered(
          params: ['ક' * 25],
          staticBodyChars: 1000,
        ).map((v) => v.issue),
        [WaParamIssue.renderedTooLong],
      );
    });

    test('seven seat_allotment values are measured together', () {
      final params = List.filled(7, 'ક' * 150); // 1050 across the batch
      expect(
        params.every((p) => WaTemplateParams.validateOne(p).isEmpty),
        isTrue,
        reason: 'every value passes on its own',
      );
      expect(
        WaTemplateParams.validateRendered(params: params, staticBodyChars: 0)
            .map((v) => v.issue),
        [WaParamIssue.renderedTooLong],
      );
    });

    test('per-parameter faults are still reported alongside the total', () {
      final issues = WaTemplateParams.validateRendered(
        params: ['fine', 'has\nbreak'],
        staticBodyChars: 0,
      );
      expect(issues.map((v) => v.issue), [WaParamIssue.newline]);
      expect(issues.single.paramIndex, 1,
          reason: 'the aggregate must not hide WHICH value is wrong');
    });

    test('free-text budget subtracts the template, and never goes negative',
        () {
      expect(WaTemplateParams.freeTextBudget(200), 824);
      expect(WaTemplateParams.freeTextBudget(0), 1024);
      expect(WaTemplateParams.freeTextBudget(2000), 0);
    });

    test('the conservative fallback is stricter than Meta, never looser', () {
      expect(
        WaTemplateParams.conservativeStaticChars,
        greaterThan(0),
        reason: 'a catalog-less composer must assume the template costs '
            'something, or it re-creates the bug it fixes',
      );
    });
  });
}
