import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/handler_controller.dart';
import 'package:occubusbooking/models/handler_manifest.dart';

/// The handler's phone is on the bus, on 2G. Every write fires a background
/// reconcile, and "board all" at a stop is several writes in a row.
void main() {
  test('a burst of reconciles runs ONE reload, then one follow-up', () async {
    var reads = 0;
    final gates = <Completer<void>>[];
    final ctrl = HandlerController(
      requestId: 'r1',
      manifestReader: (_) async {
        reads++;
        final g = Completer<void>();
        gates.add(g);
        await g.future;
        return HandlerManifest(buses: const [], passengers: const []);
      },
      scheduleReader: (_) async => const [],
    );

    for (var i = 0; i < 6; i++) {
      ctrl.reconcile();
    }
    await pumpEventQueue();
    expect(reads, 1, reason: 'six writes must not fire six full reloads');

    gates.first.complete();
    await pumpEventQueue();
    expect(reads, 2,
        reason: 'writes that landed during the first reload are confirmed once');

    gates.last.complete();
    await pumpEventQueue();
    expect(reads, 2, reason: 'and then it goes quiet');
  });

  test('signal back after a failed load re-reads; a healthy board does not',
      () async {
    var reads = 0;
    var online = false;
    final ctrl = HandlerController(
      requestId: 'r1',
      manifestReader: (_) async {
        reads++;
        if (!online) throw Exception('dead zone');
        return const HandlerManifest();
      },
      scheduleReader: (_) async => const [],
    );

    await ctrl.load();
    expect(ctrl.error.value, 'load');

    online = true;
    ctrl.reloadIfLastLoadFailed();
    await pumpEventQueue();
    expect(reads, 2);
    expect(ctrl.error.value, isNull, reason: 'the error card heals itself');

    ctrl.reloadIfLastLoadFailed();
    await pumpEventQueue();
    expect(reads, 2, reason: 'nothing failed, nothing to re-read');
  });
}
