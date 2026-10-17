part of '../tour_groups_screen.dart';

// ─── Section header ──────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  const _SectionHeader({
    required this.label,
    required this.count,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.sm),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            '$count',
            style: UgamText.tabular(UgamText.micro.copyWith(color: c.ink2)),
          ),
        ],
      ),
    );
  }
}

// ─── Passenger row ─────────────────────────────────────────────────────────

class _PassengerRow extends StatelessWidget {
  final Passenger passenger;
  final PassengerGroup? group;
  final int? groupNumber;
  final bool selecting;
  final bool selected;
  final VoidCallback onSelectToggle;
  final VoidCallback onPriorityToggle;
  final UgamColorSet c;

  const _PassengerRow({
    required this.passenger,
    required this.group,
    required this.groupNumber,
    required this.selecting,
    required this.selected,
    required this.onSelectToggle,
    required this.onPriorityToggle,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final approved = passenger.isPriorityApproved;
    return UgamCard.plain(
      // In select mode the whole row toggles selection; otherwise it is a
      // passive row (the star is the only action).
      onTap: selecting ? onSelectToggle : null,
      radius: UgamRadius.row,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
      ),
      child: Row(
        children: [
          if (selecting) ...[
            _Checkbox(checked: selected, c: c),
            const SizedBox(width: UgamSpacing.sm),
          ],
          // Avatar with the passenger's initial.
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _initial(passenger.name),
              style: UgamText.bodyStrong.copyWith(color: c.ink2),
            ),
          ),
          const SizedBox(width: UgamSpacing.sm + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Name + group tag share one line (tag sits BESIDE the name).
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        passenger.name.isEmpty
                            ? tr('tour_groups.unnamed')
                            : passenger.name,
                        style: UgamText.titleS.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (group != null && groupNumber != null) ...[
                      const SizedBox(width: UgamSpacing.sm),
                      GroupTag(
                        number: groupNumber!,
                        colorIndex: group!.colorIndex,
                        label: group!.label.isEmpty
                            ? tr('tour_groups.group')
                            : group!.label,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  passenger.requestSummary,
                  style: UgamText.caption.copyWith(color: c.ink3),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.xs),
          // Priority star — warm is the sanctioned attention colour here.
          if (!selecting)
            GestureDetector(
              onTap: onPriorityToggle,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: approved ? c.warmFill : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  approved ? Icons.star_rounded : Icons.star_outline_rounded,
                  size: 22,
                  color: approved ? c.warm : c.ink3,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _initial(String name) {
    final t = name.trim();
    return t.isEmpty ? '?' : t.characters.first.toUpperCase();
  }
}

class _Checkbox extends StatelessWidget {
  final bool checked;
  final UgamColorSet c;

  const _Checkbox({required this.checked, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: checked ? c.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: checked ? c.accent : c.border, width: 1.6),
      ),
      alignment: Alignment.center,
      child: checked
          ? Icon(Icons.check_rounded, size: 15, color: c.onAccent)
          : null,
    );
  }
}
