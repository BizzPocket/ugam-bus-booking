/// The Board's lens model — spec §5 of
/// `docs/superpowers/specs/2026-08-12-board-interaction-design.md`.
///
/// **A lens is not a screen. A lens is data.** Eleven screens exist today
/// because "the bus coloured by money" was built as a different screen from
/// "the bus coloured by who is aboard". Everything that actually differs
/// between those views is captured here as four small things:
///
///  1. a colour function — [BoardLens.paint], berth facts → (fill, ink, glyph),
///  2. a legend of at most [BoardLens.maxLegendEntries] entries, each of which
///     is also a *filter* predicate (spec §5: legend swatches filter),
///  3. the primary action of the passenger sheet ([BoardLens.primaryAction]),
///  4. the number the sticky summary strip shows ([BoardLens.stripMetric]).
///
/// Nothing in this file imports a widget, a controller or a repository, so the
/// whole thing is unit-testable: every colour function is a pure function of a
/// [BoardBerth] and a [UgamColorSet], and both are values you can construct in
/// a test.
///
/// Two rules the Board cannot break, encoded here rather than left to each
/// call site:
///
///  * **Colour is never the only signal** (spec §11). Every [BerthPaint]
///    carries a non-empty [BerthPaint.glyph]; there is no way to build one
///    without it.
///  * **Colour stops being distinguishable past five.** The pickup and group
///    lenses colour by an unbounded set (stops, groups), so they run through
///    [BoardTintScale], which tints the five biggest buckets and folds the rest
///    into one honest "other" entry.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';

import '../design/group_color.dart';
import '../design/tokens.dart';
import '../utils/formatters.dart';
import 'collection.dart';
import 'handler_phase.dart';

part 'board_lens_lenses.dart';
part 'board_lens_tint.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Berth facts — the input every colour function reads.
// ─────────────────────────────────────────────────────────────────────────────

/// Where one rider is in the boarding process for the leg on screen.
enum BerthBoarding {
  /// Ticked aboard.
  boarded,

  /// On the manifest, not yet aboard.
  expected,

  /// The bus left without them.
  noShow,
}

/// Who — if anyone — is in a berth. Derived, never stored.
enum BerthOccupancy { occupied, ladies, vacant, blocked }

/// What a berth owes. Derived from [BoardBerth.fareDue] / [BoardBerth.paid],
/// never stored.
///
/// The legend caps at three (spec §5), so an over-collected berth (the handler
/// owes change back) resolves to [paid] — there is nothing left to collect from
/// them — and carries its own glyph and semantic label instead of a fourth
/// colour. See [MoneyLens.paint].
enum BerthMoney {
  /// Square, or over-collected.
  paid,

  /// Some cash in, some still owed.
  half,

  /// Nothing in.
  due,

  /// Nobody there, or nothing to pay.
  none,
}

/// Everything the Board needs to know about ONE berth in order to paint it
/// under any lens.
///
/// Deliberately a flat value type with no `Passenger`, `Bus` or `Collection`
/// inside it. The mapping from those onto this belongs to whoever loads the
/// Board's data; keeping it out means the lenses stay pure and a test can build
/// a berth in one line.
@immutable
class BoardBerth {
  /// The berth code as printed on the coach — `DL3`, `12`, `U7`.
  final String code;

  /// True when somebody is assigned here. Kept explicit rather than inferred
  /// from [occupantName]: an anonymised seat (a stranger-share berth the agent
  /// has not de-anonymised) is occupied and has no name.
  final bool isOccupied;

  final String? occupantName;

  /// A lady is seated here — the app-wide rose treatment.
  final bool isLadies;

  /// Not sellable: a wheel arch, a broken berth, a held-back seat. Neither
  /// occupied nor available.
  final bool isBlocked;

  /// The LIVE fare for this berth (fares are per-bus, so this is recomputed,
  /// never the amount snapshotted when cash was taken).
  final double fareDue;

  /// Cash actually held for this berth, net of anything handed back.
  final double paid;

  final String? pickupStopId;
  final String? pickupStopName;

  final String? groupId;
  final String? groupName;

  final BerthBoarding boarding;

  /// "Double sofa", "Lower berth" — read out in the semantic label so a
  /// screen-reader user hears the same thing a sighted user sees in the tile
  /// shape.
  final String? seatTypeLabel;

  const BoardBerth({
    required this.code,
    this.isOccupied = false,
    this.occupantName,
    this.isLadies = false,
    this.isBlocked = false,
    this.fareDue = 0,
    this.paid = 0,
    this.pickupStopId,
    this.pickupStopName,
    this.groupId,
    this.groupName,
    this.boarding = BerthBoarding.expected,
    this.seatTypeLabel,
  });

