import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/error_reporter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An error reporter is the one component that runs while everything else is
/// already going wrong. Most of these tests are about it NOT making things
/// worse rather than about it working.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Map<String, dynamic>> sent;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ErrorReporter.resetForTest();
    sent = [];
    ErrorReporter.debugSink = (row) async => sent.add(row);
  });

  tearDown(ErrorReporter.resetForTest);

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('it cannot make things worse', () {
    test('a sink that throws does not propagate', () async {
      ErrorReporter.debugSink = (_) async => throw StateError('backend down');

      expect(
        () => ErrorReporter.report(kind: 'test', error: 'boom'),
        returnsNormally,
      );
      await settle();
    });

    test('a failed send KEEPS the report for next time', () async {
      ErrorReporter.debugSink = (_) async => throw StateError('offline');
      ErrorReporter.report(kind: 'test', error: 'offline failure');
      await settle();
      await settle();

      final prefs = await SharedPreferences.getInstance();
      final queue = prefs.getStringList('client_errors.queue') ?? [];
      expect(queue, hasLength(1),
          reason: 'a report raised while offline must survive to be sent later');

      // Now the network comes back.
      ErrorReporter.debugSink = (row) async => sent.add(row);
      await ErrorReporter.flush();

      expect(sent, hasLength(1));
      final after = (await SharedPreferences.getInstance())
              .getStringList('client_errors.queue') ??
          [];
      expect(after, isEmpty);
    });

    test('reporting a null-ish or odd error does not throw', () async {
      expect(
        () => ErrorReporter.report(kind: 'test', error: Object()),
        returnsNormally,
      );
      await settle();
    });
  });

  group('noise control', () {
    test('the same failure is reported once per session', () async {
      // A broken build() can fire sixty times a second in a rebuild loop.
      for (var i = 0; i < 20; i++) {
        ErrorReporter.report(kind: 'widget_build', error: 'same error');
      }
      await settle();
      await settle();

      expect(sent, hasLength(1));
    });

    test('different failures are all reported', () async {
      ErrorReporter.report(kind: 'widget_build', error: 'error A');
      await settle();
      ErrorReporter.report(kind: 'widget_build', error: 'error B');
      await settle();
      await settle();

      expect(sent, hasLength(2));
    });

    test('the same message under a different kind is a different report',
        () async {
      ErrorReporter.report(kind: 'flutter_error', error: 'x');
      await settle();
      ErrorReporter.report(kind: 'zone_error', error: 'x');
      await settle();
      await settle();

      expect(sent, hasLength(2));
    });
  });

  group('the payload', () {
    test('carries the build so a spike is attributable', () async {
      ErrorReporter.report(kind: 'test', error: 'boom');
      await settle();
      await settle();

      expect(sent, hasLength(1));
      final row = sent.single;
      // Without build_number a crash spike cannot be pinned to a release and a
      // staged rollout cannot be halted on evidence.
      expect(row.containsKey('build_number'), isTrue);
      expect(row.containsKey('app_version'), isTrue);
      expect(row['kind'], 'test');
      expect(row['message'], contains('boom'));
      expect(row['occurred_at'], isNotNull);
    });

    test('an enormous message is clipped to the column bound', () async {
      // The table CHECKs message <= 2000; an over-long insert would be rejected
      // and the report lost precisely when something is badly wrong.
      ErrorReporter.report(kind: 'test', error: 'y' * 5000);
      await settle();
      await settle();

      expect((sent.single['message'] as String).length, lessThanOrEqualTo(2000));
    });

    test('an enormous stack is clipped to the column bound', () async {
      ErrorReporter.report(
        kind: 'test',
        error: 'boom',
        stack: StackTrace.fromString('z' * 20000),
      );
      await settle();
      await settle();

      expect((sent.single['stack'] as String).length, lessThanOrEqualTo(8000));
    });

    test('context is carried through', () async {
      ErrorReporter.report(
        kind: 'test',
        error: 'boom',
        context: {'screen': 'handler_chart'},
      );
      await settle();
      await settle();

      expect(sent.single['context'], {'screen': 'handler_chart'});
    });
  });

  group('install', () {
    test('is idempotent and preserves the prior handler', () {
      var priorCalled = 0;
      FlutterError.onError = (_) => priorCalled++;

      ErrorReporter.install();
      ErrorReporter.install();

      FlutterError.onError!(FlutterErrorDetails(exception: 'installed'));

      // Chaining rather than replacing: losing Flutter's console logging would
      // make local debugging worse in exchange for making production better.
      expect(priorCalled, 1);
    });
  });
}
