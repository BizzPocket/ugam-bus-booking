part of '../settings_screen.dart';

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
          minHeight: UgamScale.tap(context, kSettingsRowMinHeight),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          child: Row(
            children: [
              SettingsRowIcon(
                icon: icon,
                background: c.card,
                foreground: c.ink2,
              ),
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
          minHeight: UgamScale.tap(context, kSettingsRowMinHeight),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          child: Row(
            children: [
              SettingsRowIcon(
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
