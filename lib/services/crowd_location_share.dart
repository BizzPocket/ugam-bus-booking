import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/location_rationale_sheet.dart';
import 'bus_location_consensus.dart';
import 'error_reporter.dart';
import 'location_tracker_service.dart';

/// True only when this run's launch gate ASKED and was explicitly told no.
///
/// `serviceDisabled` (GPS switch off — temporary) and `idle` (the gate threw
/// or had no screen to ask on) are NOT a "no": nobody declined anything, so a
/// later screen may still look and ask. Callers use this to suppress a SECOND
/// prompt only — never to skip reading the OS, which is always the truth.
bool launchGateDeclined({
  required bool gateDone,
  required TrackingStatus? launch,
}) =>
    gateDone &&
    (launch == TrackingStatus.denied || launch == TrackingStatus.deniedForever);

/// Asks this phone to share a precise GPS fix when the number belongs to
/// someone seated on a locked trip, then lets the server fold it into that
/// bus's single dot.
///
/// The handler chart has its own bootstrap and keeps using it. This path is
/// for everyone else — a passenger who looked up their seat, and an admin
/// whose login number is also a seat on the bus. If that admin denies
/// permission, the other phones on the same bus still produce the dot.
class CrowdLocationShare {
  CrowdLocationShare._();

  static const _rationaleSeenKey = 'tracking.rationale_seen';

  static bool _busy = false;
  static bool _settled = false;
  static String? _queuedPhone;
  static BuildContext? _context;

  /// Set once the launch gate has finished. Later screens must not ask again
  /// in the same run — the splash already did, before anything else.
  static bool permissionGateDone = false;

  /// The answer from this launch's gate. Null until [ensurePermission] returns.
  static TrackingStatus? launchStatus;

  /// Test seam. Production resolves through `location_share_target`.
  @visibleForTesting
  static Future<List<BusShareCandidate>> Function(String phone)? debugResolve;

  /// Runs on every cold start, before the splash routes anywhere.
  ///
  /// If this phone already has location permission, it returns immediately.
  /// Otherwise it discloses and asks, and does not return until the person
  /// has answered. The rest of the app waits on that answer.
  static BuildContext? _sheetContext(BuildContext context) {
    final root = Get.key.currentContext;
    if (root != null && root.mounted) return root;
    if (context.mounted) return context;
    return null;
  }

  static Future<TrackingStatus> ensurePermission(BuildContext context) async {
    try {
      final state = await _readStatus();
      if (state == TrackingStatus.live ||
          state == TrackingStatus.foregroundOnly) {
        _markLaunch(state);
        return state;
      }
      final ctx = _sheetContext(context);
      if (ctx == null) {
        _markLaunch(state);
        return state;
      }
      final asked = await _consent(ctx, alwaysDisclose: true);
      _markLaunch(asked);
      return asked;
    } catch (e, st) {
      ErrorReporter.report(kind: 'location_gate', error: e, stack: st);
      _markLaunch(TrackingStatus.idle);
      return TrackingStatus.idle;
    }
  }

  /// The explicit "Allow location" tap. Clears the launch gate so that one
  /// screen may ask again; the next cold start asks on its own.
  static void reopenPrompt() {
    permissionGateDone = false;
    launchStatus = null;
    _settled = false;
  }

  static void _markLaunch(TrackingStatus state) {
    launchStatus = state;
    permissionGateDone = true;
  }

