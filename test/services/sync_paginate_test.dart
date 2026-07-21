import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/sync_service.dart';

void main() {
  Future<List<int>> Function(int, int) fakeSource(int total, {required List<int> calls}) {
    return (from, to) async {
      calls.add(from);
      final end = (to + 1).clamp(0, total);
      if (from >= total) return <int>[];
      return [for (var i = from; i < end; i++) i];
    };
  }

  test('stops after a short page and returns every row', () async {
    final calls = <int>[];
    final rows = await paginateRows<int>(fakeSource(2300, calls: calls), pageSize: 1000);
    expect(rows.length, 2300);
    expect(calls, [0, 1000, 2000]); // third page is short → stop
  });

  test('exact-multiple boundary fetches one extra empty page then stops', () async {
    final calls = <int>[];
    final rows = await paginateRows<int>(fakeSource(2000, calls: calls), pageSize: 1000);
    expect(rows.length, 2000);
    expect(calls, [0, 1000, 2000]); // 2000 rows in 2 full pages, 3rd empty ends it
  });

  test('single short page', () async {
    final calls = <int>[];
    final rows = await paginateRows<int>(fakeSource(42, calls: calls), pageSize: 1000);
    expect(rows.length, 42);
    expect(calls, [0]);
  });
}
