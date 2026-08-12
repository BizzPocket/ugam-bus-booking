import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../utils/formatters.dart';
import 'create_tour_screen.dart';
import 'manage_buses_screen.dart';
import 'notify_screen.dart';
import 'seats_screen.dart';
import 'tour_detail_screen.dart';

/// Tours tab — chronologically grouped instead of filter-pill-driven.
///
/// Why time-grouped: agents think in time ("this week's trips"), not in
/// status (collecting / busBooked / assigning). Status is encoded per
/// row via a status dot.
///
/// Layout:
///   [Title + circle "+" + search icon]
///   [Search bar (collapsible)]
///   [Group: This week]
///   [Group: Next 30 days]
///   [Group: Later]
///   [Group: Past (collapsed by default)]
class ToursScreen extends StatefulWidget {
  const ToursScreen({super.key});

  @override
  State<ToursScreen> createState() => _ToursScreenState();
}

class _ToursScreenState extends State<ToursScreen> {
  final _searchCtrl = TextEditingController();
  bool _searchVisible = false;
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    HapticFeedback.selectionClick();
    setState(() {
      _searchVisible = !_searchVisible;
      if (!_searchVisible) {
        _searchCtrl.clear();
        _query = '';
      }
    });
  }

  /// The one way into tour creation from this tab — shared by the app-bar
  /// action, every empty state's CTA and the list's tail button.
  void _openCreate(BuildContext context) {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const CreateTourScreen()),
    );
  }

  /// Centred states (empty / error / no-match) fill the whole tab body, whose
  /// bottom ~80pt is covered by the floating dock. Reserving the same
  /// [UgamSpacing.dockClearance] the scrolling list reserves optically centres
  /// them in the area the agent can actually see, instead of parking the CTA
  /// behind the dock.
  Widget _dockSafe(Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: UgamSpacing.dockClearance),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            UgamAppBar(
              title: tr('tours.title'),
              showBack: false,
              actions: [
                UgamAppBarAction(
                  icon: _searchVisible
                      ? Icons.close_rounded
                      : Icons.search_rounded,
                  active: _searchVisible,
                  tooltip: tr('tours.search'),
                  onTap: _toggleSearch,
                ),
                // No `tint: c.accent` — tokens.dart reserves the amber for
                // "this is yours" (a selection / an owned row) and explicitly
                // NOT for controls. The create affordance is instead made
                // unmissable by the full-width tail button at the end of the
                // list, which also sits in the thumb zone.
                UgamAppBarAction(
                  icon: Icons.add_rounded,
                  tooltip: tr('tours.create'),
                  onTap: () => _openCreate(context),
                ),
              ],
            ),
            AnimatedSize(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              child: _searchVisible
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UgamSpacing.gutter,
                        0,
                        UgamSpacing.gutter,
                        UgamSpacing.md,
                      ),
                      child: UgamSearchField(
                        controller: _searchCtrl,
                        hint: tr('tours.search_hint'),
                        autofocus: true,
                        onChanged: (v) => setState(() => _query = v.trim()),
                        onClear: () => setState(() => _query = ''),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: Obx(() {
                if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
                  return _LoadingShimmer();
                }
                if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
                  // Shared load-failed + retry surface. errorMessage carries the
                  // tour-specific tr('errors.load_tours') copy; retry re-runs the
                  // (now internally-retrying) fetch.
                  return _dockSafe(
                    UgamEmpty.error(
                      onRetry: tourCtrl.refreshTours,
                      message: tourCtrl.errorMessage.value,
                    ),
                  );
                }

                if (tourCtrl.tours.isEmpty) {
                  return _dockSafe(
                    UgamEmpty(
                      icon: Icons.explore_rounded,
                      title: tr('tours.empty.title'),
                      body: tr('tours.empty.subtitle'),
                      cta: UgamCTA(
                        label: tr('tours.empty.cta'),
                        leadingIcon: Icons.add_rounded,
                        onPressed: () => _openCreate(context),
                      ),
                    ),
                  );
                }

                final groups = _group(tourCtrl.tours);
                final hasMatches = groups.any((g) => g.tours.isNotEmpty);

                if (_query.isNotEmpty && !hasMatches) {
                  return _dockSafe(
                    UgamEmpty(
                      icon: Icons.search_off_rounded,
                      title: tr('tours.no_matches_title'),
                      body: tr(
                        'tours.no_matches_body',
                        namedArgs: {'query': _query},
                      ),
                    ),
                  );
                }

                // Tours on file, but every one of them has already finished.
                // The three upcoming buckets are empty and Past is deliberately
                // kept out of the browse view, so without this branch the tab
                // rendered three collapsed groups — a completely blank page
                // that reads as a failed load. "Genuinely zero upcoming" is a
                // different statement from "no tours yet", so it gets its own
                // copy and its own way forward.
                if (!hasMatches) {
                  return _dockSafe(
                    UgamEmpty(
                      icon: Icons.event_available_rounded,
                      title: tr('tours.only_past_title'),
                      body: tr(
                        'tours.only_past_body',
                        namedArgs: {'n': '${tourCtrl.tours.length}'},
                      ),
                      cta: UgamCTA(
                        label: tr('tours.new_tour'),
                        leadingIcon: Icons.add_rounded,
                        onPressed: () => _openCreate(context),
                      ),
                    ),
                  );
                }

                return RefreshIndicator(
                  // Chrome, not ownership — the pull spinner is neutral ink2
                  // in every screen, so it never changes hue between tabs.
                  color: c.ink2,
                  onRefresh: tourCtrl.refreshTours,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.md,
                      UgamSpacing.gutter,
                      UgamSpacing.dockClearance,
                    ),
                    // +1 for the tail. A short list (one or two upcoming
                    // trips) used to end halfway up the screen with the rest
                    // of the tab as undesigned void; the tail closes the page
                    // with the tab's own primary verb, in the thumb zone,
                    // where a top-right 44pt icon was the only door before.
                    itemCount: groups.length + 1,
                    itemBuilder: (_, i) {
                      if (i == groups.length) {
                        return Padding(
                          padding: const EdgeInsets.only(top: UgamSpacing.xl),
                          child: UgamButton(
                            label: tr('tours.new_tour'),
                            icon: Icons.add_rounded,
                            kind: UgamButtonKind.neutral,
                            expand: true,
                            onPressed: () => _openCreate(context),
                          ),
                        );
                      }
                      final g = groups[i];
                      if (g.tours.isEmpty) return const SizedBox.shrink();
                      final isPast = g.bucket == _Bucket.past;
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: i == groups.length - 1 ? 0 : UgamSpacing.xl,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _GroupHeader(
                              label: g.label,
                              count: g.tours.length,
                              c: c,
                            ),
                            const SizedBox(height: UgamSpacing.md),
                            for (var j = 0; j < g.tours.length; j++) ...[
                              _TourRow(
                                tour: g.tours[j],
                                c: c,
                                dim: isPast,
                                onTap: () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        TourDetailScreen(tourId: g.tours[j].id),
                                  ),
                                ),
                              ),
                              if (j != g.tours.length - 1)
                                const SizedBox(height: UgamSpacing.md),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  // ── grouping ──────────────────────────────────────────────────────

  List<_Group> _group(List<Tour> all) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final endOfWeek = today.add(Duration(days: 7 - today.weekday));
    final endOf30 = today.add(const Duration(days: 30));

    final filtered = _query.isEmpty
        ? all
        : all
              .where(
                (t) =>
                    t.title.toLowerCase().contains(_query.toLowerCase()) ||
                    t.fromCity.toLowerCase().contains(_query.toLowerCase()) ||
                    t.toCity.toLowerCase().contains(_query.toLowerCase()),
              )
              .toList();

    final thisWeek = <Tour>[];
    final next30 = <Tour>[];
    final later = <Tour>[];
    final past = <Tour>[];

    for (final t in filtered) {
      // A tour is "past" once its end day (return date if any, else departure)
      // is before today — multi-day trips stay active until they actually end.
      final end = t.returnDate ?? t.departureDate;
      final endDay = DateTime(end.year, end.month, end.day);
      if (endDay.isBefore(today)) {
        past.add(t);
      } else if (!t.departureDate.isAfter(endOfWeek)) {
        thisWeek.add(t);
      } else if (!t.departureDate.isAfter(endOf30)) {
        next30.add(t);
      } else {
        later.add(t);
      }
    }

    int byDate(Tour a, Tour b) => a.departureDate.compareTo(b.departureDate);
    int byDateDesc(Tour a, Tour b) =>
        b.departureDate.compareTo(a.departureDate);

    thisWeek.sort(byDate);
    next30.sort(byDate);
    later.sort(byDate);
    past.sort(byDateDesc);

    return [
      _Group(_Bucket.thisWeek, tr('tours.group.this_week'), thisWeek),
      _Group(_Bucket.next30, tr('tours.group.next_30_days'), next30),
      _Group(_Bucket.later, tr('tours.group.later'), later),
      // Past/closed tours are kept out of the default browse view so the list
      // stays focused on upcoming work; they still surface when searching.
      if (_query.isNotEmpty) _Group(_Bucket.past, tr('tours.group.past'), past),
    ];
  }
}

