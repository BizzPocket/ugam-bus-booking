part of '../booking_capture_form.dart';

// ─── PICK CONTACT BUTTON ────────────────────────────────────────────────────

class _PickContactButton extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;
  const _PickContactButton({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.accentFill,
          borderRadius: BorderRadius.circular(UgamRadius.input),
          border: Border.all(color: c.accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.contacts_rounded, size: 18, color: c.accent),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              tr('booking_form.pick_contact'),
              style: UgamText.bodyStrong.copyWith(
                color: c.accent,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── SECTION EYEBROW ────────────────────────────────────────────────────────

class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        label.toUpperCase(),
        style: UgamText.micro.copyWith(color: c.ink3),
      ),
    );
  }
}

// ─── LEG TABS (the PRIMARY axis — pick which leg you're booking for) ─────────

/// Three pill tabs (Full trip / Go only / Return only), each badged with how
/// many seats sit on that leg so a split is visible without switching tabs.
class _LegTabs extends StatelessWidget {
  final UgamColorSet c;
  final List<TripType> legs;
  final TripType active;
  final String Function(TripType) labelOf;
  final IconData Function(TripType) iconOf;
  final int Function(TripType) countOf;
  final ValueChanged<TripType> onSelect;

  const _LegTabs({
    required this.c,
    required this.legs,
    required this.active,
    required this.labelOf,
    required this.iconOf,
    required this.countOf,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // IntrinsicHeight + stretch so every tab matches the tallest: a label that
    // wraps to 2 lines in one leg won't leave its neighbours shorter.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < legs.length; i++) ...[
            if (i > 0) const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _LegTab(
                key: Key('legtab-${legs[i].name}'),
                c: c,
                label: labelOf(legs[i]),
                icon: iconOf(legs[i]),
                count: countOf(legs[i]),
                active: legs[i] == active,
                onTap: () => onSelect(legs[i]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LegTab extends StatelessWidget {
  final UgamColorSet c;
  final String label;
  final IconData icon;
  final int count;
  final bool active;
  final VoidCallback onTap;

  const _LegTab({
    super.key,
    required this.c,
    required this.label,
    required this.icon,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Vertical layout: the direction glyph (+ optional seat-count badge) sits on
    // top and the full leg word runs across the tab's whole width below it,
    // centred and free to wrap to 2 lines. This keeps the label readable in
    // every locale — the long gu/hi words ("આવક-જાવક", "ફક્ત આવવા") no longer
    // fight an inline icon for horizontal room and get ellipsised — WITHOUT
    // depending on fragile locale detection to decide whether to show the icon.
    final fg = active ? c.accent : c.ink2;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.sm,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: active ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: Border.all(
            color: active ? c.accent : c.border,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 15, color: fg),
                if (count > 0) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color:
                          active ? c.accent : c.ink3.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '$count',
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(
                          color: active ? c.onAccent : c.ink2,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: UgamText.bodyStrong.copyWith(
                color: fg,
                fontSize: 12,
                height: 1.15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── SEAT COUNTER TILE (one seat type within the active leg) ────────────────

/// One seat-type counter: type label/icon + a tappable typed qty with +/- fine
/// adjust. The type is fixed (it's a fixed row per tab), so there's no type
/// swap, leg chip, or remove button — the leg lives in the tab above.
class _SeatCounterTile extends StatelessWidget {
  final Key addKey;
  final Key minusKey;
  final IconData icon;
  final String label;
  final String sublabel;
  final int value;
  final int maxPerType;
  final ValueChanged<int> onChanged;
  final VoidCallback onTapValue;

  const _SeatCounterTile({
    super.key,
    required this.addKey,
    required this.minusKey,
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.value,
    required this.maxPerType,
    required this.onChanged,
    required this.onTapValue,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final selected = value > 0;
    return AnimatedContainer(
      duration: UgamMotion.tab,
      curve: UgamMotion.easeOut,
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.sm + 2,
        UgamSpacing.md,
      ),
      decoration: BoxDecoration(
        color: selected ? c.accentFill : c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: selected ? c.accent.withValues(alpha: 0.18) : c.card,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 22, color: selected ? c.accent : c.ink2),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  sublabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: UgamText.caption.copyWith(color: c.ink2, fontSize: 11),
                ),
              ],
            ),
          ),
          _StepperButton(
            key: minusKey,
            icon: Icons.remove_rounded,
            enabled: value > 0,
            onTap: () {
              HapticFeedback.lightImpact();
              onChanged(value - 1);
            },
          ),
          // Tappable value — opens the numeric keypad so a large quantity is one
          // type action instead of N taps.
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onTapValue();
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              // >=44px min hit target on the most-used booking interaction while
              // the pill stays visually compact.
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? c.accent.withValues(alpha: 0.4) : c.border,
                ),
              ),
              child: Text(
                '$value',
                textAlign: TextAlign.center,
                style: UgamText.tabular(
                  UgamText.titleM.copyWith(
                    color: selected ? c.accent : c.ink,
                    fontSize: 18,
                  ),
                ),
              ),
            ),
          ),
          _StepperButton(
            key: addKey,
            icon: Icons.add_rounded,
            enabled: value < maxPerType,
            onTap: () {
              HapticFeedback.lightImpact();
              onChanged(value + 1);
            },
          ),
        ],
      ),
    );
  }
}

