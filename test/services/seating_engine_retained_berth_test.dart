import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/seating_engine.dart';
import 'package:occubusbooking/services/seating_plan_applier.dart';

/// A retired rider who STILL HOLDS BERTHS.
///
/// `journeyDone` used to imply seatless: `completeOutboundLeg` freed a one-way
/// rider's seats at the moment it retired them, so "excluded from the engine"
/// and "holds nothing" were the same state and the engine could ignore retired
/// riders entirely.
///
/// Per-seat leg cancellation breaks that. A round-trip rider whose RETURN is
/// struck keeps the GO berth they actually rode — the chart must still show who
/// was in that seat, and their fare must still be charged for the leg they
/// travelled. So `journeyDone` now means only "has finished travelling", and the
/// engine has to seed those berths or it will let the seat out from under them.
void main() {
  SeatCell cell(int row, int col, SeatType type, SeatPosition? pos, String id) =>
      SeatCell(row: row, col: col, seatType: type, position: pos, seatId: id);

  /// One single sofa (SU1) and one double sofa (DL1).
  Bus bus() => Bus(
        id: 'b1',
        name: 'b1',
        busType: 'Sleeper',
        layout: BusLayout(
          rows: 2,
          cols: SeatGridCols.count,
          grid: [
            cell(0, 0, SeatType.singleSofa, SeatPosition.upper, 'SU1'),
            cell(1, 4, SeatType.doubleSofa, SeatPosition.lower, 'DL1'),
          ],
        ),
      );

  /// Rode out on SU1, return cancelled: retired, berth kept, stamped GO-only.
  Passenger retiredHolder() => Passenger(
        id: 'retired',
        tourId: 't1',
        name: 'Ramesh',
        phone: '+910000000001',
        tripType: TripType.outboundOnly,
        journeyDone: true,
        requestLines: [
          RequestLine(
              seatType: SeatType.singleSofa,
              qty: 1,
              leg: TripType.outboundOnly),
        ],
        assignedSeats: [
          SeatAssignment(
              busId: 'b1', seatId: 'SU1', leg: TripType.outboundOnly),
        ],
      );

  Passenger seeker(String id, TripType leg) => Passenger(
        id: id,
        tourId: 't1',
        name: id,
        phone: '+910000000002',
        tripType: leg,
        requestLines: [
          RequestLine(seatType: SeatType.singleSofa, qty: 1, leg: leg),
        ],
      );

  test('a retired rider keeps the GO half of the berth they rode', () {
    final plan = SeatingEngine.propose(
      buses: [bus()],
      passengers: [retiredHolder(), seeker('newGo', TripType.outboundOnly)],
    );

    // The berth is still recorded as theirs...
    expect(plan.forPassenger('retired').map((a) => a.seatId), ['SU1']);
    // ...so the GO-leg seeker cannot be put on top of them. There is exactly one
    // other single sofa on this bus — none — so they land nowhere on SU1.
    expect(
      plan.forPassenger('newGo').map((a) => a.seatId),
      isNot(contains('SU1')),
      reason: 'SU1 is occupied on the GO leg by someone who rode it',
    );
  });

  test('the RETURN half of that same berth is still sellable', () {
    final plan = SeatingEngine.propose(
      buses: [bus()],
      passengers: [retiredHolder(), seeker('newRet', TripType.returnOnly)],
    );

    // This is the whole point of the feature: the freed half resells.
    expect(
      plan.forPassenger('newRet').map((a) => a.seatId),
      contains('SU1'),
      reason: 'the cancelled return leaves SU1 open for the ride home',
    );
    expect(plan.forPassenger('retired').map((a) => a.seatId), ['SU1']);
  });

  test('the plan never proposes taking a retired rider\'s berth away', () {
    final passengers = [retiredHolder(), seeker('newRet', TripType.returnOnly)];
    final plan = SeatingEngine.propose(buses: [bus()], passengers: passengers);

    // The applier diffs plan-vs-current and writes the difference. Before the
    // engine seeded these berths the plan held NOTHING for a retired rider, so
    // this diff was a command to clear their seats — the exact wipe the feature
    // exists to prevent, arriving via the next re-plan instead of the cancel.
    final changes = SeatingPlanApplier.diff(plan: plan, passengers: passengers);
    final wipe = changes.where((c) => c.passengerId == 'retired');
    expect(wipe, isEmpty, reason: 'their held berth is not a vacancy');
  });

  test('a retired rider holding NOTHING is still ignored entirely', () {
    // The ordinary completeOutboundLeg shape: retired AND seatless. They must
    // not reappear as demand.
    final seatless = retiredHolder().copyWith(assignedSeats: const []);
    final plan = SeatingEngine.propose(
      buses: [bus()],
      passengers: [seatless, seeker('newGo', TripType.outboundOnly)],
    );

    expect(plan.forPassenger('retired'), isEmpty);
    expect(
      plan.forPassenger('newGo').map((a) => a.seatId),
      contains('SU1'),
      reason: 'nobody is holding SU1, so the GO seeker takes it',
    );
  });
}
