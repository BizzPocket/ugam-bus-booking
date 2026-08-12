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

  String get label {
    switch (this) {
      case BoardAction.call:
        return tr('board_lens.action_call');
      case BoardAction.collect:
        return tr('board_lens.action_collect');
      case BoardAction.move:
        return tr('board_lens.action_move');
      case BoardAction.checkIn:
        return tr('board_lens.action_check_in');
    }
  }
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
// The five-tint cap.
// ─────────────────────────────────────────────────────────────────────────────

/// One candidate bucket for a tinted lens, before ranking.
@immutable
class BoardTintSeed {
  final String id;

  /// Already translated / already the stop's or group's own name.
  final String label;

  /// How many berths fall in this bucket. Buckets with none are dropped —
  /// "never render a legend for berths that do not exist" (spec §13).
  final int count;

  const BoardTintSeed({
    required this.id,
    required this.label,
    required this.count,
  });
}

/// A ranked bucket that won a tint.
@immutable
class BoardTintBucket {
  final String id;
  final String label;
  final int count;

  /// 0-4. Feeds [BoardTintScale.colorOf].
  final int tintIndex;

  const BoardTintBucket({
    required this.id,
    required this.label,
    required this.count,
    required this.tintIndex,
  });
}

/// The pickup / group lens's colour budget.
///
/// Past five fills the eye cannot rank colours reliably, so a tour with nine
/// pickup points does NOT get nine tints — it gets the five biggest and one
/// grey "other" bucket that says how many it stands for (spec §5). This class
/// is the whole of that rule, kept pure so the cap is provable in a test rather
/// than an intention in a widget.
@immutable
class BoardTintScale {
  /// Five. See the class doc — this is not a tunable.
  static const int maxTints = 5;

  /// The tinted buckets, biggest first, `tintIndex` 0-4.
  final List<BoardTintBucket> tinted;

  /// How many distinct buckets were folded into "other".
  final int otherBuckets;

  /// How many berths those folded buckets hold.
  final int otherBerths;

  const BoardTintScale._({
    required this.tinted,
    required this.otherBuckets,
    required this.otherBerths,
  });

  /// Nothing to tint — every occupied berth lands in "other". The state a
  /// pickup lens is in before any stop is configured.
  static const BoardTintScale empty = BoardTintScale._(
    tinted: <BoardTintBucket>[],
    otherBuckets: 0,
    otherBerths: 0,
  );

  /// Ranks [seeds] by berth count and keeps the top [maxTints].
  ///
  /// Ties break by the order [seeds] arrived in, which for pickups is the
  /// admin's route order — so two equal-sized stops always tint in the order
  /// the bus visits them, and the same tour never re-colours itself between
  /// two loads. (`List.sort` is not stable, hence the explicit index
  /// tiebreak.)
  factory BoardTintScale.fromSeeds(Iterable<BoardTintSeed> seeds) {
    final present = <(int, BoardTintSeed)>[];
    var i = 0;
    for (final s in seeds) {
      if (s.count > 0) present.add((i, s));
      i++;
    }
    present.sort((a, b) {
      final byCount = b.$2.count.compareTo(a.$2.count);
      return byCount != 0 ? byCount : a.$1.compareTo(b.$1);
    });

    final tinted = <BoardTintBucket>[];
    var otherBuckets = 0;
    var otherBerths = 0;
    for (var rank = 0; rank < present.length; rank++) {
      final seed = present[rank].$2;
      if (rank < maxTints) {
        tinted.add(
          BoardTintBucket(
            id: seed.id,
            label: seed.label,
            count: seed.count,
            tintIndex: rank,
          ),
        );
      } else {
        otherBuckets++;
        otherBerths += seed.count;
      }
    }

    return BoardTintScale._(
      tinted: List.unmodifiable(tinted),
      otherBuckets: otherBuckets,
      otherBerths: otherBerths,
    );
  }

  bool get hasOther => otherBuckets > 0;

  bool get isEmpty => tinted.isEmpty && !hasOther;

