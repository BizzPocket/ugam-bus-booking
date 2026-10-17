part of '../tours_screen.dart';

// ─── widget pieces ────────────────────────────────────────────────────

class _GroupHeader extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  /// Non-null renders a disclosure chevron (collapsible section).
  final bool? expanded;
  final VoidCallback? onTap;

  const _GroupHeader({
    required this.label,
    required this.count,
    required this.c,
    this.expanded,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = _row();
    if (onTap == null) return row;
    return UgamTappable(
      onTap: onTap,
      semanticLabel: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Align(alignment: Alignment.centerLeft, child: row),
      ),
    );
  }

  Widget _row() {
    return Row(
      children: [
        // Gujarati group labels ("આગામી 30 દિવસ") run long; let the label take
        // the width it needs and wrap rather than ellipsize — it is a fixed
        // system label, not a user value.
        Flexible(
          child: Text(label, style: UgamText.titleS.copyWith(color: c.ink)),
        ),
        const SizedBox(width: UgamSpacing.sm),
        // The shared badge, not a hand-rolled cardElev pill: same fill + ink,
        // and it tracks the component if the badge geometry changes.
        UgamReqChip(label: '$count', variant: UgamChipVariant.neutral),
        if (expanded != null) ...[
          const Spacer(),
          Icon(
            expanded! ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            size: 20,
            color: c.ink3,
          ),
        ],
      ],
    );
  }
}

