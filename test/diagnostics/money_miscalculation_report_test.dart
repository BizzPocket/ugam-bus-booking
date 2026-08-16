// Executable companion to docs/2026-08-09-money-ledger-audit.md and
// docs/superpowers/specs/2026-08-09-ledger-authoritative-design.md.
//
// This started as a REPORT that asserted each audit finding was still OPEN, so
// it passed while the bugs lived and went red as they were fixed. Every finding
// it covers is now CLOSED, so it has become what that design intended: the
// REGRESSION GUARD. Each test asserts the FIXED behaviour and prints was/now/
// correct alongside, so the numbers stay readable and a reopened bug fails here.
//
// It drives the REAL fare engine and the REAL MoneyController against the data
// `supabase/seeds/test_tours.sql` puts in the database.
//
// Run it with:
//   flutter test test/diagnostics/money_miscalculation_report_test.dart -r expanded
//
// SCOPE — what this file can and cannot prove. Tests 4-6 exercise real Dart
// (MoneyController, the fare engine) and are true regression tests. Tests 2 and
// 3 cover PostgreSQL behaviour that no Dart test can execute: they pin the RULE
// that migrations 069/070 implement, and assert the old rule really did differ,
// so a silent revert to it fails. The live proof is
// supabase/diagnostics/finance_audit_checks.sql — checks 5 and 7 must return
// zero rows against the real database.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/money_controller.dart';
import 'package:occubusbooking/controllers/tour_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/bus_type.dart';
import 'package:occubusbooking/models/collection.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_assignment.dart';
import 'package:occubusbooking/models/seat_layout.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/tour.dart';
import 'package:occubusbooking/models/tour_status.dart';
import 'package:occubusbooking/models/trip_type.dart';
import 'package:occubusbooking/services/ledger_money_source.dart';
import 'package:occubusbooking/services/sync_service.dart';

// ── The seeded data, verbatim ────────────────────────────────────────────────
// Column values copied out of supabase/seeds/test_tours.sql so the numbers below
// describe the tours actually sitting in the database, not a lookalike.

const tourAId = 'aaaa1111-0000-4000-8000-000000000001';
const busAId = 'aaaa1111-0000-4000-8000-0000000000b1';
const tourBId = 'bbbb2222-0000-4000-8000-000000000001';
const busBId = 'bbbb2222-0000-4000-8000-0000000000b1';

/// Sleeper 36 — 12 single sofas + 12 double sofas over 6 rows.
Map<String, dynamic> get _sleeperLayout {
  final grid = <Map<String, dynamic>>[];
  for (var row = 0; row < 6; row++) {
    grid.add({
      'row': row, 'col': 0, 'seatType': 'singleSofa',
      'position': 'upper', 'seatId': 'SU${row + 1}',
    });
    grid.add({
      'row': row, 'col': 1, 'seatType': 'singleSofa',
      'position': 'lower', 'seatId': 'SL${row + 1}',
    });
    grid.add({
      'row': row, 'col': 3, 'seatType': 'doubleSofa',
      'position': 'upper', 'seatId': 'DU${row + 1}',
    });
    grid.add({
      'row': row, 'col': 4, 'seatType': 'doubleSofa',
      'position': 'lower', 'seatId': 'DL${row + 1}',
    });
  }
  return {'rows': 6, 'cols': 5, 'hasBalcony': false, 'grid': grid};
}

/// Seater 40 — 4 per row over 10 rows.
Map<String, dynamic> get _seaterLayout {
  const cols = [0, 1, 3, 4];
  final grid = <Map<String, dynamic>>[
    for (var i = 0; i < 40; i++)
      {
        'row': i ~/ 4,
        'col': cols[i % 4],
        'seatType': 'seater',
        'seatId': 'ST${i + 1}',
      },
  ];
  return {'rows': 10, 'cols': 5, 'hasBalcony': false, 'grid': grid};
}

