import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/customer_requests_store.dart';
import 'package:occubusbooking/widgets/hold_countdown_strip.dart';

/// The surface that was missing entirely.
///
/// A customer who held seats and dismissed the UPI sheet had NO way back to
/// paying: My Requests showed no countdown, no retry, and no expiry notice —
/// it showed "Cancelled". This strip is the recovery path.
void main() {
  CustomerRequestEntry entry({
    required String status,
    DateTime? holdExpiresAt,
    String? holdId = 'hold-1',
    int advancePaise = 300000,
    String? vpa = 'ugamtest@upi',
  }) =>
      CustomerRequestEntry(
        id: 'req-1',
        tourId: 'tour-1',
        tourTitle: '[TEST-A] Chart Booking',
        tourFromCity: 'Ahmedabad',
        tourToCity: 'Dwarka',
        tourDepartureDate: DateTime(2026, 8, 21),
        tourPricePerSeat: 1200,
        customerName: 'Rider',
        customerPhone: '+919000000000',
        partySize: 6,
        doubleSofa: 3,
        singleSofa: 0,
        status: status,
        createdAt: DateTime(2026, 8, 9, 15, 58),
        holdExpiresAt: holdExpiresAt,
        holdId: holdId,
        advancePaise: advancePaise,
        collectVpa: vpa,
      );

  Widget harness(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  /// A clock the test advances in step with `pump(duration)`.
  ///
  /// `tester.pump(d)` moves Flutter's FAKE clock, which fires the strip's
  /// timer, but `DateTime.now()` would keep returning real wall time — so a
  /// two-second hold would never appear to lapse and the test would pass
  /// against a widget that never expires anything.
  final base = DateTime(2026, 8, 9, 16, 0);
  var offset = Duration.zero;
  DateTime clock() => base.add(offset);

  setUp(() => offset = Duration.zero);

  testWidgets('a live hold shows a countdown and a pay action', (tester) async {
    var paid = 0;
    await tester.pumpWidget(harness(
      HoldCountdownStrip(
        entry: entry(
          status: 'held',
          holdExpiresAt: clock().add(const Duration(minutes: 4, seconds: 32)),
        ),
        onPay: () async => paid++,
        onRebook: () {},
        clock: clock,
      ),
    ));
    await tester.pump();

    expect(find.byKey(HoldCountdownStrip.countdownKey), findsOneWidget);
    expect(find.byKey(HoldCountdownStrip.payKey), findsOneWidget);

    await tester.tap(find.byKey(HoldCountdownStrip.payKey));
    await tester.pump();
    expect(paid, 1, reason: 'the retry must actually reach the payment flow');
  });

  testWidgets('the countdown renders m:ss and ticks down', (tester) async {
    await tester.pumpWidget(harness(
      HoldCountdownStrip(
        entry: entry(
          status: 'held',
          holdExpiresAt: clock().add(const Duration(minutes: 2, seconds: 5)),
        ),
        onPay: () async {},
        onRebook: () {},
        clock: clock,
      ),
    ));
    await tester.pump();

    final first = tester
        .widget<Text>(find.byKey(HoldCountdownStrip.countdownKey))
        .data!;
    expect(first, matches(RegExp(r'\d+:\d{2}')));

    // Advance the injected clock in step with the fake one driving the timer.
    offset = const Duration(seconds: 2);
    await tester.pump(const Duration(seconds: 2));
    final second = tester
        .widget<Text>(find.byKey(HoldCountdownStrip.countdownKey))
        .data!;
    expect(
      second,
      isNot(first),
      reason: 'a frozen countdown tells the customer nothing about urgency',
    );
  });

  testWidgets('an expired hold offers re-booking, not payment', (tester) async {
    var rebooked = 0;
    await tester.pumpWidget(harness(
      HoldCountdownStrip(
        entry: entry(
          status: 'expired',
          holdExpiresAt: clock().subtract(const Duration(minutes: 1)),
        ),
        onPay: () async {},
        onRebook: () => rebooked++,
        clock: clock,
      ),
    ));
    await tester.pump();

    expect(
      find.byKey(HoldCountdownStrip.payKey),
      findsNothing,
      reason: 'the seats are already back on sale — paying would buy nothing',
    );
    expect(find.byKey(HoldCountdownStrip.rebookKey), findsOneWidget);

    await tester.tap(find.byKey(HoldCountdownStrip.rebookKey));
    await tester.pump();
    expect(rebooked, 1);
  });

  testWidgets('a hold that lapses while on screen swaps to the expired state',
      (tester) async {
    await tester.pumpWidget(harness(
      HoldCountdownStrip(
        entry: entry(
          status: 'held',
          holdExpiresAt: clock().add(const Duration(seconds: 2)),
        ),
        onPay: () async {},
        onRebook: () {},
        clock: clock,
      ),
    ));
    await tester.pump();
    expect(find.byKey(HoldCountdownStrip.payKey), findsOneWidget);

    offset = const Duration(seconds: 3); // past the 2s deadline
    await tester.pump(const Duration(seconds: 3));
    expect(
      find.byKey(HoldCountdownStrip.payKey),
      findsNothing,
      reason: 'paying after the deadline would send money for released seats',
    );
    expect(find.byKey(HoldCountdownStrip.rebookKey), findsOneWidget);
  });

  testWidgets('a booking with no hold renders nothing at all', (tester) async {
    await tester.pumpWidget(harness(
      HoldCountdownStrip(
        entry: entry(status: 'pending'),
        onPay: () async {},
        onRebook: () {},
        clock: clock,
      ),
    ));
    await tester.pump();

    expect(find.byKey(HoldCountdownStrip.countdownKey), findsNothing);
    expect(find.byKey(HoldCountdownStrip.payKey), findsNothing);
    expect(find.byKey(HoldCountdownStrip.rebookKey), findsNothing);
  });

  testWidgets('a held booking with no VPA cannot be paid online', (tester) async {
    await tester.pumpWidget(harness(
      HoldCountdownStrip(
        entry: entry(
          status: 'held',
          holdExpiresAt: clock().add(const Duration(minutes: 3)),
          vpa: null,
        ),
        onPay: () async {},
        onRebook: () {},
        clock: clock,
      ),
    ));
    await tester.pump();

    expect(
      find.byKey(HoldCountdownStrip.countdownKey),
      findsOneWidget,
      reason: 'the customer still needs to know their seats are held',
    );
    expect(find.byKey(HoldCountdownStrip.payKey), findsNothing);
  });
}
