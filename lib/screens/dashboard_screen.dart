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
import '../utils/formatters.dart';
import 'create_tour_screen.dart';
import 'main_shell.dart';
import 'manage_buses_screen.dart';
import 'notify_screen.dart';
import 'settings_screen.dart';
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

  // TEMP: hides the "today's trip" hero/tile so the dashboard stays free of
  // extra accent colour while the new colour system is settled. Flip to
  // `true` to restore the section. (Kept non-final on purpose so the gate
  // below doesn't const-fold into dead code.)
  // ignore: prefer_final_fields
  static bool _showTodayTrip = false;

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

          // The outer Obx already rebuilds this whole subtree whenever `tours`
          // changes (it reads `tours.isEmpty` above), so the per-section Obx
          // wrappers were redundant subscriptions that each re-scanned the
          // full tour/passenger list on the same change. Derive every section's
          // data ONCE here instead — same reactivity, a fraction of the work.
          final tours = tourCtrl.tours;
          final todayTour = _showTodayTrip ? _todaysTour(tours) : null;
          final nextTour = _showTodayTrip ? _nextUpcomingTour(tours) : null;
          final revenue = _thisWeekRevenue(tours);
          final seatsSold = _thisWeekSeatsSold(tours);
          final activeCount = tourCtrl.activeTours.length;
          final todaySeats = _todaysTotalSeats(tours);
          final waitlist = _waitlistCount(tours);
          final attention = _needsAttention(tours);
          final recent = _recentRequests(tours);

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
                // TEMP: today's-trip section gated by [_showTodayTrip].
                if (_showTodayTrip)
                  Padding(
                    // Bottom spacer lives inside the section so hiding it
                    // leaves one clean gap before the quick actions.
                    padding: const EdgeInsets.only(bottom: UgamSpacing.xl),
                    child: todayTour != null
                        ? _TodayHeroCard(tour: todayTour, c: c)
                        : _NoTripsTodayTile(nextTour: nextTour, c: c),
                  ),
                _QuickActions(c: c, shell: shell),
                const SizedBox(height: UgamSpacing.xl),
                _RevenueHero(
                  revenue: revenue,
                  seatsSold: seatsSold,
                  c: c,
                ),
                const SizedBox(height: UgamSpacing.md),
                _SmallStatsRow(
                  active: activeCount,
                  todaySeats: todaySeats,
                  waitlist: waitlist,
                  c: c,
                ),
                const SizedBox(height: UgamSpacing.xl + UgamSpacing.xs),
                if (attention.isNotEmpty)
                  Column(
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
                  ),
                if (recent.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: UgamSpacing.xl),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SectionLabel(
                          label: tr('dashboard.section_recent'),
                          action: tr('dashboard.see_all'),
                          // Tabs: 0=Dashboard 1=Tours 2=Charts 3=Requests
                          // 4=Settings. Requests is 3 (was wrongly 2=Charts).
                          onAction: () => shell.switchTab(3),
                          c: c,
                        ),
                        const SizedBox(height: UgamSpacing.md),
                        for (var i = 0; i < recent.length; i++) ...[
                          UgamRequestRow(
                            initials: _recentInitials(recent[i].passenger.name),
                            name: recent[i].passenger.name,
                            timeAgo: _recentAgo(recent[i].passenger.createdAt),
                            chips: [
                              UgamReqChip(
                                label: tr(
                                  'dashboard.recent_seats_chip',
                                  namedArgs: {
                                    'n':
                                        '${recent[i].passenger.totalSeatsRequested}',
                                  },
                                ).toUpperCase(),
                              ),
                            ],
                            // Tour-first: open the request's tour workspace.
                            onTap: () => Get.to(
                              () => TourDetailScreen(tourId: recent[i].tour.id),
                              transition: Transition.cupertino,
                            ),
                          ),
                          if (i != recent.length - 1)
                            const SizedBox(height: UgamSpacing.sm + 2),
                        ],
                      ],
                    ),
                  ),
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
              namedArgs: {'n': '${tour.passengers.length}'}),
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
      if (tour.buses.isNotEmpty &&
          tour.totalSeatsAssigned < tour.totalSeatsRequested) {
        final remaining =
            tour.totalSeatsRequested - tour.totalSeatsAssigned;
        items.add(_AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_unassigned',
              namedArgs: {'n': '$remaining'}),
          // Standardized seating entry: single "Seats" label opening the
          // SeatsScreen SUMMARY (tourOverview), never the bare grid.
          ctaLabel: tr('seats.title'),
          ctaIcon: Icons.event_seat_rounded,
          tone: UgamStatusTone.accent,
          onTap: () => Get.toNamed(
            AppRoutes.tourOverview,
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
          // The handler is picked in ManageBusesScreen (the per-bus handler
          // picker home) — NOT the seat screen — so the CTA lands where the
          // action actually lives.
          onTap: () => Get.to(
            () => ManageBusesScreen(tourId: tour.id),
            transition: Transition.cupertino,
          ),
        ));
        continue;
      }
      if (tour.allSeatsAssigned &&
          tour.handlerId != null &&
          tour.status != TourStatus.locked) {
        items.add(_AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_ready_lock'),
          ctaLabel: tr('dashboard.cta_lock'),
          ctaIcon: Icons.lock_rounded,
          tone: UgamStatusTone.good,
          // Open the tour-scoped Notify screen for THIS tour.
          onTap: () => Get.to(
            () => NotifyScreen(tourId: tour.id),
            transition: Transition.cupertino,
          ),
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
                      style: UgamText.caption.copyWith(color: c.ink2)),
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
                        UgamText.micro.copyWith(color: c.ink2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                displayName,
                style: UgamText.titleXl.copyWith(color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        GestureDetector(
          onTap: () => Get.to(
            () => const SettingsScreen(),
            transition: Transition.cupertino,
          ),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              // Tonal, not solid: the one solid-champagne focal on this
              // screen is the Create quick-action tile (accent rationing).
              color: c.accentFill,
              shape: BoxShape.circle,
              border: Border.all(color: c.accent.withValues(alpha: 0.28)),
            ),
            alignment: Alignment.center,
            child: Text(
              displayInitials,
              style: UgamText.bodyStrong.copyWith(color: c.accent),
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
      return tr('dashboard.countdown_minutes',
          namedArgs: {'n': '${diff.inMinutes}'});
    }
    return tr('dashboard.countdown_hours',
        namedArgs: {'n': '${diff.inHours}'});
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
              UgamBusBackdrop(seed: '${tour.id}-today'),
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
                        color: c.accent,
                        borderRadius:
                            BorderRadius.circular(UgamRadius.chip),
                      ),
                      child: Text(
                        tr('dashboard.today'),
                        style: UgamText.micro
                            .copyWith(color: c.onAccent, fontSize: 10),
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
                      '${bus != null ? "  ·  ${bus.busNumber}" : ""}',
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
                            color: c.accent,
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.arrow_forward_rounded,
                            size: 18,
                            color: c.onAccent,
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
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: c.accentFill,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(Icons.wb_sunny_rounded, size: 22, color: c.accent),
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
                color: c.accent,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 14, color: c.onAccent),
                  const SizedBox(width: 4),
                  Text(
                    tr('dashboard.new'),
                    style: UgamText.bodyStrong
                        .copyWith(color: c.onAccent, fontSize: 12),
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
    return tr('dashboard.days_other', namedArgs: {'n': '$days'});
  }
}

/// High-frequency quick-action tiles in a single row. The agent's daily
/// drivers: spin up a tour, triage incoming requests, jump into seat
/// assignment. Settings lives in the nav, so it's dropped here.
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
            // The single solid-champagne focal on this screen (no sticky
            // CTA here): the most-used action gets the gold tile.
            primary: true,
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
            label: tr('dashboard.qa_requests'),
            icon: Icons.chat_bubble_rounded,
            c: c,
            onTap: () {
              HapticFeedback.selectionClick();
              // Tabs: 0=Dashboard 1=Tours 2=Charts/Assign 3=Requests.
              shell.switchTab(3);
            },
          ),
        ),
        const SizedBox(width: UgamSpacing.md - 4),
        Expanded(
          child: _QA(
            label: tr('dashboard.qa_assign'),
            icon: Icons.event_seat_rounded,
            c: c,
            onTap: () {
              HapticFeedback.selectionClick();
              // The Charts/Assign tab — seat fill + handler charts.
              shell.switchTab(2);
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
  final bool primary;
  const _QA({
    required this.label,
    required this.icon,
    required this.c,
    required this.onTap,
    this.primary = false,
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
          color: primary ? c.accent : c.cardElev,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: primary
                    ? c.onAccent.withValues(alpha: 0.18)
                    : c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 20,
                color: primary ? c.onAccent : c.ink,
              ),
            ),
            const SizedBox(height: UgamSpacing.sm + 2),
            Text(
              label,
              style: UgamText.bodyStrong.copyWith(
                color: primary ? c.onAccent : c.ink,
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
        borderRadius: BorderRadius.circular(22),
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
            Formatters.formatMoneyInrCompact(revenue),
            style: UgamText.tabular(
              UgamText.display.copyWith(
                color: c.ink,
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
                : tr('dashboard.seats_sold', namedArgs: {'n': '$seatsSold'}),
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
          child: UgamStatTile(
            icon: Icons.location_on_rounded,
            value: '$active',
            label: tr('dashboard.mini_active'),
            variant: UgamStatVariant.accent,
          ),
        ),
        const SizedBox(width: UgamSpacing.md - 4),
        Expanded(
          child: UgamStatTile(
            icon: Icons.event_seat_rounded,
            value: '$todaySeats',
            label: tr('dashboard.mini_today'),
            variant: UgamStatVariant.neutral,
          ),
        ),
        const SizedBox(width: UgamSpacing.md - 4),
        Expanded(
          child: UgamStatTile(
            icon: Icons.hourglass_bottom_rounded,
            value: '$waitlist',
            label: tr('dashboard.mini_waitlist'),
            variant:
                waitlist > 0 ? UgamStatVariant.warm : UgamStatVariant.neutral,
          ),
        ),
      ],
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
        Text(label, style: UgamText.titleM.copyWith(color: c.ink)),
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
                UgamText.micro.copyWith(color: c.ink2),
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
                    style: UgamText.caption.copyWith(color: c.ink2)),
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
    // Tone drives the CARD tint (de-solidified: no more solid tone-colored
    // CTA slab). The per-row action is a quiet tonal UgamButton so solid
    // champagne stays rationed to the one focal tile up top.
    final cardTone = switch (item.tone) {
      UgamStatusTone.accent => UgamCardTone.accent,
      UgamStatusTone.good => UgamCardTone.good,
      UgamStatusTone.warm => UgamCardTone.warm,
      UgamStatusTone.neutral => UgamCardTone.none,
    };
    final iconColor = switch (item.tone) {
      UgamStatusTone.accent => c.accent,
      UgamStatusTone.good => c.good,
      UgamStatusTone.warm => c.warm,
      UgamStatusTone.neutral => c.ink2,
    };
    final iconFill = switch (item.tone) {
      UgamStatusTone.accent => c.accentFill,
      UgamStatusTone.good => c.goodFill,
      UgamStatusTone.warm => c.warmFill,
      UgamStatusTone.neutral => c.card,
    };

    return UgamCard.plain(
      onTap: item.onTap,
      tone: cardTone,
      padding: const EdgeInsets.all(UgamSpacing.md - 2),
      radius: 18,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconFill,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Icon(item.ctaIcon, size: 18, color: iconColor),
          ),
          const SizedBox(width: UgamSpacing.md - 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.tour.title,
                  style: UgamText.titleS.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  item.reason,
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          UgamButton(
            label: item.ctaLabel,
            icon: item.ctaIcon,
            kind: UgamButtonKind.tonal,
            onPressed: item.onTap,
          ),
        ],
      ),
    );
  }
}

class _RecentEntry {
  final Tour tour;
  final Passenger passenger;
  _RecentEntry({required this.tour, required this.passenger});
}

/// Two-letter avatar initials for a passenger name.
String _recentInitials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.length >= 2) {
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
  return name.isNotEmpty ? name[0].toUpperCase() : '?';
}

/// Compact "time since" label for a recent request (e.g. `3h`, `2d`).
String _recentAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inDays > 0) return '${d.inDays}d';
  if (d.inHours > 0) return '${d.inHours}h';
  if (d.inMinutes > 0) return '${d.inMinutes}m';
  return tr('dashboard.ago_now');
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
