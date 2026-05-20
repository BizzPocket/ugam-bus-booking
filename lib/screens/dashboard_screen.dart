import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../routes/app_routes.dart';
import 'create_tour_screen.dart';
import 'main_shell.dart';
import 'settings_screen.dart';
import 'tour_detail_screen.dart';

/// Admin home / cockpit. Greeting + 2×2 stat grid + upcoming tours.
/// Floating dock nav lives on the [MainShell] beneath this surface.
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
            return _LoadingShimmer();
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
                120, // clear the dock nav
              ),
              children: [
                Obx(() => _Greeting(
                      name: authCtrl.userName.value,
                      initials: authCtrl.initials,
                      c: c,
                    )),
                const SizedBox(height: UgamSpacing.xl),
                Obx(() {
                  final tours = tourCtrl.tours;
                  final activeTours = tourCtrl.activeTours;
                  final pendingRequests = tourCtrl
                      .toursByStatus(TourStatus.collecting)
                      .length;
                  final totalPassengers = tours.fold<int>(
                      0, (s, t) => s + t.passengerCount);
                  final revenue = tours.fold<double>(
                      0,
                      (s, t) =>
                          s + (t.pricePerSeat * t.totalSeatsRequested));
                  return _StatGrid(
                    activeCount: activeTours.length,
                    pendingRequests: pendingRequests,
                    totalPassengers: totalPassengers,
                    revenue: revenue,
                  );
                }),
                const SizedBox(height: UgamSpacing.xl),
                _SectionHeader(
                  title: tr('dashboard.section_upcoming'),
                  action: tr('dashboard.see_all'),
                  onAction: () => shell.switchTab(1),
                  c: c,
                ),
                const SizedBox(height: UgamSpacing.md),
                Obx(() {
                  final activeTours = tourCtrl.activeTours;
                  if (activeTours.isEmpty) {
                    return UgamCard.plain(
                      padding:
                          const EdgeInsets.symmetric(vertical: UgamSpacing.huge),
                      child: Column(
                        children: [
                          Icon(Icons.map_outlined, size: 40, color: c.ink3),
                          const SizedBox(height: UgamSpacing.sm),
                          Text(
                            tr('dashboard.empty_tours'),
                            style: UgamText.body.copyWith(color: c.ink2),
                          ),
                        ],
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    itemCount: activeTours.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UgamSpacing.md),
                    itemBuilder: (_, i) {
                      final tour = activeTours[i];
                      return _TourCard(
                        tour: tour,
                        onTap: () => Get.to(
                          () => TourDetailScreen(tourId: tour.id),
                          transition: Transition.cupertino,
                        ),
                        c: c,
                      );
                    },
                  );
                }),
              ],
            ),
          );
        }),
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
    final greeting = _greetingForHour(DateTime.now().hour);
    final displayName =
        name.isNotEmpty ? name : tr('dashboard.welcome_fallback');
    final displayInitials = initials.isNotEmpty ? initials : '👋';

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(greeting,
                  style: UgamText.body.copyWith(color: c.ink2, fontSize: 13)),
              const SizedBox(height: 2),
              Text(
                displayName,
                style: UgamText.titleXl.copyWith(color: c.ink, fontSize: 24),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        _CircleIcon(
          icon: Icons.add_rounded,
          tooltip: tr('dashboard.section_upcoming'),
          c: c,
          accent: true,
          onTap: () =>
              Get.to(() => const CreateTourScreen(), transition: Transition.cupertino),
        ),
        const SizedBox(width: UgamSpacing.sm),
        GestureDetector(
          onTap: () => Get.to(
            () => const SettingsScreen(),
            transition: Transition.cupertino,
          ),
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.accent,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(displayInitials,
                style: UgamText.bodyStrong
                    .copyWith(color: c.onAccent, fontSize: 14)),
          ),
        ),
      ],
    );
  }

  String _greetingForHour(int hour) {
    if (hour < 12) return tr('dashboard.greeting_morning');
    if (hour < 17) return tr('dashboard.greeting_afternoon');
    return tr('dashboard.greeting_evening');
  }
}

