part of '../add_bus_screen.dart';

// ════════════════════════════════════════════════════════════════════════
// Step 2 — Capacity & layout
// ════════════════════════════════════════════════════════════════════════

class _Step2Capacity extends StatelessWidget {
  final UgamColorSet c;
  final int totalSeats;
  final int singleSofaCount;
  final int sleeperSeats;
  final String singleSofaSummary;

  /// Current state of the "all-double last row" toggle, and the callback that
  /// flips it. When on, the seat engine builds the last row as 4 double sofas;
  /// when off (default) it builds 3 single + 2 double sofas.
  final bool allDoubleBackRow;
  final ValueChanged<bool> onAllDoubleBackRow;

  /// Inline validation caption shown under the single-sofa stepper, or null
  /// when the value is valid. Replaces the legacy save-time toast.
  final String? singleSofaError;

  /// Edit-mode resize warning shown above the controls when the bus already has
  /// passengers seated — changing the size will unassign them. Null hides it.
  final String? seatedWarning;

  /// Edit-mode only: force-rebuild the saved layout from the current settings
  /// (re-applies the current seat engine to a bus saved under the old one).
  /// Null in add mode, which hides the "Regenerate layout" button.
  final VoidCallback? onRegenerate;

  /// Non-null when this bus's seat plan can no longer be rebuilt (a locked or
  /// completed tour). The controls below are shown but made inert rather than
  /// hidden: the agent still needs to READ the capacity they are working with,
  /// and a step that vanished would read as a bug. The rest of the wizard —
  /// driver, boarding, departure, pricing — stays fully editable.
  final String? frozenNotice;

  final ValueChanged<int> onTotalSeats;
  final ValueChanged<int> onSingleSofa;

