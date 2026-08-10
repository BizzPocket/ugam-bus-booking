import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:occubusbooking/services/timeout_http_client.dart';

/// A hang is the absence of an exception, which is why nothing caught this for
/// so long: no crash, no error state, just a spinner. These tests prove the
/// wait now ENDS.
void main() {
  final original = TimeoutHttpClient.defaultTimeout;
  tearDown(() => TimeoutHttpClient.defaultTimeout = original);

  test('a hanging request raises TimeoutException instead of never returning',
      () async {
    TimeoutHttpClient.defaultTimeout = const Duration(milliseconds: 50);

    // A server that accepts the connection and then says nothing — exactly
    // what a stalled 2G socket looks like to the client.
    final client = TimeoutHttpClient(
      MockClient((_) => Completer<http.Response>().future),
    );

    await expectLater(
      client.get(Uri.parse('https://example.test/rest/v1/tours')),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('the timeout message names the request, not just the duration',
      () async {
    TimeoutHttpClient.defaultTimeout = const Duration(milliseconds: 20);
    final client = TimeoutHttpClient(
      MockClient((_) => Completer<http.Response>().future),
    );

    try {
      await client.get(Uri.parse('https://example.test/rest/v1/collections'));
      fail('should have timed out');
    } on TimeoutException catch (e) {
      // A bare TimeoutException from inside the Supabase client is close to
      // unattributable in a crash report.
      expect(e.message, contains('collections'));
      expect(e.message, contains('GET'));
    }
  });

  test('a fast request is untouched', () async {
    TimeoutHttpClient.defaultTimeout = const Duration(seconds: 5);
    final client = TimeoutHttpClient(
      MockClient((_) async => http.Response(jsonEncode({'ok': true}), 200)),
    );

    final res = await client.get(Uri.parse('https://example.test/x'));

    expect(res.statusCode, 200);
    expect(jsonDecode(res.body), {'ok': true});
  });

  group('remote tuning', () {
    test('a sane value is applied', () {
      TimeoutHttpClient.applyRemoteTimeout(45);
      expect(TimeoutHttpClient.defaultTimeout, const Duration(seconds: 45));
    });

    test('null leaves it alone', () {
      TimeoutHttpClient.defaultTimeout = const Duration(seconds: 30);
      TimeoutHttpClient.applyRemoteTimeout(null);
      expect(TimeoutHttpClient.defaultTimeout, const Duration(seconds: 30));
    });

    test('zero or negative is refused — that is the bug coming back', () {
      TimeoutHttpClient.defaultTimeout = const Duration(seconds: 30);
      TimeoutHttpClient.applyRemoteTimeout(0);
      TimeoutHttpClient.applyRemoteTimeout(-1);
      expect(TimeoutHttpClient.defaultTimeout, const Duration(seconds: 30));
    });

    test('an absurd value is refused', () {
      // A typo'd flag must not be able to restore an effectively unbounded wait.
      TimeoutHttpClient.defaultTimeout = const Duration(seconds: 30);
      TimeoutHttpClient.applyRemoteTimeout(99999);
      expect(TimeoutHttpClient.defaultTimeout, const Duration(seconds: 30));
    });

    test('a fractional value rounds rather than being dropped', () {
      TimeoutHttpClient.applyRemoteTimeout(20.6);
      expect(TimeoutHttpClient.defaultTimeout, const Duration(seconds: 21));
    });
  });

  test('the shipped default is a backstop, not a latency budget', () {
    // Too tight would kill a slow-but-working request on 2G — a large
    // seat-chart PDF upload legitimately takes tens of seconds — which is
    // worse than the bug being fixed.
    expect(original.inSeconds, greaterThanOrEqualTo(20));
    expect(original.inSeconds, lessThanOrEqualTo(60));
  });
}