  /// The tint slot for [id], or null when it belongs in "other" (including a
  /// berth with no stop / no group at all).
  int? tintIndexOf(String? id) {
    if (id == null) return null;
    for (final b in tinted) {
      if (b.id == id) return b.tintIndex;
    }
    return null;
  }

  String? labelOf(String? id) {
    if (id == null) return null;
    for (final b in tinted) {
      if (b.id == id) return b.label;
    }
    return null;
  }

  /// The app's one unbounded, collision-avoiding tint generator
  /// (`lib/design/group_color.dart`) — the same hues seat charts already ring
  /// groups with, so a stop tint can never be mistaken for the amber "yours"
  /// accent or the GO/RET one-way tints.
  Color colorOf(int tintIndex) => groupColor(tintIndex);
}

/// Non-colour identifiers for the five tint slots. Letters, not digits, so a
/// tint marker is never misread as part of a berth code like `DL3`.
const List<String> kTintGlyphs = <String>['A', 'B', 'C', 'D', 'E'];

/// The "other" bucket's glyph.
const String kOtherGlyph = '+';

/// An occupied berth with no stop / no group at all.
const String kUnbucketedGlyph = '·';

/// Alpha the tinted lenses paint a generated hue at. Defined ONCE: the
/// semantic colours ship paired `…Fill` tokens for exactly this reason, and a
/// generated hue has no such pair, so this is the single place the pairing is
/// invented rather than drifting per call site. Low enough that
/// [UgamColorSet.ink] stays AA-legible on top in both themes.
const double kTintFillAlpha = 0.22;

// ─────────────────────────────────────────────────────────────────────────────
// The lenses.
// ─────────────────────────────────────────────────────────────────────────────

enum BoardLensId {
  occupancy,
  money,
  pickup,
  group,
  boarding;

  String get label {
    switch (this) {
      case BoardLensId.occupancy:
        return tr('board_lens.name_occupancy');
      case BoardLensId.money:
        return tr('board_lens.name_money');
      case BoardLensId.pickup:
        return tr('board_lens.name_pickup');
      case BoardLensId.group:
        return tr('board_lens.name_group');
      case BoardLensId.boarding:
        return tr('board_lens.name_boarding');
    }
  }
}

/// The lenses wired to real data in this build wave (spec §15 steps 1 and 3).
/// The other three are modelled in full so the shape is proven against every
/// case, but the switcher should not offer them until their data source lands.
const Set<BoardLensId> kShippedBoardLenses = <BoardLensId>{
  BoardLensId.occupancy,
  BoardLensId.money,
};

/// A lens: colour function + legend + primary action + strip metric.
@immutable
abstract class BoardLens {
  const BoardLens();

  /// Builds the lens for [id]. [tints] is required in practice by the pickup
  /// and group lenses; passing none leaves every berth in their "other"
  /// bucket, which is the honest rendering of "no stops configured yet".
  factory BoardLens.of(
    BoardLensId id, {
    BoardTintScale tints = BoardTintScale.empty,
  }) {
    switch (id) {
      case BoardLensId.occupancy:
        return const OccupancyLens();
      case BoardLensId.money:
        return const MoneyLens();
      case BoardLensId.pickup:
        return PickupLens(tints);
      case BoardLensId.group:
        return GroupLens(tints);
      case BoardLensId.boarding:
        return const BoardingLens();
    }
  }

  BoardLensId get id;

  String get label => id.label;

  /// The colour function. Pure: same berth + same palette → same paint.
  BerthPaint paint(BoardBerth berth, UgamColorSet colors);

  /// Every legend row this lens can show, in reading order.
  ///
  /// Never longer than [maxLegendEntries]; use [legendFor] to drop rows no
  /// berth on this bus actually matches.
  List<BoardLegendEntry> legend(UgamColorSet colors);

  /// Three for the fixed lenses (spec §5). Six for the tinted ones: five tints
  /// plus the "other" bucket.
  int get maxLegendEntries => 3;