  const _Step2Capacity({
    required this.c,
    required this.totalSeats,
    required this.singleSofaCount,
    required this.sleeperSeats,
    required this.singleSofaSummary,
    required this.allDoubleBackRow,
    required this.onAllDoubleBackRow,
    this.singleSofaError,
    this.seatedWarning,
    this.onRegenerate,
    this.frozenNotice,
    required this.onTotalSeats,
    required this.onSingleSofa,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      physics: const BouncingScrollPhysics(),
      children: [
        _StepIntro(
          c: c,
          title: tr('add_bus.step2.title'),
          body: tr('add_bus.step2.body'),
        ),
        // The frozen notice replaces the resize warning rather than stacking
        // with it: "resizing will unassign N people" is advice about a change
        // that can no longer be made, so showing both would contradict.
        if (frozenNotice != null) ...[
          const SizedBox(height: UgamSpacing.lg),
          _ResizeWarning(c: c, text: frozenNotice!),
        ] else if (seatedWarning != null) ...[
          const SizedBox(height: UgamSpacing.lg),
          _ResizeWarning(c: c, text: seatedWarning!),
        ],
        const SizedBox(height: UgamSpacing.xl),
        // Frozen: the whole capacity cluster goes inert in ONE place rather
        // than each control growing its own disabled flag. AbsorbPointer stops
        // the taps and the dimming is what tells the agent why nothing moves —
        // a stepper that silently ignored a press would read as a broken app.
        // The values stay legible, which is the point of showing the step at
        // all on a locked tour.
        _MaybeInert(
          inert: frozenNotice != null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Every bus in this app is a sleeper coach, so there's no bus-type
              // picker — the layout is always sleeper berths (single + double).
              _Label(c: c, text: tr('add_bus.label.total_seats')),
              const SizedBox(height: UgamSpacing.sm),
              _StepperRow(
                c: c,
                value: totalSeats,
                min: 1,
                max: 100,
                onChanged: onTotalSeats,
              ),
              if (sleeperSeats > 0) ...[
                const SizedBox(height: UgamSpacing.xl),
                _Label(c: c, text: tr('add_bus.label.single_sofa_count')),
                const SizedBox(height: UgamSpacing.sm),
                _StepperRow(
                  c: c,
                  value: singleSofaCount,
                  min: 0,
                  max: sleeperSeats,
                  onChanged: onSingleSofa,
                ),
                const SizedBox(height: UgamSpacing.sm),
                Text(
                  singleSofaSummary,
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
                if (singleSofaError != null) ...[
                  const SizedBox(height: UgamSpacing.xs),
                  _InlineError(c: c, text: singleSofaError!),
                ],
                const SizedBox(height: UgamSpacing.sm),
                _ToggleRow(
                  c: c,
                  icon: Icons.weekend_rounded,
                  label: tr('add_bus.back_row_toggle.label'),
                  subtitle: allDoubleBackRow
                      ? tr('add_bus.back_row_toggle.on')
                      : tr('add_bus.back_row_toggle.off'),
                  value: allDoubleBackRow,
                  onChanged: onAllDoubleBackRow,
                ),
                if (onRegenerate != null) ...[
                  const SizedBox(height: UgamSpacing.lg),
                  // This is a button, not a settings row — it was the third
                  // copy of the icon+title+subtitle+chevron row, and the
                  // chevron read as "opens something" when it actually rebuilds
                  // and saves. The subtitle's explanation now lives in the
                  // destructive confirm, which is where it is actually read
                  // before anything happens.
                  UgamButton(
                    label: tr('add_bus.regenerate_label'),
                    kind: UgamButtonKind.neutral,
                    icon: Icons.refresh_rounded,
                    expand: true,
                    onPressed: onRegenerate,
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: UgamSpacing.xl),
      ],
    );
  }
}

/// Wraps [child] so it can be read but not touched.
///
/// Used for Step 2's capacity cluster once the seat plan is frozen. Kept as a
/// named widget rather than an inline ternary so the "shown, dimmed, inert"
/// treatment is one decision in one place — and so `inert: false` costs nothing
/// but a passthrough on the far more common unlocked path.
class _MaybeInert extends StatelessWidget {
  final bool inert;
  final Widget child;

  const _MaybeInert({required this.inert, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!inert) return child;
    return Opacity(
      opacity: 0.45,
      // Excluded from semantics traversal as well: a screen reader offering
      // "increment total seats" on a control that refuses would be worse than
      // the visual dimming it cannot see.
      child: ExcludeSemantics(child: AbsorbPointer(child: child)),
    );
  }
}

/// Edit-mode caution shown above the capacity controls when the bus already has
/// passengers seated: resizing renumbers the seats, so those people will be
/// unassigned (and returned to the pool) if the admin changes the size.
class _ResizeWarning extends StatelessWidget {
  final UgamColorSet c;
  final String text;

  const _ResizeWarning({required this.c, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.warmFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: UgamScale.px(context, 16),
            color: c.warm,
          ),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: UgamText.caption.copyWith(color: c.ink2, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepperRow extends StatelessWidget {
  final UgamColorSet c;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _StepperRow({
    required this.c,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // Interactive slab: the +/- buttons fill its full height, so the shell
      // and the buttons must resolve through the SAME helper or they diverge
      // and the row overflows. 56 -> 47.6 at the 0.85 floor, still legal.
      height: UgamScale.tap(context, 56),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          _StepperBtn(
            c: c,
            icon: Icons.remove_rounded,
            enabled: value > min,
            onTap: () => onChanged(value - 1),
          ),
          Expanded(
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: UgamText.tabular(UgamText.titleM.copyWith(color: c.ink)),
            ),
          ),
          _StepperBtn(
            c: c,
            icon: Icons.add_rounded,
            enabled: value < max,
            onTap: () => onChanged(value + 1),
          ),
        ],
      ),
    );
  }
}

class _StepperBtn extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepperBtn({
    required this.c,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return UgamTappable(
      onTap: enabled
          ? () {
              HapticFeedback.selectionClick();
              onTap();
            }
          : null,
      // The callback already fires its own selection click, and a stepper is
      // the one control here a finger can hammer — a second buzz per tap turns
      // into a rattle when the agent holds 40 seats down to 32.
      haptic: false,
      // Small chrome needs more travel than a card to read as pressed.
      pressedScale: 0.90,
      child: Container(
        // Same helper as _StepperRow's shell (see the note there).
        width: UgamScale.tap(context, 56),
        height: UgamScale.tap(context, 56),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: UgamScale.px(context, 20),
          color: enabled ? c.ink : c.ink3,
        ),
      ),
    );
  }
}