class _CircleIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final UgamColorSet c;
  final bool accent;
  final VoidCallback onTap;
  const _CircleIcon({
    required this.icon,
    required this.tooltip,
    required this.c,
    required this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: accent ? c.accentFill : c.cardElev,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 20, color: accent ? c.accent : c.ink2),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  final UgamColorSet c;

  const _SectionHeader({
    required this.title,
    required this.c,
    this.action,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: UgamText.titleM.copyWith(color: c.ink)),
        if (action != null)
          GestureDetector(
            onTap: onAction,
            child: Text(
              action!,
              style: UgamText.bodyStrong
                  .copyWith(color: c.accent, fontSize: 12),
            ),
          ),
      ],
    );
  }
}

class _StatGrid extends StatelessWidget {
  final int activeCount;
  final int pendingRequests;
  final int totalPassengers;
  final double revenue;

  const _StatGrid({
    required this.activeCount,
    required this.pendingRequests,
    required this.totalPassengers,
    required this.revenue,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: UgamSpacing.md,
      mainAxisSpacing: UgamSpacing.md,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 1.55,
      children: [
        UgamStatTile(
          icon: Icons.map_rounded,
          value: '$activeCount',
          label: tr('dashboard.stat_active_tours'),
        ),
        UgamStatTile(
          icon: Icons.access_time_rounded,
          value: '$pendingRequests',
          label: tr('dashboard.stat_pending_requests'),
          variant: UgamStatVariant.warm,
        ),
        UgamStatTile(
          icon: Icons.people_rounded,
          value: '$totalPassengers',
          label: tr('dashboard.stat_total_passengers'),
          variant: UgamStatVariant.good,
        ),
        UgamStatTile(
          icon: Icons.currency_rupee_rounded,
          value: _formatRevenue(revenue),
          label: tr('dashboard.stat_revenue'),
        ),
      ],
    );
  }

  String _formatRevenue(double amount) {
    if (amount >= 100000) {
      final lakhs = amount / 100000;
      return lakhs == lakhs.roundToDouble()
          ? '₹${lakhs.toInt()}L'
          : '₹${lakhs.toStringAsFixed(1)}L';
    }
    if (amount >= 1000) {
      final k = amount / 1000;
      return k == k.roundToDouble()
          ? '₹${k.toInt()}K'
          : '₹${k.toStringAsFixed(1)}K';
    }
    return '₹${amount.toInt()}';
  }
}

class _TourCard extends StatelessWidget {
  final Tour tour;
  final VoidCallback onTap;
  final UgamColorSet c;
  const _TourCard({required this.tour, required this.onTap, required this.c});

