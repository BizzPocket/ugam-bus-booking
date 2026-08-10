// A customer's in-progress seat selection, across ONE OR MORE buses.
//
// Pure Dart — no Flutter, no I/O — so the arithmetic can be unit-tested.
//
// *** WHY THIS EXISTS ***
// The chart used to hold picks in a flat `Map<seatId, berths>` and CLEAR it on
// every bus-tab change, because `chart_claim_seats` takes a single `p_bus_id`.
// A party willing to travel on different buses could not express that: picking
// two berths on Bus A and then opening Bus B threw Bus A away.
//
// A seat id is only unique WITHIN a bus (every sleeper has a "DU1"), so the bus
// must be part of the key — the same reason `SeatAvailability.keyFor` composes
// busId with seatId.

/// Seats picked on one bus: `seatId -> berths taken of that cell`.
typedef BusPicks = Map<String, int>;

class ChartBasket {
  final Map<String, BusPicks> _byBus = {};

  /// Berths of [seatId] on [busId] currently in the basket. Zero when untouched.
  int berthsFor({required String busId, required String seatId}) =>
      _byBus[busId]?[seatId] ?? 0;

  /// Set how many berths of one cell are taken. Zero or less REMOVES the seat,
  /// and emptying a bus removes the bus — an empty bus must never reach the
  /// claim as "a bus with no seats", which the server would reject.
  void setBerths({
    required String busId,
    required String seatId,
    required int berths,
  }) {
    if (berths <= 0) {
      final picks = _byBus[busId];
      if (picks == null) return;
      picks.remove(seatId);
      if (picks.isEmpty) _byBus.remove(busId);
      return;
    }
    (_byBus[busId] ??= <String, int>{})[seatId] = berths;
  }

  /// Seats picked on [busId]. A COPY: handing out the live map would let a
  /// caller mutate the basket behind its own back, and the only thing that
  /// would catch the resulting oversell is the server.
  BusPicks forBus(String busId) => Map<String, int>.from(_byBus[busId] ?? {});

  /// Buses with at least one seat picked, in insertion order.
  List<String> get busIds => _byBus.keys.toList();

  /// Total people in the basket, across every bus.
  int get totalBerths => _byBus.values
      .expand((picks) => picks.values)
      .fold<int>(0, (sum, n) => sum + n);

  bool get isEmpty => _byBus.isEmpty;
  bool get isNotEmpty => !isEmpty;

  /// Whether checkout has to go through the MULTI-bus claim rather than the
  /// single-bus one. One bus keeps using migration 048's existing path.
  bool get spansMultipleBuses => _byBus.length > 1;

  void clearBus(String busId) => _byBus.remove(busId);

  void clear() => _byBus.clear();
}
