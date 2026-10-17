part of '../tour_controller.dart';

/// Memoized capacity / seat-meter reads for the dashboard and charts.
mixin _TourCapacity on _TourControllerBase {
  /// Memoization cache for [capacityFor]: the last [computeTourCapacity] result
  /// per tourId, paired with the cheap content signature it was computed for.
  /// Plain (non-reactive) map — capacity is a pure function of `tours`, so any
  /// observer already rebuilds via `tours.refresh()`; this only avoids re-running
  /// the engine on each of those rebuilds. Survives until the tour's signature
  /// changes (recompute) or the controller is disposed.
  final _capacityCache = <String, ({int sig, TourCapacity capacity})>{};

  /// Memoized [computeTourCapacity] for [t].
  ///
  /// [computeTourCapacity] runs the full [SeatingEngine.propose] — expensive, and
  /// the dashboard calls it once per tour on every `tours.refresh()` (each seat
  /// tap, each realtime event). This caches the result keyed by [t.id] + a cheap
  /// [_capacitySignature] that flips whenever anything the engine reads changes
  /// (buses, passengers, seats, status). A cache hit returns the prior snapshot
  /// untouched; a miss (first call, or any signature change) recomputes and
  /// stores. Same semantics as calling [computeTourCapacity] directly — only the
  /// redundant recomputes are removed.
  ///
  /// Correctness-first: the signature folds every field [computeTourCapacity]
  /// reads, so when in doubt it recomputes rather than serve a stale snapshot.
  /// Pass the SAME [Tour] instance the UI holds (e.g. from [getTour] / the
  /// `tours` list) so the signature reflects the live state being rendered.
  TourCapacity capacityFor(Tour t) {
    final sig = _capacitySignature(t);
    final hit = _capacityCache[t.id];
    if (hit != null && hit.sig == sig) return hit.capacity;
    final capacity = computeTourCapacity(t);
    _capacityCache[t.id] = (sig: sig, capacity: capacity);
    return capacity;
  }

  /// Memoization cache for [actualCapacityFor], mirroring [_capacityCache].
  final _actualCapacityCache =
      <String, ({int sig, ActualCapacity capacity})>{};

  /// Memoized [computeActualCapacity] for [t].
  ///
  /// Cheaper than [capacityFor] — it never runs the engine — but far from free:
  /// it walks every bus grid and every passenger's seats, and the surfaces that
  /// want it (the tour-overview meter, each bus row, the seat-assignment leg
  /// meter) sit inside `Obx` blocks that rebuild on every seat tap and every
  /// realtime event. Sharing [_capacitySignature] is safe because that
  /// fingerprint already folds a strict SUPERSET of what
  /// [computeActualCapacity] reads: bus grids, legacy seat counts, and each
  /// passenger's assigned seats and legs.
  ActualCapacity actualCapacityFor(Tour t) {
    final sig = _capacitySignature(t);
    final hit = _actualCapacityCache[t.id];
    if (hit != null && hit.sig == sig) return hit.capacity;
    final capacity = computeActualCapacity(t);
    _actualCapacityCache[t.id] = (sig: sig, capacity: capacity);
    return capacity;
  }

  /// THE seat meter for [t] — the one "x / n" every admin surface shows. Built
  /// from the two memoized snapshots above, so it costs nothing extra once
  /// either has been read this frame. See [SeatMeter].
  SeatMeter seatMeterFor(Tour t) => computeSeatMeter(
        t,
        plan: capacityFor(t),
        actual: actualCapacityFor(t),
      );

  /// True once every bus on [tourId] has had its `layout` jsonb resolved —
  /// fetched, or confirmed absent on the server.
  ///
  /// Cold start ships buses WITHOUT their grids, so `bus.layout == null` is
  /// ambiguous on its own: it means EITHER "still loading" or "this bus genuinely
  /// has no seat map". Surfaces that would otherwise render a hard, wrong
  /// conclusion from that null — an empty seat chart, or a capacity-shortfall
  /// banner claiming riders will not fit when the engine simply has no grid to
  /// place them on — gate on this instead.
  bool layoutsLoadedFor(String tourId) {
    final tour = getTour(tourId);
    if (tour == null) return false;
    return tour.buses.every((b) => _layoutFetchedBusIds.contains(b.id));
  }

  /// Cheap structural fingerprint of every input [computeTourCapacity] reads —
  /// computed WITHOUT running the engine, so it's safe to evaluate on each
  /// rebuild. Folds the tour status plus, per bus, its id and seat-grid
  /// (seatId + seatType) and, per passenger, the fields that move the plan:
  /// assigned seats, request-line seat-types + legs (drives leg-aware free), the
  /// waitlist / journeyDone flags the engine + decision filter gate on, and the
  /// priorityStatus the engine gates lower-berth / ordering placement on.
  /// Order-stable (we fold list order, which the engine preserves). A collision
  /// would have to match all of these while changing the plan — astronomically
  /// unlikely, and a stale read self-heals on the next genuine change.
  int _capacitySignature(Tour t) {
    var h = t.status.index;
    for (final b in t.buses) {
      // totalSeatsLegacy is folded because capacity now FALLS BACK to it for a
      // bus with no usable grid (see [busBerths]). Without it, a bus whose
      // layout jsonb arrives mid-session — grid empty, then 37 seats — could
      // keep serving the memoized snapshot taken while it read as empty.
      h = Object.hash(h, b.id, b.totalSeatsLegacy);
      for (final cell in b.layout?.grid ?? const []) {
        // cell.reserved is folded because computeTourCapacity subtracts held
        // berths and skips reserved cells — without it, toggling a seat to
        // reserved/held left the memoized capacity (dashboard hero meter + the
        // "needs decision" badge) stale until some unrelated change bumped the
        // signature. position is already encoded in seatId (DL vs DU).
        h = Object.hash(h, cell.seatId, cell.seatType, cell.reserved);
      }
    }
    for (final p in t.passengers) {
      // priorityStatus is folded in because the engine gates placement on
      // isPriorityApproved (lower-berth reservation, seating order) — a
      // priority-only change moves the plan, so it must invalidate the cache or
      // the "N need your decision" badge goes stale. priorityReason is NOT
      // folded: the engine never reads it, so a reason edit shouldn't recompute.
      h = Object.hash(h, p.id, p.isWaitlisted, p.journeyDone, p.priorityStatus);
      for (final a in p.assignedSeats) {
        // a.leg is folded because capacity counts per seat via a.leg ?? the
        // coarse leg; a leg change (e.g. a request-leg edit re-stamp) with the
        // same seatId must invalidate the memoized capacity.
        h = Object.hash(h, a.busId, a.seatId, a.leg);
      }
      for (final l in p.requestLines) {
        h = Object.hash(h, l.seatType, l.leg, l.qty);
      }
    }
    return h;
  }
}