  /// Sellable and free.
  bool get isVacant => !isOccupied && !isBlocked;

  BerthOccupancy get occupancy {
    if (isBlocked) return BerthOccupancy.blocked;
    if (!isOccupied) return BerthOccupancy.vacant;
    return isLadies ? BerthOccupancy.ladies : BerthOccupancy.occupied;
  }

  /// +ve = still owed by the rider. Never negative; see [changeOwed].
  double get outstanding {
    final gap = fareDue - paid;
    return gap > Collection.kMoneyEpsilon ? gap : 0;
  }

  /// +ve = the handler is holding money that belongs to the rider.
  double get changeOwed {
    final over = paid - fareDue;
    return over > Collection.kMoneyEpsilon ? over : 0;
  }

  BerthMoney get money {
    if (!isOccupied) return BerthMoney.none;
    // A comped / not-yet-priced berth. Rendering ₹0 everywhere is the failure
    // spec §13 calls out, so this reads as "nothing to collect", not "paid".
    if (fareDue <= Collection.kMoneyEpsilon && paid <= Collection.kMoneyEpsilon) {
      return BerthMoney.none;
    }
    if (outstanding == 0) return BerthMoney.paid;
    return paid > Collection.kMoneyEpsilon ? BerthMoney.half : BerthMoney.due;
  }

