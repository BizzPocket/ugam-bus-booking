part of 'board_screen.dart';

enum _EmptyKind { noTour, noBus }

/// One row of the loading chart: two berths, the walkway, two berths — the
/// silhouette of a sleeper coach, so the skeleton is recognisably THIS screen
/// arriving rather than a generic list of grey bars.
class _LoadingBerthRow extends StatelessWidget {
  const _LoadingBerthRow();

  @override
  Widget build(BuildContext context) {
    const berth = Expanded(
      child: UgamSkeleton(
        height: BerthTileMetrics.comfortableHeight,
        radius: UgamRadius.seat,
      ),
    );
    return const Row(
      children: [
        berth,
        SizedBox(width: UgamSpacing.xs),
        berth,
        // The aisle. Empty, because that is what makes the shape read as a bus.
        SizedBox(width: UgamSpacing.lg),
        berth,
        SizedBox(width: UgamSpacing.xs),
        berth,
      ],
    );
  }
}

/// Shown while somebody is held in hand for tap-to-place: who is moving, onto
/// which bus, and the ONE way out of the mode.
///
/// A deliberate twin of the seat grid's own `_RelocateBanner` — same words (the
/// same `tour_seat_assignment.relocate.banner` string), same accent-fill
/// treatment, same 44pt Cancel — because an agent who learns the mode on one
/// chart must recognise it instantly on the other. Both are private to their
/// screens; when a third surface needs it, THAT is the moment it earns a home
/// in `widgets/`.
class _RelocateBanner extends StatelessWidget {
  final String moverName;
  final String busName;
  final VoidCallback onCancel;

