import 'package:geolocator/geolocator.dart';

/// One captured GPS sample — the unit of the handler's outbound buffer.
///
/// [toJson] emits exactly the keys `handler_push_locations` reads. Anything
/// else is ignored by the RPC, and a missing `recorded_at` makes the fix
/// undeliverable, so the key names here are load-bearing.
class LocationFix {
  final double lat;
  final double lng;
  final double? accuracyM;
  final double? speedKmh;
  final double? headingDeg;

  /// `'go'` or `'ret'` — matching `attendance.leg`. NOT the
  /// `'outbound'`/`'return'` pair used by `tour_seat_snapshots`; migration 047
  /// documents that divergence as deliberate. Null is accepted by the RPC.
  final String? leg;

  final DateTime recordedAt;
  final String trackingState;

  const LocationFix({
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.speedKmh,
    this.headingDeg,
    this.leg,
    required this.recordedAt,
    this.trackingState = 'live',
  });

  /// Builds a fix from a geolocator sample.
  ///
  /// `Position.speed` is METRES PER SECOND; the column is km/h. A negative
  /// speed, accuracy or heading means "unavailable" on both platforms, which
  /// becomes null rather than a bogus reading.
  ///
  /// [now] is the phone's clock at capture. A live fix is seconds old, so a
  /// GPS timestamp more than [maxClockSkew] away from it is a broken GPS clock
  /// (the 1024-week rollover still ships on older Android handsets), not a
  /// real age. The server silently refuses anything outside now-24h..now+5min
  /// — every fix from such a phone would be dropped with no error — so the
  /// capture time is used instead.
  factory LocationFix.fromPosition(
    Position p, {
    String? leg,
    String trackingState = 'live',
    DateTime? now,
  }) {
    var recordedAt = p.timestamp;
    if (now != null &&
        recordedAt.difference(now).abs() > maxClockSkew) {
      recordedAt = now.toUtc();
    }
    return LocationFix(
      lat: p.latitude,
      lng: p.longitude,
      accuracyM: p.accuracy >= 0 ? p.accuracy : null,
      speedKmh: p.speed >= 0 ? p.speed * 3.6 : null,
      headingDeg: p.heading >= 0 ? p.heading : null,
      leg: leg,
      recordedAt: recordedAt,
      trackingState: trackingState,
    );
  }

  static const Duration maxClockSkew = Duration(minutes: 10);

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lng': lng,
        'accuracy_m': accuracyM,
        'speed_kmh': speedKmh,
        'heading_deg': headingDeg,
        'leg': leg,
        'recorded_at': recordedAt.toUtc().toIso8601String(),
        'tracking_state': trackingState,
      };

  factory LocationFix.fromJson(Map<String, dynamic> json) => LocationFix(
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        accuracyM: (json['accuracy_m'] as num?)?.toDouble(),
        speedKmh: (json['speed_kmh'] as num?)?.toDouble(),
        headingDeg: (json['heading_deg'] as num?)?.toDouble(),
        leg: json['leg'] as String?,
        recordedAt: DateTime.parse(json['recorded_at'].toString()).toUtc(),
        trackingState: (json['tracking_state'] as String?)?.isNotEmpty == true
            ? json['tracking_state'] as String
            : 'live',
      );
}

/// One row of `bus_live_positions` — a bus's current dot on the admin map.
class BusPosition {
  final String busId;
  final String tourId;
  final double lat;
  final double lng;
  final double? accuracyM;
  final double? speedKmh;
  final double? headingDeg;
  final String? leg;
  final String trackingState;
  final DateTime recordedAt;
  final DateTime receivedAt;

  const BusPosition({
    required this.busId,
    required this.tourId,
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.speedKmh,
    this.headingDeg,
    this.leg,
    required this.trackingState,
    required this.recordedAt,
    required this.receivedAt,
  });

  factory BusPosition.fromMap(Map<String, dynamic> map) => BusPosition(
        busId: (map['bus_id'] ?? '').toString(),
        tourId: (map['tour_id'] ?? '').toString(),
        lat: (map['lat'] as num).toDouble(),
        lng: (map['lng'] as num).toDouble(),
        accuracyM: (map['accuracy_m'] as num?)?.toDouble(),
        speedKmh: (map['speed_kmh'] as num?)?.toDouble(),
        headingDeg: (map['heading_deg'] as num?)?.toDouble(),
        leg: map['leg'] as String?,
        trackingState: (map['tracking_state'] as String?) ?? 'live',
        recordedAt: _parseUtc(map['recorded_at']),
        receivedAt: _parseUtc(map['received_at']),
      );

  static DateTime _parseUtc(dynamic v) {
    if (v is DateTime) return v.toUtc();
    return DateTime.tryParse(v?.toString() ?? '')?.toUtc() ??
        DateTime.now().toUtc();
  }

  Duration get staleness => DateTime.now().toUtc().difference(recordedAt);

  /// Three missed 2-minute uploads. Below this a quiet bus is simply parked;
  /// above it, assume the handler's phone stopped reporting.
  bool get isStale => staleness > const Duration(minutes: 6);

  /// 5 km/h filters out GPS jitter around a stationary vehicle.
  bool get isMoving => (speedKmh ?? 0) > 5;
}
