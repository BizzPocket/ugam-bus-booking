import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/bus_position.dart';
import 'error_reporter.dart';
import 'location_fix_buffer.dart';
import 'sync_retry_policy.dart';

/// Where the handler's sharing currently stands. Drives the status card 1:1.
enum TrackingStatus {
  idle,
  awaitingPermission,
  denied,
  deniedForever,
  serviceDisabled,

  /// Streaming and uploading, including with the screen off.
  live,

  /// Permission is "while in use" only — real tracking, but it dies the moment
  /// the handler leaves the app. Told plainly rather than dressed up as live.
  foregroundOnly,

  windowClosed,
  forbidden,
}

/// Test seam for `handler_push_locations`. Production leaves it null.
typedef LocationPusher =
    Future<Map<String, dynamic>> Function(
      String requestId,
      String busId,
      List<Map<String, dynamic>> fixes,
    );

/// Owns the handler's outbound location pipeline: buffer → RPC.
///
/// THE ONE RULE THAT MATTERS. `handler_push_locations` reports refusals as
/// DATA (`{"error": "forbidden"}`), never as a throw. So:
///   * a call that RETURNS consumes its whole batch — `skipped` fixes are
///     either invalid or already stored, and resending them never helps;
///   * a call that THROWS preserves the buffer for retry.
/// Inverting this produces a queue that never drains.
class LocationTrackerService extends GetxService {
  /// Server-enforced in migration 047 (`where a.ord <= 500`).
  static const int _maxPerCall = 500;
  static const Duration _minBackoff = Duration(minutes: 2);
  static const Duration _maxBackoff = Duration(minutes: 16);

  final Rx<TrackingStatus> status = TrackingStatus.idle.obs;
  final Rxn<DateTime> lastUploadAt = Rxn<DateTime>();

  @visibleForTesting
  LocationPusher? pusher;

  String? _requestId;
  String? _busId;
  LocationFixBuffer? _buffer;
  bool _flushing = false;
  Duration _backoff = _minBackoff;

  Duration get currentBackoff => _backoff;

  /// True once the tracker has been attached to a bus and not stopped.
  bool get _attached => _requestId != null && _busId != null;

  /// The leg stamped on newly captured fixes: `'go'`, `'ret'`, or null.
  /// Mutable so the chart screen can retarget it when the handler switches leg.
  String? leg;

  // ── test helpers ──────────────────────────────────────────

  @visibleForTesting
  int get debugBufferLength => _buffer?.length ?? 0;

  @visibleForTesting
  Future<void> debugAddFix(LocationFix fix) async => record(fix);

  /// Attaches to a bus and rehydrates its buffer WITHOUT touching GPS.
  /// Production calls [start], which does this and then opens the stream.
  @visibleForTesting
  Future<void> debugAttach({
    required String requestId,
    required String busId,
    String? leg,
  }) async {
    await _attach(requestId: requestId, busId: busId, leg: leg);
  }

  // ── lifecycle ─────────────────────────────────────────────

  Future<void> _attach({
    required String requestId,
    required String busId,
    String? leg,
  }) async {
    _requestId = requestId;
    _busId = busId;
    this.leg = leg;
    _buffer = LocationFixBuffer(busId: busId);
    await _buffer!.rehydrate();
    _backoff = _minBackoff;
    status.value = TrackingStatus.live;
  }

  /// Attaches to [busId] and restores anything the last session left behind.
  /// The caller opens the GPS stream once this resolves.
  Future<void> start({
    required String requestId,
    required String busId,
    String? leg,
  }) async {
    await _attach(requestId: requestId, busId: busId, leg: leg);
    // Anything buffered through a dead zone or a kill goes out immediately.
    if (_buffer!.length > 0) await flushNow();
  }

  Future<void> stop() async {
    _requestId = null;
    _busId = null;
    leg = null;
    _buffer = null;
    _backoff = _minBackoff;
    status.value = TrackingStatus.idle;
  }

  /// Queues one captured sample. Ignored when not attached to a bus.
  Future<void> record(LocationFix fix) async {
    if (!_attached) return;
    await _buffer!.add(fix);
  }

  // ── upload ────────────────────────────────────────────────

  Future<void> flushNow() async {
    if (!_attached || _buffer == null) return;
    if (_flushing) return;
    _flushing = true;
    try {
      while (_buffer != null && _buffer!.length > 0) {
        final batch = _buffer!.take(_maxPerCall);
        final Map<String, dynamic> result;
        try {
          result = await _send(batch);
        } catch (e, st) {
          // THROWN: nothing confirmed. Keep the buffer.
          if (isRetryable(e, retryOnTimeout: true)) {
            _escalateBackoff();
          } else {
            ErrorReporter.report(
              kind: 'location_push',
              error: e,
              stack: st,
              context: {'bus_id': _busId, 'batch': batch.length},
            );
          }
          return;
        }

        // RETURNED: the batch is spent, whatever it says.
        final error = result['error'] as String?;

        if (error == 'window_closed') {
          await _stopAndClear(TrackingStatus.windowClosed);
          return;
        }
        if (error == 'forbidden') {
          await _stopAndClear(TrackingStatus.forbidden);
          return;
        }
        if (error == 'bad_payload') {
          // A client-side bug. Retrying a poison batch would block every
          // later fix behind it forever, so drop it and keep going.
          await _buffer!.drop(batch.length);
          ErrorReporter.report(
            kind: 'location_bad_payload',
            error: StateError('handler_push_locations rejected a batch'),
            context: {'bus_id': _busId, 'batch': batch.length},
          );
          continue;
        }

        await _buffer!.drop(batch.length);
        lastUploadAt.value = DateTime.now();
        _backoff = _minBackoff;
      }
    } finally {
      _flushing = false;
    }
  }

  Future<Map<String, dynamic>> _send(List<LocationFix> batch) async {
    final payload = batch.map((f) => f.toJson()).toList(growable: false);
    final push = pusher;
    if (push != null) return push(_requestId!, _busId!, payload);

    final raw = await Supabase.instance.client.rpc(
      'handler_push_locations',
      params: {
        'p_request_id': _requestId,
        'p_bus_id': _busId,
        'p_fixes': payload,
      },
    );
    return raw is Map<String, dynamic>
        ? raw
        : Map<String, dynamic>.from(raw as Map);
  }

  Future<void> _stopAndClear(TrackingStatus next) async {
    await _buffer?.clear();
    _requestId = null;
    _busId = null;
    _buffer = null;
    _backoff = _minBackoff;
    status.value = next;
  }

  void _escalateBackoff() {
    final doubled = _backoff * 2;
    _backoff = doubled > _maxBackoff ? _maxBackoff : doubled;
  }
}