  @override
  Widget build(BuildContext context) {
    final assignedTotal = tour.totalSeatsAssigned;
    final capacity = tour.totalBusSeats;
    final pct =
        capacity > 0 ? (assignedTotal / capacity).clamp(0.0, 1.0) : 0.0;
    final tone = _toneFor(tour.status);

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.sm),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 130,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    UgamBusBackdrop(seed: tour.id),
                    Positioned(
                      top: UgamSpacing.md,
                      left: UgamSpacing.md,
                      child: UgamStatusDot(
                        label: tour.status.displayName,
                        tone: tone,
                      ),
                    ),
                    Positioned(
                      top: UgamSpacing.md - 4,
                      right: UgamSpacing.md - 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UgamSpacing.sm + 2,
                          vertical: UgamSpacing.xs + 1,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(UgamRadius.chip),
                        ),
                        child: Text(
                          _formatDate(tour.departureDate, tour.returnDate),
                          style: UgamText.tabular(
                            UgamText.bodyStrong.copyWith(
                              color: Colors.white,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: UgamSpacing.md,
                      right: UgamSpacing.md,
                      bottom: UgamSpacing.md,
                      child: Text(
                        tour.title,
                        style: UgamText.titleL.copyWith(
                          color: Colors.white,
                          fontSize: 20,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.sm + 2,
                UgamSpacing.md,
                UgamSpacing.sm + 2,
                UgamSpacing.xs,
              ),
              child: Row(
                children: [
                  _MetaItem(
                    icon: Icons.people_outline_rounded,
                    text: tr('dashboard.pax',
                        namedArgs: {'count': '${tour.passengerCount}'}),
                    c: c,
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  if (tour.fromCity.isNotEmpty || tour.toCity.isNotEmpty)
                    Expanded(
                      child: _MetaItem(
                        icon: Icons.south_east_rounded,
                        text: '${tour.fromCity} → ${tour.toCity}',
                        c: c,
                      ),
                    ),
                ],
              ),
            ),
            if (capacity > 0) ...[
              const SizedBox(height: UgamSpacing.sm),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.sm + 2,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct,
                          minHeight: 6,
                          backgroundColor: c.card,
                          valueColor: AlwaysStoppedAnimation(c.accent),
                        ),
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.sm + 2),
                    Text(
                      '$assignedTotal/$capacity',
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(
                          color: c.ink2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (_actionFor(tour.status) != null) ...[
              const SizedBox(height: UgamSpacing.md),
              GestureDetector(
                onTap: () => Get.toNamed(
                  AppRoutes.seatAssignment,
                  arguments: {'tourId': tour.id},
                ),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 42,
                  margin: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.sm + 2),
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.event_seat_rounded,
                          size: 14, color: c.onAccent),
                      const SizedBox(width: 8),
                      Text(
                        tr('dashboard.action_assign_seats'),
                        style: UgamText.bodyStrong
                            .copyWith(color: c.onAccent, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: UgamSpacing.xs),
          ],
        ),
      ),
    );
  }

  String? _actionFor(TourStatus s) {
    switch (s) {
      case TourStatus.planning:
      case TourStatus.collecting:
      case TourStatus.busBooked:
      case TourStatus.assigning:
        return 'assign';
      case TourStatus.locked:
      case TourStatus.completed:
        return null;
    }
  }

  UgamStatusTone _toneFor(TourStatus s) {
    switch (s) {
      case TourStatus.planning:
        return UgamStatusTone.accent;
      case TourStatus.collecting:
        return UgamStatusTone.warm;
      case TourStatus.busBooked:
      case TourStatus.assigning:
        return UgamStatusTone.accent;
      case TourStatus.locked:
        return UgamStatusTone.good;
      case TourStatus.completed:
        return UgamStatusTone.neutral;
    }
  }

  String _formatDate(DateTime departure, DateTime? returnDate) {
    final fmt = DateFormat('MMM d');
    if (returnDate != null) {
      return '${fmt.format(departure)} – ${fmt.format(returnDate)}';
    }
    return fmt.format(departure);
  }
}

class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String text;
  final UgamColorSet c;
  const _MetaItem({required this.icon, required this.text, required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: c.ink3),
        const SizedBox(width: 4),
        Text(text,
            style: UgamText.caption.copyWith(color: c.ink2, fontSize: 11)),
      ],
    );
  }
}

class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 56, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.xl),
        Row(children: [
          Expanded(child: UgamSkeleton(height: 88, radius: UgamRadius.stat)),
          SizedBox(width: UgamSpacing.md),
          Expanded(child: UgamSkeleton(height: 88, radius: UgamRadius.stat)),
        ]),
        SizedBox(height: UgamSpacing.md),
        Row(children: [
          Expanded(child: UgamSkeleton(height: 88, radius: UgamRadius.stat)),
          SizedBox(width: UgamSpacing.md),
          Expanded(child: UgamSkeleton(height: 88, radius: UgamRadius.stat)),
        ]),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 140, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 140, radius: UgamRadius.card),
      ],
    );
  }
}
