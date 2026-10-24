import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/utils/in_flight.dart';

void main() {
  tearDown(InFlight.reset);

  test('a second tap while the first write is on the wire runs NOTHING',
      () async {
    var runs = 0;
    final gate = Completer<void>();
    Future<int> action() async {
      runs++;
      await gate.future;
      return runs;
    }

    final first = InFlight.run('upi-claim:c1', action);
    final second = await InFlight.run('upi-claim:c1', action);

    expect(second, isNull, reason: 'the double tap is dropped, not queued');
    expect(runs, 1);
    expect(InFlight.isBusy('upi-claim:c1'), isTrue);

    gate.complete();
    expect(await first, 1);
    expect(InFlight.isBusy('upi-claim:c1'), isFalse);
  });

  test('a different subject is never blocked by another one in flight',
      () async {
    final gate = Completer<void>();
    final a = InFlight.run('upi-claim:c1', () => gate.future);
    var ranB = false;
    await InFlight.run('upi-claim:c2', () async => ranB = true);
    expect(ranB, isTrue);
    gate.complete();
    await a;
  });

  test('a write that THROWS releases its key, so the agent can try again',
      () async {
    await expectLater(
      InFlight.run('tour-complete:t1', () async => throw StateError('2G')),
      throwsStateError,
    );
    expect(InFlight.isBusy('tour-complete:t1'), isFalse);

    var ran = false;
    await InFlight.run('tour-complete:t1', () async => ran = true);
    expect(ran, isTrue);
  });
}
