import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/bus_location_consensus.dart';

BusLocationSample sample({
  required String id,
  required double lat,
  double lng = 72.5,
  double? accuracyM = 15,
  DateTime? at,
  double? speedKmh,
}) {
  return BusLocationSample(
    contributorId: id,
    lat: lat,
    lng: lng,
    accuracyM: accuracyM,
    speedKmh: speedKmh,
    recordedAt: at ?? DateTime.utc(2026, 9, 23, 10),
  );
}

void main() {
  final now = DateTime.utc(2026, 9, 23, 10, 5);

  test('one phone is the bus — a lone reporter still has a position', () {
    final fix = consensusPosition(
      [sample(id: 'a', lat: 23.03, accuracyM: 12, speedKmh: 40)],
      now: now,
    );
    expect(fix!.lat, 23.03);
    expect(fix.accuracyM, 12);
    expect(fix.speedKmh, 40);
  });

  test('a phone left behind does not drag the bus off the road', () {
    // ~11 m apart along the bus, plus one phone 5 km south.
    final onBus = [
      sample(id: 'a', lat: 23.0300, accuracyM: 8),
      sample(id: 'b', lat: 23.0301, accuracyM: 20),
      sample(id: 'c', lat: 23.0299, accuracyM: 12),
      sample(id: 'd', lat: 23.03005, accuracyM: 30),
    ];
    final leftBehind = sample(id: 'home', lat: 22.985, accuracyM: 10);

    final fix = consensusPosition([...onBus, leftBehind], now: now);

    expect(fix!.lat, closeTo(23.03, 0.001));
    expect((fix.lat - 22.985).abs(), greaterThan(0.01));
  });

  test('when two phones disagree, the finer GPS wins', () {
    final fix = consensusPosition(
      [
        sample(id: 'gps', lat: 23.03, accuracyM: 8),
        sample(id: 'cell', lat: 23.20, accuracyM: 300),
      ],
      now: now,
    );
    expect(fix!.lat, closeTo(23.03, 0.0001));
  });

  test('a coarse fix barely moves a cluster of fine ones', () {
    final fix = consensusPosition(
      [
        sample(id: 'a', lat: 23.0300, accuracyM: 6),
        sample(id: 'b', lat: 23.0300, accuracyM: 6),
        sample(id: 'c', lat: 23.0302, accuracyM: 400),
      ],
      now: now,
    );
    // 0.0002 deg is ~22 m. The coarse phone is in the cluster but almost
    // weightless, so the dot stays on the fine pair.
    expect(fix!.lat, closeTo(23.0300, 0.00005));
  });

  test('a reading older than the fresh window is ignored', () {
    final fix = consensusPosition(
      [
        sample(
          id: 'old',
          lat: 23.5,
          at: now.subtract(const Duration(minutes: 30)),
        ),
      ],
      now: now,
    );
    expect(fix, isNull);
  });

  test('the same phone reporting twice counts once, and the newer fix wins', () {
    final fix = consensusPosition(
      [
        sample(id: 'a', lat: 23.01, at: now.subtract(const Duration(minutes: 4))),
        sample(id: 'a', lat: 23.04, at: now.subtract(const Duration(minutes: 1))),
      ],
      now: now,
    );
    expect(fix!.lat, 23.04);
  });

  test('each bus is judged on its own passengers', () {
    // Calling the consensus per bus is the contract: bus 2's phones must not
    // be mixed into bus 1. The picker below is the other half — a rider who
    // holds seats on two buses reports for one of them only.
    final bus1 = consensusPosition(
      [
        sample(id: 'p1', lat: 23.03),
        sample(id: 'p2', lat: 23.0301),
      ],
      now: now,
    );
    final bus2 = consensusPosition(
      [sample(id: 'p3', lat: 21.17)],
      now: now,
    );
    expect(bus1!.lat, closeTo(23.03, 0.001));
    expect(bus2!.lat, 21.17);
  });

  test('the bus closest to now wins, then the one with more berths', () {
    final picked = pickBusShareTarget(
      [
        BusShareCandidate(
          busId: 'later',
          departure: now.add(const Duration(days: 6)),
          seatCount: 4,
        ),
        BusShareCandidate(
          busId: 'today-few',
          departure: now.subtract(const Duration(hours: 2)),
          seatCount: 1,
        ),
        BusShareCandidate(
          busId: 'today-many',
          departure: now.subtract(const Duration(hours: 2)),
          seatCount: 3,
        ),
      ],
      now: now,
    );
    expect(picked!.busId, 'today-many');
  });
}