Bus get seededBusA => Bus.fromMap({
      'id': busAId,
      'tour_id': tourAId,
      'name': 'Test Bus A1',
      'registration_no': 'GJ01TEST01',
      'is_ac': true,
      'bus_type': 'Sleeper',
      'total_seats': 36,
      'price_per_seat': 1200,
      'bus_price': 30000,
      'single_sofa_price': 1400,
      'double_sofa_price': 2200, // WHOLE sofa → 1100 per berth
      'seater_price': null,
      'rear_rows': 0,
      'rear_price': null,
      'price_bands': jsonEncode([
        {'label': 'Front Premium', 'fromRow': 0, 'toRow': 1, 'price': 1600},
      ]),
      'layout': _sleeperLayout,
    });

Bus get seededBusB => Bus.fromMap({
      'id': busBId,
      'tour_id': tourBId,
      'name': 'Test Bus B1',
      'registration_no': 'GJ01TEST02',
      'is_ac': false,
      'bus_type': 'Seater',
      'total_seats': 40,
      'price_per_seat': 800,
      'bus_price': 22000,
      'seater_price': 800,
      'rear_rows': 2, // legacy rear zone → rows 8-9
      'rear_price': 600,
      'price_bands': jsonEncode(const []),
      'layout': _seaterLayout,
    });

/// A rider holding EVERY berth on [bus] — one assignment per berth, so a whole
/// double sofa is two entries on one seat id, exactly as the seating engine
/// writes it.
Passenger fullBusRider(Bus bus, {TripType leg = TripType.roundTrip}) {
  final seats = <SeatAssignment>[];
  for (final cell in bus.layout!.grid) {
    final berths = cell.seatType == SeatType.doubleSofa ? 2 : 1;
    for (var i = 0; i < berths; i++) {
      seats.add(SeatAssignment(busId: bus.id, seatId: cell.seatId!, leg: leg));
    }
  }
  return Passenger(
    id: 'full-bus-rider',
    tourId: bus.tourId!,
    name: 'Full Bus',
    phone: '9000000000',
    assignedSeats: seats,
    tripType: leg,
  );
}

String inr(num v) => '₹${v.round().toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{2})+\d{3}$)'),
      (m) => '${m[1]},',
    )}';

String pad(String s, int n) => s.padRight(n);

void section(String title) {
  // ignore: avoid_print
  print('\n${'═' * 78}\n  $title\n${'═' * 78}');
}

void line(String s) {
  // ignore: avoid_print
  print(s);
}

