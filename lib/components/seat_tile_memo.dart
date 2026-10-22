import 'package:flutter/widgets.dart';

/// PERF: per-seat memo of a built seat-tile subtree.
///
/// A seat tap or realtime event hands a chart a fresh [Tour], which used to
/// rebuild every tile on the bus (19-74 of them, each running
/// `resolveSeatRender` plus name layout). The controller keeps unchanged
/// passengers, cells and group lists as the SAME instances across an update,
/// so a tile whose key parts are all [identical] to last time is returned as
/// the same widget instance and Flutter skips its whole subtree.
///
/// Correctness rule for callers: the key must list EVERY input the built tile
/// reads (cell, each occupant instance, selection flags, palette/theme, and any
/// object its callbacks capture). Identity, never `==` — the models' `==` is
/// id-only and would serve a stale tile. Owned by a State so it outlives
/// rebuilds; bounded by the number of seat ids it has seen.
class SeatTileMemo {
  final Map<String, (List<Object?>, Widget)> _bySeat = {};

  Widget tile(String seatId, List<Object?> key, Widget Function() build) {
    final hit = _bySeat[seatId];
    if (hit != null && _same(hit.$1, key)) return hit.$2;
    final w = build();
    _bySeat[seatId] = (key, w);
    return w;
  }

  static bool _same(List<Object?> a, List<Object?> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }
}
