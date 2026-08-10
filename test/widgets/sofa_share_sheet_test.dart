import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/widgets/sofa_share_sheet.dart';

/// Sharing a sofa with a stranger must be a QUESTION, not a gesture.
///
/// It used to be a hidden tap-cycle: one tap took half the sofa — meaning an
/// unrelated person would sleep on the other berth — and a second tap took it
/// whole. Nobody discovers that. In this market, especially for a woman
/// travelling alone, "you will share this with a stranger" is one of the most
/// consequential facts in the whole booking, and it was communicated by a tile
/// splitting in half and a price quietly halving.
void main() {
  Future<int?> open(
    WidgetTester tester, {
    required double halfPrice,
    bool canTakeWhole = true,
    bool canTakeHalf = true,
    bool someoneAlreadyThere = false,
  }) async {
    int? result;
    var returned = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showSofaShareSheet(
                  context,
                  halfPrice: halfPrice,
                  canTakeWhole: canTakeWhole,
                  canTakeHalf: canTakeHalf,
                  someoneAlreadyThere: someoneAlreadyThere,
                );
                returned = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(returned, isFalse, reason: 'the sheet should still be open');
    return result;
  }

  testWidgets('both choices are offered when the sofa is free', (tester) async {
    await open(tester, halfPrice: 1100);

    expect(find.byKey(SofaShareSheet.wholeKey), findsOneWidget);
    expect(find.byKey(SofaShareSheet.halfKey), findsOneWidget);
  });

  testWidgets('taking it whole returns two berths', (tester) async {
    int? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                picked = await showSofaShareSheet(
                  context,
                  halfPrice: 1100,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SofaShareSheet.wholeKey));
    await tester.pumpAndSettle();

    expect(picked, 2);
  });

  testWidgets('taking half returns one berth', (tester) async {
    int? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                picked = await showSofaShareSheet(
                  context,
                  halfPrice: 1100,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(SofaShareSheet.halfKey));
    await tester.pumpAndSettle();

    expect(picked, 1);
  });

  testWidgets('a party that refuses to share is never offered the half',
      (tester) async {
    await open(tester, halfPrice: 1100, canTakeHalf: false);

    expect(find.byKey(SofaShareSheet.wholeKey), findsOneWidget);
    expect(
      find.byKey(SofaShareSheet.halfKey),
      findsNothing,
      reason: 'they answered no at the gate — offering it anyway reopens the '
          'exact decision they already made',
    );
  });

  testWidgets('a half-sold sofa offers only the remaining berth',
      (tester) async {
    await open(
      tester,
      halfPrice: 1100,
      canTakeWhole: false,
      someoneAlreadyThere: true,
    );

    expect(
      find.byKey(SofaShareSheet.wholeKey),
      findsNothing,
      reason: 'one berth is already sold — the whole sofa is not for sale',
    );
    expect(find.byKey(SofaShareSheet.halfKey), findsOneWidget);
  });

  testWidgets('both prices are on screen before any money is committed',
      (tester) async {
    await open(tester, halfPrice: 1100);

    expect(find.textContaining('2,200'), findsOneWidget);
    expect(find.textContaining('1,100'), findsOneWidget);
  });

  testWidgets('dismissing chooses nothing', (tester) async {
    int? picked = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                picked = await showSofaShareSheet(context, halfPrice: 1100);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Tap the scrim above the sheet.
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();

    expect(picked, isNull, reason: 'a dismissed sheet must not book anything');
  });
}
