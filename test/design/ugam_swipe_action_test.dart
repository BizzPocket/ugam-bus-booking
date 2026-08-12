import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/design/components/ugam_swipe_action.dart';

/// The shape that crashed: a row with a right-swipe action lives in a list
/// that never removes it. If the destructive left swipe is armed anyway, the
/// row is dismissed out of a list that still contains it and Flutter throws
/// "A dismissed Dismissible widget is still part of the tree".
Widget _host(Widget child) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(body: ListView(children: [child])),
    );

/// A one-row list that genuinely deletes, for the "real delete still works"
/// case — the row leaves the underlying data, not just the tree.
class _DeletableList extends StatefulWidget {
  final VoidCallback? onDeleted;
  final Future<bool> Function()? confirmDelete;
  final IconData? rightIcon;

  const _DeletableList({
    this.onDeleted,
    this.confirmDelete,
    this.rightIcon,
  });

  @override
  State<_DeletableList> createState() => _DeletableListState();
}

class _DeletableListState extends State<_DeletableList> {
  final List<String> _rows = ['row-a'];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: ListView(
          children: [
            for (final r in _rows)
              UgamSwipeAction(
                key: ValueKey(r),
                rightIcon: widget.rightIcon,
                confirmDelete: widget.confirmDelete,
                onDelete: () {
                  setState(() => _rows.remove(r));
                  widget.onDeleted?.call();
                },
                child: SizedBox(height: 64, child: Text(r)),
              ),
          ],
        ),
      ),
    );
  }
}

void main() {
  group('UgamSwipeAction destructive-swipe arming', () {
    testWidgets(
        'rightIcon with no delete handler: left swipe neither crashes nor '
        'removes the row', (tester) async {
      var rightFired = 0;

      // Rebuilt from the same unchanged data every time, exactly like the Obx
      // screens: the list still contains this row after the swipe.
      Widget row() => UgamSwipeAction(
            key: const ValueKey('collect-row'),
            rightIcon: Icons.check_rounded,
            rightLabel: 'Collect',
            onRight: () => rightFired++,
            child: const SizedBox(height: 64, child: Text('passenger row')),
          );

      await tester.pumpWidget(_host(row()));

      // Left (endToStart) fling — the destructive direction.
      await tester.drag(find.text('passenger row'), const Offset(-600, 0));
      await tester.pumpAndSettle();

      // The rebuild is what trips "A dismissed Dismissible widget is still
      // part of the tree" once the row has been wrongly dismissed.
      await tester.pumpWidget(_host(row()));
      await tester.pumpAndSettle();

      expect(
        tester.takeException(),
        isNull,
        reason: 'a row nobody deletes must never be dismissed',
      );
      expect(find.text('passenger row'), findsOneWidget);
      expect(rightFired, 0, reason: 'a left swipe is not the right action');
    });

    testWidgets('rightIcon with no delete handler arms startToEnd only',
        (tester) async {
      await tester.pumpWidget(_host(
        UgamSwipeAction(
          key: const ValueKey('collect-row'),
          rightIcon: Icons.check_rounded,
          onRight: () {},
          child: const SizedBox(height: 64, child: Text('passenger row')),
        ),
      ));

      final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
      expect(dismissible.direction, DismissDirection.startToEnd);
    });

    testWidgets('no rightIcon and no delete handler is not dismissible at all',
        (tester) async {
      await tester.pumpWidget(_host(
        const UgamSwipeAction(
          key: ValueKey('inert-row'),
          child: SizedBox(height: 64, child: Text('inert row')),
        ),
      ));

      final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
      expect(dismissible.direction, DismissDirection.none);

      await tester.drag(find.text('inert row'), const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('inert row'), findsOneWidget);
    });

    testWidgets('right swipe still fires onRight and keeps the row',
        (tester) async {
      var rightFired = 0;

      await tester.pumpWidget(_host(
        UgamSwipeAction(
          key: const ValueKey('collect-row'),
          rightIcon: Icons.check_rounded,
          onRight: () => rightFired++,
          child: const SizedBox(height: 64, child: Text('passenger row')),
        ),
      ));

      await tester.drag(find.text('passenger row'), const Offset(600, 0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(rightFired, 1);
      expect(
        find.text('passenger row'),
        findsOneWidget,
        reason: 'the right action snaps the row back, never removes it',
      );
    });

    testWidgets('a real delete handler still arms the destructive swipe',
        (tester) async {
      var deleted = 0;

      await tester.pumpWidget(_DeletableList(onDeleted: () => deleted++));

      final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
      expect(dismissible.direction, DismissDirection.endToStart);

      await tester.drag(find.text('row-a'), const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(deleted, 1);
      expect(find.text('row-a'), findsNothing);
    });

    testWidgets('rightIcon plus a delete handler stays horizontal',
        (tester) async {
      await tester.pumpWidget(
        const _DeletableList(rightIcon: Icons.check_rounded),
      );

      final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
      expect(dismissible.direction, DismissDirection.horizontal);
    });

    testWidgets('a confirmDelete that refuses snaps the row back',
        (tester) async {
      // The tours_screen shape: rightIcon plus an always-false gate.
      var deleted = 0;

      await tester.pumpWidget(_DeletableList(
        rightIcon: Icons.play_arrow_rounded,
        confirmDelete: () async => false,
        onDeleted: () => deleted++,
      ));

      await tester.drag(find.text('row-a'), const Offset(-600, 0));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(deleted, 0);
      expect(find.text('row-a'), findsOneWidget);
    });
  });
}
