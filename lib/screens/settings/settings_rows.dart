part of '../settings_screen.dart';

/// A grouped list of settings rows sharing one card surface.
///
/// Was a bare `Container(decoration: BoxDecoration(color: cardElev, …))`, so
/// these groups sat flush with the page while the [UgamCard]s directly above
/// them floated. Composing with [UgamCard] means a group picks up the app's
/// elevation scale for free instead of opting out of it.
///
/// The [Material] is load-bearing: an [InkWell] paints its splash into the
/// nearest ancestor [Material], which without this is the Scaffold's — i.e.
/// *underneath* the card fill, so tapping a row produced no visible feedback
/// at all.
class _GroupCard extends StatelessWidget {
  final List<Widget> children;
  const _GroupCard({required this.children});

  @override
  Widget build(BuildContext context) {
    // The page Column lays out with CrossAxisAlignment.start, so claim width.
    return SizedBox(
      width: double.infinity,
      child: UgamCard.plain(
        elev: true,
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(UgamRadius.card),
          child: Material(
            type: MaterialType.transparency,
            child: Column(children: children),
          ),
        ),
      ),
    );
  }
}

/// The one icon medallion every row in the settings cluster uses.
///
/// [UgamScale.px], not [UgamScale.tap]: the tile is decorative: the 44pt floor
/// belongs to the row wrapped around it, not to the glyph box.
class _RowIcon extends StatelessWidget {
  final IconData icon;
  final Color background;
  final Color foreground;

  const _RowIcon({
    required this.icon,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    final box = UgamScale.px(context, _rowIconBox);
    return Container(
      width: box,
      height: box,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(_rowIconRadius),
      ),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: UgamScale.px(context, _rowIconGlyph),
        color: foreground,
      ),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsRow({
    required this.c,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: UgamScale.tap(context, _rowMinHeight),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          child: Row(
            children: [
              _RowIcon(icon: icon, background: c.card, foreground: c.ink2),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Nothing in this row is clamped to one line, on purpose:
                    // the Gujarati and Hindi strings run ~30% past the English
                    // source and a settings row is label + value + chevron on
                    // one line, so the copy has to be free to wrap. The row
                    // grows; nothing hides behind an ellipsis.
                    Text(
                      title,
                      // `titleS` IS 15 — the override restated the step.
                      style: UgamText.titleS.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      // `caption` IS 12 — likewise redundant.
                      style: UgamText.caption.copyWith(color: c.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hairline between two rows inside a [_GroupCard]. Inset so it starts where
/// the TEXT starts rather than under the icon medallion — that inset is what
/// makes a stack of rows read as one list instead of a sliced box. Mirrored in
/// `notifications_settings_screen.dart`.
class _Divider extends StatelessWidget {
  final UgamColorSet c;
  const _Divider({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: UgamSpacing.lg +
            UgamScale.px(context, _rowIconBox) +
            UgamSpacing.md,
        right: UgamSpacing.lg,
      ),
      child: Divider(height: 1, color: c.border),
    );
  }
}

/// Log out — the one destructive action on this screen.
///
/// It used to be a `cardElev` tile geometrically IDENTICAL to the five
/// navigation rows above it, separated by the same 16px seam, and it even
/// carried a chevron; the only thing marking it destructive was a red glyph.
/// It is now a danger-toned [UgamCard] (tinted fill + danger hairline) behind
/// a wider seam, with the chevron dropped — a chevron promises "this opens a
/// page", and this ends your session. The confirmation step was already in
/// place ([UgamDialog.confirm] with `destructive: true`) and is unchanged.
class _DangerRow extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onLogout;

  const _DangerRow({
    required this.c,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      tone: UgamCardTone.danger,
      padding: EdgeInsets.zero,
      onTap: onLogout,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: UgamScale.tap(context, _rowMinHeight),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          child: Row(
            children: [
              _RowIcon(
                icon: Icons.logout_rounded,
                // The `dangerFill` token, not a per-call-site alpha.
                background: c.dangerFill,
                foreground: c.danger,
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('settings.logout'),
                      style: UgamText.titleS.copyWith(color: c.danger),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('settings.logout_subtitle'),
                      // `ink2`, not `ink3`: on the tinted danger fill the
                      // tertiary ink drops under 3:1.
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Toggle row for the Security section.
///
/// Deliberately IDENTICAL in geometry and behaviour to `_ToggleRow` in
/// `notifications_settings_screen.dart` — same 40/20/r12 medallion, same
/// padding, same [UgamSwitch], same whole-row tap target. The two remain
/// separate classes only because neither file may introduce a shared widget;
/// keep them in lockstep.
class _SecurityToggleRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _SecurityToggleRow({
    required this.c,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final on = value && enabled;

    return InkWell(
      // The whole row toggles, not just the ~50px switch — the nav rows on this
      // same screen have always been fully tappable.
      onTap: enabled ? () => onChanged(!value) : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: UgamScale.tap(context, _rowMinHeight),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          child: Row(
            children: [
              _RowIcon(
                icon: icon,
                background: c.card,
                foreground: enabled ? c.ink2 : c.ink3,
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: UgamText.titleS.copyWith(
                        color: enabled ? c.ink : c.ink3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: UgamText.caption.copyWith(color: c.ink3),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // Was a raw Material Switch that set only the two ACTIVE colours,
              // so the off state fell back to Material's grey. UgamSwitch tints
              // all four, adds the haptic, guarantees the 44pt box and
              // announces the toggled state to a screen reader.
              UgamSwitch(
                value: on,
                onChanged: enabled ? onChanged : null,
                semanticLabel: title,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