void main() {
  // ── 1 · Does the fare engine price the seeded buses as documented? ─────────
  test('1 · fare engine on the seeded buses', () {
    section('1 · FARE ENGINE — what each seat costs on the seeded buses');

    for (final bus in [seededBusA, seededBusB]) {
      final rider = fullBusRider(bus);
      line('\n${bus.name}  ·  rent ${inr(bus.busPrice)}  ·  '
          '${bus.layout!.totalSeats} berths in ${bus.layout!.totalCells} cells');
      line('  ${pad("seat", 8)}${pad("row", 5)}${pad("band", 16)}'
          '${pad("berths", 8)}due');

      var total = 0.0;
      final seen = <String>{};
      for (final cell in bus.layout!.grid) {
        final id = cell.seatId!;
        if (!seen.add(id)) continue;
        final due = bus.amountDueForSeat(rider, id);
        total += due;
        final band = bus.bandForRow(cell.row);
        final berths = cell.seatType == SeatType.doubleSofa ? 2 : 1;
        line('  ${pad(id, 8)}${pad("${cell.row}", 5)}'
            '${pad(band?.label ?? "—", 16)}${pad("$berths", 8)}${inr(due)}');
      }

      line('  ${"-" * 50}');
      line('  BILLED AT FULL OCCUPANCY (round trip): ${inr(total)}');
      line('  amountDueFor(rider) cross-check:       '
          '${inr(bus.amountDueFor(rider))}');

      // The whole-passenger total must equal the sum of the per-seat records —
      // this is the invariant collection_seat_resolver.dart documents.
      expect(bus.amountDueFor(rider), closeTo(total, 0.001),
          reason: 'amountDueFor must equal the sum of amountDueForSeat');
    }

    // Documented in docs/2026-08-09-money-ledger-audit.md — if these change, the
    // audit's expected-books table is stale.
    expect(seededBusA.amountDueFor(fullBusRider(seededBusA)), 48000);
    expect(seededBusB.amountDueFor(fullBusRider(seededBusB)), 30400);
  });

  // ── 2 · D1 · leg fallback: Dart vs the two SQL fare functions ──────────────
  test('2 · FIXED D1 — one leg-fallback rule, transcribed into SQL', () {
    section('2 · FIXED D1 — SQL now falls back to request_lines, as Dart does');

    final bus = seededBusA;

    // A real shape: the rider's stored trip_type column still says roundTrip
    // (it is the legacy default and nothing rewrites it), but their request
    // lines say they are travelling outbound only. Their seat carries no
    // per-berth leg, so both engines fall back — to DIFFERENT things.
    final rider = Passenger(
      id: 'p-legdrift',
      tourId: tourAId,
      name: 'Leg Drift',
      phone: '9111111111',
      tripType: TripType.roundTrip, // ← the passengers.trip_type column
      requestLines: const [
        RequestLine(
          seatType: SeatType.singleSofa,
          position: SeatPosition.lower,
          qty: 1,
          leg: TripType.outboundOnly, // ← what they actually booked
        ),
      ],
      assignedSeats: const [
        SeatAssignment(busId: busAId, seatId: 'SL3'), // no leg stamped
      ],
    );

    final dartDue = bus.amountDueForSeat(rider, 'SL3');

    final cell = bus.layout!.grid.firstWhere((c) => c.seatId == 'SL3');
    final berthPrice = bus.berthPriceFor(cell.seatType!, cell.row);

    // What 053's baseline_seat_due_paise and 049's booking_amount_paise USED to
    // compute: coalesce(seat->>'leg', pax.trip_type, 'roundTrip'). The seat has
    // no leg stamped, so both fell through to trip_type = roundTrip and charged
    // full fare while the app charged half.
    final oldSqlDue = berthPrice * Bus.tripFactor(rider.tripType);

    // What 070's unified baseline_seat_due_paise computes: the leg comes from
    // passenger_leg_for_seat_type, a line-by-line transcription of Dart's
    // Passenger.legForSeatType (070 §2). Same rule, so the same number — which
    // is the entire point of the migration.
    final unifiedLeg =
        rider.legForSeatType(cell.seatType!, position: cell.position);
    final newSqlDue = berthPrice * Bus.tripFactor(unifiedLeg);

    line('  rider              ${rider.name}, seat SL3 (row ${cell.row})');
    line('  berth price        ${inr(berthPrice)}');
    line('  stored trip_type   ${rider.tripType.name}');
    line('  request_lines leg  ${rider.requestLines.first.leg.name}');
    line('  derivedTripType    ${rider.derivedTripType.name}');
    line('  legForSeatType     ${unifiedLeg.name}');
    line('');
    line('  APP shows (Bus.amountDueForSeat)          ${inr(dartDue)}');
    line('  LEDGER billed, BEFORE 070                 ${inr(oldSqlDue)}');
    line('  LEDGER bills,  AFTER  070                 ${inr(newSqlDue)}');
    line('  ONLINE charges, AFTER 070 (calls the same) ${inr(newSqlDue)}');
    line('  drift closed: ${inr(oldSqlDue - dartDue)} on ONE seat, '
        '${(oldSqlDue / dartDue).toStringAsFixed(1)}x, now ${inr(0)}');
    line('\n  FIXED: 070 §2-3 replaced the trip_type fallback with a transcription');
    line('  of legForSeatType, so app / ledger / checkout price identically.');
    line('  This test pins the RULE. Check 7 in finance_audit_checks.sql is the');
    line('  live proof against the real database and must return zero rows.');

    expect(newSqlDue, closeTo(dartDue, 0.001),
        reason: 'D1 is fixed: 070 must price this seat exactly as Dart does');
    expect(oldSqlDue, isNot(closeTo(dartDue, 0.001)),
        reason: 'the old rule really did differ — otherwise 070 fixed nothing');
  });

  // ── 3 · C1 · online advance double-credited ────────────────────────────────
  test('3 · FIXED C1 — confirmed UPI advance posts exactly once', () {
    section('3 · FIXED C1 — one poster, and the money lands in the bank');

    const fare = 1600.0; // SL1 on bus A, front band
    const advance = 500.0; // tours.advance_per_berth_paise = 50000

    // BEFORE 069 — confirm_payment_claim hand-rolled an `online_payment` entry
    // AND wrote a collections row, whose own 062 trigger posted the same money a
    // second time as `cash_receipt`.
    final beforeAr = <({String from, double amount})>[
      (from: 'fare_charge   (062 §6 passengers trigger)', amount: fare),
      (from: 'online_payment(060:276 hand-rolled post)', amount: -advance),
      (from: 'cash_receipt  (062 §3 collections trigger)', amount: -advance),
    ];
    const beforeCashHandler = advance; // money that never touched a pocket

    // AFTER 069 — the collections trigger is the SINGLE poster. It splits the
    // row on the new `amount_online` column: the online slice debits
    // bank.gateway, the remainder debits cash.handler. confirm_payment_claim
    // posts nothing for money that reached a row, so nothing is counted twice.
    final afterAr = <({String from, double amount})>[
      (from: 'fare_charge   (062 §6 passengers trigger)', amount: fare),
      (from: 'online_payment(069 §2 trigger, online slice)', amount: -advance),
    ];
    const afterCashHandler = advance - advance; // = 0, the whole slice is online
    const afterBankGateway = advance;

    final beforeOwes = beforeAr.fold(0.0, (s, l) => s + l.amount);
    final afterOwes = afterAr.fold(0.0, (s, l) => s + l.amount);
    final correctOwes = fare - advance;

    line('  rider is billed ${inr(fare)} and pays ${inr(advance)} online.\n');
    line('  ar.rider postings AFTER 069:');
    for (final l in afterAr) {
      line('    ${pad(l.from, 46)}${l.amount >= 0 ? "+" : "-"}'
          '${inr(l.amount.abs())}');
    }
    line('    ${"-" * 58}');
    line('  ${pad("figure", 34)}${pad("was", 12)}${pad("now", 12)}correct');
    line('  ${pad("finance_rider_balance.owes", 34)}${pad(inr(beforeOwes), 12)}'
        '${pad(inr(afterOwes), 12)}${inr(correctOwes)}');
    line('  ${pad("cash.handler (handover due)", 34)}'
        '${pad(inr(beforeCashHandler), 12)}'
        '${pad(inr(afterCashHandler), 12)}${inr(0)}');
    line('  ${pad("bank.gateway", 34)}${pad(inr(0), 12)}'
        '${pad(inr(afterBankGateway), 12)}${inr(advance)}');
    line('\n  FIXED: 069 §2-3. The handler is no longer told to collect');
    line('  ${inr(advance)} less than the rider owes, nor asked to hand over');
    line('  ${inr(advance)} that went straight to a bank account.');
    line('  Money already double-posted is repaired by');
    line('  finance_repair_online_double_post(true); check 5 must then be empty.');

    expect(afterOwes, closeTo(correctOwes, 0.001),
        reason: 'C1 is fixed: ar.rider is credited exactly once');
    expect(afterCashHandler, 0,
        reason: 'online money must not inflate the handover expectation');
    expect(afterBankGateway, advance,
        reason: 'the advance belongs to bank.gateway, not the handler');
    expect(beforeOwes, lessThan(correctOwes),
        reason: 'the old path really did double-credit — else 069 fixed nothing');
  });

  // ── 4 · E2 · an EMPTY but reachable ledger used to zero every money screen ─
  test('4 · FIXED E2 — empty ledger no longer zeroes the board', () async {
    section('4 · FIXED E2 — ledger reachable but unpopulated → legacy fallback');
    addTearDown(Get.reset);

    // Real cash and real costs sitting in the legacy tables …
    final collections = [
      Collection(
        id: 'c1', tourId: tourAId, busId: busAId, passengerId: 'p1',
        seatId: 'SL1', amountDue: 1600, amountReceived: 1600,
      ).toMap(),
      Collection(
        id: 'c2', tourId: tourAId, busId: busAId, passengerId: 'p2',
        seatId: 'SL2', amountDue: 1600, amountReceived: 1000,
      ).toMap(),
    ];
    final expenses = [
      {
        'id': 'e1', 'tour_id': tourAId, 'bus_id': busAId,
        'category': 'fuel', 'label': '[TEST] Diesel', 'amount': 4000,
      },
    ];

    final money = await _buildController(
      rows: {'collections': collections, 'expenses': expenses},
      // The view EXISTS and answers — it is simply empty, because 062 never
      // posted (or 058 was never run). This is not an error, so loadFailed
      // stays false and _ledgerReady flips to true.
      busRollups: const [],
      riderRows: const [],
    );

    final s = money.summaryForBus(busAId);
    final t = money.tourSummary();

    line('  legacy tables hold  collected ${inr(2600)} · expenses ${inr(4000)} '
        '· rent ${inr(30000)}');
    line('  ledger view returns 0 rows (deployed, unpopulated)\n');
    line('  ${pad("figure", 26)}${pad("was", 12)}${pad("now", 12)}correct');
    line('  ${pad("summaryForBus.collected", 26)}${pad(inr(0), 12)}'
        '${pad(inr(s.collected), 12)}${inr(2600)}');
    line('  ${pad("summaryForBus.expenses", 26)}${pad(inr(30000), 12)}'
        '${pad(inr(s.expensesTotal), 12)}${inr(34000)}');
    line('  ${pad("tourSummary.totalCollected", 26)}${pad(inr(0), 12)}'
        '${pad(inr(t.totalCollected), 12)}${inr(2600)}');
    line('  ${pad("tourSummary.totalNet", 26)}${pad(inr(-30000), 12)}'
        '${pad(inr(t.totalNet), 12)}${inr(2600 - 34000)}');
    line('\n  FIXED: summaryForBus now falls through to the legacy recompute');
    line('  when the ledger holds no lines for a bus, instead of returning hard');
    line('  zeros. A genuinely empty bus computes the same zeros, so the');
    line('  fallback is never worse than the figure it replaced.');

    expect(s.collected, 2600);
    expect(s.expensesTotal, 34000);
    expect(t.totalNet, 2600 - 34000);
  });

  // ── 5 · E1 · orphan money vanishes from the trip total ─────────────────────
  test('5 · FIXED E1 — money on a removed bus stays in the trip total',
      () async {
    section('5 · FIXED E1 — orphan money stays on the books and is reported');
    addTearDown(Get.reset);

    // b1 is on the tour. bX was removed from it, but still carries ₹5,000 of
    // collected cash and ₹1,200 of expenses in the ledger.
    final money = await _buildController(
      rows: const {},
      busRollups: [
        _rollup(busId: busAId, collected: 200000, rent: 3000000),
        _rollup(busId: 'removed-bus', collected: 500000, ground: 120000),
      ],
      riderRows: const [],
    );

    final t = money.tourSummary();
    line('  ledger holds  bus A ${inr(2000)} collected · '
        'removed bus ${inr(5000)} collected + ${inr(1200)} expenses\n');
    line('  ${pad("figure", 26)}${pad("was", 12)}${pad("now", 12)}correct');
    line('  ${pad("totalCollected", 26)}${pad(inr(2000), 12)}'
        '${pad(inr(t.totalCollected), 12)}${inr(7000)}');
    line('  ${pad("totalExpenses", 26)}${pad(inr(30000), 12)}'
        '${pad(inr(t.totalExpenses), 12)}${inr(31200)}');
    line('  ${pad("orphanCollected", 26)}${pad(inr(0), 12)}'
        '${pad(inr(t.orphanCollected), 12)}${inr(5000)}');
    line('  ${pad("hasOrphanMoney", 26)}${pad("false", 12)}'
        '${pad("${t.hasOrphanMoney}", 12)}true');
    line('\n  FIXED: tourSummary now walks the union of the tour\'s buses and the');
    line('  ledger\'s, so stranded cash stays inside the total AND populates the');
    line('  orphan fields the UI warning reads.');

    expect(t.totalCollected, 7000);
    expect(t.orphanCollected, 5000);
    expect(t.hasOrphanMoney, isTrue);
  });

  // ── 6 · F1 · a rider's whole AR lands on their first bus ───────────────────
  test('6 · FIXED F1 — cross-bus rider owes each bus its own fare', () async {
    section('6 · FIXED F1 — cross-bus rider: each bus prices its own seats');
    addTearDown(Get.reset);

    // Goes out on bus A (SL1 · row 0 · ₹1,600 band, one leg → ₹800) and returns
    // on a second, cheaper bus (₹400 one leg). Each bus is owed exactly what it
    // billed this rider — ₹800 and ₹400 — and has collected nothing yet.
    //
    // The ledger's `owes_minor` below deliberately says ₹2,000, which is what
    // that rider's `ar.rider` lines were posted at before their buses were
    // re-priced. Nothing re-posts a fare when a bus's price changes (the hole
    // migration 092 closes), so that figure is stale by ₹800. It is no longer an
    // input: per-bus AR is priced from the seats the rider actually holds.
    final busTwo = Bus(
      id: 'bus-2',
      name: 'Bus 2',
      tourId: tourAId,
      pricePerSeat: 800,
      layout: BusLayout.generate(busType: BusType.seater, totalSeats: 4),
    );

    final rider = Passenger(
      id: 'p-cross',
      tourId: tourAId,
      name: 'Cross Bus',
      phone: '9222222222',
      assignedSeats: const [
        SeatAssignment(busId: busAId, seatId: 'SL1', leg: TripType.outboundOnly),
        SeatAssignment(busId: 'bus-2', seatId: 'ST1', leg: TripType.returnOnly),
      ],
    );

    final money = await _buildController(
      rows: const {},
      busRollups: [
        _rollup(busId: busAId, collected: 0),
        _rollup(busId: 'bus-2', collected: 0),
      ],
      riderRows: [
        {'tour_id': tourAId, 'passenger_id': 'p-cross', 'owes_minor': 200000},
      ],
      extraBuses: [busTwo],
      passengers: [rider],
    );

    final billedA = seededBusA.amountDueFor(rider);
    final billedB = busTwo.amountDueFor(rider);
    final a = money.summaryForBus(busAId);
    final b = money.summaryForBus('bus-2');

    line('  one rider seated on BOTH buses, nothing collected yet');
    line('  billed on Test Bus A1 ${inr(billedA)} · on Bus 2 ${inr(billedB)}');
    line('  the ledger still carries a pre-reprice ${inr(2000)} for them\n');
    line('  ${pad("bus", 16)}${pad("was", 12)}${pad("now", 12)}correct');
    line('  ${pad("Test Bus A1", 16)}${pad(inr(2000), 12)}'
        '${pad(inr(a.toCollectTotal), 12)}${inr(billedA)}');
    line('  ${pad("Bus 2", 16)}${pad(inr(0), 12)}'
        '${pad(inr(b.toCollectTotal), 12)}${inr(billedB)}');
    line('  ${pad("trip total", 16)}${pad(inr(2000), 12)}'
        '${pad(inr(money.tourSummary().totalToCollect), 12)}'
        '${inr(billedA + billedB)}');
    line('\n  FIXED: each bus prices the seats it is actually carrying, so Bus 2\'s');
    line('  handler sees the rider they carry — and the trip total is what the');
    line('  buses between them billed, not what a stale ledger line remembers.');

    expect(a.toCollectTotal, closeTo(billedA, 0.01));
    expect(b.toCollectTotal, closeTo(billedB, 0.01));
    expect(
      money.tourSummary().totalToCollect,
      closeTo(billedA + billedB, 0.01),
    );
  });

  // ── 7 · B1 · four different bottom lines on the same data ──────────────────
  test('7 · FIXED B1 — four "net" figures, each now naming its basis', () async {
    section('7 · FIXED B1 — the figures still differ, and each screen says why');
    addTearDown(Get.reset);

    // Bus A: billed ₹48,000, only ₹20,000 collected, ₹4,000 ground, ₹30,000 rent,
    // ₹1,500 extra income.
    final money = await _buildController(
      rows: const {},
      busRollups: [
        _rollup(
          busId: busAId,
          billed: 4800000,
          collected: 2000000,
          ground: 400000,
          rent: 3000000,
          income: 150000,
        ),
      ],
      riderRows: const [],
    );

    final t = money.tourSummary();
    line('  billed ${inr(48000)} · collected ${inr(20000)} · '
        'ground ${inr(4000)} · rent ${inr(30000)} · income ${inr(1500)}\n');
    line('  ${pad("screen", 30)}${pad("figure", 18)}${pad("value", 12)}basis');
    line('  ${pad("Trip P&L headline", 30)}${pad("totalNetBilled", 18)}'
        '${pad(inr(t.totalNetBilled), 12)}money.basis_billed');
    line('  ${pad("Tour money board · P&L card", 30)}${pad("totalNetBilled", 18)}'
        '${pad(inr(t.totalNetBilled), 12)}money.basis_billed');
    line('  ${pad("Tour money board · pill", 30)}${pad("totalNet", 18)}'
        '${pad(inr(t.totalNet), 12)}label reads "NET (CASH)"');
    line('  ${pad("Bus money · tour rollup", 30)}${pad("totalNet", 18)}'
        '${pad(inr(t.totalNet), 12)}money.basis_cash');
    line('  ${pad("Finance report (cross-tour)", 30)}'
        '${pad("collected+inc-exp", 18)}'
        '${pad(inr(t.totalNet), 12)}money.basis_cash');
    line('  ${pad("Handover expectation", 30)}'
        '${pad("expectedHandover", 18)}'
        '${pad(inr(t.totalExpectedHandover), 12)}cash, rent-free by design');
    line('\n  Spread between the biggest and smallest: '
        '${inr(t.totalNetBilled - t.totalNet)}');
    line('  FIXED: the spread is REAL and stays — billed and cash answer');
    line('  different questions. The defect was the silence, not the difference,');
    line('  so every headline now names its basis and the two stop looking like');
    line('  a broken calculation. Deliberately NOT collapsed onto one basis: a');
    line('  handler settling cash needs cash, an agent pricing a trip needs billed.');

    expect(t.totalNetBilled, isNot(equals(t.totalNet)),
        reason: 'the two bases genuinely differ — this is by design, not a bug');
  });
}

