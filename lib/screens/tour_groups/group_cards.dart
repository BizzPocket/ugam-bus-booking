part of '../tour_groups_screen.dart';

// ─── Suggested-group card (remembered companions) ──────────────────────────

class _SuggestionCard extends StatelessWidget {
  final List<Passenger> members;
  final bool busy;
  final VoidCallback onApply;
  final UgamColorSet c;

  const _SuggestionCard({
    required this.members,
    required this.busy,
    required this.onApply,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final names = members
        .map((m) =>
            m.name.trim().isEmpty ? tr('tour_groups.unnamed') : m.name.trim())
        .join(' · ');
    return UgamCard.plain(
      tone: UgamCardTone.accent,
      radius: UgamRadius.row,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.history_rounded, size: 18, color: c.accent),
          ),
          const SizedBox(width: UgamSpacing.sm + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('tour_groups.usually_travel_together'),
                  style: UgamText.micro.copyWith(color: c.accent),
                ),
                const SizedBox(height: 2),
                Text(
                  names,
                  style: UgamText.body.copyWith(color: c.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          UgamButton(
            label: tr('tour_groups.group'),
            icon: Icons.group_add_rounded,
            kind: UgamButtonKind.tonal,
            loading: busy,
            onPressed: busy ? null : onApply,
          ),
        ],
      ),
    );
  }
}

// ─── Existing-group card ───────────────────────────────────────────────────

class _GroupCard extends StatelessWidget {
  final PassengerGroup group;
  final int number;
  final List<Passenger> members;
  final GroupFit fit;
  final VoidCallback onDelete;
  final Future<void> Function(String passengerId) onRemoveMember;
  final VoidCallback onAddMember;
  final UgamColorSet c;

  const _GroupCard({
    required this.group,
    required this.number,
    required this.members,
    required this.fit,
    required this.onDelete,
    required this.onRemoveMember,
    required this.onAddMember,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    // Capacity tone: green with room, warm when exactly full, red when over.
    final tone = fit.isOver
        ? c.danger
        : fit.isFull
            ? c.warm
            : c.good;
    final seatsText = fit.hasBus
        ? tr('tour_groups.seats_summary', namedArgs: {
            'used': '${fit.used}',
            'cap': '${fit.capacity}',
          })
        : tr('tour_groups.seats_plain', namedArgs: {'n': '${fit.used}'});
    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Header: numbered colour badge · name · seats · delete ────────
          Row(
            children: [
              GroupNumberBadge(
                number: number,
                colorIndex: group.colorIndex,
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Text(
                  group.label.isEmpty ? tr('tour_groups.group') : group.label,
                  style: UgamText.titleS.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // Capacity readout: group berths vs the biggest single bus.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
                child: Text(
                  seatsText,
                  style: UgamText.micro.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.xs),
              // Delete the whole group — compact danger button (confirms first).
              UgamIconButton(
                icon: Icons.delete_outline_rounded,
                tone: UgamIconButtonTone.danger,
                size: 32,
                iconSize: 17,
                onTap: onDelete,
                semanticLabel: tr('tour_groups.delete_group'),
              ),
            ],
          ),
          // Over-capacity warning only — a compact inline note, no banner slab.
          if (fit.isOver) ...[
            const SizedBox(height: UgamSpacing.xs + 2),
            Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 13, color: c.danger),
                const SizedBox(width: UgamSpacing.xs),
                Expanded(
                  child: Text(
                    tr('tour_groups.wont_fit', namedArgs: {
                      'used': '${fit.used}',
                      'cap': '${fit.capacity}',
                    }),
                    style:
                        UgamText.micro.copyWith(color: c.danger, height: 1.2),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: UgamSpacing.sm + 2),
          // ── Members as removable chips + an inline add chip ──────────────
          Wrap(
            spacing: UgamSpacing.sm,
            runSpacing: UgamSpacing.sm,
            children: [
              for (final m in members)
                _MemberChip(
                  name: m.name.isEmpty ? tr('tour_groups.unnamed') : m.name,
                  onRemove: () => onRemoveMember(m.id),
                  c: c,
                ),
              _AddChip(
                enabled: !fit.isFull,
                onTap: onAddMember,
                c: c,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A single group member rendered as a compact removable pill: name + a small
/// × that ungroups it. Replaces the old full-width member row with its giant
/// circular delete button.
class _MemberChip extends StatelessWidget {
  final String name;
  final VoidCallback onRemove;
  final UgamColorSet c;

  const _MemberChip({
    required this.name,
    required this.onRemove,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 32,
      padding: const EdgeInsets.only(left: UgamSpacing.md, right: UgamSpacing.xs),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              name,
              style: UgamText.caption.copyWith(
                color: c.ink2,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onRemove,
            child: Semantics(
              button: true,
              label: tr('tour_groups.remove_member'),
              child: Padding(
                padding: const EdgeInsets.all(UgamSpacing.xs + 1),
                child: Icon(Icons.close_rounded, size: 14, color: c.ink3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tonal "+ Add" chip that sits inline at the end of the member chips.
/// Disabled (and relabelled) when the group already fills the biggest bus —
/// the capacity block from the user's "41 in a 36-seat bus" rule.
class _AddChip extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _AddChip({
    required this.enabled,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? c.accent : c.ink3;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Semantics(
        button: true,
        enabled: enabled,
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
          decoration: BoxDecoration(
            color: enabled ? c.accentFill : c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                enabled ? Icons.person_add_alt_rounded : Icons.block_rounded,
                size: 15,
                color: fg,
              ),
              const SizedBox(width: UgamSpacing.xs + 2),
              Text(
                enabled
                    ? tr('tour_groups.add_member')
                    : tr('tour_groups.full_for_bus'),
                style: UgamText.caption.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Empty states ─────────────────────────────────────────────────────────

class _NoSearchResults extends StatelessWidget {
  final String query;

  const _NoSearchResults({required this.query});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
      child: UgamEmpty(
        icon: Icons.search_off_rounded,
        title: tr('tour_groups.no_search_results', namedArgs: {'q': query}),
      ),
    );
  }
}

class _NoPassengers extends StatelessWidget {
  const _NoPassengers();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
      child: UgamEmpty(
        icon: Icons.people_outline_rounded,
        title: tr('tour_groups.no_passengers_yet'),
      ),
    );
  }
}
