import 'dart:math' as math;

import '../models/bus_position.dart';

/// One phone's latest reading, already limited to a single bus.
///
/// [contributorId] is the passenger (or the handler's passenger row). Two
/// readings from the same phone collapse to the newer one before the cluster
/// is built, so a chatty device cannot outvote the rest of the bus.
class BusLocationSample {
  final String contributorId;
  final double lat;
  final double lng;
  final double? accuracyM;
  final double? speedKmh;
  final double? headingDeg;
  final String? leg;
  final DateTime recordedAt;

  const BusLocationSample({
    required this.contributorId,
    required this.lat,
    required this.lng,
    this.accuracyM,
    this.speedKmh,
    this.headingDeg,
    this.leg,
    required this.recordedAt,
  });

  /// Unknown accuracy is treated as a mediocre phone fix, not as perfect.
  /// Matches `recompute_bus_live_position` in migration 095.
  double get accuracyForRank => accuracyM ?? unknownAccuracyM;
}

/// How far apart two phones can be and still count as the same bus.
///
/// A coach is ~12 m long and a fine GPS fix is usually inside 50 m. 400 m
/// keeps the people on the bus and drops a phone left at home or a passenger
/// who already got off at the previous town.
const double busClusterRadiusM = 400;

/// Fixes older than this are not "where the bus is now".
const Duration busLocationFreshWindow = Duration(minutes: 10);

const double minAccuracyM = 5;
const double maxAccuracyM = 500;
const double unknownAccuracyM = 80;

/// Weight for the centroid. A 10 m GPS fix outweighs a 200 m cell-tower fix
/// twenty to one, which is the "fine location" preference: precise readings
/// pull the bus, coarse ones barely move it.
double locationWeight(double? accuracyM) {
  final clamped = accuracyM == null
      ? unknownAccuracyM
      : accuracyM.clamp(minAccuracyM, maxAccuracyM).toDouble();
  return 1 / clamped;
}

/// Great-circle distance in metres. Accurate enough for a few kilometres,
/// which is the only range the cluster test cares about.
double haversineM(double lat1, double lng1, double lat2, double lng2) {
  const earth = 6371000.0;
  final p1 = lat1 * math.pi / 180;
  final p2 = lat2 * math.pi / 180;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(dLng / 2), 2);
  return earth * 2 * math.asin(math.min(1, math.sqrt(h.toDouble())));
}

/// The bus position implied by [samples].
///
/// Returns null when nothing in the fresh window remains. One phone is used
/// as-is (a bus with a single reporter still has a position). Two or more are
/// reduced to the tightest group within [busClusterRadiusM]; a phone outside
/// that group does not pull the dot. The dot itself is the accuracy-weighted
/// centre of the group, so a fine GPS reading counts for more than a coarse one.
///
/// This is the client twin of `recompute_bus_live_position`. The live map
/// reads the server's result; this function exists so the rule can be tested
/// and so the two stay obviously the same rule.
LocationFix? consensusPosition(
  List<BusLocationSample> samples, {
  required DateTime now,
}) {
  final fresh = <String, BusLocationSample>{};
  final newest = now.add(const Duration(minutes: 5));
  final oldest = now.subtract(busLocationFreshWindow);
  for (final s in samples) {
    if (s.recordedAt.isBefore(oldest) || s.recordedAt.isAfter(newest)) {
      continue;
    }
    final prev = fresh[s.contributorId];
    if (prev == null || s.recordedAt.isAfter(prev.recordedAt)) {
      fresh[s.contributorId] = s;
    }
  }
  final latest = fresh.values.toList();
  if (latest.isEmpty) return null;
  if (latest.length == 1) return _fixFrom(latest.single, radiusM: 0);

  BusLocationSample? seed;
  var seedNeighbors = -1;
  var seedWeight = -1.0;
  for (final candidate in latest) {
    final near = _within(candidate, latest);
    final neighbors = near.length;
    final weight = near.fold<double>(0, (sum, s) => sum + locationWeight(s.accuracyM));
    final better = seed == null ||
        neighbors > seedNeighbors ||
        (neighbors == seedNeighbors && weight > seedWeight) ||
        (neighbors == seedNeighbors &&
            weight == seedWeight &&
            _finerThan(candidate, seed));
    if (better) {
      seed = candidate;
      seedNeighbors = neighbors;
      seedWeight = weight;
    }
  }
  final cluster = _within(seed!, latest);
  return _centroid(cluster);
}