  /// The legend with rows nothing matches removed — "never render a legend for
  /// berths that do not exist" (spec §13).
  List<BoardLegendEntry> legendFor(
    Iterable<BoardBerth> berths,
    UgamColorSet colors,
  ) {
    final list = berths.toList(growable: false);
    return legend(
      colors,
    ).where((e) => list.any(e.selects)).toList(growable: false);
  }

  /// What the passenger sheet's primary button does under this lens.
  BoardAction get primaryAction;

  /// The number the sticky strip pins at the top.
  BoardStripMetric get stripMetric;

  /// Whether "next outstanding →" (spec §4) should stop on this berth. This is
  /// what turns the Board into a walking order instead of a picture: the
  /// control advances to the next berth in aisle order for which this is true.
  bool needsAction(BoardBerth berth);

  /// The lens's word for this berth's state — the middle of the semantic
  /// label, and the phrase the legend echoes.
  String stateLabel(BoardBerth berth);

  /// Spec §11: *"DL3, Priti Patel, paid, double sofa, boarding at Adajan"* —
  /// never just "DL3".
  String semanticLabel(BoardBerth berth) {
    final name = berth.occupantName?.trim();
    final type = berth.seatTypeLabel?.trim();
    final stop = berth.pickupStopName?.trim();
    return <String>[
      berth.code,
      if (name != null && name.isNotEmpty) name,
      stateLabel(berth),
      if (type != null && type.isNotEmpty) type,
      if (stop != null && stop.isNotEmpty)
        tr('board_lens.a11y_at_stop', namedArgs: {'stop': stop}),
    ].join(', ');
  }

  /// A vacant / blocked berth looks the same under every lens: a hole in the
  /// chart, not a state of the thing the lens is about.
  @protected
  BerthPaint? emptyPaint(BoardBerth berth, UgamColorSet colors) {
    if (berth.isBlocked) {
      return BerthPaint(fill: colors.card, ink: colors.ink3, glyph: '✕');
    }
    if (!berth.isOccupied) {
      return BerthPaint(fill: colors.bg, ink: colors.ink3, glyph: '—');
    }
    return null;
  }

  /// Shared guard so no lens can quietly grow a fourth colour.
  @protected
  List<BoardLegendEntry> checked(List<BoardLegendEntry> entries) {
    assert(
      entries.length <= maxLegendEntries,
      '${id.name} legend has ${entries.length} entries; '
      'the cap is $maxLegendEntries (spec §5)',
    );
    return List.unmodifiable(entries);
  }
}

/// બેઠક — who is aboard. The lens you place people with.
@immutable
class OccupancyLens extends BoardLens {
  const OccupancyLens();

  @override
  BoardLensId get id => BoardLensId.occupancy;

  @override
  BoardAction get primaryAction => BoardAction.call;

  @override
  BoardStripMetric get stripMetric => BoardStripMetric.seatsFilled;

  @override
  BerthPaint paint(BoardBerth berth, UgamColorSet colors) {
    switch (berth.occupancy) {
      case BerthOccupancy.blocked:
        return BerthPaint(fill: colors.card, ink: colors.ink3, glyph: '✕');
      case BerthOccupancy.vacant:
        return BerthPaint(fill: colors.bg, ink: colors.ink3, glyph: '—');
      case BerthOccupancy.ladies:
        return BerthPaint(
          fill: colors.warmFill,
          ink: colors.warm,
          glyph: '♀',
        );
      case BerthOccupancy.occupied:
        return BerthPaint(fill: colors.cardElev, ink: colors.ink, glyph: '●');
    }
  }

  @override
  List<BoardLegendEntry> legend(UgamColorSet colors) => checked([
    BoardLegendEntry(
      id: 'occupied',
      label: tr('board_lens.state_occupied'),
      swatch: colors.cardElev,
      ink: colors.ink,
      glyph: '●',
      selects: (b) => b.occupancy == BerthOccupancy.occupied,
    ),
    BoardLegendEntry(
      id: 'ladies',
      label: tr('board_lens.state_ladies'),
      swatch: colors.warmFill,
      ink: colors.warm,
      glyph: '♀',
      selects: (b) => b.occupancy == BerthOccupancy.ladies,
    ),
    BoardLegendEntry(
      id: 'empty',
      label: tr('board_lens.state_empty'),
      swatch: colors.bg,
      ink: colors.ink3,
      glyph: '—',
      selects: (b) => b.occupancy == BerthOccupancy.vacant,
    ),
  ]);

