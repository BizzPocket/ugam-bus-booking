part of '../manage_buses_screen.dart';

/// First-load placeholder shaped like the bus list it becomes, instead of a
/// centred spinner that pops.
class _BusListSkeleton extends StatelessWidget {
  const _BusListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.lg,
      ),
      children: [
        for (var i = 0; i < 3; i++) ...[
          const UgamSkeleton(height: 176, radius: UgamRadius.card),
          const SizedBox(height: UgamSpacing.md),
        ],
      ],
    );
  }
}

class _BusListItem extends StatelessWidget {
  final UgamColorSet c;
  final Bus bus;

  /// This bus's leg-aware capacity slice from the tour engine snapshot
  /// (`cap.byBus[bus.id]`). Null when the bus isn't in the plan (no layout
  /// yet) — the meter is simply skipped in that case.
  final BusCapacity? busCap;

  /// Display name of this bus's handler, or null when none is assigned yet.
  final String? handlerName;
  final VoidCallback onOpen;
  final VoidCallback onMore;

  /// Opens the per-bus handler picker (tapping the handler row).
  final VoidCallback onHandler;

  const _BusListItem({
    required this.c,
    required this.bus,
    required this.busCap,
    required this.handlerName,
    required this.onOpen,
    required this.onMore,
    required this.onHandler,
  });

  /// Driver name only (line 1 of the meta stack). Phone is no longer crammed
  /// here — it lives in the bus action sheet ("Call driver"). Empty when unset.
  String get _driverLine => bus.driverName.trim();

  /// This bus's own boarding place + departure time joined by a middot,
  /// skipping blanks so an unset half never renders as a lone "·". Per-bus
  /// values override the tour-level / chart-footer departure; empty when both
  /// are unset. This is line 2 of the meta stack.
  String get _departureLine => [
    bus.boardingPoint,
    formatHhMm(bus.departureTime),
  ].where((s) => s != null && s.trim().isNotEmpty).join(' · ');

  @override
  Widget build(BuildContext context) {
    return UgamCard.media(
      onTap: onOpen,
      elev: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // No thumbnail: buses carry no photo, so the 76pt slot only ever
          // painted an empty generated backdrop beside the name.
          Row(
            children: [
              const SizedBox(width: UgamSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      bus.displayLabel,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    // Line 1: driver name (emphasised). Line 2: boarding +
                    // departure (muted). Phone is no longer crammed here — it
                    // moved into the bus action sheet ("Call driver").
                    if (_driverLine.isNotEmpty) ...[
                      const SizedBox(height: UgamSpacing.xs),
                      Text(
                        _driverLine,
                        style: UgamText.bodyStrong.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (_departureLine.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        _departureLine,
                        style: UgamText.caption.copyWith(color: c.ink2),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (bus.isAC) ...[
                      const SizedBox(height: UgamSpacing.sm),
                      UgamReqChip(label: tr('manage_buses.tag_ac')),
                    ],
                  ],
                ),
              ),
              UgamIconButton(
                icon: Icons.more_vert_rounded,
                onTap: onMore,
                semanticLabel: tr('manage_buses.menu_more'),
              ),
            ],
          ),
          // Leg-aware occupancy: the shared two-leg meter ("Go x/n · Ret
          // y/n" + free count over a single thin bar). Replaces the old
          // merged $assigned/$cap + percentage bar, which hid which leg was
          // fuller and could leak a fractional seatLoad. Skipped when the bus
          // has no engine slice yet (no layout).
          if (busCap != null && busCap!.capacity > 0) ...[
            const SizedBox(height: UgamSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.sm),
              child: UgamCapacityMeter.bus(busCap!),
            ),
            const SizedBox(height: UgamSpacing.xs),
          ],
          const SizedBox(height: UgamSpacing.sm),
          _HandlerRow(c: c, handlerName: handlerName, onTap: onHandler),
        ],
      ),
    );
  }
}

/// Per-bus handler chip inside a bus card. Shows the current handler's name
/// (with a badge) or a "Set handler" prompt; tapping opens the picker.
class _HandlerRow extends StatelessWidget {
  final UgamColorSet c;
  final String? handlerName;
  final VoidCallback onTap;

  const _HandlerRow({
    required this.c,
    required this.handlerName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasHandler = handlerName != null && handlerName!.trim().isNotEmpty;
    // No handler yet: the action is "set one" — a content-width TONAL button,
    // not a full-width slab. Once set, a quiet neutral row names the handler.
    if (!hasHandler) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: IntrinsicWidth(
          child: UgamButton(
            label: tr('bus_handler.set_cta'),
            icon: Icons.badge_outlined,
            kind: UgamButtonKind.tonal,
            onPressed: onTap,
          ),
        ),
      );
    }
    return UgamTappable(
      onTap: onTap,
      semanticLabel: tr(
        'bus_handler.row_current',
        namedArgs: {'name': handlerName!},
      ),
      child: Container(
        // Was ~32pt tall (sm padding around a 12pt caption) on a row that is
        // the only way into the handler picker.
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm,
        ),
        // No hand-rolled border on the neutral state — depth comes from a
        // recessed fill (base card tone, sunk into the elevated bus card)
        // instead of a hairline. The set state keeps the copper accent tint:
        // an assigned handler is an ownership marker, which is exactly what
        // the accent is rationed for.
        // Neutral recessed row in BOTH states. The set state used to paint a
        // full-width copper slab per bus — two buses, two accent slabs on a
        // screen whose one accent belongs to its CTA. The badge glyph in
        // accent ink is the ownership marker now; the row itself stays quiet.
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            Icon(Icons.badge_outlined, size: 16, color: c.accent),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Text(
                tr(
                  'bus_handler.row_current',
                  namedArgs: {'name': handlerName!},
                ),
                style: UgamText.caption.copyWith(
                  color: c.ink,
                  fontWeight: FontWeight.w700,
                ),
                // Two lines: "Handler: <Gujarati name>" is the longest string
                // on the card and a single line ellipsised the name away.
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Icon(Icons.chevron_right_rounded, size: 16, color: c.ink3),
          ],
        ),
      ),
    );
  }
}
