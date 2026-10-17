part of 'board_lens.dart';

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
