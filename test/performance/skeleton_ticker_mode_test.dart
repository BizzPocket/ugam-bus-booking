import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_skeleton.dart';

/// PERF pin: a skeleton in a hidden shell tab (IndexedStack keeps it mounted
/// with tickers muted) must not keep the shared pulse — and a frame per vsync
/// — running. Showing the tab again resumes it.
void main() {
  // Mirrors MainShell: an IndexedStack whose hidden tabs are TickerMode-off.
  Widget shell(int index) => MaterialApp(
        home: IndexedStack(
          index: index,
          children: [
            // tab 0: a loaded screen, no skeleton
            TickerMode(enabled: index == 0, child: const SizedBox()),
            TickerMode(
              enabled: index == 1,
              child: const Column(
                children: [UgamSkeleton.row(), UgamSkeleton.card()],
              ),
            ),
          ],
        ),
      );

  testWidgets('hidden-tab skeletons stop the pulse; visible ones run it',
      (tester) async {
    await tester.pumpWidget(shell(1));
    expect(debugSkeletonPulseAnimating(), isTrue);
    await tester.pump(const Duration(milliseconds: 300));

    // Switch away: the skeleton tab is hidden but still mounted.
    await tester.pumpWidget(shell(0));
    expect(find.byType(UgamSkeleton, skipOffstage: false), findsNWidgets(2));
    expect(debugSkeletonPulseAnimating(), isFalse);
    // Nothing left driving frames once the switch has settled.
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.binding.hasScheduledFrame, isFalse);

    // Back to the tab: pulse resumes.
    await tester.pumpWidget(shell(1));
    expect(debugSkeletonPulseAnimating(), isTrue);

    // Unmount: stops.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(debugSkeletonPulseAnimating(), isFalse);
  });
}
