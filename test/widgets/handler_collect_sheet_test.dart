import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/payment_claim.dart';
import 'package:occubusbooking/widgets/handler/handler_collect_sheet.dart';

/// The collect sheet prices from the seat fare alone, so a rider who already
/// sent a UPI advance was asked for the full amount again on the bus — the
/// `handler_payment_claims` RPC (migration 060) has been live since August
/// with no caller. The sheet now names the rider's claims, verified or not, so
/// the handler never collects money the agent already has.
///
/// EasyLocalization is not initialised, so `tr(key)` returns the raw key.
void main() {
  final rider = Passenger(
    id: 'p-1',
    tourId: 'tour-1',
    name: 'Rider',
    phone: '9990000000',
  );

  PaymentClaim claim(PaymentClaimStatus status) => PaymentClaim(
    id: 'c-1',
    tourId: 'tour-1',
    passengerId: 'p-1',
    amountRupees: 1600,
    status: status,
    claimedAt: DateTime(2026, 9, 3),
  );

  Widget app(List<PaymentClaim> claims) => MaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: Scaffold(
      body: HandlerCollectSheet(
        passenger: rider,
        seatId: 'SL1',
        due: 1600,
        existing: null,
        claims: claims,
        onSave: (_, _, _, _) async {},
      ),
    ),
  );

  testWidgets('an unverified UPI claim is named as the rider\'s word', (
    tester,
  ) async {
    await tester.pumpWidget(app([claim(PaymentClaimStatus.pending)]));
    await tester.pumpAndSettle();

    expect(find.text('handler_chart.upi_claim_pending'), findsOneWidget);
    expect(find.text('handler_chart.upi_claim_confirmed'), findsNothing);
  });

  testWidgets('a confirmed UPI advance is named as verified', (tester) async {
    await tester.pumpWidget(app([claim(PaymentClaimStatus.confirmed)]));
    await tester.pumpAndSettle();

    expect(find.text('handler_chart.upi_claim_confirmed'), findsOneWidget);
    expect(find.text('handler_chart.upi_claim_pending'), findsNothing);
  });

  testWidgets('no claim, no line', (tester) async {
    await tester.pumpWidget(app(const []));
    await tester.pumpAndSettle();

    expect(find.text('handler_chart.upi_claim_pending'), findsNothing);
    expect(find.text('handler_chart.upi_claim_confirmed'), findsNothing);
  });

  // ── Paid in full + folded rare fields ──

  testWidgets('"Paid in full" fills the fare in one tap, then hides', (
    tester,
  ) async {
    double? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: HandlerCollectSheet(
            passenger: rider,
            seatId: 'SL1',
            due: 1600,
            existing: null,
            onSave: (received, _, _, _) async => saved = received,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('collect-paid-in-full'));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();

    // The field now reads the full fare, so the chip has nothing left to do.
    expect(find.byKey(const ValueKey('collect-paid-in-full')), findsNothing);
    expect(find.text('1600'), findsOneWidget);
    expect(find.text('handler_chart.balance_settled'), findsOneWidget);

    await tester.tap(find.text('app.action.save'));
    await tester.pumpAndSettle();
    expect(saved, 1600);
  });

  testWidgets('returned / collected-by / note start folded away', (
    tester,
  ) async {
    await tester.pumpWidget(app(const []));
    await tester.pumpAndSettle();

    // UgamInput upper-cases its label.
    const returned = 'HANDLER_CHART.FIELD_RETURNED';
    const note = 'HANDLER_CHART.FIELD_NOTE';
    expect(find.text('handler_chart.collect_more_details'), findsOneWidget);
    // AnimatedCrossFade keeps the folded child mounted (ignored, invisible),
    // so "folded" means not hit-testable.
    expect(find.text(returned).hitTestable(), findsNothing);
    expect(find.text(note).hitTestable(), findsNothing);

    await tester.ensureVisible(find.text('handler_chart.collect_more_details'));
    await tester.tap(find.text('handler_chart.collect_more_details'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(note));
    await tester.pumpAndSettle();
    expect(find.text(returned).hitTestable(), findsOneWidget);
    expect(find.text(note).hitTestable(), findsOneWidget);
  });
}