// ─── BANDED SEAT TILE (full-trip only — the seat that costs money) ──────────

/// One seat type on the FULL-TRIP tab of a banded tour.
///
/// Replaces the plain stepper because a quantity alone cannot price this seat:
/// the bus is priced by band, so the customer has to say WHICH band each seat
/// is in. Each choice is its own removable line, so a party can take two seats
/// in the front band and one at the back without leaving the form.
class _BandedSeatTile extends StatelessWidget {
  final SeatType type;
  final IconData icon;
  final String label;
  final String sublabel;
  final List<_BandEntry> entries;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  const _BandedSeatTile({
    super.key,
    required this.type,
    required this.icon,
    required this.label,
    required this.sublabel,
    required this.entries,
    required this.onAdd,
    required this.onRemove,
  });

  int get _berths =>
      entries.fold<int>(0, (s, e) => s + e.qty * type.berthsPerUnit);

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final selected = entries.isNotEmpty;

    return AnimatedContainer(
      duration: UgamMotion.tab,
      curve: UgamMotion.easeOut,
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: selected ? c.accentFill : c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: selected ? c.accent.withValues(alpha: 0.18) : c.card,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(
                  icon,
                  size: 22,
                  color: selected ? c.accent : c.ink2,
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
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sublabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UgamText.caption
                          .copyWith(color: c.ink2, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (_berths > 0)
                Text(
                  tr(
                    'booking_form.band_berths',
                    namedArgs: {'n': '$_berths'},
                  ),
                  style: UgamText.tabular(
                    UgamText.bodyStrong.copyWith(color: c.accent),
                  ),
                ),
            ],
          ),
          for (var i = 0; i < entries.length; i++) ...[
            const SizedBox(height: UgamSpacing.sm),
            _BandEntryRow(
              key: Key('seat-band-line-${type.name}-$i'),
              removeKey: Key('seat-band-remove-${type.name}-$i'),
              entry: entries[i],
              type: type,
              onRemove: () => onRemove(i),
            ),
          ],
          const SizedBox(height: UgamSpacing.sm),
          UgamTappable(
            key: Key('seat-band-add-${type.name}'),
            onTap: onAdd,
            pressedScale: 0.97,
            child: Container(
              constraints:
                  BoxConstraints(minHeight: UgamScale.tap(context, 44)),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
                border: Border.all(color: c.border),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 16, color: c.ink2),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      tr(entries.isEmpty
                          ? 'booking_form.band_add'
                          : 'booking_form.band_add_another'),
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      style: UgamText.bodyStrong
                          .copyWith(color: c.ink2, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One chosen band inside a seat type: what it costs, which rows it buys, and
/// a way to take it back off.
class _BandEntryRow extends StatelessWidget {
  final Key removeKey;
  final _BandEntry entry;
  final SeatType type;
  final VoidCallback onRemove;

  const _BandEntryRow({
    super.key,
    required this.removeKey,
    required this.entry,
    required this.type,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final band = entry.band;
    // Rows are 0-based internally, 1-based to a human counting from the front.
    final rows = band == null
        ? null
        : (band.fromRow == band.toRow
            ? tr('band_picker.row_one',
                namedArgs: {'row': '${band.fromRow + 1}'})
            : tr('band_picker.rows', namedArgs: {
                'from': '${band.fromRow + 1}',
                'to': '${band.toRow + 1}',
              }));
    // A legacy line carries no band and therefore no price — say so rather
    // than rendering a confident Rs 0.
    final price = band == null
        ? tr('booking_form.band_unpriced')
        : Formatters.formatMoneyInr(
            band.pricePaise * type.berthsPerUnit * entry.qty / 100,
          );

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.sm + 2,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          Text(
            '×${entry.qty}',
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              rows ?? tr('booking_form.band_unbanded'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: UgamText.caption.copyWith(color: c.ink2),
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            price,
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(width: 4),
          UgamTappable(
            key: removeKey,
            onTap: onRemove,
            pressedScale: 0.9,
            child: SizedBox(
              width: UgamScale.tap(context, 40),
              height: UgamScale.tap(context, 40),
              child: Icon(Icons.close_rounded, size: 16, color: c.ink3),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── SEAT TOTAL LINE ─────────────────────────────────────────────────────────

/// Running "N seats total" under the tabs, so the booking size is always
/// visible even while standing on a single leg's tab.
class _SeatTotalLine extends StatelessWidget {
  final UgamColorSet c;
  final int total;
  const _SeatTotalLine({required this.c, required this.total});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        tr('booking_form.seats_total', namedArgs: {'count': '$total'}),
        style: UgamText.caption.copyWith(color: total > 0 ? c.ink2 : c.ink3),
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepperButton({
    super.key,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      // 44×44 hit target (accessibility minimum) wrapping the compact 32×32
      // visual chip — the stepper is the single most-used tap here.
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: enabled ? c.accent : c.card,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: enabled ? c.onAccent : c.ink3),
          ),
        ),
      ),
    );
  }
}
