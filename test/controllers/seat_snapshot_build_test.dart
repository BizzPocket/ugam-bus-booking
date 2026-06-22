import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour_seat_snapshot.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// Unit tests for the pure top-level [buildSeatSnapshot] — the snapshot-building
/// logic extracted out of `TourController._captureSeatSnapshot` so it can be
/// exercised without GetX/SyncService.
///
/// The builder freezes the per-leg chart: outbound picks each seat's GO rider
/// (round-trip + outbound-only), return picks the RET rider (round-trip +
/// return-only). Empty legs return null so callers skip storing nothing.
///
/// Note on names: `Passenger.displayName` falls back to `Passenger.name` when no
/// `UserController` is registered (the test context), so a passenger's `name` is
/// exactly what lands in the snapshot seat.
void main() {
  // Minimal bus — the builder only reads `bus.id`; no layout needed.
  Bus bus(String id) => Bus(id: id, name: 'Bus $id');

  Passenger rider({
    required String id,
    required String name,
    required String phone,
    required TripType tripType,
    required List<SeatAssignment> seats,
  }) =>
      Passenger(
        id: id,
        tourId: 't1',
        name: name,
        phone: phone,
        tripType: tripType,
        requestLines: [
          RequestLine(seatType: SeatType.seater, qty: 1, leg: tripType),
        ],
        assignedSeats: seats,
      );

  SeatAssignment seat(String busId, String seatId) =>
      SeatAssignment(busId: busId, seatId: seatId);

  test('outbound snapshot picks GO riders (round-trip + outbound-only)', () {
    final passengers = [
      rider(
        id: 'p-round',
        name: 'Round Rider',
        phone: '111',
        tripType: TripType.roundTrip,
        seats: [seat('b1', 'L1')],
      ),
      rider(
        id: 'p-out',
        name: 'Outbound Rider',
        phone: '222',
        tripType: TripType.outboundOnly,
        seats: [seat('b1', 'L2')],
      ),
      rider(
        id: 'p-ret',
        name: 'Return Rider',
        phone: '333',
        tripType: TripType.returnOnly,
        seats: [seat('b1', 'L3')],
      ),
    ];

    final snap = buildSeatSnapshot(
      tourId: 't1',
      leg: SnapshotLeg.outbound,
      buses: [bus('b1')],
      passengers: passengers,
      capturedAt: DateTime(2026, 6, 19),
    );

    expect(snap, isNotNull);
    expect(snap!.leg, SnapshotLeg.outbound);
    final b1 = snap.buses.single;
    expect(b1.busId, 'b1');
    // GO riders captured...
    expect(b1.occupant('L1')?.name, 'Round Rider');
    expect(b1.occupant('L2')?.name, 'Outbound Rider');
    // ...return-only rider is NOT in the outbound snapshot.
    expect(b1.occupant('L3'), isNull);
  });

  test('return snapshot picks RET riders (round-trip + return-only)', () {
    final passengers = [
      rider(
        id: 'p-round',
        name: 'Round Rider',
        phone: '111',
        tripType: TripType.roundTrip,
        seats: [seat('b1', 'L1')],
      ),
      rider(
        id: 'p-ret',
        name: 'Return Rider',
        phone: '333',
        tripType: TripType.returnOnly,
        seats: [seat('b1', 'L3')],
      ),
      rider(
        id: 'p-out',
        name: 'Outbound Rider',
        phone: '222',
        tripType: TripType.outboundOnly,
        seats: [seat('b1', 'L2')],
      ),
    ];

    final snap = buildSeatSnapshot(
      tourId: 't1',
      leg: SnapshotLeg.return_,
      buses: [bus('b1')],
      passengers: passengers,
      capturedAt: DateTime(2026, 6, 19),
    );

    expect(snap, isNotNull);
    final b1 = snap!.buses.single;
    expect(b1.occupant('L1')?.name, 'Round Rider');
    expect(b1.occupant('L3')?.name, 'Return Rider');
    // Outbound-only rider is NOT in the return snapshot.
    expect(b1.occupant('L2'), isNull);
  });

  test('round-trip rider appears in BOTH outbound and return snapshots', () {
    final passengers = [
      rider(
        id: 'p-round',
        name: 'Round Rider',
        phone: '111',
        tripType: TripType.roundTrip,
        seats: [seat('b1', 'L1')],
      ),
    ];

    final out = buildSeatSnapshot(
      tourId: 't1',
      leg: SnapshotLeg.outbound,
      buses: [bus('b1')],
      passengers: passengers,
      capturedAt: DateTime(2026, 6, 19),
    );
    final ret = buildSeatSnapshot(
      tourId: 't1',
      leg: SnapshotLeg.return_,
      buses: [bus('b1')],
      passengers: passengers,
      capturedAt: DateTime(2026, 6, 19),
    );

    expect(out!.buses.single.occupant('L1')?.name, 'Round Rider');
    expect(ret!.buses.single.occupant('L1')?.name, 'Round Rider');
  });

  test('one-way tour (outbound-only riders) → return snapshot is NULL', () {
    final passengers = [
      rider(
        id: 'p-out1',
        name: 'A',
        phone: '111',
        tripType: TripType.outboundOnly,
        seats: [seat('b1', 'L1')],
      ),
      rider(
        id: 'p-out2',
        name: 'B',
        phone: '222',
        tripType: TripType.outboundOnly,
        seats: [seat('b1', 'L2')],
      ),
    ];

    final ret = buildSeatSnapshot(
      tourId: 't1',
      leg: SnapshotLeg.return_,
      buses: [bus('b1')],
      passengers: passengers,
      capturedAt: DateTime(2026, 6, 19),
    );

    // No return riders → nothing to store.
    expect(ret, isNull);

    // Sanity: the outbound leg DOES produce a snapshot.
    final out = buildSeatSnapshot(
      tourId: 't1',
      leg: SnapshotLeg.outbound,
      buses: [bus('b1')],
      passengers: passengers,
      capturedAt: DateTime(2026, 6, 19),
    );
    expect(out, isNotNull);
    expect(out!.buses.single.seats.length, 2);
  });

  test(
      'capture-before-wipe: outbound snapshot retains the seat completeOutboundLeg later clears',
      () {
    // This rider's seat L1 is exactly what completeOutboundLeg() wipes after
    // capture. Building the OUTBOUND snapshot first preserves it with the name.
    final passengers = [
      rider(
        id: 'p-out',
        name: 'Soon To Be Cleared',
        phone: '999',
        tripType: TripType.outboundOnly,
        seats: [seat('b1', 'L1')],
      ),
    ];

    final snap = buildSeatSnapshot(
      tourId: 't1',
      leg: SnapshotLeg.outbound,
      buses: [bus('b1')],
      passengers: passengers,
      capturedAt: DateTime(2026, 6, 19),
    );

    expect(snap, isNotNull);
    final occupant = snap!.buses.single.occupant('L1');
    expect(occupant, isNotNull);
    expect(occupant!.seatId, 'L1');
    expect(occupant.name, 'Soon To Be Cleared');
  });

  test('a bus with zero occupied seats is skipped (not in snapshot.buses)', () {
    final passengers = [
      rider(
        id: 'p-out',
        name: 'Only On b1',
        phone: '111',
        tripType: TripType.roundTrip,
        seats: [seat('b1', 'L1')],
      ),
    ];

    final snap = buildSeatSnapshot(
      tourId: 't1',
      leg: SnapshotLeg.outbound,
      buses: [bus('b1'), bus('b2')], // b2 has no riders
      passengers: passengers,
      capturedAt: DateTime(2026, 6, 19),
    );

    expect(snap, isNotNull);
    final busIds = snap!.buses.map((b) => b.busId).toList();
    expect(busIds, ['b1']);
    expect(busIds.contains('b2'), isFalse);
  });

  test('name comes from displayName and phone from Passenger.phone', () {
    final passengers = [
      rider(
        id: 'p-out',
        name: 'Ravi Patel',
        phone: '9876543210',
        tripType: TripType.roundTrip,
        seats: [seat('b1', 'L1')],
      ),
    ];

    final snap = buildSeatSnapshot(
      tourId: 't1',
      leg: SnapshotLeg.outbound,
      buses: [bus('b1')],
      passengers: passengers,
      capturedAt: DateTime(2026, 6, 19),
    );

    final occupant = snap!.buses.single.occupant('L1')!;
    // displayName falls back to name (no UserController registered).
    expect(occupant.name, 'Ravi Patel');
    expect(occupant.phone, '9876543210');
  });
}
