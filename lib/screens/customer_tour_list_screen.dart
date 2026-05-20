import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../components/ugam_logo.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import 'customer_tour_detail_screen.dart';

/// Anonymous landing screen — lists public tours that customers can
/// browse without signing in. Tapping a tour opens its detail screen.
/// The header carries an inbox icon to reach My Requests, and an admin
/// lock icon to reach the agent login.
class CustomerTourListScreen extends StatelessWidget {
  const CustomerTourListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(c: c),
            Expanded(
              child: Obx(() {
                if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
                  return _LoadingShimmer();
                }
                if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
                  return UgamEmpty(
                    icon: Icons.cloud_off_rounded,
                    title: tr('customer_tour_list.error_title'),
                    body: tourCtrl.errorMessage.value,
                    cta: UgamCTA(
                      label: tr('app.action.retry'),
                      leadingIcon: Icons.refresh_rounded,
                      onPressed: tourCtrl.refreshTours,
                    ),
                  );
                }
                final tours = _visibleTours(tourCtrl.tours);
                if (tours.isEmpty) {
                  return UgamEmpty(
                    icon: Icons.event_busy_rounded,
                    title: tr('customer_tour_list.empty_title'),
                    body: tr('customer_tour_list.empty_subtitle'),
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
                      UgamSpacing.sm,
                      UgamSpacing.gutter,
                      UgamSpacing.md,
                    ),
                    itemCount: tours.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UgamSpacing.md),
                    itemBuilder: (_, i) => _TourCard(tour: tours[i]),
                  ),
                );
              }),
            ),
            UgamStickyCTA(
              child: UgamCTA(
                label: tr('customer_tour_list.my_requests_tooltip'),
                leadingIcon: Icons.inbox_rounded,
                trailingValue: '→',
                onPressed: () => Get.toNamed('/customer-my-requests'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Tour> _visibleTours(List<Tour> all) => all
      .where((t) => t.isPublic && t.status != TourStatus.completed)
      .toList()
    ..sort((a, b) => a.departureDate.compareTo(b.departureDate));
}

class _Header extends StatelessWidget {
  final UgamColorSet c;
  const _Header({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.lg,
        UgamSpacing.md,
        UgamSpacing.lg,
        UgamSpacing.lg,
      ),
      child: Row(
        children: [
          const UgamLogo(size: 36),
          const SizedBox(width: UgamSpacing.md - 2),
          Expanded(
            child: Text(
              tr('splash.brand_name'),
              style: UgamText.titleM.copyWith(color: c.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _HeaderIcon(
            icon: Icons.lock_outline_rounded,
            c: c,
            tooltip: tr('customer_tour_list.admin_button'),
            onTap: () => Get.toNamed('/login'),
          ),
        ],
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final UgamColorSet c;
  final VoidCallback onTap;
  const _HeaderIcon({
    required this.icon,
    required this.c,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: c.cardElev,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 18, color: c.ink2),
        ),
      ),
    );
  }
}

class _TourCard extends StatelessWidget {
  final Tour tour;
  const _TourCard({required this.tour});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamCard.media(
      onTap: () => Get.to(
        () => CustomerTourDetailScreen(tour: tour),
        transition: Transition.cupertino,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _HeroBlock(tour: tour, c: c),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UgamSpacing.sm,
              UgamSpacing.md - 2,
              UgamSpacing.sm,
              UgamSpacing.xs,
            ),
            child: Row(
              children: [
                if (tour.buses.isNotEmpty &&
                    tour.buses.first.isAC) ...[
                  const UgamReqChip(label: 'AC'),
                  const SizedBox(width: 6),
                ],
                if (_seatsLow(tour))
                  const UgamReqChip(
                    label: 'FEW LEFT',
                    variant: UgamChipVariant.warm,
                  ),
                const Spacer(),
                Text(
                  '${tour.passengerCount} booked',
                  style: UgamText.tabular(
                    UgamText.caption.copyWith(color: c.ink2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _seatsLow(Tour t) {
    if (t.buses.isEmpty) return false;
    final cap = t.totalBusSeats;
    if (cap == 0) return false;
    final free = cap - t.passengerCount;
    return free > 0 && free <= 6;
  }
}

class _HeroBlock extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _HeroBlock({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(UgamRadius.photo),
      child: SizedBox(
        height: 156,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Brand gradient fallback (Phase 1 actual photos ship later).
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    c.accent.withValues(alpha: 0.85),
                    Color.alphaBlend(
                      c.accent.withValues(alpha: 0.6),
                      Colors.black,
                    ),
                  ],
                ),
              ),
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(UgamSpacing.md),
                  child: Icon(
                    Icons.directions_bus_rounded,
                    size: 38,
                    color: Colors.white.withValues(alpha: 0.32),
                  ),
                ),
              ),
            ),
            // Bottom gradient overlay for legibility.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0x99000000)],
                  stops: [0.45, 1],
                ),
              ),
            ),
            // Date tab top-left.
            Positioned(
              top: UgamSpacing.sm,
              left: UgamSpacing.sm,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.sm + 2,
                  vertical: UgamSpacing.xs + 1,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                child: Text(
                  _formatDate(tour.departureDate),
                  style: UgamText.tabular(
                    UgamText.micro.copyWith(
                      color: const Color(0xFF111111),
                      fontSize: 10.5,
                    ),
                  ),
                ),
              ),
            ),
            // Title + route + price at bottom.
            Positioned(
              left: UgamSpacing.md,
              right: UgamSpacing.md,
              bottom: UgamSpacing.md,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${tour.fromCity} → ${tour.toCity}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: UgamText.caption.copyWith(
                            color: Colors.white.withValues(alpha: 0.88),
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tour.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: UgamText.titleS.copyWith(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  RichText(
                    text: TextSpan(
                      style: UgamText.tabular(
                        UgamText.titleS.copyWith(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      children: [
                        TextSpan(text: '₹${tour.pricePerSeat.toStringAsFixed(0)}'),
                        TextSpan(
                          text: '/seat',
                          style: UgamText.caption.copyWith(
                            color: Colors.white.withValues(alpha: 0.78),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime d) {
    const months = [
      'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN',
      'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC',
    ];
    const weekdays = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    return '${weekdays[d.weekday - 1]} · ${d.day.toString().padLeft(2, '0')} ${months[d.month - 1]}';
  }
}

class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton.card(),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton.card(),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton.card(),
      ],
    );
  }
}
