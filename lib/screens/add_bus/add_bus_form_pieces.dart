part of '../add_bus_screen.dart';

// ════════════════════════════════════════════════════════════════════════
// Shared form pieces
// ════════════════════════════════════════════════════════════════════════

/// Step heading: title + one explanatory line.
///
/// It used to open with a copper eyebrow repeating the step's name. That was
/// two problems in one line — the accent is reserved for "this is yours" and an
/// eyebrow is neither a selection nor an ownership state, and the same word now
/// sits in the progress bar where it stays visible once the keyboard covers the
/// step body. The eyebrow moved there; only the title and body remain.
class _StepIntro extends StatelessWidget {
  final UgamColorSet c;
  final String title;
  final String body;

  const _StepIntro({required this.c, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: UgamText.titleXl.copyWith(color: c.ink)),
        const SizedBox(height: UgamSpacing.sm),
        Text(body, style: UgamText.body.copyWith(color: c.ink2, height: 1.5)),
      ],
    );
  }
}

/// Section header that splits the identity step into meaningful groups
/// ("The bus", "Boarding", "Driver") so it reads as structure, not a uniform
/// stack of inputs. Brighter than a field [_Label] so the two never read as
/// the same level.
///
/// Now just [UgamSectionLabel] with the brighter ink. It used to fork
/// `letterSpacing` to 0.6 against micro's own 1.4, so a group header and the
/// field label directly beneath it — which a user reads as one family — had
/// visibly different tracking. Colour alone carries the tier now, which is
/// what this widget's contract always claimed.
class _GroupHeader extends StatelessWidget {
  final UgamColorSet c;
  final String text;
  const _GroupHeader({required this.c, required this.text});

  @override
  Widget build(BuildContext context) => UgamSectionLabel(text, color: c.ink);
}

class _Label extends StatelessWidget {
  final UgamColorSet c;
  final String text;
  const _Label({required this.c, required this.text});

  @override
  Widget build(BuildContext context) => UgamSectionLabel(text, color: c.ink2);
}

/// Small inline validation caption (danger-tinted) shown beneath a non-input
/// control — used in place of a save-time error toast for layout/stepper
/// validations that can't attach to a UgamInput errorText.
class _InlineError extends StatelessWidget {
  final UgamColorSet c;
  final String text;

  const _InlineError({required this.c, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.error_outline_rounded,
          size: UgamScale.px(context, 14),
          color: c.danger,
        ),
        const SizedBox(width: UgamSpacing.xs),
        Expanded(
          child: Text(
            text,
            style: UgamText.caption.copyWith(color: c.danger, height: 1.35),
          ),
        ),
      ],
    );
  }
}

/// Read-only positional slot indicator ("Bus N"). The slot is assigned by the
/// bus's order within its tour and is not editable.
class _SlotBadge extends StatelessWidget {
  final UgamColorSet c;
  final String label;

  const _SlotBadge({required this.c, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.md,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          Icon(
            Icons.tag_rounded,
            size: UgamScale.px(context, 18),
            color: c.ink3,
          ),
          const SizedBox(width: UgamSpacing.sm),
          // Expanded, not natural width: this Row had three unbounded children
          // and nothing to give. It also pins the "auto" note to the trailing
          // edge, which reads as a state on the badge rather than a third word
          // floating after it.
          Expanded(
            child: Text(
              label,
              style: UgamText.bodyStrong.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            tr('add_bus.slot_auto'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
        ],
      ),
    );
  }
}

/// Rupee glyph for the `prefix` (prefixIcon) slot of a [UgamInput] money field.
/// Sized down so it reads as an adornment, not a leading icon.
class _RupeePrefix extends StatelessWidget {
  final UgamColorSet c;
  const _RupeePrefix({required this.c});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // Decorative gutter — scales so the gap between the glyph and the number
      // doesn't widen on a small phone while the text shrinks around it.
      width: UgamScale.px(context, 34),
      child: Center(
        widthFactor: 1,
        child: Text(
          // NOT UgamText.titleS despite also being 15: titleS is Sora/w600,
          // and this must match the number it prefixes, which UgamInput sets
          // to `body.copyWith(fontSize: 15)` (Inter/w500). Same literal, same
          // reason. See the note in the return payload.
          '₹',
          style: UgamText.body.copyWith(color: c.ink2, fontSize: 15),
        ),
      ),
    );
  }
}

/// The wizard's one switch row: icon medallion + title + state subtitle +
/// [UgamSwitch]. Serves the Step 1 "AC" toggle and the Step 2 "all-double back
/// row" toggle, which were two byte-near-identical classes that had already
/// drifted (only one of them set the subtitle's `height: 1.4`).
///
/// Tapping anywhere on the row flips the value, so the whole row — not the
/// switch — is the tap target; the medallion is decorative and therefore
/// scales through [UgamScale.px], not `tap`.
class _ToggleRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;

  /// Reflects the CURRENT state ("On" / "Off"), not a static description.
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.c,
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return UgamTappable(
      onTap: () => onChanged(!value),
      semanticLabel: label,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          children: [
            Container(
              width: UgamScale.px(context, 38),
              height: UgamScale.px(context, 38),
              decoration: BoxDecoration(
                color: value ? c.accentFill : c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: UgamScale.px(context, 18),
                color: value ? c.accent : c.ink3,
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  Text(
                    subtitle,
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            UgamSwitch(
              value: value,
              onChanged: onChanged,
              semanticLabel: label,
            ),
          ],
        ),
      ),
    );
  }
}

/// A rupee [UgamInput]: decimal keypad, digits-and-dot filter and the
/// [_RupeePrefix] glyph — the one shape every money field in this wizard uses.
UgamInput _moneyInput(
  UgamColorSet c, {
  required String label,
  required TextEditingController controller,
  required String hint,
  String? errorText,
  required ValueChanged<String> onChanged,
}) {
  return UgamInput(
    label: label,
    controller: controller,
    hint: hint,
    errorText: errorText,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
    prefix: _RupeePrefix(c: c),
    onChanged: onChanged,
  );
}
