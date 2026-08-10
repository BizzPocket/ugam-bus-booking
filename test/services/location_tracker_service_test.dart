import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_position.dart';
import 'package:occubusbooking/services/location_tracker_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

LocationFix fixAt(int minute) => LocationFix(
  lat: 23.0 + minute / 1000,
  lng: 72.0,
  recordedAt: DateTime.utc(2026, 8, 10, 12, minute),
);

/// Records every batch handed to the RPC and replies with a scripted result.
class FakePusher {
  FakePusher(this.reply);
  final Map<String, dynamic> Function(List<Map<String, dynamic>> fixes) reply;
  final List<List<Map<String, dynamic>>> calls = [];

  Future<Map<String, dynamic>> call(
    String requestId,
    String busId,
    List<Map<String, dynamic>> fixes,
  ) async {
    calls.add(fixes);
    return reply(fixes);
  }
}

Map<String, dynamic> accepted(List<Map<String, dynamic>> f) => {
  'accepted': f.length,
  'skipped': 0,
};

void main() {
  late LocationTrackerService svc;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    svc = LocationTrackerService();
  });

  Future<void> seed(int n) async {
    for (var i = 1; i <= n; i++) {
      await svc.debugAddFix(fixAt(i));
    }
  }

  group('flush — success path', () {
    test('sends buffered fixes and empties the buffer', () async {
      final fake = FakePusher(accepted);
      svc.pusher = fake.call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(3);

      await svc.flushNow();

      expect(fake.calls.first.length, 3);
      expect(svc.debugBufferLength, 0);
    });

    test('drops the whole batch even when the server skipped some', () async {
      final fake = FakePusher((f) => {'accepted': 1, 'skipped': f.length - 1});
      svc.pusher = fake.call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(4);

      await svc.flushNow();

      expect(
        svc.debugBufferLength,
        0,
        reason: 'skipped fixes are invalid or already stored — never resend',
      );
    });

    test('caps each call at 500 and loops until drained', () async {
      final fake = FakePusher(accepted);
      svc.pusher = fake.call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(1200);

      await svc.flushNow();

      expect(fake.calls.map((c) => c.length).toList(), [500, 500, 200]);
      expect(svc.debugBufferLength, 0);
    });

    test('records the upload time for the status card', () async {
      svc.pusher = FakePusher(accepted).call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(1);

      expect(svc.lastUploadAt.value, isNull);
      await svc.flushNow();
      expect(svc.lastUploadAt.value, isNotNull);
    });

    test('sends fixes in the RPC key shape', () async {
      final fake = FakePusher(accepted);
      svc.pusher = fake.call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(1);

      await svc.flushNow();

      expect(fake.calls.first.first.keys.toSet(), {
        'lat',
        'lng',
        'accuracy_m',
        'speed_kmh',
        'heading_deg',
        'leg',
        'recorded_at',
        'tracking_state',
      });
    });
  });

  group('flush — server refusals arrive as data, not throws', () {
    test('window_closed stops tracking and clears the buffer', () async {
      svc.pusher = FakePusher((_) => {'error': 'window_closed'}).call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(5);

      await svc.flushNow();

      expect(svc.status.value, TrackingStatus.windowClosed);
      expect(svc.debugBufferLength, 0);
    });

    test('forbidden stops tracking and clears the buffer', () async {
      svc.pusher = FakePusher((_) => {'error': 'forbidden'}).call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(5);

      await svc.flushNow();

      expect(svc.status.value, TrackingStatus.forbidden);
      expect(svc.debugBufferLength, 0);
    });

    test('bad_payload drops the batch instead of retrying forever', () async {
      var calls = 0;
      svc.pusher = (_, _, _) async {
        calls++;
        return {'error': 'bad_payload'};
      };
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(3);

      await svc.flushNow();

      expect(svc.debugBufferLength, 0);
      expect(calls, 1);
      expect(
        svc.status.value,
        TrackingStatus.live,
        reason: 'a client bug must not look like a permission failure',
      );
    });
  });

  group('flush — thrown errors preserve the buffer', () {
    test('a retryable failure keeps fixes and escalates backoff', () async {
      svc.pusher = (_, _, _) async =>
          throw const SocketException('no route to host');
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(3);

      expect(svc.currentBackoff, const Duration(minutes: 2));
      await svc.flushNow();

      expect(svc.debugBufferLength, 3, reason: 'nothing confirmed — keep it');
      expect(svc.currentBackoff, const Duration(minutes: 4));
    });

    test('backoff escalates 2-4-8-16 and then caps', () async {
      svc.pusher = (_, _, _) async => throw const SocketException('down');
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(1);

      final seen = <int>[];
      for (var i = 0; i < 5; i++) {
        await svc.flushNow();
        seen.add(svc.currentBackoff.inMinutes);
      }
      expect(seen, [4, 8, 16, 16, 16]);
    });

    test('a success resets backoff to the floor', () async {
      var fail = true;
      svc.pusher = (_, _, f) async {
        if (fail) throw const SocketException('down');
        return {'accepted': f.length, 'skipped': 0};
      };
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(1);

      await svc.flushNow();
      expect(svc.currentBackoff, const Duration(minutes: 4));

      fail = false;
      await svc.flushNow();
      expect(svc.currentBackoff, const Duration(minutes: 2));
    });

    test('a terminal failure keeps the buffer and does not escalate', () async {
      svc.pusher = (_, _, _) async => throw ArgumentError('client bug');
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(2);

      await svc.flushNow();

      expect(svc.debugBufferLength, 2);
      expect(
        svc.currentBackoff,
        const Duration(minutes: 2),
        reason: 'no retry storm against an error retrying cannot fix',
      );
    });
  });

  group('concurrency and lifecycle', () {
    test('overlapping flushes do not double-send', () async {
      var calls = 0;
      svc.pusher = (_, _, f) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return {'accepted': f.length, 'skipped': 0};
      };
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(3);

      await Future.wait([svc.flushNow(), svc.flushNow()]);
      expect(calls, 1);
    });

    test('flush is a no-op before start', () async {
      var calls = 0;
      svc.pusher = (_, _, _) async {
        calls++;
        return {'accepted': 0, 'skipped': 0};
      };
      await svc.flushNow();
      expect(calls, 0);
    });

    test('stop clears status back to idle', () async {
      svc.pusher = FakePusher(accepted).call;
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await svc.stop();
      expect(svc.status.value, TrackingStatus.idle);
    });

    test('a stopped tracker refuses further flushes', () async {
      var calls = 0;
      svc.pusher = (_, _, f) async {
        calls++;
        return {'accepted': f.length, 'skipped': 0};
      };
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(2);
      await svc.stop();

      await svc.flushNow();
      expect(calls, 0);
    });

    test('record is ignored before attach', () async {
      await svc.debugAddFix(fixAt(1));
      expect(svc.debugBufferLength, 0);
    });
  });

  group('buffered fixes survive a restart', () {
    test('rehydrates the previous session and uploads it', () async {
      await svc.debugAttach(requestId: 'r1', busId: 'b1');
      await seed(2);

      final revived = LocationTrackerService();
      final fake = FakePusher(accepted);
      revived.pusher = fake.call;
      await revived.debugAttach(requestId: 'r1', busId: 'b1');

      await revived.flushNow();
      expect(fake.calls.first.length, 2);
    });
  });
}
