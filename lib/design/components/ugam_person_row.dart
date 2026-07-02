import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// One person line — the canonical "name + meta + trailing" row used in
/// rosters, occupant lists, collection lists and pickers. A full-width
/// [InkWell] (min 60dp tall) so it reads and taps the same everywhere
/// instead of a hand-rolled ListTile per screen.
///
/// * [leading] overrides the default 36dp initials avatar (accentFill bg /
///   accent ink). [initials] seeds the avatar; if omitted the first letter
///   of [name] is used.
/// * [subtitle] is a muted caption under the name.
/// * [trailing] is a free slot (amount, chip, chevron, switch).
/// * [selected] frames the row in a 1.5px [accent] border + accentFill tint.
class UgamPersonRow extends StatelessWidget {
  final String name;
  final String? subtitle;
  final String? initials;
  final Widget? trailing;
  final Widget? leading;
  final bool selected;
  final VoidCallback? onTap;
  final Color? accent;

  const UgamPersonRow({
    super.key,
    required this.name,
    this.subtitle,
    this.initials,
    this.trailing,
    this.leading,
    this.selected = false,
    this.onTap,
    this.accent,
  });

  String get _initials {
    final i = initials?.trim();
    if (i != null && i.isNotEmpty) return i;
    final n = name.trim();
    return n.isEmpty ? '?' : n[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final acc = accent ?? c.accent;

    final avatar = leading ??
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: c.accentFill,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            _initials,
            style: UgamText.bodyStrong.copyWith(color: acc, fontSize: 13),
          ),
        );

    final row = Container(
      constraints: const BoxConstraints(minHeight: 60),
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: selected
          ? BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(UgamRadius.row),
              border: Border.all(color: acc, width: 1.5),
            )
          : null,
      child: Row(
        children: [
          avatar,
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  name,
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: UgamSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );

    if (onTap == null) return row;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap!();
        },
        borderRadius: BorderRadius.circular(UgamRadius.row),
        child: row,
      ),
    );
  }
}
