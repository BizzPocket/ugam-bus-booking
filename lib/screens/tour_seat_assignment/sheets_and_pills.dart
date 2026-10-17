part of '../tour_seat_assignment_screen.dart';

/// Mobile-native confirm — a bottom sheet with a prose body + a full-width
/// primary action (red when [destructive]) over a ghost Cancel. Replaces the
/// center [UgamDialog.confirm] so confirmations live in the thumb zone like
/// every other detail/confirm surface. Returns true only when the user taps the
/// primary action; swipe-down / tap-outside returns false.
Future<bool> _confirmSheet(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  String? cancelLabel,
  bool destructive = false,
  IconData? confirmIcon,
}) async {
  final c = UgamColors.of(context);
  final result = await UgamSheet.show<bool>(
    context,
    title: title,
    showClose: false,
    builder: (sheetCtx) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message != null) ...[
          Text(
            message,
            style: UgamText.body.copyWith(color: c.ink2, height: 1.4),
          ),
          const SizedBox(height: UgamSpacing.xl),
        ],
        // Destructive confirms get a full-width RED button (delete/cancel);
        // affirmative ones get the copper sticky CTA — the screen's one focal
        // action while the sheet is up.
        if (destructive)
          UgamButton(
            label: confirmLabel,
            icon: confirmIcon,
            kind: UgamButtonKind.danger,
            expand: true,
            onPressed: () => Navigator.of(sheetCtx).pop(true),
          )
        else
          UgamCTA(
            label: confirmLabel,
            leadingIcon: confirmIcon,
            onPressed: () => Navigator.of(sheetCtx).pop(true),
          ),
        const SizedBox(height: UgamSpacing.sm),
        UgamButton(
          label: cancelLabel ?? tr('app.action.cancel'),
          kind: UgamButtonKind.ghost,
          expand: true,
          onPressed: () => Navigator.of(sheetCtx).pop(false),
        ),
      ],
    ),
  );
  return result ?? false;
}

class _PendingLine {
  final SeatType seatType;
  final SeatPosition? position;
  final int remaining;
  final int totalRequested;

  const _PendingLine({
    required this.seatType,
    this.position,
    required this.remaining,
    required this.totalRequested,
  });

  _PendingLine copyDecremented() => _PendingLine(
    seatType: seatType,
    position: position,
    remaining: remaining > 0 ? remaining - 1 : 0,
    totalRequested: totalRequested,
  );

  String get label => seatTypeLabel(seatType, position);

  String get progress => '${totalRequested - remaining}/$totalRequested';
}

// ─── Seat passenger picker ───────────────────────────────────────────────

/// A compact pickup-point chip: the admin-facing short CODE (from
/// [PickupController]) when set, else the pickup NAME the booking snapshotted.
/// Renders nothing when the rider has no pickup; wrapped in [Obx] so the code
/// fills in once the global pickup list finishes loading.
class _PickupCodeChip extends StatelessWidget {
  final Passenger passenger;
  final EdgeInsetsGeometry padding;
  const _PickupCodeChip({
    required this.passenger,
    this.padding = const EdgeInsets.only(left: UgamSpacing.sm),
  });

  Widget _chip(String? label) {
    if (label == null || label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: UgamReqChip(label: label, variant: UgamChipVariant.neutral),
    );
  }

  String? _label(PickupController? pk) {
    final code = pk?.codeFor(passenger.pickupLocationId);
    if (code != null && code.isNotEmpty) return code;
    final name = passenger.pickupLocationName;
    return (name != null && name.isNotEmpty) ? name : null;
  }

  @override
  Widget build(BuildContext context) {
    final pk = Get.isRegistered<PickupController>()
        ? Get.find<PickupController>()
        : null;
    if (pk == null) return _chip(_label(null));
    return Obx(() => _chip(_label(pk)));
  }
}

/// Bottom-sheet list of pending passengers who can take a tapped EMPTY seat —
/// seat-first assignment. Each row shows the name + their outstanding request;
/// the currently-selected passenger (if any) is tagged at the top. The sheet
/// chrome (handle + seat/bus title) is supplied by [UgamSheet.show].
class _SeatPassengerPicker extends StatelessWidget {
  final List<Passenger> candidates;
  final String? activeId;
  final ValueChanged<Passenger> onPick;

  /// Optional override for the explanatory line above the list. Defaults to the
  /// seat-first "tap a passenger to seat them here" copy.
  final String? subtitle;

  /// Optional "move both" affordance, shown as a distinct row above the
  /// candidate list. Provided only when seating BOTH sharers on the target is
  /// valid (leg-disjoint pair onto a free single). [bothLabel]/[bothHint] are
  /// the row's title/subtitle; [onPickBoth] fires on tap.
  final String? bothLabel;
  final String? bothHint;
  final VoidCallback? onPickBoth;

