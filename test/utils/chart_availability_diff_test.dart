import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/chart_seat_availability.dart';

/// The customer chart polls availability every 20 seconds and used to call
/// setState unconditionally, rebuilding the entire ListView whether or not
/// anything had actually changed. On a quiet tour that is a guaranteed rebuild
/// every 20s for no reason.
///
/// [availabilityEquals] is the guard. It is a pure value comparison because
/// [SeatAvailability] has no `==` of its own — comparing the maps directly
/// would compare identities and always report "changed".
void main() {
  const busId = 'bus-1';

  SeatAvailability seat(
    String id, {
    int go = 0,
    int ret = 0,
    bool ladyGo = false,
    bool ladyRet = false,
  }) =>
      SeatAvailability(
        busId: busId,
        seatId: id,
        usedGo: go,
        usedRet: ret,
        ladyGo: ladyGo,
        ladyRet: ladyRet,
      );

  test('two separately-built maps with the same values are equal', () {
    final a = availabilityByKey([seat('SU1', go: 1, ret: 1)]);
    final b = availabilityByKey([seat('SU1', go: 1, ret: 1)]);

    expect(
      identical(a['$busId|SU1'], b['$busId|SU1']),
      isFalse,
      reason: 'the poll builds fresh instances every time — if this test ever '
          'compared identities it would prove nothing',
    );
    expect(availabilityEquals(a, b), isTrue);
  });

  test('a berth selling on the outbound leg counts as a change', () {
    final before = availabilityByKey([seat('SU1', go: 1, ret: 1)]);
    final after = availabilityByKey([seat('SU1', go: 2, ret: 1)]);
    expect(availabilityEquals(before, after), isFalse);
  });

  test('a berth selling on the return leg counts as a change', () {
    final before = availabilityByKey([seat('DL1', go: 1, ret: 1)]);
    final after = availabilityByKey([seat('DL1', go: 1, ret: 2)]);
    expect(availabilityEquals(before, after), isFalse);
  });

  test('the ladies marker appearing counts as a change', () {
    final before = availabilityByKey([seat('SU1', go: 1)]);
    final after = availabilityByKey([seat('SU1', go: 1, ladyGo: true)]);
    expect(availabilityEquals(before, after), isFalse);
  });

  test('a newly occupied seat counts as a change', () {
    final before = availabilityByKey([seat('SU1', go: 1)]);
    final after = availabilityByKey([seat('SU1', go: 1), seat('SL1', go: 1)]);
    expect(availabilityEquals(before, after), isFalse);
  });

  test('a seat freeing up entirely counts as a change', () {
    final before = availabilityByKey([seat('SU1', go: 1), seat('SL1', go: 1)]);
    final after = availabilityByKey([seat('SU1', go: 1)]);
    expect(availabilityEquals(before, after), isFalse);
  });

  test('two empty maps are equal', () {
    expect(
      availabilityEquals(
        const <String, SeatAvailability>{},
        const <String, SeatAvailability>{},
      ),
      isTrue,
    );
  });
}