  /// "Next empty berth" — the assignment walk of spec §4.
  @override
  bool needsAction(BoardBerth berth) => berth.isVacant;

  @override
  String stateLabel(BoardBerth berth) {
    switch (berth.occupancy) {
      case BerthOccupancy.blocked:
        return tr('board_lens.state_blocked');
      case BerthOccupancy.vacant:
        return tr('board_lens.state_empty');
      case BerthOccupancy.ladies:
        return tr('board_lens.state_ladies');
      case BerthOccupancy.occupied:
        return tr('board_lens.state_occupied');
    }
  }
}

/// પૈસા — what is still owed. The lens a handler walks the aisle with.
@immutable
class MoneyLens extends BoardLens {
  const MoneyLens();

  @override
  BoardLensId get id => BoardLensId.money;

  @override
  BoardAction get primaryAction => BoardAction.collect;

  @override
  BoardStripMetric get stripMetric => BoardStripMetric.moneyOutstanding;

  @override
  BerthPaint paint(BoardBerth berth, UgamColorSet colors) {
    final empty = emptyPaint(berth, colors);
    if (empty != null) return empty;

    switch (berth.money) {
      case BerthMoney.none:
        // Occupied, nothing to pay. Not a money state — a hole in this lens.
        return BerthPaint(fill: colors.card, ink: colors.ink3, glyph: '—');
      case BerthMoney.paid:
        // Over-collected folds in here (nothing left to COLLECT), but the
        // glyph says the handler is holding their change — the fourth state
        // the three-colour legend cannot afford, carried without colour.
        return BerthPaint(
          fill: colors.goodFill,
          ink: colors.good,
          glyph: berth.changeOwed > 0 ? '↩' : '✓',
        );
      case BerthMoney.half:
        return BerthPaint(
          fill: colors.warmFill,
          ink: colors.warm,
          glyph: '½',
        );
      case BerthMoney.due:
        // The amount IS the glyph (spec §11: `₹550` due). Compact, because it
        // has to survive a 20pt compact tile.
        return BerthPaint(
          fill: colors.dangerFill,
          ink: colors.danger,
          glyph: Formatters.formatMoneyInrCompact(berth.outstanding),
        );
    }
  }

  @override
  List<BoardLegendEntry> legend(UgamColorSet colors) => checked([
    BoardLegendEntry(
      id: 'paid',
      label: tr('board_lens.state_paid'),
      swatch: colors.goodFill,
      ink: colors.good,
      glyph: '✓',
      selects: (b) => b.money == BerthMoney.paid,
    ),
    BoardLegendEntry(
      id: 'half',
      label: tr('board_lens.state_half'),
      swatch: colors.warmFill,
      ink: colors.warm,
      glyph: '½',
      selects: (b) => b.money == BerthMoney.half,
    ),
    BoardLegendEntry(
      id: 'due',
      label: tr('board_lens.state_due'),
      swatch: colors.dangerFill,
      ink: colors.danger,
      glyph: '₹',
      selects: (b) => b.money == BerthMoney.due,
    ),
  ]);

  /// "આગળનું બાકી →" — anyone still holding money back.
  @override
  bool needsAction(BoardBerth berth) =>
      berth.money == BerthMoney.due || berth.money == BerthMoney.half;

