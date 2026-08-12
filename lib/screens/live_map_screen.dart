import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../design/components/ugam_tappable.dart';
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

/// Vertical room the bus strip occupies above [UgamSpacing.dockClearance].
/// Only ever used to inset the MAP (its own controls and its camera fit), so
/// an approximation is honest here — a large text scale grows the strip a few
/// points past it and costs nothing but a slightly tighter fit.
const double _kStripReserve = 60;

class _LiveMapScreenState extends State<LiveMapScreen> {
  final _repo = BusPositionsRepository();

  List<BusPosition> _positions = const [];
  StreamSubscription<BusPosition>? _sub;
  GoogleMapController? _map;
  bool _loading = true;

  /// The initial read threw. Distinct from "nobody has reported yet": an
  /// offline agent used to be told *"no bus has shared its location yet"*,
  /// which is a statement about the fleet, not about the phone. Cleared the
  /// moment any position arrives (a live fix proves the connection).
  bool _failed = false;

  /// The camera is fitted ONCE. Re-fitting on every update would wrench the
  /// map out from under an admin who is panning or zoomed into one bus. The
  /// app-bar action re-arms it on demand — see [_refit].
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
        _failed = false;
      });
      _fitCamera();
    } catch (_) {
      // The realtime subscription below may still deliver a bus a moment
      // later, so this is not fatal — but it must not be dressed up as an
      // empty fleet either. `_failed` picks the retryable error state, and the
      // first live fix clears it.
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }

    _subscribe();
  }

  void _subscribe() {
    // Retry re-enters here; without the cancel the old subscription would leak
    // a second listener onto every rebuilt channel.
    _sub?.cancel();
    _sub = _repo.watchTour(widget.tourId).listen((p) {
      if (!mounted) return;
      setState(() {
        _positions = BusPositionsRepository.mergePositions(_positions, p);
        _failed = false;
      });
      _fitCamera();
    });
  }

  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    await _load();
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

  BusPosition? _positionFor(String busId) {
    for (final p in _positions) {
      if (p.busId == busId) return p;
    }
    return null;
  }

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

  /// Re-arm the once-only fit. Without this a tour whose second and third bus
  /// start reporting AFTER the camera settled leaves them off-screen with no
  /// way to find them.
  void _refit() {
    _fitted = false;
    _fitCamera();
  }

  /// Centre on one bus and pop its callout — the bus strip's tap action.
  void _focus(BusPosition p) {
    final map = _map;
    if (map == null) return;
    // The agent has now chosen a camera; an auto-fit must not steal it back.
    _fitted = true;
    map.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(p.lat, p.lng), 14),
    );
    map.showMarkerInfoWindow(MarkerId(p.busId));
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

  UgamStatusTone _toneFor(BusPosition? p) {
    if (p == null) return UgamStatusTone.neutral;
    return p.isStale ? UgamStatusTone.warm : UgamStatusTone.good;
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
            '${tr('tracking.map_last_seen', namedArgs: {'n': agoLabelLocal(p.recordedAt)})}',
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
              UgamStatusDot(label: _detailFor(p), tone: _toneFor(p)),
              const SizedBox(height: UgamSpacing.sm),
              Text(
                tr(
                  'tracking.map_last_seen',
                  namedArgs: {'n': agoLabelLocal(p.recordedAt)},
                ),
                style: UgamText.caption.copyWith(color: c.ink2),
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

  /// "2 of 3 reporting" — the one fact the map itself cannot show, because a
  /// bus that never started tracking has no pin to be missing.
  String? _subtitle() {
    if (_loading || _failed) return null;
    final total = widget.buses.isEmpty
        ? _positions.length
        : widget.buses.length;
    if (total == 0) return null;
    final live = _positions.where((p) => !p.isStale).length;
    return tr(
      'tracking.map_reporting',
      namedArgs: {'n': '$live', 'm': '$total'},
    );
  }

  @override
  Widget build(BuildContext context) {
    return UgamScaffold(
      // Bottom inset is deliberately NOT reserved here: the map runs full-bleed
      // under the shell's floating dock, and the one thing that must stay clear
      // of it (the bus strip) reserves `dockClearance` itself.
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(
              title: tr('tracking.map_title'),
              subtitle: _subtitle(),
              actions: [
                if (_positions.isNotEmpty)
                  UgamAppBarAction(
                    icon: Icons.center_focus_strong_rounded,
                    tooltip: tr('tracking.map_fit_all'),
                    onTap: _refit,
                  ),
              ],
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    // Shaped like the screen it is becoming — a map plane with the bus strip
    // beneath it — rather than a centred spinner, which reads as a prototype
    // and tells the agent nothing about what is about to arrive.
    if (_loading) return _loadingState();

    // Nothing on screen to keep, and the read failed: offer the retry rather
    // than a confident lie about the fleet.
    if (_failed && _positions.isEmpty) {
      return UgamEmpty.error(onRetry: _retry);
    }

    if (_positions.isEmpty) {
      return UgamEmpty(
        icon: Icons.location_off_outlined,
        title: tr('tracking.map_empty_title'),
        body: tr('tracking.map_empty_body'),
        cta: UgamCTA(
          label: tr('tracking.map_check_again'),
          leadingIcon: Icons.refresh_rounded,
          onPressed: _retry,
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(_positions.first.lat, _positions.first.lng),
              zoom: 11,
            ),
            markers: _markers,
            myLocationButtonEnabled: false,
            // Keeps Google's own chrome (logo, zoom controls) — and the camera
            // fit — clear of the floating dock this screen sits under AND of
            // the bus strip above it. Without it the fitted bounds put half the
            // fleet behind the dock on a two-bus tour.
            padding: const EdgeInsets.only(
              bottom: UgamSpacing.dockClearance + _kStripReserve,
            ),
            onMapCreated: (c) {
              _map = c;
              _fitCamera();
            },
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: UgamSpacing.dockClearance,
          child: _busStrip(),
        ),
      ],
    );
  }

  Widget _loadingState() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.dockClearance,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Expanded(
            child: UgamSkeleton(
              height: double.infinity,
              radius: UgamRadius.card,
            ),
          ),
          SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              UgamSkeleton(width: 150, height: 54, radius: UgamRadius.row),
              SizedBox(width: UgamSpacing.sm),
              UgamSkeleton(width: 150, height: 54, radius: UgamRadius.row),
            ],
          ),
        ],
      ),
    );
  }

  /// One chip per bus ON THE TOUR — not per pin. A bus whose handler never
  /// opened the trip, or whose phone lost location permission, has no marker at
  /// all; without this strip its absence is indistinguishable from it simply
  /// being off the current viewport.
  Widget _busStrip() {
    // Defensive: a position for a bus that is no longer on the tour still gets
    // a chip rather than vanishing from the roster.
    final ids = <String>[
      ...widget.buses.map((b) => b.id),
      for (final p in _positions)
        if (_busFor(p.busId) == null) p.busId,
    ];
    if (ids.isEmpty) return const SizedBox.shrink();

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
      child: Row(
        children: [
          for (int i = 0; i < ids.length; i++) ...[
            if (i > 0) const SizedBox(width: UgamSpacing.sm),
            _busChip(ids[i]),
          ],
        ],
      ),
    );
  }

  Widget _busChip(String busId) {
    final c = UgamColors.of(context);
    final p = _positionFor(busId);
    final name = _busName(busId);
    final status = p == null ? tr('tracking.map_not_started') : _detailFor(p);

    return ConstrainedBox(
      // Bounded on purpose: this row scrolls horizontally, so without a cap the
      // chip's own children would be laid out against infinite width — and
      // [UgamStatusDot] puts a Flexible inside a Row, which asserts there.
      constraints: const BoxConstraints(maxWidth: 208),
      child: UgamTappable(
        onTap: p == null ? null : () => _focus(p),
        semanticLabel: '$name · $status',
        pressedScale: 0.95,
        child: UgamCard.plain(
          elev: true,
          radius: UgamRadius.row,
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.md,
            vertical: UgamSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: UgamText.bodyStrong.copyWith(color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              UgamStatusDot(label: status, tone: _toneFor(p)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact relative time. Plain Dart rather than `plural()`, which throws in
/// widget tests unless a locale is loaded in setUpAll.
///
/// This is the untranslated core, kept public because it is the unit under
/// test. Screens render [agoLabelLocal] — an English `14m` inside a Gujarati
/// sentence is not a label a Gujarati-first operator can read.
@visibleForTesting
String agoLabel(DateTime t) {
  final m = minutesAgo(t);
  if (m < 1) return 'now';
  if (m < 60) return '${m}m';
  return '${(m / 60).floor()}h';
}

int minutesAgo(DateTime t) => DateTime.now().toUtc().difference(t).inMinutes;

/// Localised sibling of [agoLabel], used everywhere the label is shown.
String agoLabelLocal(DateTime t) {
  final m = minutesAgo(t);
  if (m < 1) return tr('tracking.ago_now');
  if (m < 60) return tr('tracking.ago_minutes', namedArgs: {'n': '$m'});
  return tr(
    'tracking.ago_hours',
    namedArgs: {'n': '${(m / 60).floor()}'},
  );
}
