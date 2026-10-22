import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:occubusbooking/services/customer_requests_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A rider on a bad link taps "Request cancellation". Whether the request
/// never arrived or the server refused it are two different answers — the
/// first must say "check your connection", never "blocked".
http.Response _json(Object body, http.BaseRequest req) => http.Response(
      jsonEncode(body),
      200,
      request: req,
      headers: {'content-type': 'application/json'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await CustomerRequestsStore().add(
      CustomerRequestEntry(
        id: 'r1',
        tourId: 't1',
        tourTitle: 'Ambaji',
        tourFromCity: 'Surat',
        tourToCity: 'Ambaji',
        tourDepartureDate: DateTime(2026, 9, 10),
        tourPricePerSeat: 1200,
        customerName: 'Asha',
        customerPhone: '9876543210',
        partySize: 1,
        doubleSofa: 0,
        singleSofa: 1,
        createdAt: DateTime(2026, 9, 1),
      ),
    );
  });

  tearDown(() => CustomerRequestsStore.debugClient = null);

  SupabaseClient clientWith(MockClient http) => SupabaseClient(
        'https://example.test',
        'anon-key',
        httpClient: http,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );

  test('a dropped connection THROWS — it is not a refusal', () async {
    CustomerRequestsStore.debugClient = clientWith(
      MockClient((_) async => throw const SocketException('connection reset')),
    );
    await expectLater(
      CustomerRequestsStore().requestCancellation('r1'),
      throwsA(anything),
    );
    final entry = await CustomerRequestsStore().get('r1');
    expect(entry!.cancelRequestedAt, isNull,
        reason: 'nothing was sent, nothing may be stamped');
  });

  test('a server refusal is still null (shown as blocked)', () async {
    CustomerRequestsStore.debugClient = clientWith(
      MockClient((req) async => _json(false, req)),
    );
    expect(await CustomerRequestsStore().requestCancellation('r1'), isNull);
  });

  test('an accepted request stamps the local entry', () async {
    CustomerRequestsStore.debugClient = clientWith(
      MockClient((req) async => _json(true, req)),
    );
    final updated = await CustomerRequestsStore().requestCancellation('r1');
    expect(updated?.cancelRequestedAt, isNotNull);
  });
}