  @override
  String stateLabel(BoardBerth berth) {
    if (!berth.isOccupied) {
      return berth.isBlocked
          ? tr('board_lens.state_blocked')
          : tr('board_lens.state_empty');
    }
    switch (berth.money) {
      case BerthMoney.none:
        return tr('board_lens.state_no_fare');
      case BerthMoney.paid:
        return berth.changeOwed > 0
            ? tr(
                'board_lens.state_change_owed',
                namedArgs: {
                  'amount': Formatters.formatMoneyInr(berth.changeOwed),
                },
              )
            : tr('board_lens.state_paid');
      case BerthMoney.half:
        return tr(
          'board_lens.state_half_amount',
          namedArgs: {
            'amount': Formatters.formatMoneyInr(berth.outstanding),
          },
        );
      case BerthMoney.due:
        return tr(
          'board_lens.state_due_amount',
          namedArgs: {
            'amount': Formatters.formatMoneyInr(berth.outstanding),
          },
        );
    }
  }
}

/// બોર્ડિંગ — heads counted. The lens of departure morning.
@immutable
class BoardingLens extends BoardLens {
  const BoardingLens();

  @override
  BoardLensId get id => BoardLensId.boarding;

  @override
  BoardAction get primaryAction => BoardAction.checkIn;

  @override
  BoardStripMetric get stripMetric => BoardStripMetric.boardedCount;

  @override
  BerthPaint paint(BoardBerth berth, UgamColorSet colors) {
    final empty = emptyPaint(berth, colors);
    if (empty != null) return empty;

    switch (berth.boarding) {
      case BerthBoarding.boarded:
        return BerthPaint(fill: colors.goodFill, ink: colors.good, glyph: '●');
      case BerthBoarding.expected:
        return BerthPaint(fill: colors.cardElev, ink: colors.ink2, glyph: '○');
      case BerthBoarding.noShow:
        return BerthPaint(
          fill: colors.dangerFill,
          ink: colors.danger,
          glyph: '✕',
        );
    }
  }

  @override
  List<BoardLegendEntry> legend(UgamColorSet colors) => checked([
    BoardLegendEntry(
      id: 'boarded',
      label: tr('board_lens.state_boarded'),
      swatch: colors.goodFill,
      ink: colors.good,
      glyph: '●',
      selects: (b) => b.isOccupied && b.boarding == BerthBoarding.boarded,
    ),
    BoardLegendEntry(
      id: 'expected',
      label: tr('board_lens.state_expected'),
      swatch: colors.cardElev,
      ink: colors.ink2,
      glyph: '○',
      selects: (b) => b.isOccupied && b.boarding == BerthBoarding.expected,
    ),
    BoardLegendEntry(
      id: 'no_show',
      label: tr('board_lens.state_no_show'),
      swatch: colors.dangerFill,
      ink: colors.danger,
      glyph: '✕',
      selects: (b) => b.isOccupied && b.boarding == BerthBoarding.noShow,
    ),
  ]);

  /// "Next un-boarded."
  @override
  bool needsAction(BoardBerth berth) =>
      berth.isOccupied && berth.boarding == BerthBoarding.expected;

  @override
  String stateLabel(BoardBerth berth) {
    if (!berth.isOccupied) {
      return berth.isBlocked
          ? tr('board_lens.state_blocked')
          : tr('board_lens.state_empty');
    }
    switch (berth.boarding) {
      case BerthBoarding.boarded:
        return tr('board_lens.state_boarded');
      case BerthBoarding.expected:
        return tr('board_lens.state_expected');
      case BerthBoarding.noShow:
        return tr('board_lens.state_no_show');
    }
  }
}

/// Shared body of the two lenses that colour by an unbounded bucket set and
/// therefore live under the five-tint cap.
@immutable
abstract class TintedLens extends BoardLens {
  final BoardTintScale tints;

  const TintedLens(this.tints);

  /// Five tints plus the "other" bucket.
  @override
  int get maxLegendEntries => BoardTintScale.maxTints + 1;

  /// The berth's bucket id under this lens.
  @protected
  String? bucketIdOf(BoardBerth berth);

  /// The berth's bucket name, for the semantic label.
  @protected
  String? bucketNameOf(BoardBerth berth);

  /// Translated "N other stops" / "N other groups".
  @protected
  String get otherLabel;

