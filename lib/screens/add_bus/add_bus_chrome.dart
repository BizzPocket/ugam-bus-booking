part of '../add_bus_screen.dart';

// ════════════════════════════════════════════════════════════════════════
// Wizard progress — slim step-dot bar under the app bar
// ════════════════════════════════════════════════════════════════════════

class _WizardProgress extends StatelessWidget {
  final UgamColorSet c;
  final int steps;
  final int index;

  /// Name of the current step ("Capacity"). Three anonymous bars told the agent
  /// how far along they were but never WHAT they were being asked for, and the
  /// step's own eyebrow — the only place that word appeared — was below the
  /// fold as soon as a keyboard opened. It lives here now, next to the count.
  final String label;

  const _WizardProgress({
    required this.c,
    required this.steps,
    required this.index,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Expanded, not natural width: the Gujarati step names run well
              // past the English ones and the counter beside them must never be
              // the child that decides this row's width.
              Expanded(child: UgamSectionLabel(label, color: c.ink2)),
              const SizedBox(width: UgamSpacing.sm),
              Text(
                tr(
                  'add_bus.step_progress',
                  namedArgs: {'current': '${index + 1}', 'total': '$steps'},
                ),
                style: UgamText.tabular(UgamText.micro.copyWith(color: c.ink3)),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          _bars(),
        ],
      ),
    );
  }

  Widget _bars() {
    return Row(
      children: List.generate(steps, (i) {
        final active = i == index;
        final done = i < index;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              right: i == steps - 1 ? 0 : UgamSpacing.xs,
            ),
            child: AnimatedContainer(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              height: 4,
              decoration: BoxDecoration(
                // Accent-rationing: only the ACTIVE segment is solid copper.
                // Completed segments go tonal, so Step 3 no longer shows
                // three filled bars competing with the copper Save CTA.
                color: active
                    ? c.accent
                    : (done ? c.accent.withValues(alpha: 0.45) : c.cardElev),
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
            ),
          ),
        );
      }),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════
// Bottom bar — Back pill + Next/Save CTA
// ════════════════════════════════════════════════════════════════════════

class _BottomBar extends StatelessWidget {
  final UgamColorSet c;
  final bool isFirst;
  final bool isLast;
  final bool canAdvance;
  final bool saving;
  final bool isEditing;
  final VoidCallback onBack;
  final VoidCallback onNext;

  const _BottomBar({
    required this.c,
    required this.isFirst,
    required this.isLast,
    required this.canAdvance,
    required this.saving,
    required this.isEditing,
    required this.onBack,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final ctaLabel = isLast
        ? (saving
              ? tr('add_bus.action.saving')
              : (isEditing
                    ? tr('add_bus.action.save_changes')
                    : tr('add_bus.action.save')))
        : tr('app.action.next');
    final ctaIcon = isLast
        ? (isEditing ? Icons.check_rounded : Icons.add_rounded)
        : Icons.arrow_forward_rounded;

    return UgamStickyCTA(
      child: Row(
        children: [
          if (!isFirst) ...[
            _BackPill(c: c, onTap: onBack),
            const SizedBox(width: UgamSpacing.md),
          ],
          Expanded(
            child: UgamCTA(
              label: ctaLabel,
              leadingIcon: ctaIcon,
              loading: saving,
              onPressed: canAdvance ? onNext : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _BackPill extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;

  const _BackPill({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return UgamTappable(
      onTap: onTap,
      semanticLabel: tr('app.action.back'),
      // The CTA beside it answers a finger with a scale + haptic; this pill
      // did nothing at all, which read as "disabled" next to a live button.
      // 0.96 matches UgamCTA's travel rather than the card default.
      pressedScale: 0.96,
      child: Container(
        // Pixel-matched to the UgamCTA sitting beside it in the same Row.
        // UgamCTA resolves as max(44, md*2 + titleS) — so this uses the SAME
        // `md` vertical padding, the SAME 44 floor, the SAME titleS label and
        // the SAME 18pt leading icon. The old `lg + 2` (18) was what made the
        // pill ~56 against the CTA's 44. Deliberately NOT UgamButton: its
        // hardcoded 50 cannot match the CTA, which is the whole defect here.
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Fixed 18 (not scaled) so it stays identical to UgamCTA's
            // leadingIcon, which is also a fixed 18.
            Icon(Icons.chevron_left_rounded, size: 18, color: c.ink),
            const SizedBox(width: UgamSpacing.xs),
            Text(
              tr('app.action.back'),
              style: UgamText.titleS.copyWith(color: c.ink),
            ),
          ],
        ),
      ),
    );
  }
}