  static Future<TrackingStatus> _readStatus() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    return resolveTrackingStatus(
      serviceEnabled: serviceEnabled,
      permission: permission,
    );
  }

  /// [phone] may contain spaces or a +91 prefix; the server matches the last
  /// 10 digits. A number that is not seated on a locked trip is a no-op —
  /// we do not ask a person who is not on a bus for their location.
  ///
  /// Does not show a permission dialog when the launch gate already ran.
  /// Sharing starts here only after permission was granted up front.
  static Future<void> offer(BuildContext context, String? phone) async {
    final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length < 10) return;
    _queuedPhone = digits.substring(digits.length - 10);
    _context = context;
    if (_busy || _settled) return;
    _busy = true;
    try {
      while (_queuedPhone != null && !_settled) {
        final next = _queuedPhone!;
        _queuedPhone = null;
        await _offerOnce(next);
      }
    } finally {
      _busy = false;
    }
  }

  static Future<void> _offerOnce(String phone) async {
    if (!Get.isRegistered<LocationTrackerService>()) return;
    final tracker = Get.find<LocationTrackerService>();
    try {
      final candidates = await _resolve(phone);
      final target = pickBusShareTarget(candidates, now: DateTime.now());
      if (target == null) return;
      // Already reporting for that bus — or reporting as the HANDLER, whose
      // own bus outranks whichever bus this number happens to hold seats on.
      if ((tracker.isSharing && tracker.attachedBusId == target.busId) ||
          tracker.isSharingAsHandler) {
        _settled = true;
        return;
      }

      final ctx = _context;
      if (ctx == null || !ctx.mounted) return;

      // The OS is the truth — not the launch gate's cached answer. A phone
      // whose GPS switch was off at launch, or that granted permission in
      // system settings since, must start sharing now without a relaunch.
      var state = await _readStatus();
      if (state != TrackingStatus.live &&
          state != TrackingStatus.foregroundOnly) {
        if (permissionGateDone) {
          // The launch gate already asked this run: never prompt twice. A
          // denial stands until the next open, or the tracking card's Allow.
          if (state != TrackingStatus.serviceDisabled) _settled = true;
          if (!tracker.isSharing) tracker.status.value = state;
          return;
        }
        if (!ctx.mounted) return;
        state = await _consent(ctx);
      }
      // Location switched off is temporary — the next open should look again.
      // A denial is a decision; don't ask again until the app is relaunched.
      if (state == TrackingStatus.serviceDisabled) {
        tracker.status.value = state;
        return;
      }
      _settled = true;
      if (state != TrackingStatus.live &&
          state != TrackingStatus.foregroundOnly) {
        tracker.status.value = state;
        return;
      }

      await tracker.startPassenger(phone: phone, busId: target.busId);
      tracker.status.value = state;
      tracker.startStream();
    } catch (e, st) {
      // Offline, or the migration is not applied yet. Leave [_settled] clear
      // so the next screen the rider opens can try again.
      ErrorReporter.report(kind: 'crowd_location', error: e, stack: st);
    }
  }

  static Future<List<BusShareCandidate>> _resolve(String phone) async {
    final injected = debugResolve;
    if (injected != null) return injected(phone);

    final raw = await Supabase.instance.client.rpc(
      'location_share_target',
      params: {'p_phone': phone},
    );
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! List) return const [];
    final out = <BusShareCandidate>[];
    for (final row in decoded) {
      if (row is! Map) continue;
      final map = Map<String, dynamic>.from(row);
      final busId = (map['bus_id'] ?? '').toString();
      final departure = DateTime.tryParse((map['departure'] ?? '').toString());
      final seats = (map['seat_count'] as num?)?.toInt() ?? 0;
      if (busId.isEmpty || departure == null || seats <= 0) continue;
      out.add(
        BusShareCandidate(
          busId: busId,
          departure: departure.toUtc(),
          seatCount: seats,
        ),
      );
    }
    return out;
  }

  /// Disclosure, then the OS prompt.
  ///
  /// [alwaysDisclose] is the launch gate: every open that does not already
  /// have permission shows the explanation again, then waits for the answer.
  /// The handler chart still discloses once, because the splash has usually
  /// asked already.
  static Future<TrackingStatus> _consent(
    BuildContext context, {
    bool alwaysDisclose = false,
  }) async {
    var serviceEnabled = await Geolocator.isLocationServiceEnabled();
    var permission = await Geolocator.checkPermission();
    var state = resolveTrackingStatus(
      serviceEnabled: serviceEnabled,
      permission: permission,
    );
    if (state == TrackingStatus.live ||
        state == TrackingStatus.foregroundOnly) {
      return state;
    }

    final needsSheet = alwaysDisclose || state == TrackingStatus.denied;
    if (needsSheet) {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getBool(_rationaleSeenKey) ?? false;
      if (alwaysDisclose || !seen) {
        if (!context.mounted) return state;
        final go = await showLocationRationale(context);
        await prefs.setBool(_rationaleSeenKey, true);
        if (!go) return state;
      }
    }

    if (state == TrackingStatus.serviceDisabled ||
        state == TrackingStatus.deniedForever) {
      return state;
    }

    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.whileInUse && Platform.isAndroid) {
      permission = await Geolocator.requestPermission();
    }
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    return resolveTrackingStatus(
      serviceEnabled: serviceEnabled,
      permission: permission,
    );
  }
}
