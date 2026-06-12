import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/chart_footer.dart';
import 'package:occubusbooking/services/chart_footer_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Fresh, empty preference store before each test.
    SharedPreferences.setMockInitialValues({});
  });

  group('ChartFooterStore', () {
    test('save → load round-trips every field', () async {
      const footer = ChartFooter(
        boardingPlace: 'સ્થળ બસ સ્ટેન્ડ',
        departureTime: 'સાંજે 5 વાગ્યે',
        note: 'હેન્ડલર: રસિક',
      );
      await ChartFooterStore.save('tour-1', footer);

      final loaded = await ChartFooterStore.load('tour-1');
      expect(loaded.boardingPlace, footer.boardingPlace);
      expect(loaded.departureTime, footer.departureTime);
      expect(loaded.note, footer.note);
    });

    test('missing tour returns an empty footer', () async {
      final loaded = await ChartFooterStore.load('does-not-exist');
      expect(loaded.isEmpty, isTrue);
      expect(loaded.boardingPlace, '');
      expect(loaded.departureTime, '');
      expect(loaded.note, '');
    });

    test('footers are keyed per tour and do not bleed across tours', () async {
      await ChartFooterStore.save(
          'tour-a', const ChartFooter(boardingPlace: 'Place A'));
      await ChartFooterStore.save(
          'tour-b', const ChartFooter(boardingPlace: 'Place B'));

      expect((await ChartFooterStore.load('tour-a')).boardingPlace, 'Place A');
      expect((await ChartFooterStore.load('tour-b')).boardingPlace, 'Place B');
    });

    test('re-saving overwrites the previous footer', () async {
      await ChartFooterStore.save(
          'tour-1', const ChartFooter(note: 'first'));
      await ChartFooterStore.save(
          'tour-1', const ChartFooter(note: 'second'));

      expect((await ChartFooterStore.load('tour-1')).note, 'second');
    });
  });
}