List<BusLocationSample> _within(
  BusLocationSample origin,
  List<BusLocationSample> all,
) {
  return all
      .where(
        (s) =>
            haversineM(origin.lat, origin.lng, s.lat, s.lng) <= busClusterRadiusM,
      )
      .toList();
}

/// Finer accuracy, then newer. Used only to break a tie between seeds that
/// have the same neighbour count and the same weight.
bool _finerThan(BusLocationSample a, BusLocationSample b) {
  final byAcc = a.accuracyForRank.compareTo(b.accuracyForRank);
  if (byAcc != 0) return byAcc < 0;
  return a.recordedAt.isAfter(b.recordedAt);
}

LocationFix _centroid(List<BusLocationSample> cluster) {
  var wSum = 0.0;
  var lat = 0.0;
  var lng = 0.0;
  for (final s in cluster) {
    final w = locationWeight(s.accuracyM);
    wSum += w;
    lat += s.lat * w;
    lng += s.lng * w;
  }
  lat /= wSum;
  lng /= wSum;

  var radius = 0.0;
  for (final s in cluster) {
    final d = haversineM(lat, lng, s.lat, s.lng);
    if (d > radius) radius = d;
  }

  final finest = cluster.reduce(
    (a, b) => _finerThan(a, b) ? a : b,
  );
  var newest = cluster.first.recordedAt;
  for (final s in cluster) {
    if (s.recordedAt.isAfter(newest)) newest = s.recordedAt;
  }
  return _fixFrom(
    finest,
    lat: lat,
    lng: lng,
    radiusM: radius,
    recordedAt: newest,
  );
}

LocationFix _fixFrom(
  BusLocationSample instrument, {
  double? lat,
  double? lng,
  required double radiusM,
  DateTime? recordedAt,
}) {
  final instrumentAcc = instrument.accuracyM ?? unknownAccuracyM;
  final accuracy = instrumentAcc > radiusM ? instrumentAcc : radiusM;
  return LocationFix(
    lat: lat ?? instrument.lat,
    lng: lng ?? instrument.lng,
    accuracyM: accuracy,
    speedKmh: instrument.speedKmh,
    headingDeg: instrument.headingDeg,
    leg: instrument.leg,
    recordedAt: recordedAt ?? instrument.recordedAt,
  );
}

/// One row the server may hand back from `location_share_target`: a bus this
/// phone actually holds a seat on, during a locked trip.
class BusShareCandidate {
  final String busId;
  final DateTime departure;
  final int seatCount;

  const BusShareCandidate({
    required this.busId,
    required this.departure,
    required this.seatCount,
  });
}

/// Which bus this phone should report for.
///
/// The trip closest to [now] wins, because a locked tour that left this
/// morning is the bus they are on, not the locked tour that leaves next week.
/// On that trip, the bus where they hold more berths wins. A remaining tie
/// breaks on [BusShareCandidate.busId] so two phones never disagree.
BusShareCandidate? pickBusShareTarget(
  List<BusShareCandidate> candidates, {
  required DateTime now,
}) {
  if (candidates.isEmpty) return null;
  final ranked = [...candidates]..sort((a, b) {
    final gap = _gap(a, now).compareTo(_gap(b, now));
    if (gap != 0) return gap;
    final seats = b.seatCount.compareTo(a.seatCount);
    if (seats != 0) return seats;
    return a.busId.compareTo(b.busId);
  });
  return ranked.first;
}

int _gap(BusShareCandidate c, DateTime now) =>
    c.departure.toUtc().difference(now.toUtc()).inSeconds.abs();
