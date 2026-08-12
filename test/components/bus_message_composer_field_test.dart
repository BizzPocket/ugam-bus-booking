import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/components/bus_message_composer_field.dart';
import 'package:occubusbooking/services/wa_formatting.dart';

/// The composer's job is to make a refusal impossible to be surprised by.
///
/// Two things used to reach the sender only AFTER a batch had gone to Meta and
/// come back refused: a line break in the text, and — never reported at all —
/// the fact that `*asterisks*` silently turn the words inside them bold. This
/// covers the second, and the fact that the first is measured against the
/// ASSEMBLED message rather than the typed text alone.
///
/// `tr()` resolves to its key path when easy_localization is not initialized,
/// which is what the key-based finders below rely on.
void main() {
  Widget harness(TextEditingController controller) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BusMessageComposerField(controller: controller),
          ),
        ),
      );

  Finder byKeyText(String key) => find.text(key);

  group('the formatting preview', () {
    testWidgets('stays hidden while nothing will be formatted',
        (tester) async {
      final c = TextEditingController(text: 'બસ 7 વાગ્યે ઉપડશે');
      await tester.pumpWidget(harness(c));

      expect(byKeyText('bus_message.preview_label'), findsNothing);
      expect(byKeyText('bus_message.fix_plain'), findsNothing);
    });

    testWidgets('appears as soon as a paired mark is typed', (tester) async {
      final c = TextEditingController();
      await tester.pumpWidget(harness(c));

      c.text = 'બસ *સવારે 6* વાગ્યે ઉપડશે';
      await tester.pump();

      expect(byKeyText('bus_message.preview_label'), findsOneWidget);
      expect(byKeyText('bus_message.fix_plain'), findsOneWidget);
    });

    testWidgets('a lone asterisk between digits raises nothing',
        (tester) async {
      // "10*20" arrives literally, so warning about it would be noise — and
      // noise is what teaches senders to ignore the real warning.
      final c = TextEditingController(text: 'ભાડું 10*20 મીટર');
      await tester.pumpWidget(harness(c));

      expect(byKeyText('bus_message.preview_label'), findsNothing);
    });

    testWidgets('the preview renders the styles WhatsApp will apply',
        (tester) async {
      final c = TextEditingController(text: 'a *b* c');
      await tester.pumpWidget(harness(c));
      await tester.pump();

      final rich = tester.widgetList<Text>(find.byType(Text)).firstWhere(
            (t) => t.textSpan != null,
            orElse: () => const Text(''),
          );
      expect(rich.textSpan, isNotNull,
          reason: 'the preview is a styled TextSpan, not flat text');

      final children = (rich.textSpan! as TextSpan).children!;
      final bold = children
          .whereType<TextSpan>()
          .where((s) => s.style?.fontWeight == FontWeight.w700)
          .toList();
      expect(bold, hasLength(1));
      expect(bold.single.text, 'b');
    });
  });

  group('make it plain text', () {
    testWidgets('removes the markers and keeps every word', (tester) async {
      final c = TextEditingController(text: 'બસ *સવારે 6* વાગ્યે');
      await tester.pumpWidget(harness(c));
      await tester.pump();

      await tester.tap(byKeyText('bus_message.fix_plain'));
      await tester.pump();

      expect(c.text, 'બસ સવારે 6 વાગ્યે');
      expect(WaFormatting.hasMarks(c.text), isFalse);
      expect(byKeyText('bus_message.preview_label'), findsNothing,
          reason: 'the notice retires once there is nothing left to warn about');
    });
  });

  group('the line-break refusal', () {
    testWidgets('is raised as the paragraph break is typed', (tester) async {
      final c = TextEditingController();
      await tester.pumpWidget(harness(c));

      c.text = 'પહેલો ફકરો\n\nબીજો ફકરો';
      await tester.pump();

      expect(byKeyText('bus_message.invalid_newline'), findsOneWidget);
      expect(byKeyText('bus_message.fix_auto'), findsOneWidget);
    });

    testWidgets('an untouched field is not scolded', (tester) async {
      final c = TextEditingController();
      await tester.pumpWidget(harness(c));

      expect(byKeyText('bus_message.invalid_empty'), findsNothing);
    });
  });
}
