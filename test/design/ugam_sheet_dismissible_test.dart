import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_sheet.dart';

/// Regression cover for `isDismissible` on the **Cupertino** presentation path.
///
/// `UgamSheet.show` branches on platform: Android gets `showModalBottomSheet`
/// (which takes `isDismissible` directly), iOS/macOS get
/// `showCupertinoModalPopup` — whose `barrierDismissible` DEFAULTS TO TRUE and
/// was not being passed. A sheet the caller declared non-dismissible was
/// therefore still tap-outside-dismissible on iPhone and not on Android, so any
/// flow leaning on that guarantee (a required choice, an unsaved-changes
/// prompt) could be escaped on exactly one platform.
///
/// The grab handle is covered here too: it is a second dismissal path and has
/// to obey the same flag, or the guarantee is false on both platforms.
void main() {
  Widget host({
    required TargetPlatform platform,
    required bool isDismissible,
  }) => MaterialApp(
    theme: ThemeData(brightness: Brightness.dark, platform: platform),
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () => UgamSheet.show<void>(
              context,
              isDismissible: isDismissible,
              // The close button is the caller's own explicit escape hatch and
              // is deliberately NOT gated by isDismissible — keep it out of
              // the way so these tests only see the barrier and the handle.
              showClose: false,
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

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('sheet-content')),
      findsOneWidget,
      reason: 'sheet should be open before the dismissal attempt',
    );
  }

  /// Taps well above the sheet — inside the scrim, outside the content.
  Future<void> tapBarrier(WidgetTester tester) async {
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    testWidgets('$platform: non-dismissible sheet survives a barrier tap', (
      tester,
    ) async {
      await tester.pumpWidget(host(platform: platform, isDismissible: false));
      await openSheet(tester);
      await tapBarrier(tester);

      // Pre-fix this FAILED: showCupertinoModalPopup was left on its
      // barrierDismissible: true default, so the sheet popped.
      expect(
        find.byKey(const Key('sheet-content')),
        findsOneWidget,
        reason: 'isDismissible: false must block the tap-outside path on '
            '$platform exactly as it does on Android',
      );
    });

    testWidgets('$platform: dismissible sheet still closes on a barrier tap', (
      tester,
    ) async {
      await tester.pumpWidget(host(platform: platform, isDismissible: true));
      await openSheet(tester);
      await tapBarrier(tester);

      expect(
        find.byKey(const Key('sheet-content')),
        findsNothing,
        reason: 'the default must stay tap-outside-dismissible',
      );
    });
  }

  testWidgets('android: non-dismissible sheet survives a barrier tap', (
    tester,
  ) async {
    // The platform that was already correct — pinned so a future refactor of
    // the shared path cannot regress it while fixing iOS.
    await tester.pumpWidget(
      host(platform: TargetPlatform.android, isDismissible: false),
    );
    await openSheet(tester);
    await tapBarrier(tester);

    expect(find.byKey(const Key('sheet-content')), findsOneWidget);
  });

  testWidgets('android: dismissible sheet still closes on a barrier tap', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(platform: TargetPlatform.android, isDismissible: true),
    );
    await openSheet(tester);
    await tapBarrier(tester);

    expect(find.byKey(const Key('sheet-content')), findsNothing);
  });

  group('grab handle', () {
    // The 36x4 bar. `Container(width:, height:)` resolves to tight
    // constraints, so match on those rather than on a SizedBox.
    final handle = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.constraints == BoxConstraints.tightFor(width: 36, height: 4),
      description: 'sheet grab handle',
    );

    testWidgets('is inert when the sheet is non-dismissible', (tester) async {
      await tester.pumpWidget(
        host(platform: TargetPlatform.android, isDismissible: false),
      );
      await openSheet(tester);
      expect(handle, findsOneWidget);

      await tester.tap(handle, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('sheet-content')),
        findsOneWidget,
        reason: 'the handle must not defeat isDismissible: false',
      );
    });

    testWidgets('still dismisses a normal sheet', (tester) async {
      await tester.pumpWidget(
        host(platform: TargetPlatform.android, isDismissible: true),
      );
      await openSheet(tester);

      await tester.tap(handle);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('sheet-content')),
        findsNothing,
        reason: 'the handle stays a working dismissal path by default',
      );
    });
  });
}
