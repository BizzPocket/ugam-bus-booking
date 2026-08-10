import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/bus_position.dart';

/// The admin's read side of live tracking.
///
/// WHY ITS OWN REALTIME CHANNEL. [RealtimeService] is a single broadcast stream
/// feeding every admin controller, each of which debounces and refetches its
/// slice of the world on any event. Position rows update once every two minutes
/// per bus, and routing them through that fan-out would wake unrelated screens
/// into refetches for data they never read. This channel opens with the map and
/// closes with it.
///
/// Authorisation is not this class's business: 047's owner-only RLS already
/// confines every read to the signed-in owner's tours.
class BusPositionsRepository {
  SupabaseClient get _client => Supabase.instance.client;

  RealtimeChannel? _channel;
  StreamController<BusPosition>? _controller;

  Future<List<BusPosition>> fetchForTour(String tourId) async {
    final rows = await _client
        .from('bus_live_positions')
        .select()
        .eq('tour_id', tourId);
    return (rows as List)
        .map((r) => BusPosition.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
  }

  /// Live updates for one tour. Filtered SERVER-side, so other tours' buses
  /// never reach this device.
  Stream<BusPosition> watchTour(String tourId) {
    dispose();
    final controller = StreamController<BusPosition>.broadcast();
    _controller = controller;

    final channel = _client.channel('bus-positions-$tourId');
    channel.onPostgresChanges(
      event: PostgresChangeEvent.all,
      schema: 'public',
      table: 'bus_live_positions',
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'tour_id',
        value: tourId,
      ),
      callback: (payload) {
        if (controller.isClosed) return;
        final row = payload.newRecord;
        // DELETE carries no new row; nothing to move on the map.
        if (row.isEmpty) return;
        controller.add(BusPosition.fromMap(Map<String, dynamic>.from(row)));
      },
    );
    channel.subscribe();
    _channel = channel;

    return controller.stream;
  }

  void dispose() {
    final channel = _channel;
    if (channel != null) _client.removeChannel(channel);
    _channel = null;
    _controller?.close();
    _controller = null;
  }

  /// One dot per bus, and never a backwards step.
  ///
  /// The server already guards this (047 re-reads the newest fix before
  /// updating the live row), but an offline flush and a real-time fix can still
  /// arrive at the CLIENT out of order. Equal timestamps are accepted because
  /// `tracking_state` can change without the position moving.
  static List<BusPosition> mergePositions(
    List<BusPosition> current,
    BusPosition incoming,
  ) {
    final next = <BusPosition>[];
    var replaced = false;
    for (final p in current) {
      if (p.busId != incoming.busId) {
        next.add(p);
        continue;
      }
      replaced = true;
      next.add(incoming.recordedAt.isBefore(p.recordedAt) ? p : incoming);
    }
    if (!replaced) next.add(incoming);
    return next;
  }
}
