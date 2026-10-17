part of 'seat_move_flow.dart';

// ─── Destination-bus picker ──────────────────────────────────────────────

class _DestinationPickerSheet extends StatelessWidget {
  final Passenger mover;
  final List<Bus> buses;
  final String currentBusId;
  final ValueChanged<Bus> onPick;

  const _DestinationPickerSheet({
    required this.mover,
    required this.buses,
    required this.currentBusId,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        // This sheet bypasses _SheetShell, and its parent passes
        // useSafeArea: true — which insets the TOP only. Own the bottom inset
        // here or the last bus row is clipped by the gesture pill.
        UgamSpacing.lg +
            math.max(
              MediaQuery.viewInsetsOf(context).bottom,
              MediaQuery.paddingOf(context).bottom,
            ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SheetGrabber(),
          Text(
            tr(
              'seat_detail.destination.title',
              namedArgs: {'name': mover.displayName},
            ),
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            tr('seat_detail.destination.body'),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.md),
          for (final b in buses)
            Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
              child: GestureDetector(
                onTap: () => onPick(b),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.all(UgamSpacing.md),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.row),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.directions_bus_rounded,
                        size: 20,
                        color: c.accent,
                      ),
                      const SizedBox(width: UgamSpacing.md),
                      Expanded(
                        child: Text(
                          b.name,
                          style: UgamText.bodyStrong.copyWith(color: c.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (b.id == currentBusId)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UgamSpacing.sm,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: c.cardElev,
                            borderRadius: BorderRadius.circular(
                              UgamRadius.chip,
                            ),
                            border: Border.all(color: c.border),
                          ),
                          child: Text(
                            tr('seat_detail.destination.current'),
                            style: UgamText.micro.copyWith(color: c.ink2),
                          ),
                        ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: c.ink3,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── Swap assistant ──────────────────────────────────────────────────────

class _SwapAssistSheet extends StatelessWidget {
  final Passenger mover;
  final Bus destination;
  final SwapAssist assist;
  final ValueChanged<String> onTakeFree;
  final ValueChanged<SwapCandidate> onSwap;

  const _SwapAssistSheet({
    required this.mover,
    required this.destination,
    required this.assist,
    required this.onTakeFree,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final hasAnything =
        assist.freeSeatIds.isNotEmpty ||
        assist.movable.isNotEmpty ||
        assist.blocked.isNotEmpty;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm + 4,
        UgamSpacing.gutter,
        UgamSpacing.lg +
            math.max(
              MediaQuery.viewInsetsOf(context).bottom,
              MediaQuery.paddingOf(context).bottom,
            ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetGrabber(),
            Text(
              tr(
                'seat_detail.swap.title',
                namedArgs: {
                  'name': mover.displayName,
                  'destination': destination.name,
                },
              ),
              style: UgamText.titleM.copyWith(color: c.ink),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              mover.requestSummary,
              style: UgamText.caption.copyWith(color: c.ink2),
            ),
            const SizedBox(height: UgamSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!hasAnything)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: UgamSpacing.lg,
                        ),
                        child: Text(
                          tr(
                            'seat_detail.swap.no_room',
                            namedArgs: {'destination': destination.name},
                          ),
                          style: UgamText.body.copyWith(color: c.ink2),
                        ),
                      ),
                    if (assist.freeSeatIds.isNotEmpty) ...[
                      _SwapSectionLabel(
                        label: tr('seat_detail.swap.section_free'),
                        count: assist.freeSeatIds.length,
                        c: c,
                      ),
                      Wrap(
                        spacing: UgamSpacing.sm,
                        runSpacing: UgamSpacing.sm,
                        children: [
                          for (final seatId in assist.freeSeatIds)
                            GestureDetector(
                              onTap: () => onTakeFree(seatId),
                              behavior: HitTestBehavior.opaque,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: UgamSpacing.md,
                                  vertical: UgamSpacing.sm + 2,
                                ),
                                decoration: BoxDecoration(
                                  color: c.accentFill,
                                  borderRadius: BorderRadius.circular(
                                    UgamRadius.chip,
                                  ),
                                  border: Border.all(
                                    color: c.accent.withValues(alpha: 0.3),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.event_seat_rounded,
                                      size: 14,
                                      color: c.accent,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      seatId,
                                      style: UgamText.tabular(
                                        UgamText.caption.copyWith(
                                          color: c.accent,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: UgamSpacing.md),
                    ],
                    if (assist.movable.isNotEmpty) ...[
                      _SwapSectionLabel(
                        label: tr('seat_detail.swap.section_can_swap'),
                        count: assist.movable.length,
                        c: c,
                      ),
                      for (final cand in assist.movable)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.sm,
                          ),
                          child: GestureDetector(
                            onTap: () => onSwap(cand),
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              padding: const EdgeInsets.all(UgamSpacing.md),
                              decoration: BoxDecoration(
                                color: c.cardElev,
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.row,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: c.accent,
                                      shape: BoxShape.circle,
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      SeatChartTile.initials(
                                        cand.passengerName,
                                      ),
                                      style: UgamText.bodyStrong.copyWith(
                                        color: c.onAccent,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: UgamSpacing.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          cand.passengerName,
                                          style: UgamText.bodyStrong.copyWith(
                                            color: c.ink,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          tr(
                                            'seat_detail.swap.candidate_seat',
                                            namedArgs: {
                                              'seat': cand.seatId,
                                              'reason': cand.reason,
                                            },
                                          ),
                                          style: UgamText.micro.copyWith(
                                            color: c.ink2,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: UgamSpacing.sm),
                                  Icon(
                                    Icons.swap_horiz_rounded,
                                    size: 18,
                                    color: c.accent,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: UgamSpacing.md),
                    ],
                    if (assist.blocked.isNotEmpty) ...[
                      _SwapSectionLabel(
                        label: tr('seat_detail.swap.section_cannot_move'),
                        count: assist.blocked.length,
                        c: c,
                      ),
                      for (final b in assist.blocked)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.sm,
                          ),
                          child: Opacity(
                            opacity: 0.55,
                            child: Container(
                              padding: const EdgeInsets.all(UgamSpacing.md),
                              decoration: BoxDecoration(
                                color: c.cardElev.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(
                                  UgamRadius.row,
                                ),
                                border: Border.all(color: c.border),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      b.passengerName,
                                      style: UgamText.bodyStrong.copyWith(
                                        color: c.ink2,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: UgamSpacing.sm),
                                  Flexible(
                                    child: Text(
                                      b.reason,
                                      style: UgamText.micro.copyWith(
                                        color: c.ink3,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.end,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwapSectionLabel extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  const _SwapSectionLabel({
    required this.label,
    required this.count,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: Text(
        '${label.toUpperCase()} · $count',
        style: UgamText.micro.copyWith(color: c.ink3, letterSpacing: UgamText.tracking(0.8)),
      ),
    );
  }
}

class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