  BoardBerth copyWith({
    String? code,
    bool? isOccupied,
    String? occupantName,
    bool? isLadies,
    bool? isBlocked,
    double? fareDue,
    double? paid,
    String? pickupStopId,
    String? pickupStopName,
    String? groupId,
    String? groupName,
    BerthBoarding? boarding,
    String? seatTypeLabel,
  }) => BoardBerth(
    code: code ?? this.code,
    isOccupied: isOccupied ?? this.isOccupied,
    occupantName: occupantName ?? this.occupantName,
    isLadies: isLadies ?? this.isLadies,
    isBlocked: isBlocked ?? this.isBlocked,
    fareDue: fareDue ?? this.fareDue,
    paid: paid ?? this.paid,
    pickupStopId: pickupStopId ?? this.pickupStopId,
    pickupStopName: pickupStopName ?? this.pickupStopName,
    groupId: groupId ?? this.groupId,
    groupName: groupName ?? this.groupName,
    boarding: boarding ?? this.boarding,
    seatTypeLabel: seatTypeLabel ?? this.seatTypeLabel,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Paint — what a colour function returns.
// ─────────────────────────────────────────────────────────────────────────────

/// The three things a lens says about a berth: its fill, the ink that is
/// legible on that fill, and the glyph that carries the same meaning WITHOUT
/// colour (spec §11).
///
/// [glyph] is required and asserted non-empty on purpose: the accessibility
/// rule is enforced by the type, not by review.
@immutable
class BerthPaint {
  final Color fill;
  final Color ink;

  /// `✓` paid · `₹550` due · `½` part-paid · `—` empty · `●` boarded.
  final String glyph;

  const BerthPaint({
    required this.fill,
    required this.ink,
    required this.glyph,
  }) : assert(glyph != '', 'colour is never the only signal (spec §11)');

  @override
  bool operator ==(Object other) =>
      other is BerthPaint &&
      other.fill == fill &&
      other.ink == ink &&
      other.glyph == glyph;

  @override
  int get hashCode => Object.hash(fill, ink, glyph);

  @override
  String toString() => 'BerthPaint($glyph, fill: $fill, ink: $ink)';
}

/// One legend row — and, because a legend swatch IS the filter control
/// (spec §5), the predicate that decides which berths it selects.
@immutable
class BoardLegendEntry {
  /// Stable key for "which swatch is active" state and for tests. Never shown.
  final String id;

  /// Translated, user-facing.
  final String label;

  final Color swatch;
  final Color ink;
  final String glyph;

  /// True for the "+N other stops / groups" bucket, which the legend must
  /// render as visibly muted rather than as another equal colour.
  final bool isOther;

  final bool Function(BoardBerth berth) _selects;

  const BoardLegendEntry({
    required this.id,
    required this.label,
    required this.swatch,
    required this.ink,
    required this.glyph,
    required bool Function(BoardBerth berth) selects,
    this.isOther = false,
  }) : _selects = selects;

  /// Whether tapping this swatch keeps [berth] lit (everything else dims to
  /// 30%).
  bool selects(BoardBerth berth) => _selects(berth);

  @override
  String toString() => 'BoardLegendEntry($id)';
}

/// The passenger-sheet primary action a lens puts under the thumb.
enum BoardAction {
  call,
  collect,
  move,
  checkIn;

  String get label => switch (this) {
        BoardAction.call => tr('board_lens.action_call'),
        BoardAction.collect => tr('board_lens.action_collect'),
        BoardAction.move => tr('board_lens.action_move'),
        BoardAction.checkIn => tr('board_lens.action_check_in'),
      };
}

/// Which number the sticky summary strip pins at the top (spec §3). The strip
/// formats it; the lens only decides which one it is.
enum BoardStripMetric {
  /// `73/74 · 1 ખાલી`
  seatsFilled,

  /// `₹55,200 બાકી · 32% એકઠી`
  moneyOutstanding,

  /// `18/22 અડાજણ`
  stopProgress,

  /// `12 ગ્રુપ · 3 વિભાજિત`
  groupSpread,

  /// `52/60 ચડ્યા`
  boardedCount,
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase-driven default (spec §6).
// ─────────────────────────────────────────────────────────────────────────────

/// The lens the Board OPENS on, given where the bus is in its trip.
///
/// Spec §6: *planning/filling → Occupancy · pre-departure (T-2d) → Money ·
/// departure day → Boarding · in transit → Pickup · settling → Money.*
///
/// [HandlerPhase] starts at [HandlerPhase.boardingGo] — it models the trip from
/// the depot onwards and has no value for "still filling the bus", because the
/// four timestamps it derives from are all null until the handler stamps the
/// first one. Two extra inputs bridge that gap without touching the enum:
///
///  * [phase] `null` — no trip state at all, i.e. the bus is still being
///    filled. Occupancy, unless [daysUntilDeparture] says the T-2d money chase
///    has started.
///  * [daysUntilDeparture] — the one thing the phase cannot express: an
///    un-stamped bus two days out is *pre-departure* (Money), the same bus on
///    the morning itself is *departure day* (Boarding). Pass null when unknown
///    and boardingGo is treated as departure day, which is the safer default
///    (a handler holding the phone at the pickup point is counting heads).
///
/// [available] narrows the answer to the lenses actually wired to data —
/// pass [kShippedBoardLenses] during the staged build so the Board never opens
/// on a lens that has no data source yet. Anything unavailable falls back to
/// Occupancy, the only lens that needs nothing but the seat plan.
BoardLensId defaultLensForPhase(
  HandlerPhase? phase, {
  int? daysUntilDeparture,
  Set<BoardLensId> available = const {
    BoardLensId.occupancy,
    BoardLensId.money,
    BoardLensId.pickup,
    BoardLensId.group,
    BoardLensId.boarding,
  },
}) {
  assert(available.isNotEmpty, 'the Board must have at least one lens');

  final preDeparture = daysUntilDeparture != null && daysUntilDeparture > 0;

  BoardLensId wanted;
  switch (phase) {
    case null:
      // Filling the bus. Once the T-2d window opens, balances are the job.
      wanted = (daysUntilDeparture != null && daysUntilDeparture <= 2)
          ? BoardLensId.money
          : BoardLensId.occupancy;
    case HandlerPhase.boardingGo:
    case HandlerPhase.boardingRet:
      wanted = preDeparture ? BoardLensId.money : BoardLensId.boarding;
    case HandlerPhase.enRouteGo:
    case HandlerPhase.enRouteRet:
      wanted = BoardLensId.pickup;
    case HandlerPhase.settling:
      wanted = BoardLensId.money;
    case HandlerPhase.closed:
      // Books square, read-only. Nothing left to chase, so the honest opening
      // view is the roster of who was aboard.
      wanted = BoardLensId.occupancy;
  }

  if (available.contains(wanted)) return wanted;
  if (available.contains(BoardLensId.occupancy)) return BoardLensId.occupancy;
  return available.first;
}

/// The lens to show right now.
///
/// Spec §6: *"the user can always switch; this only sets the default. Never
/// override an explicit manual choice within the same session."* [manualChoice]
/// is that session choice — once it is non-null the phase stops deciding, and
/// this one line is the whole rule, so no screen can re-derive the default on a
/// rebuild and yank the lens out from under the handler.
BoardLensId resolveBoardLens({
  required HandlerPhase? phase,
  BoardLensId? manualChoice,
  int? daysUntilDeparture,
  Set<BoardLensId> available = const {
    BoardLensId.occupancy,
    BoardLensId.money,
    BoardLensId.pickup,
    BoardLensId.group,
    BoardLensId.boarding,
  },
}) {
  if (manualChoice != null && available.contains(manualChoice)) {
    return manualChoice;
  }
  return defaultLensForPhase(
    phase,
    daysUntilDeparture: daysUntilDeparture,
    available: available,
  );
}
