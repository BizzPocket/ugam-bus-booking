import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Tables that admin-side controllers want to know about live.
enum LiveTable { tours, passengers, buses, bookingRequests }

extension on LiveTable {
  String get tableName => switch (this) {
        LiveTable.tours => 'tours',
        LiveTable.passengers => 'passengers',
        LiveTable.buses => 'buses',
        LiveTable.bookingRequests => 'booking_requests',
      };
}

class DataChangedEvent {
  final LiveTable table;
  final PostgresChangeEvent eventType;
  final Map<String, dynamic>? newRow;
  final Map<String, dynamic>? oldRow;

  const DataChangedEvent({
    required this.table,
    required this.eventType,
    this.newRow,
    this.oldRow,
  });
}

/// Supabase Realtime fan-out. One channel per logical scope (admin vs anon
/// customer). Controllers subscribe to [events] and react however they want
/// (typically by debouncing and refetching their slice of the world).
///
/// Why a single broadcast stream instead of per-table streams: most screens
/// care about more than one table at a time (e.g. the Requests screen needs
/// `passengers` AND `booking_requests`), and a single stream keeps the
/// debounce logic in one place per consumer.
class RealtimeService extends GetxService {
  final _controller = StreamController<DataChangedEvent>.broadcast();
  Stream<DataChangedEvent> get events => _controller.stream;

  final _reconnects = StreamController<void>.broadcast();

  /// Fires when the live channel RE-joins after a drop. Events committed while
  /// it was down were never delivered, so consumers should refetch their slice
  /// (debounced — a flapping link rejoins repeatedly).
  Stream<void> get reconnects => _reconnects.stream;

  @visibleForTesting
  void notifyReconnected() {
    if (!_reconnects.isClosed) _reconnects.add(null);
  }

  SupabaseClient get _client => Supabase.instance.client;

  RealtimeChannel? _adminChannel;
  String? _subscribedFor;

  StreamSubscription? _authSub;

  @override
  void onInit() {
    super.onInit();
    // Resubscribe whenever the auth state flips. Covers login, logout,
    // token refresh, and restored sessions from cold start.
    _authSub = _client.auth.onAuthStateChange.listen((state) {
      final uid = state.session?.user.id;
      if (uid == null) {
        _teardownAdminChannel();
      } else {
        _ensureAdminChannel(uid);
      }
    });
    // Cover the case where a session already exists at boot.
    final currentUid = _client.auth.currentUser?.id;
    if (currentUid != null) _ensureAdminChannel(currentUid);
  }

  @override
  void onClose() {
    _authSub?.cancel();
    _teardownAdminChannel();
    _controller.close();
    _reconnects.close();
    super.onClose();
  }

  void _teardownAdminChannel() {
    if (_adminChannel != null) {
      _client.removeChannel(_adminChannel!);
      _adminChannel = null;
    }
    _subscribedFor = null;
  }

  Future<void> _ensureAdminChannel(String uid) async {
    if (_subscribedFor == uid && _adminChannel != null) return;
    _teardownAdminChannel();
    _subscribedFor = uid;

    final channel = _client.channel('admin-data-$uid');

    void wire(LiveTable table) {
      channel.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table.tableName,
        callback: (payload) {
          if (_controller.isClosed) return;
          _controller.add(DataChangedEvent(
            table: table,
            eventType: payload.eventType,
            newRow: payload.newRecord.isNotEmpty
                ? Map<String, dynamic>.from(payload.newRecord)
                : null,
            oldRow: payload.oldRecord.isNotEmpty
                ? Map<String, dynamic>.from(payload.oldRecord)
                : null,
          ));
        },
      );
    }

    wire(LiveTable.tours);
    wire(LiveTable.passengers);
    wire(LiveTable.buses);
    wire(LiveTable.bookingRequests);

    var wasSubscribed = false;
    channel.subscribe((status, error) {
      if (error != null) {
        dev.log(
          'channel status=$status err=$error',
          name: 'RealtimeService',
        );
      }
      // A SECOND `subscribed` on the same channel is a rejoin: the socket
      // dropped (dead zone, radio handover) and realtime_client re-joined it
      // with its own backoff. Every change committed in between was never
      // delivered, and nothing else would notice — the connectivity flag often
      // stays "mobile" throughout.
      if (status == RealtimeSubscribeStatus.subscribed) {
        if (wasSubscribed && identical(_adminChannel, channel)) {
          notifyReconnected();
        }
        wasSubscribed = true;
      }
    });

    _adminChannel = channel;
  }
}