enum _Bucket { thisWeek, next30, later, past }

class _Group {
  final _Bucket bucket;
  final String label;
  final List<Tour> tours;
  _Group(this.bucket, this.label, this.tours);
}

// ─── widget pieces ────────────────────────────────────────────────────

class _GroupHeader extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  const _GroupHeader({
    required this.label,
    required this.count,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
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
    final assigned = tour.occupiedBerths;
    final capacity = tour.totalBusSeats;
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
                    Text(
                      tour.title,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1,
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
      return trimmed.isEmpty ? '' : trimmed.substring(0, 1).toUpperCase();
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
        break;
      case _RowActionKind.addBus:
      case _RowActionKind.pickHandler:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ManageBusesScreen(tourId: t.id),
          ),
        );
        break;
      case _RowActionKind.lockNotify:
        Navigator.of(context).push(
          MaterialPageRoute(builder: (context) => NotifyScreen(tourId: t.id)),
        );
        break;
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

/// First-load placeholder. Shaped like the list it stands in for — a group
/// header (title + count badge) over full-width tour cards at the row's real
/// height — so the shimmer/content swap is a fill change, not a re-layout.
/// The gutters and the dock clearance match the real [ListView.builder] above,
/// so nothing shifts sideways or hides under the dock when the data lands.
class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.dockClearance,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        _ShimmerGroupHeader(),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 132, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 132, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.xl),
        _ShimmerGroupHeader(),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 132, radius: UgamRadius.card),
      ],
    );
  }
}

class _ShimmerGroupHeader extends StatelessWidget {
  const _ShimmerGroupHeader();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        UgamSkeleton(height: 20, width: 116, radius: 6),
        SizedBox(width: UgamSpacing.sm),
        UgamSkeleton(height: 16, width: 24, radius: 6),
      ],
    );
  }
}
