import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/tour_cache_store.dart';

import 'money_summary_bench_test.dart' show bigTour;

/// Microbenchmark (prints, asserts nothing about time): the JSON work the cold
/// start and the debounced tour-cache save do, on realistic payloads — the
/// three shipped translation bundles and a cached graph of 8 full 4-bus trips.
/// Desktop JIT numbers; a 2–3 GB Android phone is several times slower.
double _avgMs(int n, void Function() f) {
  for (var i = 0; i < 3; i++) {
    f();
  }
  final sw = Stopwatch()..start();
  for (var i = 0; i < n; i++) {
    f();
  }
  return sw.elapsedMicroseconds / n / 1000;
}

void main() {
  test('BENCH translation bundle jsonDecode', () {
    for (final lang in ['en', 'gu', 'hi']) {
      final raw = File('assets/translations/$lang.json').readAsStringSync();
      // ignore: avoid_print
      print('BENCH i18n $lang bytes=${raw.length} '
          'jsonDecode=${_avgMs(20, () => jsonDecode(raw)).toStringAsFixed(2)}ms');
    }
  });

  test('BENCH tour cache encode/decode (8 full trips)', () {
    final tours = <Tour>[
      for (var i = 0; i < 8; i++) bigTour(),
    ];
    late List<Map<String, dynamic>> maps;
    final encodeMs = _avgMs(10, () => maps = [for (final t in tours) encodeTour(t)]);
    late String payload;
    final jsonEncodeMs = _avgMs(10, () => payload = jsonEncode({'tours': maps}));
    late Object? decoded;
    final jsonDecodeMs = _avgMs(10, () => decoded = jsonDecode(payload));
    final toursJson = (decoded as Map)['tours'] as List;
    final decodeMs = _avgMs(10, () {
      for (final t in toursJson) {
        decodeTour(Map<String, dynamic>.from(t as Map));
      }
    });
    // ignore: avoid_print
    print('BENCH cache main-thread (old, inline) '
        'read=${(jsonDecodeMs + decodeMs).toStringAsFixed(2)}ms '
        'write=${(encodeMs + jsonEncodeMs).toStringAsFixed(2)}ms');
    // ignore: avoid_print
    print('BENCH cache bytes=${payload.length} '
        'encodeTour=${encodeMs.toStringAsFixed(2)}ms '
        'jsonEncode=${jsonEncodeMs.toStringAsFixed(2)}ms '
        'jsonDecode=${jsonDecodeMs.toStringAsFixed(2)}ms '
        'decodeTour=${decodeMs.toStringAsFixed(2)}ms');
  });

  test('BENCH tour cache store: longest main-isolate stall during read/write',
      () async {
    final dir = await Directory.systemTemp.createTemp('cache_bench');
    addTearDown(() => dir.delete(recursive: true));
    final store = TourCacheStore.forDirectory(dir);
    final snap = TourGraphSnapshot(
      scopeKey: 'tours_admin_a',
      savedAt: DateTime(2026, 10, 1),
      tours: [for (var i = 0; i < 8; i++) bigTour()],
    );

    /// Longest gap between 1 ms event-loop ticks while [op] runs — the time
    /// the main isolate could not service a frame.
    Future<double> maxStallMs(Future<void> Function() op) async {
      var worst = 0;
      final sw = Stopwatch()..start();
      var last = 0;
      final probe = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final now = sw.elapsedMicroseconds;
        if (now - last > worst) worst = now - last;
        last = now;
      });
      await op();
      probe.cancel();
      final tail = sw.elapsedMicroseconds - last;
      if (tail > worst) worst = tail;
      return worst / 1000;
    }

    await store.write(snap); // warm the isolate code path
    final w = await maxStallMs(() => store.write(snap));
    final r = await maxStallMs(() async {
      final got = await store.read('tours_admin_a');
      expect(got!.tours, hasLength(8));
    });
    // The pre-round-2 store, inline on the main isolate, probed the same way.
    final f = File('${dir.path}/inline.json');
    final wOld = await maxStallMs(() async {
      final payload = jsonEncode({
        'tours': [for (final t in snap.tours) encodeTour(t)],
      });
      await f.writeAsString(payload, flush: true);
    });
    final rOld = await maxStallMs(() async {
      final m = jsonDecode(await f.readAsString()) as Map;
      for (final t in m['tours'] as List) {
        decodeTour(Map<String, dynamic>.from(t as Map));
      }
    });
    // ignore: avoid_print
    print('BENCH cache store max main stall '
        'write old=${wOld.toStringAsFixed(2)}ms new=${w.toStringAsFixed(2)}ms '
        'read old=${rOld.toStringAsFixed(2)}ms new=${r.toStringAsFixed(2)}ms');
  });
}
