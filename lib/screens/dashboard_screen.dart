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
import '../utils/tour_capacity.dart';
import 'create_tour_screen.dart';
import 'main_shell.dart';
import 'seating_exceptions_screen.dart';
import 'seats_screen.dart';
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
                _TripHero(c: c),
                const SizedBox(height: UgamSpacing.xl),
                _QuickActions(c: c, shell: shell),
                const SizedBox(height: UgamSpacing.xl),
                Obx(() {
                  final attention = _needsAttention(context, tourCtrl.tours);
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


  /// Tours that need agent action. Ordered by departure date (soonest first).
  List<_AttentionItem> _needsAttention(BuildContext context, List<Tour> tours) {
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
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => TourDetailScreen(tourId: tour.id),
            ),
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
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => SeatingExceptionsScreen(tourId: tour.id),
              ),
            ),
          ));
          continue;
        }
      }
      if (tour.buses.isNotEmpty && tour.pendingSeatsToAssign > 0) {
        final remaining = tour.pendingSeatsToAssign;
        items.add(_AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_unassigned', args: ['$remaining']),
          ctaLabel: tr('dashboard.cta_assign'),
          ctaIcon: Icons.grid_view_rounded,
          tone: UgamStatusTone.accent,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => SeatsScreen(
                tourId: tour.id,
                initialMode: SeatsMode.grid,
              ),
            ),
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
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => TourDetailScreen(tourId: tour.id),
            ),
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

/// Futuristic-simple dashboard hero: pick a tour (defaults to the nearest
/// upcoming one), see its passenger count as the headline figure, and the
/// nearest-trip details with a way in. (Labels are placeholder English pending
/// i18n keys.)
class _TripHero extends StatefulWidget {
  final UgamColorSet c;
  const _TripHero({required this.c});

  @override
  State<_TripHero> createState() => _TripHeroState();
}

class _TripHeroState extends State<_TripHero> {
  String? _selectedId;

