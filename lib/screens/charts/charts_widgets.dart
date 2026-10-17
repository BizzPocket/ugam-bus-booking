part of '../charts_screen.dart';

// ─── Horizontal scroll edge fade ───────────────────────────────────────

/// Wraps a horizontally scrolling strip (a [UgamSelectorPills] row here) and
/// dissolves whichever edge still has content behind it.
///
/// A pill row that runs past the viewport used to be sliced dead straight
/// mid-word on both sides, which reads as a rendering fault rather than as
/// "there is more here" — nothing on screen said the row could be dragged. A
/// soft edge instead of a hard cut is the standard affordance, and fading only
/// the side that actually overflows means a row of two pills stays crisp.
///
/// It listens for the inner scrollable's notifications rather than owning a
/// controller, so the shared pill component keeps building its own [ListView]
/// untouched. [ScrollMetricsNotification] covers the first layout and any later
/// resize (rotation, a tour added/removed); [ScrollNotification] covers drags.
class _ScrollEdgeFade extends StatefulWidget {
  final Widget child;

  const _ScrollEdgeFade({required this.child});

  @override
  State<_ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<_ScrollEdgeFade> {
  /// Fade ramp width. Wide enough to read as a dissolve, narrow enough that it
  /// never dims a whole pill — this is a hint, not a vignette.
  static const double _ramp = 24;

  bool _fadeLeft = false;
  bool _fadeRight = false;

  /// `extentBefore`/`extentAfter` are leading/trailing, not left/right, so they
  /// are mapped through the scrollable's own [ScrollMetrics.axisDirection] —
  /// which already accounts for both RTL locales and a reversed list.
  ///
  /// Always returns false: the notification keeps bubbling, so nothing that
  /// already listens for this strip's scrolling stops hearing it.
  bool _sync(ScrollMetrics m) {
    if (m.axis != Axis.horizontal || !m.hasContentDimensions) return false;
    final flipped = m.axisDirection == AxisDirection.left;
    final left = (flipped ? m.extentAfter : m.extentBefore) > 1;
    final right = (flipped ? m.extentBefore : m.extentAfter) > 1;
    if (left == _fadeLeft && right == _fadeRight) return false;
    // A metrics notification can be dispatched from inside layout, where
    // setState would throw. Only THEN defer to the end of the frame — a frame
    // is by definition already in flight there, so the callback is guaranteed
    // to run. Deferring unconditionally would risk parking the very first
    // update until some unrelated thing scheduled the next frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _apply(left, right));
    } else {
      _apply(left, right);
    }
    return false;
  }

  void _apply(bool left, bool right) {
    if (!mounted || (left == _fadeLeft && right == _fadeRight)) return;
    setState(() {
      _fadeLeft = left;
      _fadeRight = right;
    });
  }

  @override
  Widget build(BuildContext context) {
    final fadeLeft = _fadeLeft;
    final fadeRight = _fadeRight;

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => _sync(n.metrics),
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) => _sync(n.metrics),
        // The mask stays mounted even when BOTH edges are opaque (where it is
        // a visual no-op). Inserting/removing it around the strip would swap
        // the widget type above the pill row, remounting its [ListView] and
        // throwing the scroll offset back to zero the instant a drag turned
        // the first fade on — the strip would jump home under the finger.
        child: ShaderMask(
          // The gradient is an ALPHA STENCIL, not colour: `dstIn` keeps the
          // child wherever the mask is opaque. Black/transparent here carry no
          // palette meaning, so they are deliberately not tokens.
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) {
            final ramp = rect.width <= 0
                ? 0.0
                : (_ramp / rect.width).clamp(0.0, 0.35);
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                fadeLeft ? Colors.transparent : Colors.black,
                Colors.black,
                Colors.black,
                fadeRight ? Colors.transparent : Colors.black,
              ],
              stops: [0, ramp, 1 - ramp, 1],
            ).createShader(rect);
          },
          child: widget.child,
        ),
      ),
    );
  }
}

// ─── Bus bar ───────────────────────────────────────────────────────────

