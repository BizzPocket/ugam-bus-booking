import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
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
                UgamAppBarAction(
                  icon: Icons.add_rounded,
                  tint: c.accent,
                  tooltip: tr('tours.create'),
                  onTap: () {
                    HapticFeedback.lightImpact();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => const CreateTourScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
            AnimatedSize(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              child: _searchVisible
                  ? _SearchField(
                      c: c,
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _query = v.trim()),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: Obx(() {
                if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
                  return _LoadingShimmer();
                }
                if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
                  return UgamEmpty(
                    icon: Icons.cloud_off_rounded,
                    title: tr('tours.title'),
                    body: tourCtrl.errorMessage.value,
                    cta: UgamCTA(
                      label: tr('app.action.retry'),
                      leadingIcon: Icons.refresh_rounded,
                      onPressed: tourCtrl.refreshTours,
                    ),
                  );
                }

                if (tourCtrl.tours.isEmpty) {
                  return UgamEmpty(
                    icon: Icons.explore_rounded,
                    title: tr('tours.empty.title'),
                    body: tr('tours.empty.subtitle'),
                    cta: UgamCTA(
                      label: tr('tours.empty.cta'),
                      leadingIcon: Icons.add_rounded,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const CreateTourScreen(),
                        ),
                      ),
                    ),
                  );
                }

                final groups = _group(tourCtrl.tours);
                final hasMatches = groups.any((g) => g.tours.isNotEmpty);

                if (_query.isNotEmpty && !hasMatches) {
                  return UgamEmpty(
                    icon: Icons.search_off_rounded,
                    title: tr('tours.no_matches_title'),
                    body: tr(
                      'tours.no_matches_body',
                      namedArgs: {'query': _query},
                    ),
                  );
                }

                return RefreshIndicator(
                  color: c.accent,
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
                    itemCount: groups.length,
                    itemBuilder: (_, i) {
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
                                const SizedBox(height: UgamSpacing.sm + 2),
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

class _SearchField extends StatelessWidget {
  final UgamColorSet c;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchField({
    required this.c,
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Container(
        height: 48,
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
                autofocus: true,
                onChanged: onChanged,
                style: UgamText.body.copyWith(color: c.ink, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: tr('tours.search_hint'),
                  hintStyle: UgamText.body.copyWith(
                    color: c.ink3,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
        Text(
          label,
          style: UgamText.titleM.copyWith(color: c.ink, fontSize: 16),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Text(
            '$count',
            style: UgamText.tabular(
              UgamText.micro.copyWith(color: c.ink2, fontSize: 10),
            ),
          ),
        ),
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
      padding: const EdgeInsets.all(UgamSpacing.md - 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(UgamRadius.photo),
                child: SizedBox(
                  width: 88,
                  height: 88,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      UgamBusBackdrop(seed: tour.id, label: _routeLabel(tour)),
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          // Graphite-on-graphite chip reads cleanly over the
                          // backdrop instead of a stray black box.
                          decoration: BoxDecoration(
                            color: c.cardElev,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            _formatDate(tour.departureDate),
                            style: UgamText.tabular(
                              UgamText.micro.copyWith(
                                color: c.ink,
                                fontSize: 9.5,
                              ),
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
                      style: UgamText.titleS.copyWith(
                        color: c.ink,
                        fontSize: 15,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${tour.fromCity} → ${tour.toCity}',
                      style: UgamText.caption.copyWith(
                        color: c.ink2,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: UgamSpacing.sm + 2),
                    Row(
                      children: [
                        Flexible(
                          child: UgamStatusDot(
                            label: tour.status.displayName,
                            tone: _toneFor(tour.status),
                          ),
                        ),
                        // Urgency is carried by a copper micro eyebrow naming
                        // the next step (swipe the card to run it) — no inline
                        // button competes for the thumb-zone any more.
                        if (action != null) ...[
                          const SizedBox(width: UgamSpacing.sm),
                          Flexible(
                            child: Text(
                              action.label.toUpperCase(),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: UgamText.micro.copyWith(color: c.accent),
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (capacity > 0)
                          Text(
                            '$assigned/$capacity',
                            style: UgamText.tabular(
                              UgamText.bodyStrong.copyWith(
                                color: c.ink,
                                fontSize: 12,
                              ),
                            ),
                          )
                        else
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
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (capacity > 0) ...[
            const SizedBox(height: UgamSpacing.md - 2),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: pct,
                minHeight: 5,
                // Neutral per-row progress: the champagne accent is rationed
                // for the single signal in this view, not painted on every
                // capacity bar.
                backgroundColor: c.border,
                valueColor: AlwaysStoppedAnimation(c.ink3),
              ),
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
            rightColor: c.accent,
            borderRadius: BorderRadius.circular(UgamRadius.card),
            onRight: () => _runRowAction(context, action.kind, tour),
            child: card,
          );

    return Opacity(opacity: dimAlpha, child: swipeable);
  }

  static String _formatDate(DateTime d) {
    const months = [
      'JAN',
      'FEB',
      'MAR',
      'APR',
      'MAY',
      'JUN',
      'JUL',
      'AUG',
      'SEP',
      'OCT',
      'NOV',
      'DEC',
    ];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]}';
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

  UgamStatusTone _toneFor(TourStatus s) => switch (s) {
    TourStatus.planning => UgamStatusTone.accent,
    TourStatus.collecting => UgamStatusTone.warm,
    TourStatus.busBooked => UgamStatusTone.accent,
    TourStatus.assigning => UgamStatusTone.accent,
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

class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 28, width: 120, radius: 8),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 120, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.sm),
        UgamSkeleton(height: 120, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 28, width: 120, radius: 8),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 120, radius: UgamRadius.card),
      ],
    );
  }
}
