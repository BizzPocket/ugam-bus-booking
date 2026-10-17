part of '../pickup_locations_screen.dart';

/// Section heading for the visible / hidden groups.
///
/// Deliberately NOT [UgamSectionLabel]: `.toUpperCase()` is a no-op in Gujarati
/// and Hindi, so caps carry no emphasis for most of this app's users. Weight
/// and ink do the work instead.
class _SectionHead extends StatelessWidget {
  final String label;
  final String? hint;

  const _SectionHead({required this.label, this.hint});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: UgamText.bodyStrong.copyWith(color: c.ink)),
        if (hint != null) ...[
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 13,
                  color: c.ink3,
                ),
              ),
              const SizedBox(width: UgamSpacing.xs),
              Expanded(
                child: Text(
                  hint!,
                  style: UgamText.caption.copyWith(color: c.ink3),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// First-load placeholder, shaped like the list it becomes — a section heading
/// and four rows — rather than a centred spinner that pops.
class _PickupListSkeleton extends StatelessWidget {
  const _PickupListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const UgamSkeleton.text(width: 150),
        const SizedBox(height: UgamSpacing.md),
        for (var i = 0; i < 4; i++) ...[
          const UgamSkeleton(height: 56, radius: UgamRadius.row),
          const SizedBox(height: UgamSpacing.sm),
        ],
      ],
    );
  }
}

/// A single row inside the overflow sheet (Rename / Hide / Delete).
class _MenuAction extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;

  /// Muted second line spelling out the consequence — the difference between
  /// "Hide" and "Delete" is the whole point of this menu.
  final String? subtitle;
  final bool destructive;
  final VoidCallback onTap;

  const _MenuAction({
    required this.c,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = destructive ? c.danger : c.ink;
    return UgamTappable(
      onTap: onTap,
      semanticLabel: label,
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 56)),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.gutter,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          // Danger carries its own tonal surface, so the destructive row is
          // recognisable before the label is read.
          color: destructive ? c.dangerFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: destructive
              ? Border.all(color: c.danger.withValues(alpha: 0.28))
              : null,
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: UgamText.titleS.copyWith(color: fg)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
