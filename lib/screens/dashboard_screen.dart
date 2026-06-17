import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../routes/app_routes.dart';
import '../utils/tour_capacity.dart';
import 'create_tour_screen.dart';
import 'main_shell.dart';
import 'tour_detail_screen.dart';

/// Admin home — actual control center. Tells the agent what matters
/// THIS hour, not just what's in the database.
///
/// Order top-to-bottom:
///   1. Greeting + date pill + avatar (links to settings)
///   2. "TODAY" hero card if a trip departs in the next 24h, otherwise
///      a quieter "Next trip in N days" tile
///   3. Quick action row — 4 chunky tiles (Create / Requests / Assign / Notify)
///   4. Revenue hero — ONE big number (this week) with seats-sold subline
///   5. Small stats trio (Active tours / Today's seats / Waitlist)
///   6. "Needs attention" — tours blocked on agent action, with one-tap fix
///   7. Recent requests — last 5 new passengers across all tours
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  // The "today's trip" hero/tile. Now that UgamBusBackdrop is a calm graphite
  // tile (champagne reserved for the route monogram only) the section no
  // longer fights the revenue hero for accent, so it is re-enabled to match
  // the loading shimmer's 220-tall hero block. (Kept non-final on purpose so
  // the gate below doesn't const-fold into dead code.)
  // ignore: prefer_final_fields
  static bool _showTodayTrip = true;

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final authCtrl = Get.find<AuthController>();
    final shell = Get.find<ShellController>();
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
            return _LoadingShimmer(c: c);
          }
          if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
            return UgamEmpty(
              icon: Icons.cloud_off_rounded,
              title: tr('dashboard.section_overview'),
              body: tourCtrl.errorMessage.value,
              cta: UgamCTA(
                label: tr('app.action.retry'),
                leadingIcon: Icons.refresh_rounded,
                onPressed: tourCtrl.refreshTours,
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: tourCtrl.refreshTours,
            color: c.accent,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.gutter,
                UgamSpacing.lg,
                UgamSpacing.gutter,
                140,
              ),
              children: [
                Obx(() => _Greeting(
                      name: authCtrl.userName.value,
                      initials: authCtrl.initials,
                      c: c,
                    )),
                const SizedBox(height: UgamSpacing.xl),
                // TEMP: today's-trip section gated by [_showTodayTrip]. The
                // collection-if keeps the Obx out of the tree entirely when
                // hidden — an Obx whose builder reads no observable throws.
                if (_showTodayTrip)
                  Obx(() {
                    final today = _todaysTour(tourCtrl.tours);
                    final card = today != null
                        ? _TodayHeroCard(tour: today, c: c)
                        : _NoTripsTodayTile(
                            nextTour: _nextUpcomingTour(tourCtrl.tours),
                            c: c,
                          );
                    // Bottom spacer lives inside the section so hiding it
                    // leaves one clean gap before the quick actions.
                    return Padding(
                      padding: const EdgeInsets.only(bottom: UgamSpacing.xl),
                      child: card,
                    );
                  }),
                _QuickActions(c: c, shell: shell),
                const SizedBox(height: UgamSpacing.xl),
                Obx(() {
                  final revenue = _thisWeekRevenue(tourCtrl.tours);
                  final seatsSold = _thisWeekSeatsSold(tourCtrl.tours);
                  return _RevenueHero(
                    revenue: revenue,
                    seatsSold: seatsSold,
                    c: c,
                  );
                }),
                const SizedBox(height: UgamSpacing.md),
                Obx(() {
                  final active = tourCtrl.activeTours.length;
                  final todaySeats = _todaysTotalSeats(tourCtrl.tours);
                  final waitlist = _waitlistCount(tourCtrl.tours);
                  return _SmallStatsRow(
                    active: active,
                    todaySeats: todaySeats,
                    waitlist: waitlist,
                    c: c,
                  );
                }),
                const SizedBox(height: UgamSpacing.xl + UgamSpacing.xs),
                Obx(() {
                  final attention = _needsAttention(tourCtrl.tours);
                  if (attention.isEmpty) return const SizedBox.shrink();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SectionLabel(
                        label: tr('dashboard.section_attention'),
                        meta: '${attention.length}',
                        c: c,
                      ),
                      const SizedBox(height: UgamSpacing.md),
                      for (var i = 0; i < attention.length; i++) ...[
                        _AttentionRow(item: attention[i], c: c),
                        if (i != attention.length - 1)
                          const SizedBox(height: UgamSpacing.sm + 2),
                      ],
                    ],
                  );
                }),
                Obx(() {
                  final recent = _recentRequests(tourCtrl.tours);
                  if (recent.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: UgamSpacing.xl),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SectionLabel(
                          label: tr('dashboard.section_recent'),
                          action: tr('dashboard.see_all'),
                          onAction: () => shell.switchTab(3), // Requests tab
                          c: c,
                        ),
                        const SizedBox(height: UgamSpacing.md),
                        for (var i = 0; i < recent.length; i++) ...[
                          _RecentRequestRow(
                            entry: recent[i],
                            c: c,
                            onTap: () => shell.switchTab(3), // Requests tab
                          ),
                          if (i != recent.length - 1)
                            const SizedBox(height: UgamSpacing.sm + 2),
                        ],
                      ],
                    ),
                  );
                }),
              ],
            ),
          );
        }),
      ),
    );
  }

  // ── data helpers ───────────────────────────────────────────────────

  /// Tour departing today or in the next 24 hours.
  Tour? _todaysTour(List<Tour> tours) {
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(hours: 24));
    final candidates = tours
        .where((t) =>
            t.status != TourStatus.completed &&
            t.departureDate.isAfter(now.subtract(const Duration(hours: 6))) &&
            t.departureDate.isBefore(tomorrow))
        .toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));
    return candidates.isEmpty ? null : candidates.first;
  }

  Tour? _nextUpcomingTour(List<Tour> tours) {
    final now = DateTime.now();
    final candidates = tours
        .where((t) =>
            t.status != TourStatus.completed &&
            t.departureDate.isAfter(now))
        .toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));
    return candidates.isEmpty ? null : candidates.first;
  }

  /// Returns (Monday, Sunday) bounds for the calendar week containing today.
  (DateTime, DateTime) _currentWeekBounds() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final mondayStart = DateTime(monday.year, monday.month, monday.day);
    final sundayEnd = mondayStart
        .add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
    return (mondayStart, sundayEnd);
  }

  double _thisWeekRevenue(List<Tour> tours) {
    final (start, end) = _currentWeekBounds();
    return tours
        .where((t) =>
            t.departureDate.isAfter(start) &&
            t.departureDate.isBefore(end) &&
            t.status != TourStatus.completed)
        .fold<double>(
          0,
          (sum, t) => sum + (t.pricePerSeat * t.totalSeatsAssigned),
        );
  }

  int _thisWeekSeatsSold(List<Tour> tours) {
    final (start, end) = _currentWeekBounds();
    return tours
        .where((t) =>
            t.departureDate.isAfter(start) &&
            t.departureDate.isBefore(end) &&
            t.status != TourStatus.completed)
        .fold<int>(0, (sum, t) => sum + t.totalSeatsAssigned);
  }

  int _todaysTotalSeats(List<Tour> tours) {
    final today = _todaysTour(tours);
    if (today == null) return 0;
    return today.totalSeatsRequested;
  }

  int _waitlistCount(List<Tour> tours) {
    return tours
        .where((t) => t.status != TourStatus.completed)
        .fold<int>(
          0,
          (sum, t) =>
              sum + t.passengers.where((p) => p.isWaitlisted).length,
        );
  }

  /// Tours that need agent action. Ordered by departure date (soonest first).
  List<_AttentionItem> _needsAttention(List<Tour> tours) {
    final items = <_AttentionItem>[];
    final relevant = tours
        .where((t) =>
            t.status != TourStatus.completed &&
            t.status != TourStatus.locked)
        .toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));

    for (final tour in relevant) {
      // Skip empty planning tours — no requests, no urgency
      if (tour.status == TourStatus.planning && tour.passengers.isEmpty) {
        continue;
      }
      if (tour.passengers.isNotEmpty && tour.buses.isEmpty) {
        items.add(_AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_no_bus',
              args: ['${tour.passengers.length}']),
          ctaLabel: tr('dashboard.cta_add_bus'),
          ctaIcon: Icons.directions_bus_rounded,
          tone: UgamStatusTone.warm,
          onTap: () => Get.to(
            () => TourDetailScreen(tourId: tour.id),
            transition: Transition.cupertino,
          ),
        ));
        continue;
      }
      // A passenger the engine can't auto-seat (overflow, group won't fit,
      // priority miss, no matching seat type) is a sharper blocker than a raw
      // "N seats unassigned" — surface it first, routing straight to the
      // "needs your decision" list. Count comes from the live, non-mutating
      // computeTourCapacity (same source as the Requests banner).
      if (tour.buses.isNotEmpty) {
        final decisions = computeTourCapacity(tour).needsDecision;
        if (decisions > 0) {
          items.add(_AttentionItem(
            tour: tour,
            reason: tr('dashboard.attention_seating_decisions',
                args: ['$decisions']),
            ctaLabel: tr('dashboard.cta_decide'),
            ctaIcon: Icons.error_outline_rounded,
            tone: UgamStatusTone.warm,
            onTap: () => Get.toNamed(
              AppRoutes.seatingExceptions,
              arguments: {'tourId': tour.id},
            ),
          ));
          continue;
        }
      }
      if (tour.buses.isNotEmpty &&
          tour.totalSeatsAssigned < tour.totalSeatsRequested) {
        final remaining =
            tour.totalSeatsRequested - tour.totalSeatsAssigned;
        items.add(_AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_unassigned', args: ['$remaining']),
          ctaLabel: tr('dashboard.cta_assign'),
          ctaIcon: Icons.grid_view_rounded,
          tone: UgamStatusTone.accent,
          onTap: () => Get.toNamed(
            AppRoutes.seatAssignment,
            arguments: {'tourId': tour.id},
          ),
        ));
        continue;
      }
      if (tour.allSeatsAssigned && tour.handlerId == null) {
        items.add(_AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_pick_handler'),
          ctaLabel: tr('dashboard.cta_pick'),
          ctaIcon: Icons.person_pin_rounded,
          tone: UgamStatusTone.good,
          onTap: () => Get.to(
            () => TourDetailScreen(tourId: tour.id),
            transition: Transition.cupertino,
          ),
        ));
        continue;
      }
      if (tour.allSeatsAssigned && tour.handlerId != null) {
        items.add(_AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_ready_lock'),
          ctaLabel: tr('dashboard.cta_lock'),
          ctaIcon: Icons.lock_rounded,
          tone: UgamStatusTone.good,
          onTap: () {
            Get.find<ShellController>().switchTab(4);
          },
        ));
      }
    }
    return items.take(4).toList();
  }

  /// Last 5 passenger requests across all active tours.
  List<_RecentEntry> _recentRequests(List<Tour> tours) {
    final entries = <_RecentEntry>[];
    for (final t in tours.where((t) => t.status != TourStatus.completed)) {
      for (final p in t.passengers) {
        entries.add(_RecentEntry(tour: t, passenger: p));
      }
    }
    entries.sort((a, b) => b.passenger.createdAt.compareTo(a.passenger.createdAt));
    return entries.take(5).toList();
  }
}

