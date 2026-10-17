part of '../manage_buses_screen.dart';

/// A row in the per-bus handler picker — a seated passenger with a check tick
/// when they already handle this bus.
class _HandlerPickTile extends StatelessWidget {
  final UgamColorSet c;
  final Passenger passenger;
  final bool isCurrent;
  final VoidCallback onTap;

  const _HandlerPickTile({
    required this.c,
    required this.passenger,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = UgamScale.px(context, 36);
    return UgamTappable(
      onTap: onTap,
      semanticLabel: passenger.displayName,
      child: Container(
        margin: const EdgeInsets.only(bottom: UgamSpacing.sm),
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 56)),
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: isCurrent ? Border.all(color: c.accent, width: 1.5) : null,
        ),
        child: Row(
          children: [
            Container(
              width: avatar,
              height: avatar,
              decoration: BoxDecoration(
                color: isCurrent ? c.accent : c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                passenger.displayName.isNotEmpty
                    ? passenger.displayName.characters.first.toUpperCase()
                    : '?',
                style: UgamText.bodyStrong.copyWith(
                  color: isCurrent ? c.onAccent : c.ink,
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 2 lines before ellipsis — app-wide name rule, see
                  // UgamRequestRow.
                  Text(
                    passenger.displayName,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (passenger.phone.isNotEmpty)
                    Text(
                      passenger.phone,
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (isCurrent) ...[
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.check_circle_rounded, size: 20, color: c.accent),
            ],
          ],
        ),
      ),
    );
  }
}

class _BusMenuTile extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;

  /// Optional muted second line under the label (e.g. the driver's phone
  /// number on the "Call driver" tile, or what deleting actually costs).
  final String? subtitle;
  final bool danger;
  final VoidCallback onTap;

  const _BusMenuTile({
    required this.c,
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? c.danger : c.ink;
    // InkWell (ripple + 48dp tap target) replaces the raw GestureDetector;
    // selection haptic on tap for native feel.
    //
    // The destructive tile's fill rides an [Ink] ABOVE the InkWell rather than
    // a Container below it: a decorated child paints over the Material the
    // splash lands on, which would have left the one tile that most needs to
    // acknowledge the finger as the only tile with no visible press at all.
    return Material(
      color: Colors.transparent,
      child: Ink(
        // A destructive entry carries its own tonal danger surface, so it is
        // recognisable before the label is read. `warmFill` (rose) on the old
        // medallion said "a lady is seated here", not "this destroys data".
        decoration: danger
            ? BoxDecoration(
                color: c.dangerFill,
                borderRadius: BorderRadius.circular(UgamRadius.row),
                border: Border.all(color: c.danger.withValues(alpha: 0.28)),
              )
            : null,
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          borderRadius: BorderRadius.circular(UgamRadius.row),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: UgamScale.tap(context, 56)),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: UgamSpacing.md,
                horizontal: UgamSpacing.md,
              ),
              child: Row(
                children: [
                  Container(
                    width: UgamScale.px(context, 36),
                    height: UgamScale.px(context, 36),
                    decoration: BoxDecoration(
                      color: danger
                          ? c.danger.withValues(alpha: 0.14)
                          : c.cardElev,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon, size: 18, color: fg),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: UgamText.bodyStrong.copyWith(color: fg),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (subtitle != null &&
                            subtitle!.trim().isNotEmpty) ...[
                          const SizedBox(height: 2),
                          // Wraps rather than truncating: the delete tile's
                          // subtitle is a full Gujarati sentence and it is the
                          // line that says what the tap costs.
                          Text(
                            subtitle!,
                            style: UgamText.caption.copyWith(color: c.ink2),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
