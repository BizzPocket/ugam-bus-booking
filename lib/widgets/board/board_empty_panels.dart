part of 'board_empty_states.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Presentation.
// ─────────────────────────────────────────────────────────────────────────────

/// Medallion behind the state's icon. Decorative, so it scales with [UgamScale]
/// rather than being floored at a tap size.
const double _kMedallion = 56;
const double _kMedallionIcon = 26;
const double _kNoteMedallion = 32;
const double _kNoteIcon = 18;

/// The panel never stretches to the full width of a landscape phone — spec §3
/// makes landscape first-class, and a title stretched across 800pt reads as a
/// banner, not as a message.
const double _kPanelMaxWidth = 420;

/// Above this the zero note puts its action beside the text instead of under
/// it. Vertical space is the scarce one in landscape.
const double _kNoteRowBreakpoint = 420;

/// A full-bleed empty state that stands INSTEAD of the chart.
///
/// Deliberately not built on [UgamEmpty] even though it is the same family of
/// object, for three reasons that all matter here: this one carries a kind
/// eyebrow (the only signal separating "set up" from "not yet", and it is a
/// word, not a colour), it carries the preview facts spec §13 asks the boarding
/// state for, and its body is not capped at two lines — Gujarati is the primary
/// language and runs ~30% longer, so a two-line clamp truncates exactly the
/// sentence that explains the way out.
class BoardEmptyPanel extends StatelessWidget {
  final BoardEmptyState state;

  /// Fires with [BoardEmptyState.action]. The host owns the destination; see
  /// [BoardEmptyAction] for the real one behind each value.
  final ValueChanged<BoardEmptyAction> onAction;

  final EdgeInsetsGeometry padding;

  const BoardEmptyPanel({
    super.key,
    required this.state,
    required this.onAction,
    this.padding = const EdgeInsets.symmetric(
      horizontal: UgamSpacing.huge,
      vertical: UgamSpacing.huge2,
    ),
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final allClear = state.kind == BoardEmptyKind.allClear;
    final medallionFill = allClear ? c.goodFill : c.cardElev;
    final iconInk = allClear
        ? c.good
        : (state.kind == BoardEmptyKind.missing ? c.ink2 : c.ink3);

    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: padding,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _kPanelMaxWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: UgamScale.px(context, _kMedallion),
                  height: UgamScale.px(context, _kMedallion),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: medallionFill,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.border),
                  ),
                  child: Icon(
                    state.icon,
                    size: UgamScale.px(context, _kMedallionIcon),
                    color: iconInk,
                  ),
                ),
                const SizedBox(height: UgamSpacing.lg),
                // One screen-reader node for the message: eyebrow, then title,
                // then body, then any preview numbers — the same order a
                // sighted user reads them in.
                MergeSemantics(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        state.kind.eyebrow.toUpperCase(),
                        textAlign: TextAlign.center,
                        style: UgamText.micro.copyWith(
                          color: allClear ? c.good : c.ink3,
                        ),
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      Text(
                        state.title,
                        textAlign: TextAlign.center,
                        style: UgamText.titleM.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: UgamSpacing.sm),
                      Text(
                        state.body,
                        textAlign: TextAlign.center,
                        style: UgamText.body.copyWith(color: c.ink2),
                      ),
                      if (state.facts.isNotEmpty) ...[
                        const SizedBox(height: UgamSpacing.lg),
                        _FactRow(facts: state.facts),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: UgamSpacing.xl),
                UgamButton(
                  label: state.action.label,
                  icon: state.action.icon,
                  // A missing prerequisite is the thing to do next, so it takes
                  // the quiet-primary tonal weight; a "not yet" state is only
                  // offering a look ahead and must not compete with it.
                  kind: state.kind == BoardEmptyKind.missing
                      ? UgamButtonKind.tonal
                      : UgamButtonKind.neutral,
                  onPressed: () => onAction(state.action),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The preview numbers. A [Wrap], not a [Row]: two Gujarati labels side by side
/// on a 360pt phone are wider than they look in English.
class _FactRow extends StatelessWidget {
  final List<BoardEmptyFact> facts;

  const _FactRow({required this.facts});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: UgamSpacing.lg,
      runSpacing: UgamSpacing.sm,
      children: [
        for (final fact in facts)
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(fact.value, style: UgamText.numLg.copyWith(color: c.ink)),
              const SizedBox(height: UgamSpacing.xs),
              Text(
                fact.label,
                style: UgamText.caption.copyWith(color: c.ink3),
              ),
            ],
          ),
      ],
    );
  }
}

/// The **genuinely zero** state: a compact note pinned above a chart that still
/// draws.
///
/// This is the half of spec §13 the app gets wrong in the other direction. When
/// every rupee is in, the money lens is a bus of green ticks and a ₹0 total —
/// visually indistinguishable from a tour whose fares were never set. The note
/// says which of the two it is, in one line, without taking the chart away.
class BoardZeroNote extends StatelessWidget {
  final BoardEmptyState state;
  final ValueChanged<BoardEmptyAction> onAction;
  final EdgeInsetsGeometry margin;

  const BoardZeroNote({
    super.key,
    required this.state,
    required this.onAction,
    this.margin = const EdgeInsets.symmetric(
      horizontal: UgamSpacing.gutter,
      vertical: UgamSpacing.sm,
    ),
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final text = MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            state.title,
            style: UgamText.bodyStrong.copyWith(color: c.ink),
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            state.body,
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
        ],
      ),
    );

    final button = UgamButton(
      label: state.action.label,
      kind: UgamButtonKind.ghost,
      onPressed: () => onAction(state.action),
    );

    return Padding(
      padding: margin,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.goodFill,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          // The tonal fill alone is a colour-only signal; the hairline plus the
          // tick glyph carry the same "this is settled" meaning without it.
          border: Border.all(color: c.good.withValues(alpha: 0.28)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _kNoteRowBreakpoint;
            final head = Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: UgamScale.px(context, _kNoteMedallion),
                  height: UgamScale.px(context, _kNoteMedallion),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.good.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    state.icon,
                    size: UgamScale.px(context, _kNoteIcon),
                    color: c.good,
                  ),
                ),
                const SizedBox(width: UgamSpacing.md),
                Expanded(child: text),
                if (wide) ...[const SizedBox(width: UgamSpacing.md), button],
              ],
            );

            if (wide) return head;
            // Narrow: the action drops to its own line rather than squeezing
            // the Gujarati title into an ellipsis.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                head,
                const SizedBox(height: UgamSpacing.sm),
                button,
              ],
            );
          },
        ),
      ),
    );
  }
}
