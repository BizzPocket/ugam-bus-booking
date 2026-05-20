import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import 'tour_detail_screen.dart';

class ToursScreen extends StatefulWidget {
  const ToursScreen({super.key});

  @override
  State<ToursScreen> createState() => _ToursScreenState();
}

enum _Filter { active, collecting, locked, completed }

class _ToursScreenState extends State<ToursScreen> {
  _Filter _filter = _Filter.active;

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
            Padding(
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
                      style: UgamText.titleXl.copyWith(color: c.ink),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Get.toNamed('/create-tour'),
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c.accent,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.add_rounded,
                          size: 22, color: c.onAccent),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.gutter,
              ),
              child: Obx(() {
                final activeCount = tourCtrl.activeTours.length;
                final collectingCount = tourCtrl
                    .toursByStatus(TourStatus.collecting)
                    .length;
                final lockedCount =
                    tourCtrl.toursByStatus(TourStatus.locked).length;
                final completedCount = tourCtrl.completedTours.length;

                return UgamTabPills(
                  currentIndex: _Filter.values.indexOf(_filter),
                  onChanged: (i) =>
                      setState(() => _filter = _Filter.values[i]),
                  items: [
                    UgamTabItem(
                      label: tr('tours.stat.active'),
                      count: activeCount,
                    ),
                    UgamTabItem(
                      label: tr('tours.stat.collecting'),
                      count: collectingCount,
                    ),
                    UgamTabItem(
                      label: tr('tours.stat.locked'),
                      count: lockedCount,
                    ),
                    UgamTabItem(
                      label: tr('tours.stat.completed'),
                      count: completedCount,
                    ),
                  ],
                );
              }),
            ),
            const SizedBox(height: UgamSpacing.lg),
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

                final filtered = _applyFilter(tourCtrl);
                if (filtered.isEmpty) {
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

                return RefreshIndicator(
                  color: c.accent,
                  onRefresh: tourCtrl.refreshTours,
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      0,
                      UgamSpacing.gutter,
                      120,
                    ),
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UgamSpacing.md),
                    itemBuilder: (_, i) => _TourRow(
                      tour: filtered[i],
                      onTap: () => Get.to(
                        () => TourDetailScreen(tourId: filtered[i].id),
                        transition: Transition.cupertino,
                      ),
                      c: c,
                    ),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  List<Tour> _applyFilter(TourController ctrl) {
    final list = switch (_filter) {
      _Filter.active => ctrl.activeTours,
      _Filter.collecting => ctrl.toursByStatus(TourStatus.collecting),
      _Filter.locked => ctrl.toursByStatus(TourStatus.locked),
      _Filter.completed => ctrl.completedTours,
    };
    final sorted = [...list]
      ..sort((a, b) => b.departureDate.compareTo(a.departureDate));
    return sorted;
  }
}

class _TourRow extends StatelessWidget {
  final Tour tour;
  final VoidCallback onTap;
  final UgamColorSet c;
  const _TourRow({required this.tour, required this.onTap, required this.c});

  @override
  Widget build(BuildContext context) {
    final assignedTotal = tour.totalSeatsAssigned;
    final capacity = tour.totalBusSeats;
    final tone = _toneFor(tour.status);

    return UgamCard.plain(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(tour.title,
                        style: UgamText.titleS
                            .copyWith(color: c.ink, fontSize: 16),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text(
                      '${tour.fromCity} → ${tour.toCity}',
                      style: UgamText.caption
                          .copyWith(color: c.ink2, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.sm + 2,
                  vertical: UgamSpacing.xs + 1,
                ),
                decoration: BoxDecoration(
                  color: c.accentFill,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                child: Text(
                  _formatDate(tour.departureDate),
                  style: UgamText.tabular(
                    UgamText.micro.copyWith(color: c.accent, fontSize: 10.5),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              UgamStatusDot(label: tour.status.displayName, tone: tone),
              const Spacer(),
              Text(
                tr('dashboard.pax',
                    namedArgs: {'count': '${tour.passengerCount}'}),
                style: UgamText.tabular(
                  UgamText.caption.copyWith(color: c.ink2),
                ),
              ),
              if (capacity > 0) ...[
                const SizedBox(width: UgamSpacing.md),
                Text('· ',
                    style: UgamText.caption.copyWith(color: c.ink3)),
                Text(
                  '$assignedTotal/$capacity',
                  style: UgamText.tabular(
                    UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
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

  static String _formatDate(DateTime d) {
    const months = [
      'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
      'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
    ];
    return '${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]}';
  }
}

class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 96, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 96, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 96, radius: UgamRadius.card),
      ],
    );
  }
}
