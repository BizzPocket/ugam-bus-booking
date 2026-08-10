import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_sheet.dart';

/// Regression cover for enforced edge-to-edge (Android 15+, and unavoidable at
/// targetSdk 36).
///
/// `UgamSheet.show` passes `useSafeArea: true` to `showModalBottomSheet`, which
/// the framework resolves to `SafeArea(bottom: false)` — it insets the TOP only
/// and deliberately leaves the bottom to the sheet. Before the fix, the shell
/// padded `viewInsets.bottom` alone, which is 0 whenever the keyboard is down,
/// so the last row of every sheet in the app sat under the gesture pill or the
/// 3-button navigation bar.
///
/// The default widget-test harness reports padding/viewPadding/viewInsets as
/// zero on every pump, so no existing test can see a system-bar inset. This one
/// fakes one explicitly.
void main() {
  // A 3-button navigation bar is 48dp. FakeViewPadding is in PHYSICAL pixels,
  // so at devicePixelRatio 3.0 that is 144.
  const navBarLogical = 48.0;
  const navBarPhysical = 144.0;

  Widget host() => MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          // Pin the platform so we exercise the Material bottom-sheet path
          // rather than showCupertinoModalPopup.
          platform: TargetPlatform.android,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => UgamSheet.show<void>(
                  context,
                  builder: (_) => const SizedBox(
                    key: Key('sheet-content'),
                    height: 120,
                    width: double.infinity,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

  testWidgets('sheet content clears the system navigation bar inset',
      (tester) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.padding = const FakeViewPadding(bottom: navBarPhysical);
    tester.view.viewPadding = const FakeViewPadding(bottom: navBarPhysical);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sheet-content')), findsOneWidget);

    final screenBottom = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final contentBottom =
        tester.getBottomLeft(find.byKey(const Key('sheet-content'))).dy;
    final clearance = screenBottom - contentBottom;

    // Pre-fix this is UgamSpacing.xl (the shell's own content padding) alone,
    // which is well under 48 and leaves the content under the nav bar.
    expect(
      clearance,
      greaterThanOrEqualTo(navBarLogical),
      reason: 'sheet content must not render under the $navBarLogical dp '
          'navigation bar; clearance was $clearance',
    );
  });

  testWidgets('no phantom inset when there is no system bar', (tester) async {
    // The zero-inset case must be unchanged — max() must not invent padding.
    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final screenBottom = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final contentBottom =
        tester.getBottomLeft(find.byKey(const Key('sheet-content'))).dy;

    // Only the shell's own padding, no system inset added.
    expect(screenBottom - contentBottom, lessThan(navBarLogical));
  });
}
