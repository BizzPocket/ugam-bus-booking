import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../routes/app_routes.dart';
import 'manage_buses_screen.dart';
import 'notify_screen.dart';
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

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              c: c,
              searchActive: _searchVisible,
              onToggleSearch: _toggleSearch,
              onCreate: () {
                HapticFeedback.lightImpact();
                Get.toNamed('/create-tour');
              },
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
                      onPressed: () => Get.toNamed('/create-tour'),
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
                      140,
                    ),
                    itemCount: groups.length,
                    itemBuilder: (_, i) {
                      final g = groups[i];
                      if (g.tours.isEmpty) return const SizedBox.shrink();
                      final isPast = g.bucket == _Bucket.past;
                      return Padding(
                        padding: EdgeInsets.only(
                          bottom: i == groups.length - 1 ? 0 : UgamSpacing.lg,
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
                                onTap: () => Get.to(
                                  () => TourDetailScreen(tourId: g.tours[j].id),
                                  transition: Transition.cupertino,
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
      if (_query.isNotEmpty)
        _Group(_Bucket.past, tr('tours.group.past'), past),
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

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final bool searchActive;
  final VoidCallback onToggleSearch;
  final VoidCallback onCreate;

  const _TopBar({
    required this.c,
    required this.searchActive,
    required this.onToggleSearch,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.lg,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              tr('tours.title'),
              style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 28),
            ),
          ),
          Semantics(
            button: true,
            label: tr('tours.search'),
            child: Tooltip(
              message: tr('tours.search'),
              child: _IconCircle(
                icon: searchActive ? Icons.close_rounded : Icons.search_rounded,
                c: c,
                onTap: onToggleSearch,
                active: searchActive,
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          // Labelled pill rather than a bare "+" circle: the primary
          // action on this screen reads as a verb, not a glyph.
          Semantics(
            button: true,
            label: tr('tours.create'),
            child: GestureDetector(
              onTap: onCreate,
              behavior: HitTestBehavior.opaque,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.lg),
                decoration: BoxDecoration(
                  color: c.accent,
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add_rounded, size: 20, color: c.onAccent),
                    const SizedBox(width: UgamSpacing.xs),
                    Text(
                      tr('tours.create'),
                      style: UgamText.bodyStrong.copyWith(color: c.onAccent),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _IconCircle extends StatelessWidget {
  final IconData icon;
  final UgamColorSet c;
  final VoidCallback onTap;
  final bool active;
  const _IconCircle({
    required this.icon,
    required this.c,
    required this.onTap,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: active ? c.accentFill : c.cardElev,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 19, color: active ? c.accent : c.ink),
      ),
    );
  }
}

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
    final assigned = tour.totalSeatsAssigned;
    final capacity = tour.totalBusSeats;
    final pct = capacity > 0 ? (assigned / capacity).clamp(0.0, 1.0) : 0.0;
    final action = _actionFor(tour);
    final dimAlpha = dim ? 0.55 : 1.0;

    return Opacity(
      opacity: dimAlpha,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(UgamSpacing.sm),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: SizedBox(
                      width: 88,
                      height: 88,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          UgamBusBackdrop(seed: tour.id),
                          Positioned(
                            left: 6,
                            top: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                _formatDate(tour.departureDate),
                                style: UgamText.tabular(
                                  UgamText.micro.copyWith(
                                    color: Colors.white,
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
                            UgamStatusDot(
                              label: tour.status.displayName,
                              tone: _toneFor(tour.status),
                            ),
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
                    backgroundColor: c.card,
                    valueColor: AlwaysStoppedAnimation(c.accent),
                  ),
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: UgamSpacing.md),
                GestureDetector(
                  onTap: () => _runRowAction(action.kind, tour),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    height: 38,
                    decoration: BoxDecoration(
                      color: c.accent,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                    ),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(action.icon, size: 14, color: c.onAccent),
                        const SizedBox(width: 6),
                        Text(
                          action.label,
                          style: UgamText.bodyStrong.copyWith(
                            color: c.onAccent,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
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
    if (t.buses.isNotEmpty && t.totalSeatsAssigned < t.totalSeatsRequested) {
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
  void _runRowAction(_RowActionKind kind, Tour t) {
    switch (kind) {
      case _RowActionKind.seats:
        Get.toNamed(AppRoutes.tourOverview, arguments: {'tourId': t.id});
        break;
      case _RowActionKind.addBus:
      case _RowActionKind.pickHandler:
        Get.to(() => ManageBusesScreen(tourId: t.id),
            transition: Transition.cupertino);
        break;
      case _RowActionKind.lockNotify:
        Get.to(() => NotifyScreen(tourId: t.id),
            transition: Transition.cupertino);
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
        UgamSkeleton(height: 120, radius: 20),
        SizedBox(height: UgamSpacing.sm),
        UgamSkeleton(height: 120, radius: 20),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 28, width: 120, radius: 8),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 120, radius: 20),
      ],
    );
  }
}
