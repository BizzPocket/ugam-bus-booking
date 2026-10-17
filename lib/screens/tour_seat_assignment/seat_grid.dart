part of '../tour_seat_assignment_screen.dart';

// ─── Seat grid card ────────────────────────────────────────────────────

class _SeatGrid extends StatelessWidget {
  /// Visible scroll-area height. The in-place pinch-zoom box is bounded to it
  /// so the constrained [InteractiveViewer] (inside [UgamPinchZoom]) has finite
  /// height even though it lives in an unbounded vertical scroll view.
  final double viewportHeight;
  final BusLayout? layout;
  final Tour tour;
  final Map<String, List<String>> assignmentMap;
  final String? currentPassengerId;
  final ValueChanged<SeatCell> onTap;
  final String busName;

  // ── Drag-to-move hooks ────────────────────────────────────────────────────
  final bool enableDrag;
  final bool dragActive;
  final bool Function(SeatCell cell) canDragSeat;
  final SeatDropHighlight Function(SeatCell cell) dropHighlightFor;
  final String? Function(SeatCell cell) dragLabelFor;
  final void Function(SeatCell cell) onSeatDragStarted;
  final VoidCallback onSeatDragEnded;
  final void Function(String fromSeatId, String toSeatId) onSeatDraggedToSeat;

  /// A pending rider dragged from the dock was dropped on a seat.
  final void Function(String passengerId, String seatId)
      onPendingRiderDroppedToSeat;

  /// Long-press an EMPTY seat → open its Hold/Premium flag sheet. Booked seats
  /// keep long-press = drag; they reach the flag sheet via the occupant menu.
  final void Function(String seatId) onSeatLongPressForFlags;

  const _SeatGrid({
    required this.viewportHeight,
    required this.layout,
    required this.tour,
    required this.assignmentMap,
    required this.currentPassengerId,
    required this.onTap,
    required this.busName,
    required this.enableDrag,
    required this.dragActive,
    required this.canDragSeat,
    required this.dropHighlightFor,
    required this.dragLabelFor,
    required this.onSeatDragStarted,
    required this.onSeatDragEnded,
    required this.onSeatDraggedToSeat,
    required this.onPendingRiderDroppedToSeat,
    required this.onSeatLongPressForFlags,
  });

