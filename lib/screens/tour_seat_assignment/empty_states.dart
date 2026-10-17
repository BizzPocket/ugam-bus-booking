part of '../tour_seat_assignment_screen.dart';

// ─── Empty states ──────────────────────────────────────────────────────

class _NoBuses extends StatelessWidget {
  final String tourId;
  const _NoBuses({required this.tourId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: UgamEmpty(
          icon: Icons.directions_bus_outlined,
          title: tr('tour_seat_assignment.no_buses_title'),
          body: tr('tour_seat_assignment.no_buses_body'),
          cta: UgamCTA(
            label: tr('tour_seat_assignment.btn_add_bus'),
            leadingIcon: Icons.add_rounded,
            onPressed: () => Get.to(() => ManageBusesScreen(tourId: tourId)),
          ),
        ),
      ),
    );
  }
}

class _NoPassengers extends StatelessWidget {
  final String tourId;
  const _NoPassengers({required this.tourId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(UgamSpacing.lg),
        child: UgamEmpty(
          icon: Icons.people_outline_rounded,
          title: tr('tour_seat_assignment.no_passengers_title'),
          body: tr('tour_seat_assignment.no_passengers_body'),
          // Dead-end fix: buses exist but nobody is booked, and this state used
          // to offer nothing to tap while the adjacent _NoBuses state hands the
          // agent a button. Route to the tour's requests, which is where a
          // passenger actually enters the system. Mirrors _NoBuses exactly.
          cta: UgamCTA(
            label: tr('tour_seat_assignment.btn_view_requests'),
            leadingIcon: Icons.assignment_outlined,
            onPressed: () =>
                Get.to(() => RequestsScreen(initialTourId: tourId)),
          ),
        ),
      ),
    );
  }
}

class _NoLayout extends StatelessWidget {
  const _NoLayout();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
      alignment: Alignment.center,
      child: Text(
        tr('tour_seat_assignment.no_layout'),
        textAlign: TextAlign.center,
        style: UgamText.caption.copyWith(color: c.ink2),
      ),
    );
  }
}

// ─── Edit-seats flag sheet ─────────────────────────────────────────────────

/// Edit-mode sheet for one seat: two switches that toggle the seat's "Forward /
/// premium" and "Hold / reserved" flags. The handlers write straight through to
/// [TourController.setSeatForward] / [setSeatReserved]; the chart repaints
/// reactively once the bus layout mutates.
class _SeatFlagsSheet extends StatefulWidget {
  final String seatId;
  final String typeLabel;
  final String busName;
  final bool forward;
  final bool reserved;
  final ValueChanged<bool> onForward;
  final ValueChanged<bool> onReserved;

  const _SeatFlagsSheet({
    required this.seatId,
    required this.typeLabel,
    required this.busName,
    required this.forward,
    required this.reserved,
    required this.onForward,
    required this.onReserved,
  });

  @override
  State<_SeatFlagsSheet> createState() => _SeatFlagsSheetState();
}

class _SeatFlagsSheetState extends State<_SeatFlagsSheet> {
  late bool _forward = widget.forward;
  late bool _reserved = widget.reserved;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.tune_rounded, size: 18, color: c.ink),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tr(
                      'tour_seat_assignment.seat_label',
                      namedArgs: {'seat': widget.seatId},
                    ),
                    style: UgamText.titleM.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.typeLabel} · ${widget.busName}',
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.lg),
        _FlagRow(
          icon: Icons.star_rounded,
          title: tr('tour_seat_assignment.flags.forward_title'),
          subtitle: tr('tour_seat_assignment.flags.forward_subtitle'),
          value: _forward,
          // Warm = attention; the forward zone is the priority/premium band.
          activeColor: c.warm,
          c: c,
          onTap: () {
            final v = !_forward;
            setState(() => _forward = v);
            widget.onForward(v);
          },
        ),
        const SizedBox(height: UgamSpacing.sm),
        _FlagRow(
          icon: Icons.lock_outline_rounded,
          title: tr('tour_seat_assignment.flags.reserved_title'),
          subtitle: tr('tour_seat_assignment.flags.reserved_subtitle'),
          value: _reserved,
          activeColor: c.accent,
          c: c,
          onTap: () {
            final v = !_reserved;
            setState(() => _reserved = v);
            widget.onReserved(v);
          },
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamCTA(
          label: tr('app.action.done'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

/// One tappable flag row in [_SeatFlagsSheet] — a full-width [UgamCard.plain]
/// that fills accentFill + a check tick when ON, and fires the controller call
/// immediately on tap (no Switch, no separate confirm). The whole row is the
/// hit target, the active tone reads the flag's colour (warm/accent).
class _FlagRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final Color activeColor;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _FlagRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.activeColor,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // One surface: a single tappable card whose fill flips to a tonal wash of
    // the flag's colour while ON, with a hairline tone border. No nested card.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(UgamRadius.row),
        child: AnimatedContainer(
          duration: UgamMotion.tab,
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.md,
            // `sm + 4` was exactly UgamSpacing.md — same 12, now named.
            vertical: UgamSpacing.md,
          ),
          decoration: BoxDecoration(
            color: value ? activeColor.withValues(alpha: 0.14) : c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.row),
            border: value
                ? Border.all(color: activeColor.withValues(alpha: 0.5))
                : null,
          ),
          child: Row(
            children: [
              // Small scale cue on the flag glyph as the value flips, alongside
              // the row's own color/border ease. Scale-only, no layout change.
              AnimatedScale(
                scale: value ? 1.12 : 1.0,
                duration: UgamMotion.tab,
                curve: Curves.easeOutCubic,
                child: Icon(
                  icon,
                  size: 18,
                  color: value ? activeColor : c.ink3,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: UgamText.bodyStrong.copyWith(color: c.ink),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // A filled tick when ON; a hollow ring when OFF — the at-a-glance
              // "this flag is set" cue that replaces the Switch thumb.
              Icon(
                value
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 22,
                color: value ? activeColor : c.ink3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
