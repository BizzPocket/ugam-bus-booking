import 'package:flutter/material.dart';

import '../design/ugam.dart';

/// ── Canonical settings-row geometry ────────────────────────────────────────
/// The settings cluster (the Settings hub + Account Details, Notifications,
/// WhatsApp) was built across several passes and drifted: 38 vs 40 px icon
/// tiles, 18 vs 20 px glyphs, corner radius 11 vs 12 vs 14, and two different
/// row paddings. These four numbers are the agreed spec. They used to be
/// copied at the top of both `settings_screen.dart` and
/// `notifications_settings_screen.dart`; this file is now their one home.
const double kSettingsRowIconBox = 40;
const double kSettingsRowIconGlyph = 20;
const double kSettingsRowIconRadius = 12;
const double kSettingsRowMinHeight = 64;

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
class SettingsGroupCard extends StatelessWidget {
  final List<Widget> children;
  const SettingsGroupCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    // Both hosts (the Settings page Column and SettingsScaffold) lay out with
    // CrossAxisAlignment.start, so claim the width.
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
class SettingsRowIcon extends StatelessWidget {
  final IconData icon;
  final Color background;
  final Color foreground;

  const SettingsRowIcon({
    super.key,
    required this.icon,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    final box = UgamScale.px(context, kSettingsRowIconBox);
    return Container(
      width: box,
      height: box,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(kSettingsRowIconRadius),
      ),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: UgamScale.px(context, kSettingsRowIconGlyph),
        color: foreground,
      ),
    );
  }
}

/// Hairline between two rows inside a [SettingsGroupCard]. Inset so it starts
/// where the TEXT starts rather than under the icon medallion — that inset is
/// what makes a stack of rows read as one list instead of a sliced box.
class SettingsRowDivider extends StatelessWidget {
  final UgamColorSet c;
  const SettingsRowDivider({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: UgamSpacing.lg +
            UgamScale.px(context, kSettingsRowIconBox) +
            UgamSpacing.md,
        right: UgamSpacing.lg,
      ),
      child: Divider(height: 1, color: c.border),
    );
  }
}

/// Toggle row of the settings cluster (the hub's Security section and every
/// Notifications switch) — 40/20/r12 medallion, [UgamSwitch], whole-row tap
/// target. The two screens used to carry line-for-line copies kept "in
/// lockstep" by comment; this is the one shared row.
class SettingsToggleRow extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String title;
  final String subtitle;

  /// Shown INSTEAD of [subtitle] while the row is disabled. Null keeps
  /// [subtitle] in both states.
  final String? disabledSubtitle;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const SettingsToggleRow({
    super.key,
    required this.c,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.disabledSubtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final on = value && enabled;

    return InkWell(
      // The whole row toggles, not just the ~50px switch. The nav rows on the
      // Settings hub have always been fully tappable; these looked identical
      // but only responded to a hit on the control itself.
      onTap: enabled ? () => onChanged(!value) : null,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: UgamScale.tap(context, kSettingsRowMinHeight),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          child: Row(
            children: [
              // Single neutral icon tile — the Switch is the only colour
              // signal. `card` on a `cardElev` group, matching the hub: this
              // pairing used to be inverted (a cardElev tile on a card row).
              SettingsRowIcon(
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
                    // Nothing here is clamped to one line: the Hindi
                    // `turn_on_hint` overruns the space left beside a switch at
                    // 375px, so it has to be free to wrap rather than ellipsis.
                    Text(
                      title,
                      style: UgamText.titleS.copyWith(
                        color: enabled ? c.ink : c.ink3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      enabled ? subtitle : (disabledSubtitle ?? subtitle),
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
