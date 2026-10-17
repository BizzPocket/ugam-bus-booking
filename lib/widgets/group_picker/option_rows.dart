part of '../group_picker.dart';

// ─── Shared rows ───────────────────────────────────────────────────────────

class _PassengerOptionRow extends StatelessWidget {
  final Passenger passenger;
  final bool enabled;
  final String? blockedReason;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _PassengerOptionRow({
    required this.passenger,
    required this.enabled,
    required this.blockedReason,
    required this.onTap,
    required this.c,
  });

  String get _initial {
    final t = passenger.name.trim();
    return t.isEmpty ? '?' : t.characters.first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return _OptionRowFrame(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: c.card, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Text(
          _initial,
          style: UgamText.bodyStrong.copyWith(color: c.ink2),
        ),
      ),
      title: _displayName(passenger),
      subtitle: passenger.requestSummary,
      enabled: enabled,
      blockedReason: blockedReason,
      onTap: onTap,
      c: c,
    );
  }
}

/// The tappable option row both sheets share: a leading mark, a one-line title
/// over a one-line caption, and an add glyph — or, when the pick would push a
/// group past one bus, a "won't fit" chip on a dimmed, inert row.
class _OptionRowFrame extends StatelessWidget {
  final Widget leading;
  final String title;
  final String subtitle;
  final bool enabled;
  final String? blockedReason;
  final VoidCallback onTap;
  final UgamColorSet c;

  const _OptionRowFrame({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.blockedReason,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.lg,
            vertical: UgamSpacing.md,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.row),
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: UgamText.caption.copyWith(color: c.ink3),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              if (blockedReason != null)
                UgamReqChip(
                  label: blockedReason!.toUpperCase(),
                  variant: UgamChipVariant.warm,
                )
              else
                Icon(Icons.add_circle_outline_rounded,
                    size: 20, color: c.accent),
            ],
          ),
        ),
      ),
    );
  }
}

class _CapacityLine extends StatelessWidget {
  final GroupFit fit;
  final UgamColorSet c;
  const _CapacityLine({required this.fit, required this.c});

  @override
  Widget build(BuildContext context) {
    if (!fit.hasBus) {
      return _InfoNote(text: tr('requests.group.no_bus'), c: c);
    }
    final tone = fit.isOver
        ? c.danger
        : fit.isFull
            ? c.warm
            : c.good;
    return Row(
      children: [
        Icon(Icons.event_seat_outlined, size: 16, color: tone),
        const SizedBox(width: UgamSpacing.sm),
        Text(
          tr('tour_groups.seats_summary',
              namedArgs: {'used': '${fit.used}', 'cap': '${fit.capacity}'}),
          style: UgamText.bodyStrong.copyWith(color: tone, fontSize: 13),
        ),
        const SizedBox(width: UgamSpacing.sm),
        if (fit.remaining > 0)
          Text(
            tr('tour_groups.seats_left', namedArgs: {'n': '${fit.remaining}'}),
            style: UgamText.caption.copyWith(color: c.ink3),
          )
        else
          Text(
            tr('tour_groups.full_for_bus'),
            style: UgamText.caption.copyWith(color: c.warm),
          ),
      ],
    );
  }
}

class _InfoNote extends StatelessWidget {
  final String text;
  final UgamColorSet c;
  const _InfoNote({required this.text, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.warmFill,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 15, color: c.warm),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: UgamText.caption.copyWith(color: c.warm, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final UgamColorSet c;

  const _SheetSearchField({
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 18, color: c.ink2),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              style: UgamText.body.copyWith(color: c.ink, fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintStyle: UgamText.body.copyWith(color: c.ink3, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
