import 'dart:math';

/// Seeded generators that produce SERVER-SHAPED rows — the exact map shape
/// PostgREST hands back — rather than hand-written fixtures.
///
/// Everything is driven by a seeded [Random], so a failure is reproducible:
/// the tests print the seed, and re-running with that seed replays the exact
/// same rows. That is the whole point of fuzzing here — these tests are
/// deliberately NOT modelled on what the app currently does, so they can
/// reach shapes no hand-written fixture would think to try.
class RowGen {
  final Random _r;
  final int seed;

  RowGen(this.seed) : _r = Random(seed);

  // ── primitives ────────────────────────────────────────────────────────
  bool boolean() => _r.nextBool();
  int intIn(int min, int max) => min + _r.nextInt(max - min + 1);
  T pick<T>(List<T> xs) => xs[_r.nextInt(xs.length)];
  T? maybe<T>(T value, {double nullChance = 0.3}) =>
      _r.nextDouble() < nullChance ? null : value;

  String uuid() {
    String h(int n) =>
        List.generate(n, (_) => '0123456789abcdef'[_r.nextInt(16)]).join();
    return '${h(8)}-${h(4)}-${h(4)}-${h(4)}-${h(12)}';
  }

  /// Names deliberately include scripts and widths the app will really see —
  /// Gujarati, Hindi, emoji, RTL marks, and a very long name — because the
  /// roster is typed by hand on a phone.
  String personName() => pick([
        'Ramesh Patel',
        'રમેશ પટેલ',
        'रमेश पटेल',
        "O'Brien-Shah",
        'A',
        'Ramesh  ' * 20,
        '  leading and trailing  ',
        'Name\nwith\nnewlines',
        'emoji 🚌 rider',
        // Bidi override, built from code points so no invisible control
        // character ever sits in this source file.
        '${String.fromCharCode(0x202E)}reversed${String.fromCharCode(0x202C)}',
        '',
      ]);

  String phone() => pick([
        '+919876543210',
        '9876543210',
        '+91 98765 43210',
        '098765-43210',
        '+9198765432100000',
        '',
      ]);

  String isoDate() {
    final d = DateTime.utc(2026, 1, 1).add(Duration(hours: _r.nextInt(20000)));
    return d.toIso8601String();
  }

  // ── nested JSONB ──────────────────────────────────────────────────────
  Map<String, dynamic> seatAssignment() => {
        'busId': uuid(),
        'seatId': pick(['A1', 'DL3', 'S12', 'DU7', 'seat with space', '']),
        if (boolean()) 'locked': true,
        if (boolean()) 'leg': pick(['roundTrip', 'outboundOnly', 'returnOnly']),
      };

  List<Map<String, dynamic>> assignedSeats() =>
      List.generate(_r.nextInt(5), (_) => seatAssignment());

  Map<String, dynamic> requestLine() => {
        'seatType': pick(['singleSofa', 'doubleSofa', 'seater']),
        'position': maybe(pick(['upper', 'lower'])),
        'qty': intIn(0, 12),
        if (boolean())
          'leg': pick(['roundTrip', 'outboundOnly', 'returnOnly']),
      };

  List<Map<String, dynamic>> requestLines() =>
      List.generate(1 + _r.nextInt(3), (_) => requestLine());

  // ── a full passengers row, exactly as PostgREST returns it ────────────
  Map<String, dynamic> passengerRow() => {
        'id': uuid(),
        'tour_id': uuid(),
        'user_id': maybe(uuid()),
        'name': personName(),
        'phone': phone(),
        'age_group': pick(['child', 'adult', 'senior']),
        'request_lines': requestLines(),
        'assigned_seats': assignedSeats(),
        'payment_status': pick(['paid', 'notPaid']),
        'is_handler': boolean(),
        'is_waitlisted': boolean(),
        'is_confirmed': boolean(),
        'note': maybe(pick(['window seat', 'ને લખો', 'x' * 500])),
        'trip_type': pick(['roundTrip', 'outboundOnly', 'returnOnly']),
        'group_id': maybe(uuid()),
        'priority_status': pick(['none', 'requested', 'approved', 'declined']),
        'priority_reason': maybe('elderly parents'),
        'journey_done': boolean(),
        'pickup_location_id': maybe(uuid()),
        'pickup_location_name': maybe('Paldi Cross Roads'),
        'cancelled_at': maybe(isoDate(), nullChance: 0.85),
        'cancel_requested_at': maybe(isoDate(), nullChance: 0.85),
        'seats_notified_sig': maybe('sig-${intIn(1, 9999)}'),
        'created_at': isoDate(),
      };

  /// Values a column might hold if the server, a migration, or a hand-edit
  /// put something unexpected there. Used to prove parsing degrades instead
  /// of throwing into the UI.
  Object? hostileValue() => pick<Object?>([
        null,
        '',
        'true',
        'false',
        0,
        1,
        -1,
        3.14,
        9223372036854775807,
        'not-a-date',
        '2026-13-45T99:99:99Z',
        <String, dynamic>{},
        <dynamic>[],
        [1, 2, 3],
        {'unexpected': 'object'},
        'null',
        '   ',
        '🚌',
      ]);
}
