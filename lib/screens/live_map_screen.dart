import 'dart:async';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/bus_position.dart';
import '../services/bus_positions_repository.dart';
import '../utils/phone_dialer.dart';
import '../widgets/osm_map_layers.dart';

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

/// How often the screen re-reads `bus_live_positions` on its own. Realtime is
/// the fast path; this is the floor under it. A socket that died while the
/// phone slept, or a publication that never carried the table, used to leave
/// the map frozen on its first read with nothing on screen saying so.
const Duration _kPollEvery = Duration(seconds: 60);

/// How often "last seen" and the stale flag are re-evaluated. Without it the
/// map only redrew on an incoming row — so a bus whose phone died kept saying
/// "Moving · 54 km/h · now" indefinitely, which is exactly the bus the office
/// needs to notice.
const Duration _kClockEvery = Duration(seconds: 30);

class _LiveMapScreenState extends State<LiveMapScreen>
    with WidgetsBindingObserver {
  final _repo = BusPositionsRepository();
  final _map = MapController();

  List<BusPosition> _positions = const [];
  StreamSubscription<BusPosition>? _sub;
  Timer? _poll;
  Timer? _clock;
  bool _mapReady = false;
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
    WidgetsBinding.instance.addObserver(this);
    _clock = Timer.periodic(_kClockEvery, (_) {
      if (mounted) setState(() {});
    });
    final seeded = widget.initialPositions;
    if (seeded != null) {
      _positions = seeded;
      _loading = false;
      return;
    }
    _load();
  }

  /// Back from the background: the realtime socket may have been torn down
  /// while the phone slept. Re-read now and reopen the channel.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (widget.initialPositions != null || _loading) return;
    unawaited(_refresh());
    _subscribe();
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
    _poll?.cancel();
    _poll = Timer.periodic(_kPollEvery, (_) => unawaited(_refresh()));
  }

  /// Quiet re-read. Merged row by row so an out-of-order poll can never rewind
  /// a dot realtime already moved; a failure keeps what is on screen.
  Future<void> _refresh() async {
    try {
      final rows = await _repo.fetchForTour(widget.tourId);
      if (!mounted) return;
      setState(() {
        var next = _positions;
        for (final p in rows) {
          next = BusPositionsRepository.mergePositions(next, p);
        }
        _positions = next;
        _failed = false;
      });
      _fitCamera();
    } catch (_) {
      // Offline. The clock tick will age the dots into "not reporting".
    }
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
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _poll?.cancel();
    _sub?.cancel();
    _repo.dispose();
    _map.dispose();
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

  /// Room the fitted camera leaves around the fleet: clear of the bus strip
  /// and the floating dock below, and of the attribution above.
  static const EdgeInsets _fitPadding = EdgeInsets.fromLTRB(
    56,
    56,
    56,
    UgamSpacing.dockClearance + _kStripReserve + 40,
  );

  void _fitCamera() {
    if (_fitted || !_mapReady || _positions.isEmpty) return;
    _fitted = true;
    final points = [for (final p in _positions) LatLng(p.lat, p.lng)];
    if (points.length == 1) {
      _map.move(points.first, 13);
      return;
    }
    _map.fitCamera(
      CameraFit.coordinates(
        coordinates: points,
        padding: _fitPadding,
        // Two buses parked side by side must not zoom to street-furniture level.
        maxZoom: 15,
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

  /// Centre on one bus — the bus strip's tap action.
  void _focus(BusPosition p) {
    if (!_mapReady) return;
    // The agent has now chosen a camera; an auto-fit must not steal it back.
    _fitted = true;
    _map.move(LatLng(p.lat, p.lng), 14);
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

  List<Marker> get _markers => [
    for (final p in _positions)
      Marker(
        point: LatLng(p.lat, p.lng),
        width: _BusPin.width,
        height: _BusPin.height,
        child: _BusPin(
          name: _busName(p.busId),
          position: p,
          semanticLabel: '${_busName(p.busId)} · ${_detailFor(p)}',
          onTap: () => _openBusSheet(p),
        ),
      ),
  ];

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
          child: FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: LatLng(
                _positions.first.lat,
                _positions.first.lng,
              ),
              initialZoom: 11,
              // A rotated map is a lost map for this audience; north stays up.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onMapReady: () {
                _mapReady = true;
                _fitCamera();
              },
            ),
            children: [
              osmTileLayer(context),
              MarkerLayer(markers: _markers),
              const OsmAttribution(),
            ],
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

/// One bus on the map: its name above a round badge.
///
/// Moving with a known heading → an arrow pointing the way it is going.
/// Parked → a bus glyph. Not reporting → the same glyph in the warm tone, so a
/// dead phone never reads like a running bus. The badge sits exactly on the
/// bus's coordinate (the box is symmetric about it).
class _BusPin extends StatelessWidget {
  static const double width = 148;
  static const double height = 96;
  static const double _badge = 36;
  static const double _label = 26;

  final String name;
  final BusPosition position;
  final String semanticLabel;
  final VoidCallback onTap;

  const _BusPin({
    required this.name,
    required this.position,
    required this.semanticLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final p = position;
    final tone = p.isStale ? c.warm : c.good;
    final heading = p.headingDeg;
    final showArrow = !p.isStale && p.isMoving && heading != null;

    return UgamTappable(
      onTap: onTap,
      semanticLabel: semanticLabel,
      pressedScale: 0.92,
      child: Column(
        children: [
          SizedBox(
            height: _label,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: c.card,
                  borderRadius: BorderRadius.circular(UgamRadius.row),
                  border: Border.all(color: c.border),
                ),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UgamText.caption.copyWith(
                    color: c.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: (height - _badge) / 2 - _label),
          Container(
            width: _badge,
            height: _badge,
            decoration: BoxDecoration(
              color: tone,
              shape: BoxShape.circle,
              border: Border.all(color: c.card, width: 3),
              boxShadow: const [
                BoxShadow(blurRadius: 6, color: Color(0x40000000)),
              ],
            ),
            child: showArrow
                ? Transform.rotate(
                    angle: heading * math.pi / 180,
                    child: Icon(
                      Icons.navigation_rounded,
                      size: 20,
                      color: c.card,
                    ),
                  )
                : Icon(
                    Icons.directions_bus_rounded,
                    size: 18,
                    color: c.card,
                  ),
          ),
        ],
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