  const _RelocateBanner({
    required this.moverName,
    required this.busName,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: c.accentFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(color: c.accent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.touch_app_rounded,
            size: UgamScale.px(context, 18),
            color: c.accent,
          ),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              tr(
                'tour_seat_assignment.relocate.banner',
                namedArgs: {'name': moverName, 'bus': busName},
              ),
              style: UgamText.caption.copyWith(
                color: c.accent,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // The only exit from relocate mode, so it gets a real 44pt box; the
          // width factor keeps that box shrink-wrapped to the label so the
          // banner does not reflow.
          UgamTappable(
            onTap: onCancel,
            semanticLabel: tr('app.action.cancel'),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: UgamScale.tap(context, 44),
                minHeight: UgamScale.tap(context, 44),
              ),
              child: Center(
                widthFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.sm,
                  ),
                  child: Text(
                    tr('app.action.cancel'),
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Chrome pieces — each with its own Obx, so a lens tap does not rebuild the bus
// and a walk step does not rebuild the switcher.
// ─────────────────────────────────────────────────────────────────────────────

class _DensityAction extends StatelessWidget {
  final BoardController board;

  /// Drawable tiles on the bus, taken from the LAYOUT. See the note below on
  /// why this is not read off the controller.
  final int berthCount;

  const _DensityAction({required this.board, required this.berthCount});

  @override
  Widget build(BuildContext context) => Obx(() {
    // `BoardController.density` falls back to the berth count, and it reads
    // that count off the aisle walk — an observable the canvas republishes
    // from inside its own build. Subscribing to it from the app bar, which is
    // a SIBLING of the canvas rather than an ancestor, makes the framework
    // throw the moment the layout changes.
    //
    // So the default half of the rule is evaluated here, against the same
    // threshold and the same number, and the controller is only asked once the
    // user HAS a stored preference — at which point `??` short-circuits before
    // the walk is touched.
    final compact = board.densityIsManual
        ? board.isCompact
        : berthCount > BoardController.compactBerthThreshold;
    return UgamAppBarAction(
      // Compact shows the whole coach, so the action offers the OTHER mode —
      // the icon names where the tap goes, not where you are.
      icon: compact
          ? Icons.density_medium_rounded
          : Icons.density_small_rounded,
      tooltip: tr(
        compact
            ? 'board_screen.density_comfortable'
            : 'board_screen.density_compact',
      ),
      onTap: board.toggleDensity,
    );
  });
}

class _LensBar extends StatelessWidget {
  final BoardController board;

  const _LensBar({required this.board});

  @override
  Widget build(BuildContext context) => Obx(() {
    // Ordered by the enum rather than by set iteration, so the strip never
    // re-orders itself between two loads of the same tour.
    final lenses = [
      for (final id in BoardLensId.values)
        if (board.availableLenses.contains(id)) id,
    ];
    if (lenses.isEmpty) return const SizedBox.shrink();
    return BoardLensSwitcher(
      lenses: lenses,
      current: board.lens,
      onChanged: board.selectLens,
    );
  });
}

class _LegendBar extends StatelessWidget {
  final BoardController board;
  final BoardLens lens;

  /// The bus on screen in aisle order. [BoardLegend] drops any row no berth
  /// here matches (spec §13), so this is what stops the Board doing what the
  /// chart does today: printing ten colour codes over an empty bus.
  final List<BoardBerth> berths;

  const _LegendBar({
    required this.board,
    required this.lens,
    required this.berths,
  });

  @override
  Widget build(BuildContext context) => Obx(
    () => Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.sm),
      child: BoardLegend(
        lens: lens,
        berths: berths,
        activeId: board.legendFilter.value,
        onToggle: board.toggleLegendFilter,
      ),
    ),
  );
}

/// **"આગળનું બાકી →"** — the walk control of spec §4, in the summary strip's
/// trailing slot (which the strip reserves for exactly this).
///
/// It renders the arrow and the REMAINING COUNT rather than the words. That is
/// a width decision, not a shortcut: the strip's job is to pin `₹55,200 બાકી ·
/// 32% એકઠી` where it can never be lost, Gujarati is the primary language and
/// runs ~30% longer than English, and `આગળનું બાકી →` set beside that figure on
/// a 375pt phone ellipsizes the FIGURE — the one thing spec §3 says must never
/// go. The words are carried in full by the semantic label and the tooltip, and
/// the count is the more useful glance anyway: it is the length of the round.
///
/// When nothing is left the control does not vanish (it is "persistent"), it
/// goes quiet: a tick, no accent, no gesture, and a screen reader is told the
/// round is complete.
class _NextOutstanding extends StatelessWidget {
  static const Key tapKey = Key('board_screen.next_outstanding');

  final BoardController board;
  final List<BoardBusPage> pages;
  final BoardLens Function(BoardBusPage page) lensOf;
  final Future<void> Function() onAdvance;

  const _NextOutstanding({
    required this.board,
    required this.pages,
    required this.lensOf,
    required this.onAdvance,
  });

  @override
  Widget build(BuildContext context) => Obx(() {
    final c = UgamColors.of(context);
    if (pages.isEmpty) return const SizedBox.shrink();

    final page = pages[board.busIndex.value.clamp(0, pages.length - 1)];
    final needsAction = boardNeedsAction(lensOf(page), page.berths);
    // Reads the walk, so the count is live: it drops as the round is worked.
    final remaining = board.outstandingCount(needsAction);
    final hasNext = board.hasNextOutstanding(needsAction);

    final done = remaining == 0 || !hasNext;
    final ink = done ? c.ink3 : c.accent;

    return Semantics(
      button: !done,
      enabled: !done,
      label: done
          ? tr('board_screen.round_done_a11y')
          : tr(
              'board_screen.next_outstanding_a11y',
              namedArgs: {'count': '$remaining'},
            ),
      onTap: done ? null : () => unawaited(onAdvance()),
      child: ExcludeSemantics(
        child: Tooltip(
          message: done
              ? tr('board_screen.round_done')
              : tr('board_screen.next_outstanding'),
          child: UgamTappable(
            key: tapKey,
            onTap: done ? null : () => unawaited(onAdvance()),
            // The advance fires its own selectionClick (spec §12); the
            // wrapper's lightImpact on top would double-buzz every step of a
            // 22-person round.
            haptic: false,
            pressedScale: 0.93,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: UgamScale.tap(context, 44),
                minWidth: UgamScale.tap(context, 44),
              ),
              child: Center(
                child: AnimatedContainer(
                  duration: UgamMotion.tab,
                  curve: UgamMotion.easeOut,
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: UgamSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: done ? c.card : c.accentFill,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                    border: Border.all(
                      color: done
                          ? c.border
                          : c.accent.withValues(alpha: 0.55),
                      width: done ? 1 : 1.4,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!done)
                        Text(
                          '$remaining',
                          maxLines: 1,
                          style: UgamText.tabular(
                            UgamText.bodyStrong.copyWith(color: ink),
                          ),
                        ),
                      if (!done) const SizedBox(width: UgamSpacing.xs),
                      Icon(
                        done
                            ? Icons.check_rounded
                            : Icons.arrow_forward_rounded,
                        size: UgamScale.px(context, 18),
                        color: ink,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  });
}