/// One compact row that merges what used to be a separate bus-selector strip
/// AND a full `n/total` tally card. The bus selector sits on the left (pills
/// when the tour carries >1 bus, else the single bus's name so it never
/// disappears), the placed/total fill on the right. Folding the standalone
/// tally card away reclaims a whole vertical band for the seat grid without
/// losing the fill signal or the bus name.
class _BusBar extends StatelessWidget {
  final Tour tour;
  final Bus bus;
  final int assigned;
  final int total;
  final ValueChanged<String> onPickBus;
  final UgamColorSet c;

  const _BusBar({
    required this.tour,
    required this.bus,
    required this.assigned,
    required this.total,
    required this.onPickBus,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final multiBus = tour.buses.length > 1;
    final plate = bus.busNumber.trim();
    // The registration goes on its OWN line under the bus row, not into the
    // label above it. On a multi-bus tour that label is a scrolling pill strip
    // sharing its row with the fill indicator — the narrowest thing on the
    // screen, already the first to clip — so `name · GJ05HU7162` would push the
    // plate straight off the edge on the tour where it matters most. Down here
    // it always fits, it names the SELECTED bus, and one placement serves both
    // the pills and the single-bus label.
    final row = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: multiBus
              // Same edge fade as the tour row: this strip is even narrower
              // (it shares the row with the fill indicator), so it clips first.
              ? _ScrollEdgeFade(
                  child: UgamSelectorPills(
                    padding: EdgeInsets.zero,
                    items: [
                      for (final b in tour.buses)
                        UgamSelectorItem(label: b.name),
                    ],
                    currentIndex: tour.buses.indexWhere((b) => b.id == bus.id),
                    onChanged: (i) => onPickBus(tour.buses[i].id),
                  ),
                )
              // Was `micro` + `.toUpperCase()`, which is the exact pair the
              // ladder now rules out: the caps are a no-op in Gujarati and
              // Hindi, so the PRIMARY language got a tracked 10pt eyebrow
              // (8.5pt on a small phone) where English got a caps label, and
              // the emphasis simply vanished. [UgamText.label] is the
              // script-safe step — Inter 13/w700, no tracking — and weight plus
              // full ink carry the emphasis in every script. It also lands next
              // to the 12.5/w600 that [UgamSelectorPills] draws, which is what
              // this stands in for on a single-bus tour.
              : Text(
                  bus.name,
                  style: UgamText.label.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
        const SizedBox(width: UgamSpacing.md),
        _FillIndicator(assigned: assigned, total: total, c: c),
      ],
    );

    if (plate.isEmpty) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        const SizedBox(height: 2),
        Text(
          plate,
          // Meta, so ink2 and never the accent — a plate identifies, it does
          // not mark ownership. Tabular so the digits sit in even columns the
          // way a registration is read off a windscreen.
          style: UgamText.tabular(UgamText.caption).copyWith(color: c.ink2),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// The compact placed/total signal on the right of the [_BusBar]: a tabular
/// `n/total` count and a short NEUTRAL-ink fill bar. Ink, not amber: a fill
/// ratio is a measurement, not an ownership mark, and this screen now spends
/// the accent NOWHERE — the only amber on it comes from the seat tiles, where
/// it marks a specific rider's berth.
class _FillIndicator extends StatelessWidget {
  final int assigned;
  final int total;
  final UgamColorSet c;

  const _FillIndicator({
    required this.assigned,
    required this.total,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final ratio = total == 0 ? 0.0 : assigned / total;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$assigned/$total',
          // `numLg` unforked — this is a tabular count like every other one in
          // the app, and the 16pt override made it read a step small.
          style: UgamText.tabular(UgamText.numLg.copyWith(color: c.ink)),
        ),
        const SizedBox(width: UgamSpacing.sm),
        SizedBox(
          // Decorative rail: scales, so it stops crowding the bus pills to its
          // left on a narrow phone.
          width: UgamScale.px(context, 52),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: UgamScale.px(context, 6),
              backgroundColor: c.card,
              valueColor: AlwaysStoppedAnimation(c.ink2),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Seat-grid skeleton ────────────────────────────────────────────────

/// Placeholder shown while a bus's `layout` jsonb is still on the wire.
///
/// Deliberately shaped like the grid it will become — rows of seat-sized blocks
/// inside the usual chassis padding — so the chart does not appear to be empty
/// and then jump. Distinct from [UgamEmpty], which states a CONCLUSION ("this
/// bus has no seat layout") that is only true once loading has finished.
class _SeatGridSkeleton extends StatelessWidget {
  const _SeatGridSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Semantics(
      label: tr('charts.layout_loading'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var row = 0; row < 4; row++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var col = 0; col < 4; col++)
                      Container(
                        width: kSeatTileW,
                        height: kSeatTileH,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: c.cardElev,
                          borderRadius: BorderRadius.circular(UgamRadius.seat),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: UgamSpacing.md),
            Text(
              tr('charts.layout_loading'),
              style: UgamText.caption.copyWith(color: c.ink3),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Edit-seats FAB ────────────────────────────────────────────────────

/// The chart's one primary hand-off into the editable grid, as a small FAB
/// overlaying the chart's bottom-right (thumb zone) instead of a full-width
/// footer button. Edit glyph plus a compact label, floating clear of the
/// berths underneath it, with a 44pt-min tap target, ripple and haptic.
class _EditSeatsFab extends StatelessWidget {
  final VoidCallback onTap;

  const _EditSeatsFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: tr('charts.edit_seats'),
      // Only the LIFT is bespoke — everything else is the shared [UgamButton],
      // so height, radius, icon size and press feedback match every other
      // primary in the app.
      //
      // That lift used to be an amber `glow` halo. [UgamButtonKind.primary] is
      // `action` — deliberately no brand hue — so the halo was pure decoration
      // in the one colour this app reserves for "this is yours", floating over
      // a grid whose seat tiles use that same amber to mark a rider's berth.
      // It is a genuine level-2 surface (it floats above the card, over
      // content), so it takes the level-2 shadow and says so.
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(UgamRadius.input),
          boxShadow: UgamElevation.of(context).raised,
        ),
        child: UgamButton(
          label: tr('charts.edit_seats'),
          icon: Icons.edit_rounded,
          kind: UgamButtonKind.primary,
          onPressed: onTap,
        ),
      ),
    );
  }
}

// ─── Seat chart card ───────────────────────────────────────────────────

/// The rounded card holding the canonical read-only chart for the bus. Renders
/// the same [SeatChartTile] + [CombinedSeatGrid] every other chart uses (drag
/// OFF), so the browser reads identically — group / priority rings, one-way leg
/// colours — minus any editing.
class _SeatChartCard extends StatelessWidget {
  final BusLayout? layout;

  /// Whether this bus's `layout` jsonb has been RESOLVED — fetched, or confirmed
  /// absent on the server. Separates "no grid yet" from "no grid at all".
  final bool loaded;

  /// Raw, berth-accurate occupant lists for TILE rendering: a whole double held
  /// solo appears twice so the half-double split detection stays exact.
  final Map<String, List<Passenger>> assignments;

  /// De-duped, GO-first distinct occupants per seat (the shared resolver's
  /// `occ.all`) for the SHEET. Keyed by seatId; a shared/leg-shared double has
  /// both people here, a whole-double-solo collapses to one.
  final Map<String, List<Passenger>> sheetOccupants;
  final GroupColorResolver groupColors;

  /// Hands the tapped seat's id plus its FULL distinct-occupant list (de-duped,
  /// GO-first) to the read-only sheet — a shared/leg-shared double surfaces BOTH
  /// names, not just the first. This list is the bug-fix surface.
  final void Function(String seatId, List<Passenger> occupants) onSeatTap;

  /// Dead space kept at the BOTTOM of the scroll extent so the floating
  /// edit-seats pill has somewhere of its own to sit. Zero when no grid
  /// renders (nothing floats over an empty card).
  final double bottomReserve;

  /// The empty state's way out — opens the bus wizard where the layout is
  /// actually generated.
  final VoidCallback onCreateLayout;

  /// Riders still holding a seat on THIS bus. Non-zero next to a missing grid
  /// is the signature of a lost layout rather than an unconfigured bus, and it
  /// is what decides which of the two empty states below is honest.
  final int seatedRiders;

  /// Rebuild the lost grid from the surviving seat ids, re-attaching everyone.
  /// Offered only when [seatedRiders] is non-zero — with nobody seated there is
  /// no evidence to rebuild from and [onCreateLayout] is the right answer.
  final VoidCallback onRecoverLayout;

  const _SeatChartCard({
    required this.layout,
    required this.loaded,
    required this.assignments,
    required this.sheetOccupants,
    required this.groupColors,
    required this.bottomReserve,
    required this.onCreateLayout,
    required this.seatedRiders,
    required this.onRecoverLayout,
    required this.onSeatTap,
  });

  @override
  Widget build(BuildContext context) {
    final l = layout;
    if (l == null || l.totalCells == 0) {
      // `layout == null` is AMBIGUOUS on its own: cold start ships buses without
      // their grids to save 2G bytes, so it means either "still loading" or
      // "this bus genuinely has no seat map". Rendering the second answer while
      // the first is true showed an empty-chart dead end on a bus that had 36
      // riders seated on it. [loaded] resolves the ambiguity.
      // A bus with riders on it did NOT arrive here unconfigured — it LOST its
      // grid (the full-row write that erased two live seat charts; see
      // `Bus.toPatch`). `total_seats` and every rider's `assigned_seats` survive
      // that, which is why the meter above still reads "37/37" over this card.
      //
      // Offering "create seat plan" here was actively harmful: it opens the bus
      // wizard, and generating a layout renumbers every seat id — unassigning
      // all 37 of the people the bar just counted. So when there is evidence to
      // rebuild FROM, lead with the repair, which re-derives the same grid from
      // the surviving ids and puts everyone back where they were.
      final lost = loaded && seatedRiders > 0;
      return UgamCard.plain(
        child: !loaded
            ? const _SeatGridSkeleton()
            : lost
                ? UgamEmpty(
                    icon: Icons.restore_page_outlined,
                    title: tr('charts.layout_lost'),
                    body: tr(
                      'charts.layout_lost_body',
                      namedArgs: {'count': '$seatedRiders'},
                    ),
                    cta: UgamCTA(
                      label: tr('charts.recover_layout'),
                      leadingIcon: Icons.auto_fix_high_rounded,
                      onPressed: onRecoverLayout,
                    ),
                  )
                : UgamEmpty(
                    icon: Icons.event_seat_outlined,
                    title: tr('charts.no_layout'),
                    body: tr('charts.no_layout_body'),
                    // Was a dead end: it stated the problem and offered nothing.
                    cta: UgamCTA(
                      label: tr('charts.create_layout'),
                      leadingIcon: Icons.grid_view_rounded,
                      onPressed: onCreateLayout,
                    ),
                  ),
      );
    }

    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.lg,
      ),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        // Padding on the SCROLL VIEW, not on the chassis: it joins the scroll
        // extent, so the last berth clears the floating edit-seats pill both
        // when the grid overflows (at maximum scroll) and when it does not
        // (the grid simply ends higher up the card).
        padding: EdgeInsets.only(bottom: bottomReserve),
        child: UgamBusChassis(
          child: CombinedSeatGrid(
            layout: l,
            cellWidth: kSeatTileW,
            cellHeight: kSeatTileH,
            colGap: 6,
            rowGap: 6,
            driverLabel: tr('charts.driver_label'),
            // Header band so the top-left expand button clears the first seat.
            reserveTopAction: true,
            tileBuilder: (ctx, cell) {
              final occupants = cell.seatId != null
                  ? (assignments[cell.seatId] ?? const <Passenger>[])
                  : const <Passenger>[];
              return RepaintBoundary(
                child: SeatChartTile(
                  cell: cell,
                  occupants: occupants,
                  groupColors: groupColors,
                  markHalfDouble: true,
                  // Pass ALL occupants (not `.first`) to the read-only sheet so
                  // a shared / leg-shared double surfaces BOTH names. The
                  // distinct, GO-first set comes from the shared resolver
                  // (sheetOccupants), matching what the tile paints.
                  onTapBooked: occupants.isEmpty
                      ? null
                      : () => onSeatTap(
                          cell.seatId!,
                          sheetOccupants[cell.seatId] ?? occupants,
                        ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
