import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:occubusbooking/services/supabase_service.dart';
import 'package:occubusbooking/services/sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Sync extends SyncService {
  @override
  // ignore: must_call_super
  void onInit() {}
}

http.Response _json(Object body, http.BaseRequest req) => http.Response(
      jsonEncode(body),
      200,
      request: req,
      headers: {'content-type': 'application/json'},
    );

/// The generic write path, driven through a real SupabaseClient over a fake
/// transport — what actually crosses the 2G link.
void main() {
  tearDown(() => SupabaseService.debugClient = null);

  SupabaseClient clientWith(MockClient transport) => SupabaseClient(
        'https://example.test',
        'anon-key',
        httpClient: transport,
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );

  test('an update asks for the id back, never the whole row', () async {
    final urls = <Uri>[];
    SupabaseService.debugClient = clientWith(MockClient((req) async {
      urls.add(req.url);
      return _json([
        {'id': 'b1'},
      ], req);
    }));

    await _Sync().smartUpdate(
      table: 'buses',
      entityId: 'b1',
      data: {'name': 'Bus 1'},
    );

    expect(urls, hasLength(1));
    // A bare select() echoed the bus's layout jsonb on every save.
    expect(urls.single.queryParameters['select'], 'id');
  });

  test('a connection dropped mid-response is retried, and the write lands',
      () async {
    var calls = 0;
    SupabaseService.debugClient = clientWith(MockClient((req) async {
      calls++;
      if (calls == 1) {
        // What IOClient raises for "Connection closed before full header".
        throw http.ClientException(
          'Connection closed before full header was received',
          req.url,
        );
      }
      return _json([
        {'id': 'p1'},
      ], req);
    }));

    await _Sync().updatePatch(
      table: 'passengers',
      entityId: 'p1',
      fields: {'note': 'window seat'},
    );
    expect(calls, 2);
  });
}
