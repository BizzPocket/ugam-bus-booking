part of '../tour_seat_assignment_screen.dart';

// ─── Assignment dock ───────────────────────────────────────────────────
//
// Cohesive bottom panel that floats over the seat chart. Two snap states:
//   • Collapsed (default): grab handle + a one-line active-passenger summary
//     + the pending queue strip + the lock/download action. The chart owns
//     all the space above, so the WHOLE grid is visible.
//   • Expanded: drag the handle up (or tap it) to reveal the full passenger
//     detail (phone, every pending line, handler nudge, edit) — the sheet
//     grows UPWARD as an overlay, so the chart is never squeezed.
//
// Replaces the old stacked `_PassengerCard` + `_PendingDock`, which together
// ate ~40% of the screen and left only a sliver of the chart visible.
class _AssignmentDock extends StatelessWidget {
  final UgamColorSet c;
  final Tour tour;

  /// Active passenger being seated. Null when nobody is selected or every
  /// seat is filled — the dock then shows only its queue / done-state.
  final Passenger? passenger;
  final List<_PendingLine> pendingLines;
  final String? handlerId;
  final VoidCallback onManageBuses;

  /// The pending queue (everyone still needing seats).
  final List<Passenger> pending;
  final String? activeId;
  final ValueChanged<String> onTapPassenger;

  /// A pending-rider chip started / ended being dragged toward a seat. The
  /// screen uses these to light up fitting seats during the drag.
  final ValueChanged<String> onPendingDragStarted;
  final VoidCallback onPendingDragEnded;

  final VoidCallback? onLockTour;
  final VoidCallback? onDownloadChart;

  final bool expanded;
  final VoidCallback onToggleExpanded;
  final ValueChanged<bool> onSetExpanded;

