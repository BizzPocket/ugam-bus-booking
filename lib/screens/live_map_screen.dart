import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/bus_position.dart';
import '../services/bus_positions_repository.dart';
import '../utils/phone_dialer.dart';

/// Every bus on one tour, moving. Admin-only — 047's RLS has no anon policy,
/// so a customer could not read these rows even if this screen were reachable.
class LiveMapScreen extends StatefulWidget {
  final String tourId;
  final List<Bus> buses;

  /// TEST SEAM. Production leaves this null and the screen builds its own
  /// repository; a test can inject positions without Supabase or map tiles.
  @visibleForTesting
  final List<BusPosition>? initialPositions;

  const LiveMapScreen({
    super.key,
    required this.tourId,
    required this.buses,
    this.initialPositions,
  });

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  final _repo = BusPositionsRepository();

  List<BusPosition> _positions = const [];
  StreamSubscription<BusPosition>? _sub;
  GoogleMapController? _map;
  bool _loading = true;

  /// The camera is fitted ONCE. Re-fitting on every update would wrench the
  /// map out from under an admin who is panning or zoomed into one bus.
  bool _fitted = false;

  @override
  void initState() {
    super.initState();
    final seeded = widget.initialPositions;
    if (seeded != null) {
      _positions = seeded;
      _loading = false;
      return;
    }
    _load();
  }

  Future<void> _load() async {
    try {
      final initial = await _repo.fetchForTour(widget.tourId);
      if (!mounted) return;
      setState(() {
        _positions = initial;
        _loading = false;
      });
      _fitCamera();
    } catch (_) {
      // An empty map with its empty state beats an error card here: the
      // realtime subscription below may still deliver a bus a moment later.
      if (mounted) setState(() => _loading = false);
    }

    _sub = _repo.watchTour(widget.tourId).listen((p) {
      if (!mounted) return;
      setState(
        () => _positions = BusPositionsRepository.mergePositions(_positions, p),
      );
      _fitCamera();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _repo.dispose();
    super.dispose();
  }

  Bus? _busFor(String busId) {
    for (final b in widget.buses) {
      if (b.id == busId) return b;
    }
    return null;
  }

  String _busName(String busId) => _busFor(busId)?.name ?? busId;

  void _fitCamera() {
    if (_fitted || _map == null || _positions.isEmpty) return;
    _fitted = true;
    if (_positions.length == 1) {
      _map!.animateCamera(
        CameraUpdate.newLatLngZoom(
          LatLng(_positions.first.lat, _positions.first.lng),
          13,
        ),
      );
      return;
    }
    final lats = _positions.map((p) => p.lat);
    final lngs = _positions.map((p) => p.lng);
    _map!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(
            lats.reduce((a, b) => a < b ? a : b),
            lngs.reduce((a, b) => a < b ? a : b),
          ),
          northeast: LatLng(
            lats.reduce((a, b) => a > b ? a : b),
            lngs.reduce((a, b) => a > b ? a : b),
          ),
        ),
        64,
      ),
    );
  }

  /// What the bus is doing, in three words. Stale wins over speed: a bus that
  /// stopped reporting an hour ago is not "54 km/h", whatever its last fix said.
  String _detailFor(BusPosition p) {
    if (p.isStale) return tr('tracking.map_stale');
    if (p.isMoving) {
      return tr(
        'tracking.map_moving',
        namedArgs: {'n': (p.speedKmh ?? 0).round().toString()},
      );
    }
    return tr('tracking.map_parked');
  }

  Set<Marker> get _markers => _positions.map((p) {
    return Marker(
      markerId: MarkerId(p.busId),
      position: LatLng(p.lat, p.lng),
      rotation: p.headingDeg ?? 0,
      // A bus that stopped reporting must not read like a running one.
      icon: BitmapDescriptor.defaultMarkerWithHue(
        p.isStale ? BitmapDescriptor.hueOrange : BitmapDescriptor.hueGreen,
      ),
      infoWindow: InfoWindow(
        title: _busName(p.busId),
        snippet:
            '${_detailFor(p)} · '
            '${tr('tracking.map_last_seen', namedArgs: {'n': agoLabel(p.recordedAt)})}',
        onTap: () => _openBusSheet(p),
      ),
    );
  }).toSet();

  void _openBusSheet(BusPosition p) {
    final bus = _busFor(p.busId);
    UgamSheet.show<void>(
      context,
      title: _busName(p.busId),
      builder: (sheetContext) {
        final c = UgamColors.of(sheetContext);
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            UgamSpacing.gutter,
            0,
            UgamSpacing.gutter,
            UgamSpacing.gutter,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UgamStatusDot(
                label: _detailFor(p),
                tone: p.isStale ? UgamStatusTone.warm : UgamStatusTone.good,
              ),
              const SizedBox(height: UgamSpacing.sm),
              Text(
                tr(
                  'tracking.map_last_seen',
                  namedArgs: {'n': agoLabel(p.recordedAt)},
                ),
                style: UgamText.caption.copyWith(color: c.ink3),
              ),
              if (bus != null && bus.busNumber.trim().isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  bus.busNumber,
                  style: UgamText.caption.copyWith(color: c.ink3),
                ),
              ],
              if (bus != null && bus.driverPhone.trim().isNotEmpty) ...[
                const SizedBox(height: UgamSpacing.md),
                UgamCTA(
                  label: bus.driverName.trim().isEmpty
                      ? bus.driverPhone
                      : '${bus.driverName} · ${bus.driverPhone}',
                  leadingIcon: Icons.call_rounded,
                  onPressed: () => PhoneDialer.call(bus.driverPhone),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(title: tr('tracking.map_title')),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_positions.isEmpty) {
      return UgamEmpty(
        icon: Icons.location_off_outlined,
        title: tr('tracking.map_empty_title'),
        body: tr('tracking.map_empty_body'),
      );
    }
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: LatLng(_positions.first.lat, _positions.first.lng),
        zoom: 11,
      ),
      markers: _markers,
      myLocationButtonEnabled: false,
      onMapCreated: (c) {
        _map = c;
        _fitCamera();
      },
    );
  }
}

/// Compact relative time. Plain Dart rather than `plural()`, which throws in
/// widget tests unless a locale is loaded in setUpAll.
@visibleForTesting
String agoLabel(DateTime t) {
  final m = DateTime.now().toUtc().difference(t).inMinutes;
  if (m < 1) return 'now';
  if (m < 60) return '${m}m';
  return '${(m / 60).floor()}h';
}
