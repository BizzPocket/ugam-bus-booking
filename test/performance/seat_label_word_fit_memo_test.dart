import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/widgets/seat_occupant_label.dart';

/// PERF pin: the per-word TextPainter fit for seat names is memoized — a
/// repeat build measures nothing, and any input change re-measures.
void main() {
  testWidgets('word-fit is measured once per distinct input', (tester) async {
    const style = TextStyle(fontSize: 13, fontWeight: FontWeight.w700);
    const scaler = TextScaler.noScaling;
    final before = debugWordFitMeasureCount;
    final a = wordFitFontSize('Hasmukhbhai Vaghani', style, scaler, 50, null);
    final measured = debugWordFitMeasureCount;
    expect(measured, before + 1);

    // Same inputs: cache hit, identical answer, no layout.
    expect(wordFitFontSize('Hasmukhbhai Vaghani', style, scaler, 50, null), a);
    expect(debugWordFitMeasureCount, measured);

    // Each input change invalidates: width, name, style, scaler.
    final wider =
        wordFitFontSize('Hasmukhbhai Vaghani', style, scaler, 500, null);
    expect(wider, 13); // fits at full size when there is room
    expect(a, lessThan(13)); // and was stepped down when there was not
    wordFitFontSize('Other Name', style, scaler, 50, null);
    wordFitFontSize(
        'Hasmukhbhai Vaghani', style.copyWith(fontSize: 12), scaler, 50, null);
    wordFitFontSize('Hasmukhbhai Vaghani', style,
        const TextScaler.linear(1.1), 50, null);
    expect(debugWordFitMeasureCount, measured + 4);
  });

  testWidgets('a rebuilt seat label re-uses the cached fit', (tester) async {
    Widget label(Color c) => MaterialApp(
          home: Center(
            child: SizedBox(
              width: 52,
              child: SeatOccupantLabel(
                name: 'Ramesh Patel',
                phone: '9876543210',
                nameColor: c,
                phoneColor: c,
              ),
            ),
          ),
        );
    await tester.pumpWidget(label(Colors.white));
    final n = debugWordFitMeasureCount;
    await tester.pumpWidget(label(Colors.white));
    await tester.pumpWidget(label(Colors.white));
    expect(debugWordFitMeasureCount, n);
    // A different colour is a different style -> measured again (correctness
    // first: TextStyle equality is the key).
    await tester.pumpWidget(label(Colors.black));
    expect(debugWordFitMeasureCount, n + 1);
  });
}