  const _AssignmentDock({
    required this.c,
    required this.tour,
    required this.passenger,
    required this.pendingLines,
    required this.handlerId,
    required this.onManageBuses,
    required this.pending,
    required this.activeId,
    required this.onTapPassenger,
    required this.onPendingDragStarted,
    required this.onPendingDragEnded,
    required this.onLockTour,
    required this.onDownloadChart,
    required this.expanded,
    required this.onToggleExpanded,
    required this.onSetExpanded,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final e = UgamElevation.of(context);
    final hasActive = passenger != null;
    final showDetail = expanded && hasActive;

    return Container(
      decoration: BoxDecoration(
        color: c.card,
        // Lift the sheet off the chart only while it overlays it (expanded);
        // deliberately flush with the page when collapsed.
        //
        // This was a hand-rolled `Colors.black @ 22%, blur 20, offset (0,-8)`
        // that painted IDENTICALLY in both themes. On the near-black Midnight
        // ground that is exactly the pooled "dirty halo" [UgamElevation] was
        // written to stop; on Daylight it was an untinted grey that reads as
        // dirt under the warm neutral surfaces.
        //
        // `raised` (level 2), not `rest`: while expanded this dock OVERLAYS the
        // seat chart, which is the sheet role the token names. It is also the
        // only level whose wide layer is deliberately offset-free, so a surface
        // anchored to the BOTTOM edge still casts upward — `rest` is two
        // downward layers that would fall off the bottom of the screen and
        // leave the dock looking pasted on.
        boxShadow: showDetail ? e.raised : e.flat,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Grab handle — tap toggles, a vertical flick snaps open/closed.
          // Disabled when there's no active passenger (nothing to expand to).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasActive ? onToggleExpanded : null,
            onVerticalDragEnd: hasActive
                ? (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -50) {
                      onSetExpanded(true);
                    } else if (v > 50) {
                      onSetExpanded(false);
                    }
                  }
                : null,
            child: Container(
              width: double.infinity,
              alignment: Alignment.center,
              // Pure hit-area growth (18 -> 44): the visible 36x4 bar and its
              // centred position are unchanged. This zone owns BOTH the tap
              // toggle and the drag-to-snap, and at 18pt the "drag the handle
              // up" gesture landed on the chart behind it instead.
              padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xxl),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: hasActive ? c.ink3 : c.border,
                  // 999 clamps to 2 on a 4pt-tall bar — identical pixels.
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
              ),
            ),
          ),
          // Body: full detail when expanded, otherwise the one-line summary.
          // AnimatedSize keeps owning the height change; the inner
          // AnimatedSwitcher cross-fades the detail / compact / done content so
          // the swap eases instead of popping. Keyed so the switcher animates.
          AnimatedSize(
            // Was a raw 200ms against the inner switcher's 180ms, so the dock's
            // content visibly lagged its container on expand.
            duration: UgamMotion.sheet,
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: AnimatedSwitcher(
              duration: UgamMotion.sheet,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeOutCubic,
              child: showDetail
                  ? ConstrainedBox(
                      key: const ValueKey('dock-detail'),
                      constraints: BoxConstraints(
                        maxHeight: media.size.height * 0.5,
                      ),
                      child: SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        child: _PassengerCard(
                          tour: tour,
                          passenger: passenger!,
                          pending: pendingLines,
                          handlerId: handlerId,
                          onManageBuses: onManageBuses,
                        ),
                      ),
                    )
                  : hasActive
                  ? KeyedSubtree(
                      key: const ValueKey('dock-compact'),
                      child: _compactActive(context),
                    )
                  : const SizedBox.shrink(key: ValueKey('dock-done')),
            ),
          ),
          // Queue strip + primary action, then the bottom safe-area inset.
          _queueRow(context),
          SizedBox(height: media.padding.bottom + UgamSpacing.xs),
        ],
      ),
    );
  }

  /// One-line active-passenger summary shown while collapsed: avatar, name,
  /// request summary + "needs N more", and the seats-assigned tally. Tapping
  /// it expands the dock (same as the handle).
  Widget _compactActive(BuildContext context) {
    final p = passenger!;
    final stillNeeded = pendingLines.fold<int>(0, (s, l) => s + l.remaining);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.xs,
        UgamSpacing.gutter,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          UgamSectionLabel(tr('tour_seat_assignment.now_seating')),
          const SizedBox(height: UgamSpacing.xs),
          // The active passenger sits in ONE clearly-accented card so it never
          // reads as "just another queue row". Tapping it expands to the full
          // request breakdown (same as the grab handle).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggleExpanded,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.tight,
              ),
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(UgamRadius.row),
                border: Border.all(color: c.accent.withValues(alpha: 0.28)),
              ),
              child: Row(
                children: [
                  Container(
                    // Accent-rationing: this disc was a solid `c.accent` fill
                    // sitting INSIDE an already accentFill-tinted card, right
                    // above the solid-accent Lock & notify button — three
                    // coppers competing in the collapsed dock. `c.card` (not
                    // accentFill) because accentFill on accentFill is invisible
                    // in light mode. The one solid accent left on this screen is
                    // the dock's primary UgamButton.
                    width: UgamScale.px(context, 38),
                    height: UgamScale.px(context, 38),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.card,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      SeatChartTile.initials(p.displayName),
                      // bodyStrong is already 14 — the override was a no-op.
                      style: UgamText.bodyStrong.copyWith(color: c.accent),
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.tight),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          p.displayName,
                          // titleS IS 15 — this was `titleM` (18) forked down.
                          style: UgamText.titleS.copyWith(color: c.ink),
                          // 2 lines before ellipsis — app-wide name rule, see
                          // UgamRequestRow.
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 1),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                p.requestSummary,
                                style: UgamText.caption.copyWith(color: c.ink2),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (stillNeeded > 0) ...[
                              Text(
                                '  ·  ',
                                style:
                                    UgamText.caption.copyWith(color: c.ink3),
                              ),
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
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Text(
                    '${p.totalSeatsAssigned}/${p.totalSeatsRequested}',
                    // titleS IS 15 — matches the name beside it, and the
                    // expanded card's tally now sits on bodyStrong (14), so the
                    // pair no longer jumps size on a dock toggle.
                    style: UgamText.tabular(
                      UgamText.titleS.copyWith(color: c.ink),
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.xs),
                  Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: c.ink3),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Pending queue — a VERTICAL list of up to three full-name [UgamPersonRow]s
  /// (the active one framed selected) plus a "See all N" row opening the full
  /// pending sheet, then the primary lock / download action. The vertical rows
  /// give each pending passenger their full name + request summary instead of
  /// the old horizontal cards that truncated names.
  Widget _queueRow(BuildContext context) {
    const cap = 6;
    // The active rider already has the "Now seating" card right above (or the
    // expanded detail) — listing them again as the first "Up next" chip showed
    // the same person twice. Up next = everyone ELSE still waiting.
    final upNext = passenger == null
        ? pending
        : pending.where((p) => p.id != passenger!.id).toList();
    final visible = upNext.take(cap).toList();
    final overflow = upNext.length - visible.length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pending.isEmpty)
            Row(
              children: [
                Icon(Icons.check_circle_rounded, size: 16, color: c.good),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    tr('tour_seat_assignment.all_assigned_dock'),
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                ),
              ],
            )
          else if (upNext.isNotEmpty) ...[
            // "Up next" as a single COMPACT horizontal strip of passenger
            // chips, clearly under the "Now seating" card — no more stacked
            // near-identical full-width rows. Full names + request breakdown
            // still live one tap away in the "See all" sheet.
            Row(
              children: [
                Expanded(
                  child: UgamSectionLabel(
                    tr(
                      'tour_seat_assignment.up_next',
                      namedArgs: {'count': '${upNext.length}'},
                    ),
                  ),
                ),
                if (overflow > 0)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _showAllPending(context),
                    // On a >6-deep queue this label is the ONLY route to the
                    // rest of the riders, and it was a bare ~20pt Row. Padding
                    // (12 + 20 + 12) takes it to 44 without touching the
                    // painted label or chevron.
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UgamSpacing.sm,
                        vertical: UgamSpacing.md,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tr('tour_seat_assignment.dock_see_all_short'),
                            style: UgamText.caption.copyWith(
                              color: c.ink2,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 16,
                            color: c.ink3,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: UgamSpacing.xs + 2),
            SizedBox(
              // The chips inside were 40pt — a horizontally-scrolling strip of
              // sub-44 targets. tap() floors the strip at 44 and lets it reach
              // the tuned 48 on a baseline-width phone.
              height: UgamScale.tap(context, 48),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemCount: visible.length + (overflow > 0 ? 1 : 0),
                separatorBuilder: (_, _) =>
                    const SizedBox(width: UgamSpacing.sm),
                itemBuilder: (ctx, i) {
                  if (i >= visible.length) {
                    return _pendingMoreChip(context, overflow);
                  }
                  return _pendingChip(context, visible[i]);
                },
              ),
            ),
          ],
          // Primary action slot (mutually exclusive): Lock > Pick-handler >
          // Download.
          //
          // Pick-handler is the done-state dead-end fix: every seat is assigned
          // but no handler is picked, so the lock gate stays closed and the
          // in-detail handler nudge (only shown while a passenger is expanded)
          // is unreachable — this CTA routes to Manage Buses to pick one.
          if (onLockTour != null) ...[
            const SizedBox(height: UgamSpacing.xs),
            UgamButton(
              label: tr('tour_seat_assignment.btn_lock_notify'),
              icon: Icons.lock_rounded,
              kind: UgamButtonKind.primary,
              expand: true,
              onPressed: onLockTour,
            ),
          ] else if (handlerId == null &&
              pending.isEmpty &&
              tour.status != TourStatus.locked &&
              tour.status != TourStatus.completed) ...[
            const SizedBox(height: UgamSpacing.xs),
            UgamButton(
              label: tr('tour_seat_assignment.btn_pick_handler_lock'),
              icon: Icons.badge_outlined,
              kind: UgamButtonKind.primary,
              expand: true,
              onPressed: onManageBuses,
            ),
          ] else if (onDownloadChart != null) ...[
            const SizedBox(height: UgamSpacing.xs),
            UgamButton(
              label: tr('tour_seat_assignment.btn_download_chart'),
              icon: Icons.download_rounded,
              // Solid only once everyone is seated: with riders still waiting
              // the job on this screen is seating them, and a solid Download
              // claimed the one accent for a chart that is not finished yet.
              kind: pending.isEmpty
                  ? UgamButtonKind.primary
                  : UgamButtonKind.tonal,
              expand: true,
              onPressed: onDownloadChart,
            ),
          ],
          // Download the chart ALONGSIDE a Lock / Pick-handler primary, so the
          // organiser can review or share it BEFORE locking. Kept secondary
          // (neutral) so Lock stays the single accent primary; suppressed when
          // Download is already the primary above (its own else-if branch).
          if (onDownloadChart != null &&
              (onLockTour != null ||
                  (handlerId == null &&
                      pending.isEmpty &&
                      tour.status != TourStatus.locked &&
                      tour.status != TourStatus.completed))) ...[
            const SizedBox(height: UgamSpacing.xs),
            UgamButton(
              label: tr('tour_seat_assignment.btn_download_chart'),
              icon: Icons.download_rounded,
              kind: UgamButtonKind.neutral,
              expand: true,
              onPressed: onDownloadChart,
            ),
          ],
        ],
      ),
    );
  }

  /// One compact "Up next" chip: avatar + name + assigned/requested tally.
  /// Tapping it makes that passenger active (same as the old vertical row). The
  /// active passenger is accent-filled so the strip echoes the "Now seating"
  /// card above it.
  Widget _pendingChip(BuildContext context, Passenger p) {
    final selected = activeId == p.id;
    final chip = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTapPassenger(p.id);
      },
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.xs,
          UgamSpacing.sm,
          UgamSpacing.md,
          UgamSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: selected ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: selected
              ? Border.all(color: c.accent.withValues(alpha: 0.35))
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              // Accent-rationing: a solid copper disc here rendered at the same
              // time as the "Now seating" avatar ~60px above, for the SAME
              // person — read as two different selected passengers. The chip
              // already carries selection via its accentFill + accent hairline.
              width: UgamScale.px(context, 30),
              height: UgamScale.px(context, 30),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? c.accent.withValues(alpha: 0.18)
                    : c.card,
                shape: BoxShape.circle,
              ),
              child: Text(
                SeatChartTile.initials(p.displayName),
                style: UgamText.caption.copyWith(
                  color: selected ? c.accent : c.ink2,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 108),
              child: Text(
                p.displayName,
                style: UgamText.caption.copyWith(
                  color: selected ? c.accent : c.ink,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${p.totalSeatsAssigned}/${p.totalSeatsRequested}',
              // Dropped the fractional 10.5 fork onto caption's own 12,
              // matching the name it sits beside.
              style: UgamText.tabular(
                UgamText.caption.copyWith(
                  color: selected ? c.accent : c.ink3,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // Long-press to DRAG this rider onto a seat (tap still selects). 150ms hold
    // so a horizontal swipe still scrolls the strip. The screen flags the drag
    // so fitting seats light up; the seat's drop target does the placement.
    return LongPressDraggable<PendingRiderDragData>(
      data: PendingRiderDragData(p.id),
      delay: const Duration(milliseconds: 150),
      hapticFeedbackOnStart: true,
      onDragStarted: () => onPendingDragStarted(p.id),
      onDragEnd: (_) => onPendingDragEnded(),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.md,
            vertical: UgamSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: c.accent,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Text(
            p.displayName,
            style: UgamText.caption.copyWith(
              color: c.onAccent,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: chip),
      child: chip,
    );
  }

  /// Trailing "+N" chip on the "Up next" strip → opens the full pending sheet.
  Widget _pendingMoreChip(BuildContext context, int overflow) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showAllPending(context),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: Border.all(color: c.border),
        ),
        child: Text(
          '+$overflow',
          style: UgamText.bodyStrong.copyWith(color: c.ink2),
        ),
      ),
    );
  }

  /// Full sheet of every pending passenger — opened from the dock's "+N"
  /// overflow tile so the agent can jump to anyone, not just the first few.
  void _showAllPending(BuildContext context) {
    UgamSheet.show<void>(
      context,
      title: tr(
        'tour_seat_assignment.dock_all_pending_title',
        namedArgs: {'count': '${pending.length}'},
      ),
      builder: (sheetCtx) {
        final cc = UgamColors.of(sheetCtx);
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.55,
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const BouncingScrollPhysics(),
            itemCount: pending.length,
            separatorBuilder: (_, _) => const SizedBox(height: UgamSpacing.sm),
            itemBuilder: (_, i) {
              final p = pending[i];
              final selected = p.id == activeId;
              return UgamPersonRow(
                name: p.displayName,
                subtitle: p.requestSummary,
                initials: SeatChartTile.initials(p.displayName),
                selected: selected,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  onTapPassenger(p.id);
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) ...[
                      Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: cc.accent,
                      ),
                      const SizedBox(width: UgamSpacing.xs),
                    ],
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: cc.ink3,
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