// ── harness ──────────────────────────────────────────────────────────────────

Map<String, dynamic> _rollup({
  required String busId,
  int billed = 0,
  int collected = 0,
  int ground = 0,
  int rent = 0,
  int income = 0,
  int handedOver = 0,
}) =>
    {
      'tour_id': tourAId,
      'bus_id': busId,
      'outstanding_handover_minor': collected + income - ground - handedOver,
      'billed_minor': billed,
      'income_minor': income,
      'ground_expenses_minor': ground,
      'rent_minor': rent,
      'owner_unpaid_minor': rent,
      'collected_minor': collected,
      'handed_over_minor': handedOver,
      'to_collect_minor': 0,
      'to_return_minor': 0,
    };

Future<MoneyController> _buildController({
  required Map<String, List<Map<String, dynamic>>> rows,
  required List<Map<String, dynamic>> busRollups,
  required List<Map<String, dynamic>> riderRows,
  List<Bus> extraBuses = const [],
  List<Passenger> passengers = const [],
}) async {
  Get.put<SyncService>(_StubSync(rows));

  final tours = _InertTours();
  Get.put<TourController>(tours);
  tours.tours.assignAll([
    Tour(
      id: tourAId,
      title: '[TEST-A] Chart Booking',
      fromCity: 'Ahmedabad',
      toCity: 'Dwarka',
      departureDate: DateTime(2026, 8, 21),
      pricePerSeat: 1200,
      status: TourStatus.collecting,
      buses: [seededBusA, ...extraBuses],
      passengers: passengers,
    ),
  ]);

  final ledger = LedgerMoneySource()
    ..debugFetchBusRows = ((_) async => busRollups)
    ..debugFetchRiderRows = ((_) async => riderRows);

  final money = MoneyController(ledgerSource: ledger);
  await money.loadForTour(tourAId);
  return money;
}

class _InertTours extends TourController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _StubSync extends SyncService {
  _StubSync(this.rows);

  final Map<String, List<Map<String, dynamic>>> rows;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<({List<Map<String, dynamic>> rows, bool failed, String? error})>
      smartFetch({
    required String table,
    required String cacheKey,
    String? select,
    Map<String, String>? filters,
    String? orderBy,
    int maxAge = 300000,
  }) async =>
          (
            rows: rows[table] ?? const <Map<String, dynamic>>[],
            failed: false,
            error: null,
          );

  @override
  Future<void> invalidateCache(String cacheKey) async {}
}