  const _SeatPassengerPicker({
    required this.candidates,
    required this.activeId,
    required this.onPick,
    this.subtitle,
    this.bothLabel,
    this.bothHint,
    this.onPickBoth,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          subtitle ?? tr('tour_seat_assignment.picker_subtitle'),
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
        const SizedBox(height: UgamSpacing.md),
        if (onPickBoth != null) ...[
          _bothRow(c),
          const SizedBox(height: UgamSpacing.sm),
        ],
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.55,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const BouncingScrollPhysics(),
              itemCount: candidates.length,
              separatorBuilder: (_, _) =>
                  const SizedBox(height: UgamSpacing.sm),
              itemBuilder: (_, i) => _row(c, candidates[i]),
            ),
          ),
        ),
      ],
    );
  }

  /// Distinct accent-tinted row that seats BOTH sharers on the target single
  /// (leg-reuse), freeing the double. Visually set apart from the one-or-other
  /// candidate rows below by the accent group icon and tinted fill.
  Widget _bothRow(UgamColorSet c) {
    return GestureDetector(
      onTap: onPickBoth,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.accentFill,
          borderRadius: BorderRadius.circular(UgamRadius.row),
          border: Border.all(color: c.accent, width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.groups_rounded, size: 19, color: c.onAccent),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bothLabel ?? '',
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (bothHint != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      bothHint!,
                      style: UgamText.micro.copyWith(color: c.ink2),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.xs),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.accent),
          ],
        ),
      ),
    );
  }

  Widget _row(UgamColorSet c, Passenger p) {
    final isActive = p.id == activeId;
    return UgamPersonRow(
      name: p.displayName,
      subtitle: p.requestSummary,
      initials: SeatChartTile.initials(p.displayName),
      selected: isActive,
      onTap: () => onPick(p),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PickupCodeChip(
            passenger: p,
            padding: const EdgeInsets.only(right: UgamSpacing.sm),
          ),
          if (isActive) ...[
            Icon(Icons.check_circle_rounded, size: 16, color: c.accent),
            const SizedBox(width: UgamSpacing.xs),
          ],
          Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
        ],
      ),
    );
  }
}

// ─── Bus pills ─────────────────────────────────────────────────────────

class _BusPills extends StatelessWidget {
  final List<Bus> buses;
  final String selectedBusId;
  final int Function(String) seatsAssignedFor;
  final ValueChanged<String> onTapBus;
  final UgamColorSet c;

  const _BusPills({
    required this.buses,
    required this.selectedBusId,
    required this.seatsAssignedFor,
    required this.onTapBus,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // tap() not px(): every pill is a tap target, so the strip follows the
      // app scale but never drops under the 44pt minimum.
      height: UgamScale.tap(context, 44),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
        itemCount: buses.length,
        separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.sm),
        itemBuilder: (ctx, i) {
          final bus = buses[i];
          final selected = bus.id == selectedBusId;
          final assigned = seatsAssignedFor(bus.id);
          final capacity = bus.totalSeats;
          return GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onTapBus(bus.id);
            },
            child: AnimatedContainer(
              duration: UgamMotion.tab,
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.lg,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: selected ? c.accentFill : c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
                border: selected
                    ? Border.all(color: c.accent.withValues(alpha: 0.28))
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bus.name,
                    // caption IS 12 — this was `bodyStrong` forked down to 12.
                    style: UgamText.caption.copyWith(
                      color: selected ? c.accent : c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  // Was the third hand-rolled badge geometry in this file
                  // (6/2 padding + a forked 10.5pt). UgamReqChip is THE badge.
                  UgamReqChip(
                    label: '$assigned/$capacity',
                    variant: selected
                        ? UgamChipVariant.accent
                        : UgamChipVariant.neutral,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Relocate banner ─────────────────────────────────────────────────────

/// Slim accent banner shown while a cross-bus relocate is in progress: tells
/// the agent who is in hand and which bus they're placing on, with a Cancel.
class _RelocateBanner extends StatelessWidget {
  final String moverName;
  final String busName;
  final VoidCallback onCancel;
  final UgamColorSet c;

  const _RelocateBanner({
    required this.moverName,
    required this.busName,
    required this.onCancel,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      // Vertical padding drops sm+2 -> xs because the Cancel below now carries
      // its own 44pt box; keeping 10 on top of that would have grown the banner
      // twice over.
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: c.accentFill,
        borderRadius: BorderRadius.circular(UgamRadius.row),
        border: Border.all(color: c.accent.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.touch_app_rounded, size: 18, color: c.accent),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Text(
              tr(
                'tour_seat_assignment.relocate.banner',
                namedArgs: {'name': moverName, 'bus': busName},
              ),
              style: UgamText.caption.copyWith(
                color: c.accent,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // This is the ONLY exit from cross-bus relocate mode, and it was a
          // ~20pt-tall bare label. The painted text is unchanged; it now sits
          // in a real 44x44 hit box (Center(widthFactor: 1) keeps the box
          // shrink-wrapped to the label's width so the banner does not
          // reflow horizontally).
          GestureDetector(
            onTap: onCancel,
            behavior: HitTestBehavior.opaque,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              child: Center(
                widthFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.sm,
                  ),
                  child: Text(
                    tr('app.action.cancel'),
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
