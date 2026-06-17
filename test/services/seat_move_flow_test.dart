import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/services/seat_move_flow.dart';

/// Regression for "moving a passenger to another bus is not functional".
///
/// The real call site ([occupant_action_sheet]) POPS its own bottom sheet and
/// then calls [SeatMoveFlow.start] with that SAME context. The destination
/// picker still opens (the popped sheet is mid-exit animation), but the SECOND
/// sheet — the swap assistant — is launched LATER from the picker's onPick
/// callback, by which time the original context is unmounted. Opening the swap
/// assistant against a defunct context silently fails, so after the agent picks
/// a destination bus, nothing happens. This test reproduces that exact chain.
class _FakeTourController extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

Bus _bus(String id, String name, {required int seats}) => Bus(
      id: id,
      name: name,
      busType: 'Sleeper',
      layout: BusLayout.generate(busType: BusType.sleeper, totalSeats: seats),
    );

void main() {
  tearDown(Get.reset);

  testWidgets(
      'picking a destination bus opens the swap assistant (cross-bus move)',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);

    final bus1 = _bus('b1', 'Bus 1', seats: 15);
    final bus2 = _bus('b2', 'Bus 2', seats: 40);

    // Where the mover currently sits on Bus 1, and a request line of the same
    // class so the empty Bus 2 offers compatible FREE seats.
    final firstCell =
        bus1.layout!.grid.firstWhere((c) => c.hasSeat && c.seatId != null);
    final fromSeatId = firstCell.seatId!;
    final seatType = firstCell.seatType!;

    final mover = Passenger(
      id: 'm1',
      tourId: 't1',
      name: 'abhi',
      phone: '+910000000000',
      requestLines: [RequestLine(seatType: seatType, qty: 1)],
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: fromSeatId)],
    );

    ctrl.tours.assignAll([
      Tour(
        id: 't1',
        title: 'test',
        fromCity: 'A',
        toCity: 'B',
        departureDate: DateTime(2026, 7, 1),
        pricePerSeat: 1,
        buses: [bus1, bus2],
        passengers: [mover],
      ),
    ]);

    // Host that mimics the occupant action sheet: a bottom sheet which, on tap,
    // POPS itself and then starts the move flow with its own (dying) context.
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (rootCtx) => Center(
              child: ElevatedButton(
                onPressed: () {
                  showModalBottomSheet<void>(
                    context: rootCtx,
                    builder: (sheetCtx) => ElevatedButton(
                      onPressed: () {
                        Navigator.of(sheetCtx).pop();
                        SeatMoveFlow.start(
                          sheetCtx,
                          tourId: 't1',
                          sourceBusId: 'b1',
                          mover: mover,
                          fromSeatId: fromSeatId,
                        );
                      },
                      child: const Text('move'),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('move'));
    await tester.pumpAndSettle(); // action sheet fully gone; picker shown

    // Destination picker is up.
    expect(find.text('Bus 2'), findsOneWidget);
    await tester.tap(find.text('Bus 2'));
    await tester.pumpAndSettle();

    // The swap assistant must now be open, listing free seats on empty Bus 2
    // (each chip carries an event_seat icon). The destination picker used a
    // bus icon, so this icon uniquely marks the swap assistant.
    expect(find.byIcon(Icons.event_seat_rounded), findsWidgets);
  });

  testWidgets(
      'with onRelocateToBus, picking a bus hands back to the chart (no swap assistant)',
      (tester) async {
    final ctrl = _FakeTourController();
    Get.put<TourController>(ctrl);

    final bus1 = _bus('b1', 'Bus 1', seats: 15);
    final bus2 = _bus('b2', 'Bus 2', seats: 40);
    final firstCell =
        bus1.layout!.grid.firstWhere((c) => c.hasSeat && c.seatId != null);
    final fromSeatId = firstCell.seatId!;

    final mover = Passenger(
      id: 'm1',
      tourId: 't1',
      name: 'abhi',
      phone: '+910000000000',
      requestLines: [RequestLine(seatType: firstCell.seatType!, qty: 1)],
      assignedSeats: [SeatAssignment(busId: 'b1', seatId: fromSeatId)],
    );

    ctrl.tours.assignAll([
      Tour(
        id: 't1',
        title: 'test',
        fromCity: 'A',
        toCity: 'B',
        departureDate: DateTime(2026, 7, 1),
        pricePerSeat: 1,
        buses: [bus1, bus2],
        passengers: [mover],
      ),
    ]);

    Bus? relocateDest;
    Passenger? relocateMover;
    String? relocateSource;
    String? relocateFromSeat;

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (rootCtx) => Center(
              child: ElevatedButton(
                onPressed: () => SeatMoveFlow.start(
                  rootCtx,
                  tourId: 't1',
                  sourceBusId: 'b1',
                  mover: mover,
                  fromSeatId: fromSeatId,
                  onRelocateToBus: (dest, m, src, seat) {
                    relocateDest = dest;
                    relocateMover = m;
                    relocateSource = src;
                    relocateFromSeat = seat;
                  },
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bus 2'));
    await tester.pumpAndSettle();

    // The callback fired with the destination + the mover's source identity…
    expect(relocateDest?.id, 'b2');
    expect(relocateMover?.id, 'm1');
    expect(relocateSource, 'b1');
    expect(relocateFromSeat, fromSeatId);
    // …and the auto swap-assistant did NOT open.
    expect(find.byIcon(Icons.event_seat_rounded), findsNothing);
  });
}
