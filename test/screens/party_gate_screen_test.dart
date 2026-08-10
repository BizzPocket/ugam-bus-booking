import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/booking_mode.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/screens/party_gate_screen.dart';
import 'package:occubusbooking/utils/party_fit.dart';

/// Three plain questions, then the chart opens already filled in.
///
/// The previous version of this screen asked how many people and whether they
/// had to stay on one bus, then handed over the same blank 36-cell puzzle. It
/// added a step without removing the hard one.
///
/// It now asks only what the picker cannot work out for itself, and — because
/// nothing here needs the seat map — it loads NO data and shows no spinner.
/// The two questions it gained are ones a customer has a real opinion about;
/// the one it lost (same bus or split) was asking them to predict what the
/// picker exists to decide.
void main() {
  Tour chartTour() => Tour(
        id: 'tour-1',
        title: 'TEST',
        fromCity: 'Surat',
        toCity: 'Shirdi',
        departureDate: DateTime(2026, 9, 15),
        pricePerSeat: 900,
        status: TourStatus.busBooked,
        bookingMode: BookingMode.chart,
      );

  PartyIntent? captured;

  Widget harness() => MaterialApp(
        home: PartyGateScreen(
          tour: chartTour(),
          onContinue: (intent) => captured = intent,
        ),
      );

  setUp(() => captured = null);

  Future<void> pickPeople(WidgetTester tester, int n) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(PartyGateScreen.peopleKey),
        matching: find.text('$n'),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> answer(WidgetTester tester, Key group, bool yes) async {
    await tester.tap(
      find.descendant(
        of: find.byKey(group),
        matching:
            find.byKey(yes ? PartyGateScreen.yesKey : PartyGateScreen.noKey),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byKey(PartyGateScreen.continueKey));
    await tester.pumpAndSettle();
  }

  testWidgets('it shows both questions immediately, with no loading',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: 'nothing here needs the seat map, so nothing should be fetched '
          'before the customer can answer',
    );
    expect(find.byKey(PartyGateScreen.peopleKey), findsOneWidget);
    expect(find.byKey(PartyGateScreen.shareKey), findsOneWidget);
  });

  testWidgets('it no longer asks about ladies', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('party_ladies')),
      findsNothing,
      reason: 'the picker never read the answer, so the question was a tax on '
          'the customer and nothing else',
    );
  });

  testWidgets('it never asks about splitting across buses', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);

    expect(
      find.byKey(const Key('party_together')),
      findsNothing,
      reason: 'the picker decides that — asking the customer to predict it was '
          'asking them to do the picker\'s job',
    );
  });

  testWidgets('a solo traveller defaults sensibly and can continue at once',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await submit(tester);

    expect(captured, isNotNull);
    expect(captured!.people, 1);
  });

  testWidgets('the answers reach the chart', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await pickPeople(tester, 4);
    await answer(tester, PartyGateScreen.shareKey, false);
    await submit(tester);

    expect(captured!.people, 4);
    expect(
      captured!.shareOk,
      isFalse,
      reason: 'this is the answer that stops half-sofas being proposed at all',
    );
  });

  testWidgets('sharing defaults to allowed, so the picker is not hobbled',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 2);
    await submit(tester);

    expect(captured!.shareOk, isTrue);
  });

  Future<void> setSplit(WidgetTester tester, Key group, int n) async {
    await tester.tap(
      find.descendant(of: find.byKey(group), matching: find.text('$n')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the split block is hidden until the party says it is mixed',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);

    expect(find.byKey(PartyGateScreen.splitKey), findsNothing);

    await answer(tester, PartyGateScreen.bothWaysKey, false);
    expect(find.byKey(PartyGateScreen.splitKey), findsOneWidget);
  });

  testWidgets('everyone both ways sends one round-trip bucket', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);
    await submit(tester);

    expect(captured!.roundTrip, 4);
    expect(captured!.outboundOnly, 0);
    expect(captured!.returnOnly, 0);
    expect(captured!.isMixed, isFalse);
  });

  testWidgets('the split buckets start at zero, not pre-filled', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);
    await answer(tester, PartyGateScreen.bothWaysKey, false);
    await submit(tester);

    expect(
      captured,
      isNull,
      reason: 'a zero split does not add up, so continuing must be blocked — '
          'a pre-filled split would let them skip the question entirely and we '
          'would record a guess as if it were their answer',
    );
  });

  testWidgets('a split that adds up reaches the chart', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);
    await answer(tester, PartyGateScreen.bothWaysKey, false);
    await setSplit(tester, PartyGateScreen.roundTripKey, 2);
    await setSplit(tester, PartyGateScreen.outboundKey, 2);
    await submit(tester);

    expect(captured!.roundTrip, 2);
    expect(captured!.outboundOnly, 2);
    expect(captured!.returnOnly, 0);
    expect(captured!.people, 4);
    expect(captured!.isMixed, isTrue);
  });

  testWidgets('a return-only party is expressible', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 2);
    await answer(tester, PartyGateScreen.bothWaysKey, false);
    await setSplit(tester, PartyGateScreen.returnKey, 2);
    await submit(tester);

    expect(captured!.returnOnly, 2);
    expect(captured!.people, 2);
  });

  testWidgets('changing the headline count re-zeroes the split', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 4);
    await answer(tester, PartyGateScreen.bothWaysKey, false);
    await setSplit(tester, PartyGateScreen.roundTripKey, 4);
    await pickPeople(tester, 3);
    await submit(tester);

    expect(
      captured,
      isNull,
      reason: 'a stale split from the old headline must not silently survive '
          'into a party that no longer has that many people',
    );
  });

  testWidgets('saying yes again clears a half-entered split', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    await pickPeople(tester, 3);
    await answer(tester, PartyGateScreen.bothWaysKey, false);
    await setSplit(tester, PartyGateScreen.outboundKey, 3);
    await answer(tester, PartyGateScreen.bothWaysKey, true);
    await submit(tester);

    expect(captured!.roundTrip, 3);
    expect(captured!.outboundOnly, 0, reason: 'the abandoned split is gone');
  });

  testWidgets('changing the party size updates what is sent', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await pickPeople(tester, 5);
    await pickPeople(tester, 2);
    await submit(tester);

    expect(captured!.people, 2, reason: 'the last answer wins');
  });
}