// ─── widget pieces ────────────────────────────────────────────────────

class _Greeting extends StatelessWidget {
  final String name;
  final String initials;
  final UgamColorSet c;

  const _Greeting({
    required this.name,
    required this.initials,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? tr('dashboard.greeting_morning')
        : hour < 17
            ? tr('dashboard.greeting_afternoon')
            : tr('dashboard.greeting_evening');
    final displayName = name.isNotEmpty ? name : tr('dashboard.welcome_fallback');
    final displayInitials = initials.isNotEmpty ? initials : '👋';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(greeting,
                      style: UgamText.body
                          .copyWith(color: c.ink2, fontSize: 13)),
                  const SizedBox(width: UgamSpacing.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.sm + 2,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: c.cardElev,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                    ),
                    child: Text(
                      DateFormat('EEE, d MMM').format(DateTime.now()),
                      style: UgamText.tabular(
                        UgamText.micro.copyWith(color: c.ink2, fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                displayName,
                style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 26),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        GestureDetector(
          // Settings is shell tab 4 — switch to it rather than pushing a
          // second, dock-nav-less copy of the same screen (which also left
          // its hand-rolled back button popping the whole shell).
          onTap: () => Get.find<ShellController>().switchTab(4),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: c.cardElev,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              displayInitials,
              style: UgamText.bodyStrong
                  .copyWith(color: c.ink, fontSize: 15),
            ),
          ),
        ),
      ],
    );
  }
}

