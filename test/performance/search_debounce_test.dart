import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/search_debounce.dart';

// testWidgets for its fake clock: tester.pump(d) advances timers by d.
void main() {
  testWidgets('small list (<= 50 rows): every keystroke applies at once',
      (tester) async {
    final d = SearchDebouncer();
    final applied = <String>[];
    for (final q in ['r', 'ra', 'ram']) {
      d.run(q, 50, applied.add);
    }
    expect(applied, ['r', 'ra', 'ram']);
    expect(d.isPending, isFalse);
  });

  testWidgets('big list: a typing burst applies ONCE, with the latest query',
      (tester) async {
    final d = SearchDebouncer();
    final applied = <String>[];
    d.run('r', 76, applied.add);
    await tester.pump(const Duration(milliseconds: 100));
    d.run('ra', 76, applied.add);
    await tester.pump(const Duration(milliseconds: 100));
    d.run('ram', 76, applied.add);
    expect(applied, isEmpty);
    await tester.pump(const Duration(milliseconds: 249));
    expect(applied, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(applied, ['ram']);
  });

  testWidgets(
      'big list: clearing applies immediately and drops the pending query',
      (tester) async {
    final d = SearchDebouncer();
    final applied = <String>[];
    d.run('ram', 76, applied.add);
    d.run('', 76, applied.add);
    expect(applied, ['']);
    await tester.pump(const Duration(seconds: 1));
    expect(applied, ['']);
  });

  testWidgets('cancel / dispose drop a pending apply', (tester) async {
    final d = SearchDebouncer();
    final applied = <String>[];
    d.run('ram', 76, applied.add);
    d.dispose();
    await tester.pump(const Duration(seconds: 1));
    expect(applied, isEmpty);
  });
}