  @override
  Widget build(BuildContext context) {
    final l = layout;
    if (l == null) {
      return const _NoLayout();
    }
    final c = UgamColors.of(context);

    // Resolve passenger ids → models once and build a stable group-colour
    // resolver from the tour's groups, so the shared canonical tile renders
    // names, group rings and GO/RET exactly like every other chart.
    final byId = {for (final p in tour.passengers) p.id: p};
    final resolver = tourGroupColors(tour);

    // Occupants per seat for the currently-shown bus, resolved with the exact
    // same logic the tileBuilder uses below — fed verbatim to the shared
    // full-screen chart so it reads identically to the inline chart.
    final occupantsBySeat = <String, List<Passenger>>{
      for (final e in assignmentMap.entries)
        e.key: e.value.map((id) => byId[id]).whereType<Passenger>().toList(),
    };
    final canExpand = l.totalCells > 0;

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Stack(
        children: [
          // In-place pinch-zoom for close inspection of a dense chart; the
          // full-screen expand button (below, outside the zoom layer) still
          // opens the shared fullscreen chart. The zoom wraps only the grid so
          // the expand affordance stays fixed and tappable. Bounded to the
          // visible scroll-area height so the constrained InteractiveViewer has
          // finite height inside this unbounded vertical scroll view; the chart
          // sits at the top so it reads exactly as before at scale 1.
          SizedBox(
            height: viewportHeight > 0 ? viewportHeight : null,
            child: UgamPinchZoom(
            child: Align(
            alignment: Alignment.topCenter,
            child: CombinedSeatGrid(
            layout: l,
            cellWidth: kSeatTileW,
            cellHeight: kSeatTileH,
            colGap: 8,
            rowGap: 8,
            driverLabel: tr('tour_seat_assignment.grid_label_driver'),
            // Reserve a header band so the top-left expand button clears SU1.
            reserveTopAction: canExpand,
            // Drag-to-move: a booked seat can be long-pressed onto another. The
            // grid owns the gesture; the screen owns move/swap (group-safe).
            enableDrag: enableDrag,
            dragActive: dragActive,
            canDragSeat: canDragSeat,
            dropHighlightFor: dropHighlightFor,
            dragLabelFor: dragLabelFor,
            reportRejectedDrops: true,
            onSeatDragStarted: onSeatDragStarted,
            onSeatDragEnded: onSeatDragEnded,
            onSeatDraggedToSeat: onSeatDraggedToSeat,
            onPendingRiderDroppedToSeat: onPendingRiderDroppedToSeat,
            onSeatLongPressForFlags: onSeatLongPressForFlags,
            tileBuilder: (ctx, cell) {
              final owners = assignmentMap[cell.seatId] ?? const <String>[];
              final occ = owners
                  .map((id) => byId[id])
                  .whereType<Passenger>()
                  .toList();
              final isMine =
                  currentPassengerId != null &&
                  owners.contains(currentPassengerId);
              final tile = SeatChartTile(
                cell: cell,
                occupants: occ,
                groupColors: resolver,
                // [occ] is berth-accurate (one entry per assignment), so a
                // half-taken double sofa renders split (filled + empty) instead
                // of reading as fully booked.
                markHalfDouble: true,
                onTapBooked: () => onTap(cell),
                onTapFree: () => onTap(cell),
              );
              return SizedBox(
                width: kSeatTileW,
                height: kSeatTileH,
                child: RepaintBoundary(
                  child: Stack(
                    children: [
                      tile,
                      // Selection ring marks the seats already held by
                      // the passenger currently being assigned. Kept always
                      // mounted (IgnorePointer + Positioned.fill = zero layout
                      // impact) so its opacity can ease in/out as [isMine]
                      // flips, instead of popping.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: isMine ? 1.0 : 0.0,
                            duration: UgamMotion.sheet,
                            curve: Curves.easeOutCubic,
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.seat,
                                ),
                                border: Border.all(
                                  color: c.accent,
                                  width: 2.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
            ),
            ),
            ),
          ),
          // Expand to the shared full-screen chart — works in both standalone
          // and embedded modes. Top-left, since the driver indicator owns the
          // chart's top-right.
          if (canExpand)
            ChartExpandButton(
              onTap: () => FullscreenChartScreen.open(
                context,
                layout: l,
                occupantsBySeat: occupantsBySeat,
                groupColors: resolver,
                title: busName,
                driverLabel: tr('tour_seat_assignment.grid_label_driver'),
                // [occupantsBySeat] here is berth-accurate, so the expanded
                // chart can split a half-taken double too.
                markHalfDouble: true,
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Passenger card ────────────────────────────────────────────────────
//
// Sits between the seat chart and the pending dock. Shows who the agent
// is currently assigning + their pending request lines + handler + edit
// buttons. Kept as a single dense card so the seat grid stays the focal
// surface.
class _PassengerCard extends StatelessWidget {
  final Tour tour;
  final Passenger passenger;
  final List<_PendingLine> pending;

  /// Tour-wide handler pointer — kept only to badge the handler in this card
  /// and to drive the "assign a handler" nudge. Handlers are now assigned
  /// PER BUS on the Manage Buses screen, so there's no toggle here.
  final String? handlerId;

  /// Opens Manage Buses, where each bus's handler is picked.
  final VoidCallback onManageBuses;

  const _PassengerCard({
    required this.tour,
    required this.passenger,
    required this.pending,
    required this.handlerId,
    required this.onManageBuses,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final selectedSeats = passenger.assignedSeats.isEmpty
        ? '—'
        : passenger.assignedSeats.map((a) => a.seatId).join(', ');
    final stillNeeded = pending.fold<int>(0, (sum, l) => sum + l.remaining);

    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                // px() not tap(): the avatar is decorative — the whole card
                // is the tap target, not this disc. The 13pt initials match
                // UgamPersonRow's default avatar exactly, so no fork here.
                width: UgamScale.px(context, 32),
                height: UgamScale.px(context, 32),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  SeatChartTile.initials(passenger.displayName),
                  style: UgamText.bodyStrong.copyWith(
                    color: c.accent,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.tight),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            passenger.displayName,
                            // bodyStrong IS 14 — this was `titleM` (18) forked
                            // down. The collapsed dock renders the same name at
                            // titleS, so the two states now share one ramp.
                            style: UgamText.bodyStrong.copyWith(color: c.ink),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (handlerId == passenger.id) ...[
                          const SizedBox(width: 6),
                          // Was a 4px-radius hand-rolled badge sitting directly
                          // beside the pill-shaped pickup chip below.
                          UgamReqChip(
                            label: tr('tour_seat_assignment.badge_handler'),
                            variant: UgamChipVariant.warm,
                          ),
                        ],
                        _PickupCodeChip(passenger: passenger),
                      ],
                    ),
                    if (passenger.phone.isNotEmpty)
                      Text(
                        passenger.phone,
                        style: UgamText.caption.copyWith(color: c.ink2),
                      ),
                  ],
                ),
              ),
              UgamIconButton(
                // size/iconSize overrides deleted — inherit the component's
                // 44/19 defaults so this matches every other icon button.
                icon: Icons.edit_outlined,
                semanticLabel: tr('tour_seat_assignment.tooltip_edit_request'),
                onTap: () => EditRequestSheet.show(
                  context: context,
                  tour: tour,
                  passenger: passenger,
                ),
              ),
              Text(
                '${passenger.totalSeatsAssigned}/${passenger.totalSeatsRequested}',
                // 13 -> bodyStrong's own 14, matching the name beside it.
                style: UgamText.tabular(
                  UgamText.bodyStrong.copyWith(color: c.ink),
                ),
              ),
            ],
          ),
          if (pending.isNotEmpty) ...[
            const SizedBox(height: UgamSpacing.sm),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: pending.map((line) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.sm,
                    vertical: UgamSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    // Was a 6px corner while the visually identical queue chips
                    // ~40px below are full pills — two corner languages for the
                    // same information.
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Text(
                    '${line.label}  ${line.progress}',
                    style: UgamText.caption.copyWith(
                      color: line.remaining == 0 ? c.good : c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
          const SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  tr(
                    'tour_seat_assignment.seats_label',
                    namedArgs: {'seats': selectedSeats},
                  ),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (stillNeeded > 0)
                Text(
                  tr(
                    'tour_seat_assignment.more_needed',
                    namedArgs: {'count': stillNeeded.toString()},
                  ),
                  style: UgamText.caption.copyWith(
                    color: c.warm,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          if (handlerId == null && stillNeeded == 0) ...[
            const SizedBox(height: UgamSpacing.tight),
            GestureDetector(
              onTap: onManageBuses,
              behavior: HitTestBehavior.opaque,
              child: Container(
                // Styled as a button but was only ~32pt tall, and it is the
                // only in-card route to assigning a handler (the gate that
                // blocks Lock & notify). centerLeft is load-bearing: without an
                // alignment the Row top-aligns inside the taller box, and
                // `center` would re-centre it horizontally.
                constraints: const BoxConstraints(minHeight: 44),
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.md,
                  vertical: UgamSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: c.warmFill,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                child: Row(
                  children: [
                    Icon(Icons.badge_outlined, size: 14, color: c.warm),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr('tour_seat_assignment.hint_pick_handler'),
                        style: UgamText.caption.copyWith(color: c.warm),
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, size: 14, color: c.warm),
                  ],
                ),
              ),
            ),
          ],
          // The all-passenger chip picker that used to live here was removed:
          // the dock's queue strip is now the SINGLE passenger switcher, so the
          // cramped bottom third breathes and there's only one place to jump
          // between requests.
        ],
      ),
    );
  }
}