/// "TODAY" hero card. Renders when a tour departs in the next 24h.
class _TodayHeroCard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _TodayHeroCard({required this.tour, required this.c});

  String _countdown() {
    final now = DateTime.now();
    final diff = tour.departureDate.difference(now);
    if (diff.isNegative) return tr('dashboard.countdown_now');
    if (diff.inHours < 1) {
      return tr('dashboard.countdown_minutes', args: ['${diff.inMinutes}']);
    }
    return tr('dashboard.countdown_hours', args: ['${diff.inHours}']);
  }

  /// Champagne route monogram for the graphite backdrop, e.g. `S→M`.
  String? _routeMonogram() {
    final from = tour.fromCity.trim();
    final to = tour.toCity.trim();
    if (from.isEmpty || to.isEmpty) return null;
    return '${from[0].toUpperCase()}→${to[0].toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final bus = tour.buses.isNotEmpty ? tour.buses.first : null;
    return GestureDetector(
      onTap: () => Get.to(
        () => TourDetailScreen(tourId: tour.id),
        transition: Transition.cupertino,
      ),
      behavior: HitTestBehavior.opaque,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: SizedBox(
          height: 220,
          child: Stack(
            fit: StackFit.expand,
            children: [
              UgamBusBackdrop(
                seed: '${tour.id}-today',
                label: _routeMonogram(),
              ),
              // top row: TODAY pill + countdown
              Positioned(
                top: UgamSpacing.lg,
                left: UgamSpacing.lg,
                right: UgamSpacing.lg,
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UgamSpacing.md,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius:
                            BorderRadius.circular(UgamRadius.chip),
                      ),
                      child: Text(
                        tr('dashboard.today'),
                        style: UgamText.micro
                            .copyWith(color: Colors.white, fontSize: 10),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: UgamSpacing.md,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius:
                            BorderRadius.circular(UgamRadius.chip),
                      ),
                      child: Text(
                        _countdown(),
                        style: UgamText.tabular(
                          UgamText.micro
                              .copyWith(color: Colors.white, fontSize: 10),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: UgamSpacing.lg,
                right: UgamSpacing.lg,
                bottom: UgamSpacing.lg,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tour.title,
                      style: UgamText.display.copyWith(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        height: 1.05,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${tour.fromCity} → ${tour.toCity}'
                      '${bus != null ? "  ·  ${bus.displayLabel}" : ""}',
                      style: UgamText.bodyStrong
                          .copyWith(color: Colors.white.withValues(alpha: 0.85), fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: UgamSpacing.md),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UgamSpacing.md,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            borderRadius:
                                BorderRadius.circular(UgamRadius.chip),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.event_seat_rounded,
                                  size: 12, color: Colors.white),
                              const SizedBox(width: 4),
                              Text(
                                tr('dashboard.seats_count', namedArgs: {
                                  'assigned': '${tour.totalSeatsAssigned}',
                                  'total':
                                      '${tour.totalBusSeats > 0 ? tour.totalBusSeats : tour.totalSeatsRequested}',
                                }),
                                style: UgamText.tabular(
                                  UgamText.bodyStrong.copyWith(
                                    color: Colors.white,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.arrow_forward_rounded,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Quiet tile when no tour departs today.
class _NoTripsTodayTile extends StatelessWidget {
  final Tour? nextTour;
  final UgamColorSet c;
  const _NoTripsTodayTile({required this.nextTour, required this.c});

  @override
  Widget build(BuildContext context) {
    final next = nextTour;
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.sheet),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: c.card,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.wb_sunny_rounded, size: 22, color: c.ink2),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  next == null
                      ? tr('dashboard.no_upcoming_trips')
                      : tr('dashboard.no_trips_today'),
                  style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  next == null
                      ? tr('dashboard.no_trips_cta')
                      : tr('dashboard.next_trip', namedArgs: {
                          'name': next.title,
                          'when': _daysUntil(next.departureDate),
                        }),
                  style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => Get.to(
              () => const CreateTourScreen(),
              transition: Transition.cupertino,
            ),
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 14, color: c.ink),
                  const SizedBox(width: 4),
                  Text(
                    tr('dashboard.new'),
                    style: UgamText.bodyStrong
                        .copyWith(color: c.ink, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _daysUntil(DateTime when) {
    final days = when.difference(DateTime.now()).inDays;
    if (days <= 0) return tr('dashboard.days_today');
    if (days == 1) return tr('dashboard.days_one');
    return tr('dashboard.days_other', args: ['$days']);
  }
}

/// 4 chunky quick-action tiles in a single row.
class _QuickActions extends StatelessWidget {
  final UgamColorSet c;
  final ShellController shell;
  const _QuickActions({required this.c, required this.shell});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _QA(
            label: tr('dashboard.qa_create'),
            icon: Icons.add_rounded,
            c: c,
            onTap: () {
              HapticFeedback.lightImpact();
              Get.to(() => const CreateTourScreen(),
                  transition: Transition.cupertino);
            },
          ),
        ),
        const SizedBox(width: UgamSpacing.md - 4),
        Expanded(
          child: _QA(
            label: tr('dashboard.qa_tours'),
            icon: Icons.location_on_rounded,
            c: c,
            onTap: () {
              HapticFeedback.selectionClick();
              shell.switchTab(1);
            },
          ),
        ),
        const SizedBox(width: UgamSpacing.md - 4),
        Expanded(
          child: _QA(
            label: tr('dashboard.qa_assign'),
            icon: Icons.grid_view_rounded,
            c: c,
            onTap: () {
              HapticFeedback.selectionClick();
              shell.switchTab(3);
            },
          ),
        ),
        const SizedBox(width: UgamSpacing.md - 4),
        Expanded(
          child: _QA(
            label: tr('dashboard.qa_notify'),
            icon: Icons.notifications_active_rounded,
            c: c,
            onTap: () {
              HapticFeedback.selectionClick();
              shell.switchTab(4);
            },
          ),
        ),
      ],
    );
  }
}

class _QA extends StatelessWidget {
  final String label;
  final IconData icon;
  final UgamColorSet c;
  final VoidCallback onTap;
  const _QA({
    required this.label,
    required this.icon,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.sheet),
        ),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 20,
                color: c.ink,
              ),
            ),
            const SizedBox(height: UgamSpacing.sm + 2),
            Text(
              label,
              style: UgamText.bodyStrong.copyWith(
                color: c.ink,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Big revenue number, week-of-context. The hero metric of the dashboard.
class _RevenueHero extends StatelessWidget {
  final double revenue;
  final int seatsSold;
  final UgamColorSet c;

  const _RevenueHero({
    required this.revenue,
    required this.seatsSold,
    required this.c,
  });

  String _format() {
    if (revenue >= 100000) {
      final lakhs = revenue / 100000;
      return lakhs == lakhs.roundToDouble()
          ? '₹${lakhs.toInt()}L'
          : '₹${lakhs.toStringAsFixed(1)}L';
    }
    if (revenue >= 1000) {
      final k = revenue / 1000;
      return k == k.roundToDouble()
          ? '₹${k.toInt()}K'
          : '₹${k.toStringAsFixed(1)}K';
    }
    return '₹${revenue.toInt()}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.xl,
        UgamSpacing.lg,
        UgamSpacing.xl,
        UgamSpacing.lg,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.sheet),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                tr('dashboard.this_week'),
                style: UgamText.micro.copyWith(color: c.ink3),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.sm + 2, vertical: 2),
                decoration: BoxDecoration(
                  color: c.goodFill,
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.trending_up_rounded,
                        size: 11, color: c.good),
                    const SizedBox(width: 3),
                    Text(
                      tr('dashboard.stat_revenue'),
                      style: UgamText.micro
                          .copyWith(color: c.good, fontSize: 9.5),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm + 2),
          Text(
            _format(),
            style: UgamText.tabular(
              UgamText.display.copyWith(
                // The dashboard's single rationed champagne signal.
                color: c.accent,
                fontSize: 40,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.2,
                height: 1,
              ),
            ),
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            seatsSold == 0
                ? tr('dashboard.no_seats_sold')
                : tr('dashboard.seats_sold', args: ['$seatsSold']),
            style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _SmallStatsRow extends StatelessWidget {
  final int active;
  final int todaySeats;
  final int waitlist;
  final UgamColorSet c;

  const _SmallStatsRow({
    required this.active,
    required this.todaySeats,
    required this.waitlist,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _MiniStat(
            value: '$active',
            label: tr('dashboard.mini_active'),
            c: c,
          ),
        ),
        const SizedBox(width: UgamSpacing.md - 4),
        Expanded(
          child: _MiniStat(
            value: '$todaySeats',
            label: tr('dashboard.mini_today'),
            c: c,
          ),
        ),
        const SizedBox(width: UgamSpacing.md - 4),
        Expanded(
          child: _MiniStat(
            value: '$waitlist',
            label: tr('dashboard.mini_waitlist'),
            tint: waitlist > 0 ? UgamStatusTone.warm : null,
            c: c,
          ),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String value;
  final String label;
  final UgamColorSet c;
  final UgamStatusTone? tint;
  const _MiniStat({
    required this.value,
    required this.label,
    required this.c,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    Color valueColor = c.ink;
    if (tint == UgamStatusTone.warm) valueColor = c.warm;
    if (tint == UgamStatusTone.good) valueColor = c.good;
    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: UgamSpacing.md,
        horizontal: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Column(
        children: [
          Text(value,
              style: UgamText.tabular(UgamText.titleL
                  .copyWith(color: valueColor, fontSize: 22))),
          const SizedBox(height: 2),
          Text(label.toUpperCase(),
              style: UgamText.micro
                  .copyWith(color: c.ink3, fontSize: 9.5)),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final String? meta;
  final String? action;
  final VoidCallback? onAction;
  final UgamColorSet c;

  const _SectionLabel({
    required this.label,
    required this.c,
    this.meta,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(label,
            style: UgamText.titleM.copyWith(color: c.ink, fontSize: 17)),
        if (meta != null) ...[
          const SizedBox(width: UgamSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
            ),
            child: Text(
              meta!,
              style: UgamText.tabular(
                UgamText.micro.copyWith(color: c.ink2, fontSize: 10),
              ),
            ),
          ),
        ],
        const Spacer(),
        if (action != null)
          GestureDetector(
            onTap: onAction,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Text(action!,
                    style: UgamText.bodyStrong
                        .copyWith(color: c.ink2, fontSize: 12)),
                const SizedBox(width: 2),
                Icon(Icons.chevron_right_rounded, size: 16, color: c.ink2),
              ],
            ),
          ),
      ],
    );
  }
}

class _AttentionItem {
  final Tour tour;
  final String reason;
  final String ctaLabel;
  final IconData ctaIcon;
  final UgamStatusTone tone;
  final VoidCallback onTap;
  const _AttentionItem({
    required this.tour,
    required this.reason,
    required this.ctaLabel,
    required this.ctaIcon,
    required this.tone,
    required this.onTap,
  });
}

class _AttentionRow extends StatelessWidget {
  final _AttentionItem item;
  final UgamColorSet c;

  const _AttentionRow({required this.item, required this.c});

  @override
  Widget build(BuildContext context) {
    // Accent-rationing: the dashboard spends its single champagne signal on
    // the revenue hero, so the "assign seats" attention row (formerly accent)
    // is demoted to neutral ink here. Warm/good keep their semantic tokens.
    final toneColor = switch (item.tone) {
      UgamStatusTone.accent => c.ink,
      UgamStatusTone.good => c.good,
      UgamStatusTone.warm => c.warm,
      UgamStatusTone.neutral => c.ink2,
    };
    final toneFill = switch (item.tone) {
      UgamStatusTone.accent => c.card,
      UgamStatusTone.good => c.goodFill,
      UgamStatusTone.warm => c.warmFill,
      UgamStatusTone.neutral => c.card,
    };
    // Dark ink-on-light text for the neutral pill; onAccent for warm/good.
    final ctaTextColor =
        item.tone == UgamStatusTone.accent ? c.bg : c.onAccent;

    return GestureDetector(
      onTap: item.onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md - 2),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: toneFill,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(item.ctaIcon, size: 18, color: toneColor),
            ),
            const SizedBox(width: UgamSpacing.md - 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.tour.title,
                    style: UgamText.titleS.copyWith(color: c.ink, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    item.reason,
                    style: UgamText.caption.copyWith(color: c.ink2, fontSize: 11.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.md, vertical: UgamSpacing.sm),
              decoration: BoxDecoration(
                color: toneColor,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Text(
                item.ctaLabel,
                style: UgamText.bodyStrong
                    .copyWith(color: ctaTextColor, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentEntry {
  final Tour tour;
  final Passenger passenger;
  _RecentEntry({required this.tour, required this.passenger});
}

class _RecentRequestRow extends StatelessWidget {
  final _RecentEntry entry;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _RecentRequestRow({
    required this.entry,
    required this.c,
    required this.onTap,
  });

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays > 0) return '${d.inDays}d';
    if (d.inHours > 0) return '${d.inHours}h';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return tr('dashboard.ago_now');
  }

  @override
  Widget build(BuildContext context) {
    final p = entry.passenger;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md - 2),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                _initials(p.name),
                style: UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 12),
              ),
            ),
            const SizedBox(width: UgamSpacing.md - 2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          p.name,
                          style: UgamText.bodyStrong.copyWith(
                            color: c.ink,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _ago(p.createdAt),
                        style: UgamText.tabular(
                          UgamText.caption.copyWith(color: c.ink3, fontSize: 10.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 1),
                  Text(
                    tr('dashboard.recent_subtitle', namedArgs: {
                      'title': entry.tour.title,
                      'n': '${p.totalSeatsRequested}',
                    }),
                    style: UgamText.caption.copyWith(color: c.ink2, fontSize: 11.5),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingShimmer extends StatelessWidget {
  final UgamColorSet c;
  const _LoadingShimmer({required this.c});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 60, radius: 16),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 220, radius: 28),
        SizedBox(height: UgamSpacing.xl),
        Row(children: [
          Expanded(child: UgamSkeleton(height: 92, radius: 20)),
          SizedBox(width: 8),
          Expanded(child: UgamSkeleton(height: 92, radius: 20)),
          SizedBox(width: 8),
          Expanded(child: UgamSkeleton(height: 92, radius: 20)),
          SizedBox(width: 8),
          Expanded(child: UgamSkeleton(height: 92, radius: 20)),
        ]),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 140, radius: 22),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 56, radius: 18),
        SizedBox(height: 8),
        UgamSkeleton(height: 56, radius: 18),
      ],
    );
  }
}