  List<Tour> _upcoming(List<Tour> tours) {
    // Active (non-completed) tours, soonest departure first. We don't drop
    // already-departed tours — an agent still manages a trip up to and around
    // its run date, so the "nearest" trip stays relevant after departure.
    return tours.where((t) => t.status != TourStatus.completed).toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));
  }

  static String _fmt(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${m[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final tourCtrl = Get.find<TourController>();
    return Obx(() {
      final upcoming = _upcoming(tourCtrl.tours);
      if (upcoming.isEmpty) return _emptyHero(context, c);

      var tour = upcoming.first;
      if (_selectedId != null) {
        for (final t in upcoming) {
          if (t.id == _selectedId) {
            tour = t;
            break;
          }
        }
      }
      final pax = tour.passengerCount;
      final cap = computeTourCapacity(tour);
      final isNearest = tour.id == upcoming.first.id;

      return Column(
        children: [
          _selectorPill(context, c, tour, upcoming, isNearest),
          const SizedBox(height: UgamSpacing.xl),
          _passengerHero(c, pax, cap.free, cap.capacity),
          const SizedBox(height: UgamSpacing.lg),
          _tripCard(context, c, tour, cap),
        ],
      );
    });
  }

  Widget _selectorPill(BuildContext context, UgamColorSet c, Tour tour,
      List<Tour> all, bool isNearest) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: all.length > 1 ? () => _openPicker(context, c, all) : null,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.directions_bus_rounded,
                  size: 18, color: c.accent),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${tour.fromCity} → ${tour.toCity}',
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                      '${isNearest ? tr('dashboard.nearest_trip') : tour.title} · ${tr('dashboard.departs_short', namedArgs: {
                            'date': _fmt(tour.departureDate)
                          })}',
                      style: UgamText.caption.copyWith(color: c.ink3),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (all.length > 1)
              Icon(Icons.expand_more_rounded, color: c.accent),
          ],
        ),
      ),
    );
  }

  Widget _passengerHero(UgamColorSet c, int pax, int left, int cap) {
    return SizedBox(
      height: 184,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [c.glow, c.glow.withValues(alpha: 0)],
                stops: const [0.0, 0.7],
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tr('dashboard.passengers').toUpperCase(),
                  style: UgamText.micro.copyWith(color: c.ink3)),
              const SizedBox(height: UgamSpacing.sm),
              Text('$pax',
                  style: UgamText.hero.copyWith(color: c.ink, fontSize: 64)),
              const SizedBox(height: UgamSpacing.sm),
              Text(
                  cap > 0
                      ? tr('dashboard.seats_left',
                          namedArgs: {'left': '$left', 'total': '$cap'})
                      : tr('dashboard.no_bus_added'),
                  style: UgamText.body
                      .copyWith(color: left > 0 ? c.good : c.ink2)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tripCard(
      BuildContext context, UgamColorSet c, Tour tour, TourCapacity cap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TourDetailScreen(tourId: tour.id)),
      ),
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.xl),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('dashboard.nearest_trip').toUpperCase(),
                style: UgamText.micro.copyWith(color: c.accent)),
            const SizedBox(height: UgamSpacing.md),
            Row(
              children: [
                Flexible(
                  child: Text(tour.fromCity,
                      style: UgamText.titleM.copyWith(color: c.ink),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
                  child: Icon(Icons.more_horiz_rounded, color: c.ink3, size: 18),
                ),
                Flexible(
                  child: Text(tour.toCity,
                      style: UgamText.titleM.copyWith(color: c.ink),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.sm),
            Text(
                tr('dashboard.departs',
                    namedArgs: {'date': _fmt(tour.departureDate)}),
                style: UgamText.caption.copyWith(color: c.ink2)),
            const SizedBox(height: UgamSpacing.lg),
            Container(height: 1, color: c.border),
            const SizedBox(height: UgamSpacing.lg),
            Row(
              children: [
                _leg(c, tr('dashboard.leg_go').toUpperCase(), cap.goOccupied,
                    c.ink),
                _leg(c, tr('dashboard.leg_return').toUpperCase(),
                    cap.retOccupied, c.ink),
                _leg(c, tr('dashboard.leg_free').toUpperCase(), cap.free,
                    cap.free > 0 ? c.good : c.ink2),
              ],
            ),
            const SizedBox(height: UgamSpacing.lg),
            Container(
              height: 52,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Brand.copper, Brand.copperDeep],
                ),
                borderRadius: BorderRadius.circular(UgamRadius.button),
                boxShadow: [
                  BoxShadow(
                      color: c.glow,
                      blurRadius: 22,
                      offset: const Offset(0, 10)),
                ],
              ),
              alignment: Alignment.center,
              child: Text(tr('dashboard.open_trip'),
                  style: UgamText.titleS.copyWith(color: c.onAccent)),
            ),
          ],
        ),
      ),
    );
  }

  /// One column of the leg breakdown: a small caps label + a big Sora figure.
  Widget _leg(UgamColorSet c, String label, int n, Color numColor) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: UgamText.micro.copyWith(color: c.ink3)),
          const SizedBox(height: 4),
          Text('$n', style: UgamText.numXl.copyWith(color: numColor)),
        ],
      ),
    );
  }

  Widget _emptyHero(BuildContext context, UgamColorSet c) {
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.xl),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Column(
        children: [
          Icon(Icons.explore_rounded, size: 30, color: c.ink3),
          const SizedBox(height: UgamSpacing.md),
          Text(tr('dashboard.no_upcoming_trips'),
              style: UgamText.titleM.copyWith(color: c.ink)),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: tr('tours.empty.cta'),
            leadingIcon: Icons.add_rounded,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CreateTourScreen()),
            ),
          ),
        ],
      ),
    );
  }

  void _openPicker(BuildContext context, UgamColorSet c, List<Tour> all) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.card,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(UgamRadius.sheet)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(UgamSpacing.gutter,
              UgamSpacing.lg, UgamSpacing.gutter, UgamSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: UgamSpacing.lg),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              Text(tr('dashboard.choose_trip'),
                  style: UgamText.titleM.copyWith(color: c.ink)),
              const SizedBox(height: UgamSpacing.md),
              for (final t in all)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() => _selectedId = t.id);
                    Navigator.of(ctx).pop();
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: UgamSpacing.sm),
                    padding: const EdgeInsets.all(UgamSpacing.md),
                    decoration: BoxDecoration(
                      color: c.cardElev,
                      borderRadius: BorderRadius.circular(UgamRadius.row),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('${t.fromCity} → ${t.toCity}',
                                  style:
                                      UgamText.titleS.copyWith(color: c.ink),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              const SizedBox(height: 2),
                              Text(
                                  tr('dashboard.departs_short', namedArgs: {
                                    'date': _fmt(t.departureDate)
                                  }),
                                  style: UgamText.caption
                                      .copyWith(color: c.ink3)),
                            ],
                          ),
                        ),
                        Text('${t.passengerCount}',
                            style: UgamText.numLg.copyWith(color: c.accent)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

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
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const CreateTourScreen(),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
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
        const SizedBox(width: UgamSpacing.md),
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
        const SizedBox(width: UgamSpacing.md),
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
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        child: Column(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 20, color: c.ink),
            ),
            const SizedBox(height: UgamSpacing.sm + 2),
            Text(
              label,
              style: UgamText.caption.copyWith(color: c.ink2, fontSize: 11.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
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
        UgamSkeleton(height: 150, radius: 20),
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