  /// Translated "no pickup point" / "no group".
  @protected
  String get unbucketedLabel;

  @override
  BerthPaint paint(BoardBerth berth, UgamColorSet colors) {
    final empty = emptyPaint(berth, colors);
    if (empty != null) return empty;

    final bucket = bucketIdOf(berth);
    final index = tints.tintIndexOf(bucket);
    if (index == null) {
      return BerthPaint(
        fill: colors.cardElev,
        ink: colors.ink2,
        glyph: bucket == null ? kUnbucketedGlyph : kOtherGlyph,
      );
    }
    return BerthPaint(
      fill: tints.colorOf(index).withValues(alpha: kTintFillAlpha),
      // Normal ink, not the tint: at 22% the fill cannot be relied on to carry
      // ink of its own hue at AA in both themes, and the tint already reads
      // from the fill plus the glyph letter.
      ink: colors.ink,
      glyph: kTintGlyphs[index],
    );
  }

  @override
  List<BoardLegendEntry> legend(UgamColorSet colors) => checked([
    for (final b in tints.tinted)
      BoardLegendEntry(
        id: b.id,
        label: b.label,
        swatch: tints.colorOf(b.tintIndex).withValues(alpha: kTintFillAlpha),
        ink: colors.ink,
        glyph: kTintGlyphs[b.tintIndex],
        selects: (berth) => berth.isOccupied && bucketIdOf(berth) == b.id,
      ),
    if (tints.hasOther)
      BoardLegendEntry(
        id: 'other',
        label: otherLabel,
        swatch: colors.cardElev,
        ink: colors.ink2,
        glyph: kOtherGlyph,
        isOther: true,
        selects: (berth) =>
            berth.isOccupied && tints.tintIndexOf(bucketIdOf(berth)) == null,
      ),
  ]);

  /// Neither tinted lens drives the aisle walk: "next outstanding" needs a
  /// state that CLEARS when the handler acts on it, and belonging to a stop or
  /// a group never clears. Boarding and money own the walk.
  @override
  bool needsAction(BoardBerth berth) => false;

  @override
  String stateLabel(BoardBerth berth) {
    if (!berth.isOccupied) {
      return berth.isBlocked
          ? tr('board_lens.state_blocked')
          : tr('board_lens.state_empty');
    }
    final name = bucketNameOf(berth)?.trim();
    if (name == null || name.isEmpty) return unbucketedLabel;
    return name;
  }
}

/// પિકઅપ — who gets on where. The lens of a bus working its stops.
@immutable
class PickupLens extends TintedLens {
  const PickupLens([super.tints = BoardTintScale.empty]);

  @override
  BoardLensId get id => BoardLensId.pickup;

  @override
  BoardAction get primaryAction => BoardAction.call;

  @override
  BoardStripMetric get stripMetric => BoardStripMetric.stopProgress;

  @override
  String? bucketIdOf(BoardBerth berth) => berth.pickupStopId;

  @override
  String? bucketNameOf(BoardBerth berth) => berth.pickupStopName;

  @override
  String get otherLabel => tr(
    'board_lens.other_stops',
    namedArgs: {'count': '${tints.otherBuckets}'},
  );

  @override
  String get unbucketedLabel => tr('board_lens.state_no_stop');
}

/// ગ્રુપ — who travels together. The lens that replaces the groups screen.
@immutable
class GroupLens extends TintedLens {
  const GroupLens([super.tints = BoardTintScale.empty]);

  @override
  BoardLensId get id => BoardLensId.group;

  @override
  BoardAction get primaryAction => BoardAction.move;

  @override
  BoardStripMetric get stripMetric => BoardStripMetric.groupSpread;

  @override
  String? bucketIdOf(BoardBerth berth) => berth.groupId;

  @override
  String? bucketNameOf(BoardBerth berth) => berth.groupName;

  @override
  String get otherLabel => tr(
    'board_lens.other_groups',
    namedArgs: {'count': '${tints.otherBuckets}'},
  );

  @override
  String get unbucketedLabel => tr('board_lens.state_no_group');
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
