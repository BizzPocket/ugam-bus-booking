import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/ugam.dart';

/// PERF pin: a display-only UgamCard no longer allocates a press controller,
/// so the press animation must still work for every card that IS tappable —
/// including one that only becomes tappable on a later rebuild.
void main() {
  Widget host(VoidCallback? onTap) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: UgamCard.plain(
              onTap: onTap,
              child: const SizedBox(width: 100, height: 60, child: Text('x')),
            ),
          ),
        ),
      );

  double scale(WidgetTester t) => t
      .widget<ScaleTransition>(find.descendant(
        of: find.byType(UgamCard),
        matching: find.byType(ScaleTransition),
      ))
      .scale
      .value;

  testWidgets('BENCH mounting 150 display-only cards', (tester) async {
    Widget page(int gen) => MaterialApp(
          home: SingleChildScrollView(
            child: Column(children: [
              for (var i = 0; i < 150; i++)
                UgamCard.plain(
                  key: ValueKey('$gen-$i'),
                  child: const SizedBox(height: 4),
                ),
            ]),
          ),
        );
    await tester.pumpWidget(page(-1));
    final sw = Stopwatch()..start();
    for (var g = 0; g < 10; g++) {
      await tester.pumpWidget(page(g));
    }
    // ignore: avoid_print
    print('BENCH mount 150 UgamCards: '
        '${(sw.elapsedMicroseconds / 10).toStringAsFixed(0)}us per frame');
  });

  testWidgets('display-only card renders no press layer', (tester) async {
    await tester.pumpWidget(host(null));
    expect(
      find.descendant(
          of: find.byType(UgamCard), matching: find.byType(ScaleTransition)),
      findsNothing,
    );
  });

  testWidgets('card that gains onTap later still scales on press',
      (tester) async {
    await tester.pumpWidget(host(null));
    var taps = 0;
    await tester.pumpWidget(host(() => taps++));
    expect(scale(tester), 1.0);
    final g = await tester.startGesture(tester.getCenter(find.text('x')));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 60));
    expect(scale(tester), lessThan(1.0));
    await g.up();
    await tester.pumpAndSettle();
    expect(scale(tester), 1.0);
    expect(taps, 1);
  });
}
