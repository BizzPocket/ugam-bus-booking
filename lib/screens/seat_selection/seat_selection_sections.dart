part of '../seat_selection_screen.dart';

// Layout sections of [SeatSelectionScreen]: header, leg/bus tabs, the
// deck + grid sizing, legend and footer.
extension _SeatSelectionSections on _SeatSelectionScreenState {
  /// Everything above the map: the leg tabs, the bus tabs and the sentence.
  ///
  /// Lifted OUT of the scroll view so the map below can be handed a bounded
  /// height. These three are short and fixed; the map is the thing that should
  /// absorb whatever height is left.
  Widget _headerBlock(UgamColorSet c, {required bool showSummary}) {
    final items = <Widget>[
      if (_tabs.length >= 2) _legTabs(c),
      if (_buses.length > 1) _busTabs(c),
      if (showSummary) _summaryBar(),
    ];
    if (items.isEmpty) return const SizedBox(height: UgamSpacing.sm);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(height: UgamSpacing.md),
            items[i],
          ],
        ],
      ),
    );
  }

  /// Which maps this party actually needs. A round-trip or go-only party fills
  /// the GO map; a return-only party fills the RETURN map. A party needing only
  /// one sees no strip at all.
  ///
  /// The tour having a return leg is folded in here rather than guarding the
  /// call site: without one there is no return map to show, whatever the intent
  /// says. One condition, one place.
  List<TripType> get _tabs {
    final go = widget.intent.roundTrip + widget.intent.outboundOnly > 0;
    final ret = widget.intent.returnOnly > 0 && _hasReturn;
    return [
      if (go) TripType.roundTrip,
      if (ret) TripType.returnOnly,
    ];
  }

  /// The two maps a mixed party moves between.
  ///
  /// These used to be leg PILLS that chose what the booking was, and switching
  /// one wiped the basket. Now the leg lives on each seat, so this is a view
  /// filter: it changes which map you are looking at and nothing else.
  ///
  /// The active tab is TONAL (accentFill + accent ink), not solid champagne.
  /// Solid gold is rationed to the one focal CTA per screen, which this screen
  /// already spends on Continue.
  Widget _legTabs(UgamColorSet c) {
    final tabs = _tabs;
    if (tabs.length < 2) return const SizedBox.shrink();

    Widget tab(TripType leg, Key key, String label) {
      final on = _viewLeg == leg;
      return Expanded(
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          // NOTE: no basket mutation here. That is the whole change.
          onTap: () {
            HapticFeedback.selectionClick();
            _update(() => _viewLeg = leg);
          },
          child: AnimatedContainer(
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            height: UgamScale.tap(context, 44),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? c.accentFill : c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(
                color: on ? c.accent.withValues(alpha: 0.32) : c.border,
              ),
            ),
            child: Text(
              label,
              style: UgamText.bodyStrong.copyWith(color: on ? c.accent : c.ink2),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        tab(
          TripType.roundTrip,
          SeatSelectionScreen.goTabKey,
          tr('seat_pick.tab_go'),
        ),
        const SizedBox(width: UgamSpacing.sm),
        tab(
          TripType.returnOnly,
          SeatSelectionScreen.returnTabKey,
          tr('seat_pick.tab_return'),
        ),
      ],
    );
  }

  /// The sentence above the map.
  ///
  /// A seat map answers "which cells exist"; a customer arrives asking "are we
  /// sorted, together, and what does it cost?". That is a sentence, not a
  /// diagram — so it gets said, in words, above the deck.
  Widget _summaryBar() {
    return ChartSummaryBar(
      people: widget.intent.people,
      pickedBerths: _selectedBerths,
      lowerBerths: _selectedLowerBerths,
      total: _total,
      busNames: _selectedBusNames,
      shortfall: _shortfall,
    );
  }

  Widget _busTabs(UgamColorSet c) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < _buses.length; i++) ...[
            GestureDetector(
              // The chip stays a chip; the HIT BOX around it is padded out to
              // the 44pt minimum, which the bare pill (≈24pt tall) missed.
              behavior: HitTestBehavior.opaque,
              onTap: () => _update(() {
                // Deliberately does NOT clear: the basket is per bus, so
                // switching tabs now keeps what was picked on the other bus.
                // That is the whole point of the multi-bus checkout.
                _busIndex = i;
              }),
              child: SizedBox(
                height: UgamScale.tap(context, 44),
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.only(right: UgamSpacing.xs),
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.md,
                      vertical: UgamSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: i == _busIndex ? c.cardElev : Colors.transparent,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                      border: Border.all(
                        color: i == _busIndex ? c.ink3 : c.border,
                      ),
                    ),
                    child: Text(
                      _buses[i].name,
                      style: UgamText.caption.copyWith(
                        color: i == _busIndex ? c.ink : c.ink2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Height [CombinedSeatGrid] spends ABOVE its first row — the driver strip,
  /// its gap, the divider and the gap under it.
  ///
  /// Deliberately generous. It only feeds the "how much room does the map
  /// need" estimate below, and over-estimating costs a hair of growth while
  /// under-estimating would let the fit shrink a tall chart.
  static const double _gridChrome =
      UgamSpacing.xxl + UgamSpacing.sm + UgamSpacing.md + 1;

  /// The gap between seat slots, both axes.
  static const double _seatGap = UgamSpacing.sm;

  /// How far the map may be blown up past its natural size.
  ///
  /// Capped for two reasons: past this the seats stop reading as a bus and
  /// start reading as a keypad, and the grid's own chrome — the driver strip
  /// and the divider under it — needs real width to lay out in.
  static const double _maxMapGrowth = 1.35;

  /// Rows of the layout that actually carry a seat — what the grid draws.
  int _seatRowCount(BusLayout layout) {
    final rows = <int>{};
    for (final cell in layout.grid) {
      if (cell.hasSeat) rows.add(cell.row);
    }
    return rows.isEmpty ? 1 : rows.length;
  }

  /// Slots in the widest row the grid will draw.
  ///
  /// A normal row is the used lane columns plus the aisle; the back bench packs
  /// its berths flat with no aisle gap, so it can be one slot wider. Mirrors
  /// [CombinedSeatGrid]'s own placement rules — get this wrong and the map is
  /// merely scaled a little differently, never broken.
  int _widestRowSlots(BusLayout layout) {
    final lanes = <int>{};
    for (final cell in layout.grid) {
      if (cell.hasSeat && cell.col != SeatGridCols.aisle) lanes.add(cell.col);
    }
    final hasLeft = lanes.contains(SeatGridCols.singleUpper) ||
        lanes.contains(SeatGridCols.singleLower);
    final hasRight = lanes.contains(SeatGridCols.doubleUpper) ||
        lanes.contains(SeatGridCols.doubleLower);
    var widest = lanes.length + (hasLeft && hasRight ? 1 : 0);
    for (var r = 0; r < layout.rows; r++) {
      final pair = layout.balconyPair(r);
      if (!pair.upper.hasSeat && !pair.lower.hasSeat) continue;
      final n = layout.cellsInRow(r).length;
      if (n > widest) widest = n;
    }
    return widest < 1 ? 1 : widest;
  }

  /// The seat map. [width] and [height] are the card's inner content box,
  /// measured by the caller.
  ///
  /// *** TWO BUGS LIVED IN THE OLD THREE LINES OF GEOMETRY ***
  ///
  /// 1. BADGE BLEED. Every tile is pinned to [ChartSeatMetrics] (56x52) and the
  ///    grid drops it into its slot through a `BoxFit.scaleDown` fit. The slot
  ///    was 44x46 — SMALLER than the tile — so each tile was squeezed to
  ///    44x40.9 and sat flush against its slot's edges. A corner badge or a
  ///    Gujarati label whose matras overshoot the line box then had nowhere to
  ///    go but onto the row above. The slot is now the tile PLUS a reserved
  ///    margin, so a tile can never reach a neighbour across that margin and
  ///    the [_seatGap] between slots.
  ///
  /// 2. THE SCREEN ENDING AT 60%. The grid fits its rows with
  ///    `BoxFit.scaleDown`, which never grows, so a short chart drew at its
  ///    natural size at the top of the viewport and left the rest blank. Given
  ///    a bounded height it is now scaled UP to fill it — the seats were the
  ///    thing worth spending that space on, being both the tap target and the
  ///    thing being read.
  ///
  /// Growth is one `BoxFit.contain` rather than a bigger slot, because a bigger
  /// slot cannot make a tile bigger: the tile's own size is a const in
  /// [ChartSeatMetrics], and the grid only ever scales it DOWN into the slot.
  Widget _deck(
    UgamColorSet c,
    Bus bus,
    BusLayout layout, {
    required double width,
    required double height,
  }) {
    final e = UgamElevation.of(context);

    // Slot = tile + reserved margin, floored at the 44pt tap minimum.
    final slotW =
        UgamScale.tap(context, ChartSeatMetrics.width + UgamSpacing.xs);
    final slotH =
        UgamScale.tap(context, ChartSeatMetrics.height + UgamSpacing.sm);

    final rows = _seatRowCount(layout);
    final cols = _widestRowSlots(layout);
    final naturalW = cols * slotW + (cols - 1) * _seatGap;
    final naturalH = rows * slotH + (rows - 1) * _seatGap + _gridChrome;

    // Both floored at the map's own natural size, so a degenerate (or, for
    // height, unbounded) region can only ever mean "do not grow".
    final availW = math.max(width, naturalW);
    final availH = height.isFinite ? height : naturalH;
    final grow =
        math.min(availW / naturalW, availH / naturalH).clamp(1.0, _maxMapGrowth);

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(color: c.border),
        // Level 1: the map is a plane lifted off the page, not a grey rectangle
        // painted on it. The legend rail below stays flush, so the two read as
        // two surfaces.
        boxShadow: e.rest,
      ),
      child: SizedBox(
        width: double.infinity,
        // Taller than the region only when the chart genuinely needs it, which
        // is what makes a long bus scroll instead of being shrunk to fit.
        height: math.max(availH, naturalH * grow),
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.topCenter,
          child: SizedBox(
            // Pre-divided by the scale the fit is about to apply, so the grid
            // still lays out against the FULL content width. Cutting the box
            // to the seat rows alone starves the grid's own chrome — the
            // driver strip overflows and the divider under it collapses to
            // nothing.
            width: availW / grow,
            child: _grid(bus, layout, slotW, slotH),
          ),
        ),
      ),
    );
  }

  Widget _grid(Bus bus, BusLayout layout, double slotW, double slotH) {
    return CombinedSeatGrid(
      layout: layout,
      cellWidth: slotW,
      cellHeight: slotH,
      colGap: _seatGap,
      rowGap: _seatGap,
      tileBuilder: (ctx, cell) {
        final seatId = cell.seatId;
        final tile = ChartSeatTile(
          cell: cell,
          occupancy: seatId == null ? null : _occupancyFor(seatId),
          // The map being LOOKED AT drives what availability is painted.
          leg: _viewLeg,
          selectedBerths: seatId == null ? 0 : _berthsOn(seatId),
          // Band pricing used to be invisible until the footer total moved.
          berthPrice:
              cell.hasSeat ? _berthPrice(bus, cell, _bucketForTap()) : null,
          bothLegs: widget.intent.isMixed &&
              _basket
                      .entryFor(busId: bus.id, seatId: cell.seatId ?? '')
                      ?.leg ==
                  TripType.roundTrip,
        );
        if (!cell.hasSeat) return tile;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _tapSeat(cell),
          child: tile,
        );
      },
    );
  }

  /// The legend, as a rail pinned to the bottom of the screen.
  ///
  /// It is deliberately FLUSH — [UgamElevationSet.flat] — while the map above
  /// sits at rest. Two surfaces at two heights is what stops the screen reading
  /// as one flat sheet, and pinning it also gives the composition a bottom edge
  /// in the state where nothing is picked and there is no CTA yet.
  Widget _legendRail(UgamColorSet c) {
    final e = UgamElevation.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.tight,
      ),
      decoration: BoxDecoration(
        color: c.card,
        boxShadow: e.flat,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: _legend(c),
    );
  }

  Widget _legend(UgamColorSet c) {
    // Decorative swatch — it is never tapped, so px() and not tap().
    final swatch = UgamScale.px(context, UgamSpacing.lg);
    Widget item(Color bg, Color? border, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: swatch,
              height: swatch,
              decoration: BoxDecoration(
                color: bg,
                // A swatch stands for a SEAT, so it echoes the seat's corner
                // rather than becoming a dot. UgamRadius has no step this small
                // (seat = 14 on a 16px box is a circle), so the original 5 is
                // kept — see the report: the scale wants a `micro` step.
                borderRadius: BorderRadius.circular(5),
                border: border != null ? Border.all(color: border) : null,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(label, style: UgamText.micro.copyWith(color: c.ink2)),
          ],
        );

    return Wrap(
      alignment: WrapAlignment.center,
      spacing: UgamSpacing.md,
      runSpacing: UgamSpacing.xs,
      children: [
        item(c.cardElev, c.border, tr('seat_pick.legend_open')),
        item(c.accent, null, tr('seat_pick.legend_yours')),
        // The taken tile is the page ground with a hairline; at swatch size on
        // the dark rail that hairline vanished and the swatch read as nothing.
        // A stronger outline keeps it legible while still reading "empty-ish".
        item(c.bg, c.ink3, tr('seat_pick.legend_taken')),
        item(c.warmFill, null, tr('seat_pick.legend_lady')),
      ],
    );
  }

  Widget _footer(UgamColorSet c) {
    return UgamStickyCTA(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
            child: Row(
              children: [
                // Expanded, not a Spacer: the berth count is the one line here
                // that grows with the language and the accessibility scale, and
                // a Spacer let it push the total off the right edge instead of
                // giving way. The price must never be the thing that is lost.
                Expanded(
                  child: Text(
                    _selectedBerths == 1
                        ? tr('seat_pick.berth_one')
                        : tr('seat_pick.berth_many',
                            namedArgs: {'n': '$_selectedBerths'}),
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Text(
                  Formatters.formatMoneyInr(_total),
                  style: UgamText.tabular(
                    UgamText.titleS.copyWith(color: c.ink),
                  ),
                ),
              ],
            ),
          ),
          UgamCTA(
            label: tr('seat_pick.continue'),
            leadingIcon: Icons.arrow_forward_rounded,
            onPressed: _continue,
          ),
        ],
      ),
    );
  }
}