class _TourRow extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final bool dim;
  final VoidCallback onTap;

  const _TourRow({
    required this.tour,
    required this.c,
    required this.onTap,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) {
    // Leg-aware physical berths (max(GO, RET) per bus) — the SAME engine-truth
    // occupancy the Requests banner shows, so the card no longer reads a false
    // "full" by double-counting leg-shared berths. See [Tour.occupiedBerths].
    //
    // Now THE seat meter ([SeatMeter]) — identical to the dashboard, Requests
    // and tour detail figures for the same tour.
    final meter = Get.find<TourController>().seatMeterFor(tour);
    final assigned = meter.occupied;
    final capacity = meter.capacity;
    final pct = capacity > 0 ? (assigned / capacity).clamp(0.0, 1.0) : 0.0;
    final action = _actionFor(tour);
    final dimAlpha = dim ? 0.55 : 1.0;

    final card = UgamCard.plain(
      onTap: onTap,
      radius: UgamRadius.card,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(UgamRadius.photo),
                child: SizedBox(
                  // Decorative thumbnail — follows the same scale factor the
                  // title/route text beside it already rides, so it stops
                  // dominating the row on a sub-390pt phone.
                  width: UgamScale.px(context, 72),
                  height: UgamScale.px(context, 72),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      UgamBusBackdrop(seed: tour.id, label: _routeLabel(tour)),
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UgamSpacing.badgeH,
                            vertical: UgamSpacing.badgeV,
                          ),
                          // Graphite-on-graphite chip reads cleanly over the
                          // backdrop instead of a stray black box.
                          decoration: BoxDecoration(
                            color: c.cardElev,
                            borderRadius: BorderRadius.circular(UgamRadius.chip),
                          ),
                          // No `.toUpperCase()`: it is a no-op in Gujarati and
                          // Hindi (Indic scripts have no case), so it only ever
                          // shouted at the English minority. The eyebrow read
                          // comes from micro's weight + letter-spacing, which
                          // works in every script.
                          child: Text(
                            Formatters.formatDateShort(
                              tour.departureDate,
                              // Localizations.localeOf (not easy_localization's
                              // context.locale) so the date pill never hard-
                              // crashes if the l10n provider isn't mounted yet;
                              // app.dart feeds context.locale into the app's
                              // Localizations, so this is the SAME locale in app.
                              locale: Localizations.localeOf(context).toString(),
                            ),
                            style: UgamText.tabular(
                              UgamText.micro.copyWith(color: c.ink),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 2 lines before ellipsis — long Gujarati titles ("આસો
                    // સુદ બીજ(…) AC બસ") lost their distinguishing tail at 1.
                    Text(
                      tour.title,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${tour.fromCity} → ${tour.toCity}',
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: UgamSpacing.md),
                    // Status line. Three competing items used to share this
                    // row (status · next-step · count); in Gujarati that left
                    // ~240pt for three ellipsized strings at 375 and all three
                    // read as fragments. The count moved down beside the bar it
                    // describes and the next step got its own full-width line,
                    // so nothing here ellipsizes in any language.
                    Row(
                      children: [
                        Expanded(
                          child: UgamStatusDot(
                            label: tour.status.displayName,
                            tone: _toneFor(tour.status),
                          ),
                        ),
                        if (capacity == 0) ...[
                          const SizedBox(width: UgamSpacing.sm),
                          Text(
                            tr(
                              'tours.pax',
                              namedArgs: {'count': '${tour.passengerCount}'},
                            ),
                            style: UgamText.tabular(
                              UgamText.caption.copyWith(color: c.ink2),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (capacity > 0) ...[
            const SizedBox(height: UgamSpacing.tight),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 5,
                      // Neutral per-row progress: the champagne accent is
                      // rationed for the single signal in this view, not
                      // painted on every capacity bar.
                      backgroundColor: c.border,
                      valueColor: AlwaysStoppedAnimation(c.ink3),
                    ),
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Text(
                  '$assigned/$capacity',
                  style: UgamText.tabular(
                    UgamText.caption.copyWith(color: c.ink),
                  ),
                ),
              ],
            ),
          ],
          // The next step, on its own full-width line. Was an UPPERCASED
          // copper micro eyebrow squeezed into the status row: the uppercase
          // is a no-op in Gujarati/Hindi, and painting every actionable row
          // amber is exactly the overuse that stopped the accent meaning
          // "this is yours". Emphasis now comes from weight, and the double
          // chevron names the right-swipe that runs it.
          if (action != null) ...[
            const SizedBox(height: UgamSpacing.sm),
            Row(
              children: [
                Icon(action.icon, size: 14, color: c.ink2),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    action.label,
                    maxLines: 2,
                    style: UgamText.caption.copyWith(
                      color: c.ink2,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Icon(
                  Icons.keyboard_double_arrow_right_rounded,
                  size: 14,
                  color: c.ink3,
                ),
              ],
            ),
          ],
        ],
      ),
    );

    // The contextual action no longer sits as a button inside the card (the
    // card already navigates on tap). Instead it lives behind a right-swipe:
    // swipe the row to reveal a copper pane labelled with the next step and
    // run it. Rows with no pending action (locked / completed) just navigate.
    final swipeable = action == null
        ? card
        : UgamSwipeAction(
            key: ValueKey('tour-row-${tour.id}'),
            rightLabel: action.label,
            rightIcon: action.icon,
            // No explicit rightColor — the component already defaults to the
            // accent, and the revealed pane genuinely IS "the row you picked".
            borderRadius: BorderRadius.circular(UgamRadius.card),
            onRight: () => _runRowAction(context, action.kind, tour),
            // Supplying rightIcon flips the Dismissible to `horizontal`, which
            // also arms the DESTRUCTIVE left swipe — and with no onDelete the
            // row was dismissed out of a list that still contains it (the
            // "dismissed Dismissible is still part of the tree" assertion).
            // Gating it here cancels that swipe and snaps the row back; there
            // is no delete-a-tour gesture on this screen.
            confirmDelete: () async => false,
            child: card,
          );

    return Opacity(opacity: dimAlpha, child: swipeable);
  }

  /// Short route monogram for the backdrop, e.g. "S→M" from the from/to
  /// cities. Returns null when either end is blank so the backdrop falls
  /// back to its plain bus glyph.
  static String? _routeLabel(Tour t) {
    String initial(String s) {
      final trimmed = s.trim();
      return trimmed.isEmpty ? '' : trimmed.characters.first.toUpperCase();
    }

    final from = initial(t.fromCity);
    final to = initial(t.toCity);
    if (from.isEmpty || to.isEmpty) return null;
    return '$from→$to';
  }

  /// Status dot tone. Three of these used to be [UgamStatusTone.accent], which
  /// painted an amber dot on nearly every row in the list — the accent means
  /// "this is yours", and something on every row means nothing. The setup
  /// phases now read neutral (their label already names them, and the next-step
  /// line below says what to do); colour is spent only where it is a real
  /// signal: warm while money/bookings are moving, mint once the tour is locked.
  UgamStatusTone _toneFor(TourStatus s) => switch (s) {
    TourStatus.planning => UgamStatusTone.neutral,
    TourStatus.collecting => UgamStatusTone.warm,
    TourStatus.busBooked => UgamStatusTone.neutral,
    TourStatus.assigning => UgamStatusTone.neutral,
    TourStatus.locked => UgamStatusTone.good,
    TourStatus.completed => UgamStatusTone.neutral,
  };

  _RowAction? _actionFor(Tour t) {
    if (t.status == TourStatus.completed || t.status == TourStatus.locked) {
      return null;
    }
    if (t.passengers.isNotEmpty && t.buses.isEmpty) {
      return _RowAction(
        label: tr('tours.action.add_bus'),
        icon: Icons.directions_bus_rounded,
        kind: _RowActionKind.addBus,
      );
    }
    if (t.buses.isNotEmpty && t.pendingSeatsToAssign > 0) {
      // Standardized seating entry: single "Seats" label that opens the
      // SeatsScreen SUMMARY — never the banned "Assign N" synonym/grid.
      return _RowAction(
        label: tr('seats.title'),
        icon: Icons.event_seat_rounded,
        kind: _RowActionKind.seats,
      );
    }
    if (t.allSeatsAssigned && t.handlerId == null) {
      return _RowAction(
        label: tr('tours.action.pick_handler'),
        icon: Icons.person_pin_rounded,
        kind: _RowActionKind.pickHandler,
      );
    }
    if (t.allSeatsAssigned && t.handlerId != null) {
      return _RowAction(
        label: tr('tours.action.lock_notify'),
        icon: Icons.lock_rounded,
        kind: _RowActionKind.lockNotify,
      );
    }
    return null;
  }

  /// Runs the row's labelled action so the accent CTA does what it says.
  /// Routing follows the shared convention:
  ///   • seats      -> SeatsScreen SUMMARY (tourOverview), the single "Seats"
  ///                   destination — never the bare grid.
  ///   • addBus /
  ///     pickHandler -> ManageBusesScreen, the per-bus home where buses are
  ///                   added and the handler is picked (NOT the seat screen).
  ///   • lockNotify -> NotifyScreen focused on this tour (the one lock+send
  ///                   path).
  void _runRowAction(BuildContext context, _RowActionKind kind, Tour t) {
    switch (kind) {
      case _RowActionKind.seats:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) =>
                SeatsScreen(tourId: t.id, initialMode: SeatsMode.summary),
          ),
        );
      case _RowActionKind.addBus:
      case _RowActionKind.pickHandler:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ManageBusesScreen(tourId: t.id),
          ),
        );
      case _RowActionKind.lockNotify:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => NotifyScreen(tourId: t.id)),
        );
    }
  }
}

enum _RowActionKind { seats, addBus, pickHandler, lockNotify }

class _RowAction {
  final String label;
  final IconData icon;
  final _RowActionKind kind;
  _RowAction({required this.label, required this.icon, required this.kind});
}
