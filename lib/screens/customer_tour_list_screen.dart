import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import 'customer_tour_detail_screen.dart';

/// Anonymous landing screen, modeled directly on the image-5 reference:
///   • Top bar with menu / notifications / avatar
///   • Big two-line "Explore / Choose your trip" headline
///   • Search-style location pill with accent circle
///   • Horizontal pill tab row (All / Weekend / Day / Pilgrimage)
///   • Big hero feature card with bus photo overlay + chips + circle arrow
///   • "What's new" horizontal scroll of secondary cards
///   • Floating dock with circular nav buttons pinned to the bottom
class CustomerTourListScreen extends StatefulWidget {
  const CustomerTourListScreen({super.key});

  @override
  State<CustomerTourListScreen> createState() => _CustomerTourListScreenState();
}

enum _Cat { all, weekend, dayTrip, pilgrimage }

class _CustomerTourListScreenState extends State<CustomerTourListScreen> {
  _Cat _cat = _Cat.all;

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      extendBody: true,
      body: SafeArea(
        bottom: false,
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

          return RefreshIndicator(
            color: c.accent,
            onRefresh: tourCtrl.refreshTours,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                SliverToBoxAdapter(child: _TopBar(c: c)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter + 6,
                      UgamSpacing.lg,
                      UgamSpacing.gutter + 6,
                      UgamSpacing.md,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tr('customer_tour_list.brand_tagline'),
                          style: UgamText.body
                              .copyWith(color: c.ink2, fontSize: 14),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Choose your trip',
                          style: UgamText.titleXl
                              .copyWith(color: c.ink, fontSize: 28),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: _LocationPill(c: c)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter + 6,
                      UgamSpacing.lg,
                      UgamSpacing.gutter + 6,
                      UgamSpacing.md,
                    ),
                    child: _CategoryPills(
                      current: _cat,
                      onChanged: (v) => setState(() => _cat = v),
                      c: c,
                    ),
                  ),
                ),
                if (tours.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: UgamEmpty(
                      icon: Icons.event_busy_rounded,
                      title: tr('customer_tour_list.empty_title'),
                      body: tr('customer_tour_list.empty_subtitle'),
                    ),
                  )
                else ...[
                  SliverToBoxAdapter(
                    child: _HeroCard(tour: tours.first, c: c),
                  ),
                  if (tours.length > 1) ...[
                    SliverToBoxAdapter(
                      child: _SectionHeader(
                        title: "What's new",
                        action: 'View',
                        c: c,
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: _HorizontalCarousel(
                        tours: tours.skip(1).take(6).toList(),
                        c: c,
                      ),
                    ),
                  ],
                  if (tours.length > 1) ...[
                    SliverToBoxAdapter(
                      child: _SectionHeader(
                        title: 'All trips',
                        c: c,
                      ),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(
                        UgamSpacing.gutter + 6,
                        0,
                        UgamSpacing.gutter + 6,
                        140,
                      ),
                      sliver: SliverList.separated(
                        itemCount: tours.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: UgamSpacing.md),
                        itemBuilder: (_, i) =>
                            _CompactTourRow(tour: tours[i], c: c),
                      ),
                    ),
                  ] else
                    const SliverToBoxAdapter(child: SizedBox(height: 140)),
                ],
              ],
            ),
          );
        }),
      ),
      bottomNavigationBar: _AnonDock(c: c),
    );
  }

  List<Tour> _visibleTours(List<Tour> all) {
    final base = all
        .where((t) => t.isPublic && t.status != TourStatus.completed)
        .toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));
    return base;
  }
}

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  const _TopBar({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      child: Row(
        children: [
          _CircleBtn(
            icon: Icons.menu_rounded,
            c: c,
            onTap: () {},
          ),
          const Spacer(),
          _CircleBtn(
            icon: Icons.notifications_none_rounded,
            c: c,
            onTap: () => Get.toNamed('/customer-my-requests'),
          ),
          const SizedBox(width: UgamSpacing.sm),
          GestureDetector(
            onTap: () => Get.toNamed('/login'),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.lock_outline_rounded,
                  size: 18, color: c.onAccent),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final UgamColorSet c;
  final VoidCallback onTap;
  const _CircleBtn({required this.icon, required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: c.cardElev,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 19, color: c.ink),
      ),
    );
  }
}

class _LocationPill extends StatelessWidget {
  final UgamColorSet c;
  const _LocationPill({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter + 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.md,
          UgamSpacing.sm,
          UgamSpacing.sm,
          UgamSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          children: [
            Text(
              'Current:',
              style: UgamText.body.copyWith(color: c.ink2, fontSize: 13),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Ahmedabad, IN',
                style: UgamText.bodyStrong
                    .copyWith(color: c.ink, fontSize: 13),
              ),
            ),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.location_on_rounded,
                  size: 16, color: c.onAccent),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryPills extends StatelessWidget {
  final _Cat current;
  final ValueChanged<_Cat> onChanged;
  final UgamColorSet c;

  const _CategoryPills({
    required this.current,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final items = const [
      (_Cat.all, Icons.directions_bus_rounded, 'Bus Tours'),
      (_Cat.weekend, Icons.weekend_rounded, 'Weekend'),
      (_Cat.dayTrip, Icons.wb_sunny_rounded, 'Day Trip'),
      (_Cat.pilgrimage, Icons.temple_hindu_rounded, 'Pilgrimage'),
    ];
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.sm),
        itemBuilder: (_, i) {
          final (cat, icon, label) = items[i];
          final active = cat == current;
          return GestureDetector(
            onTap: () => onChanged(cat),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              padding: const EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: active ? c.accent : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon,
                        size: 16, color: active ? c.onAccent : c.ink2),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: UgamSpacing.md),
                    child: Text(
                      label,
                      style: UgamText.bodyStrong.copyWith(
                        color: active ? c.ink : c.ink2,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final UgamColorSet c;

  const _SectionHeader({required this.title, required this.c, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter + 6,
        UgamSpacing.xl,
        UgamSpacing.gutter + 6,
        UgamSpacing.md,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title,
              style: UgamText.titleM.copyWith(color: c.ink, fontSize: 17)),
          if (action != null)
            Row(
              children: [
                Text(action!,
                    style: UgamText.bodyStrong
                        .copyWith(color: c.ink2, fontSize: 12)),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded, size: 16, color: c.ink2),
              ],
            ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _HeroCard({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter + 6,
      ),
      child: GestureDetector(
        onTap: () => Get.to(
          () => CustomerTourDetailScreen(tour: tour),
          transition: Transition.cupertino,
        ),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.all(UgamSpacing.sm),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(width: UgamSpacing.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.md,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                    ),
                    child: Text(
                      tour.fromCity.isEmpty ? 'Tour' : tour.fromCity,
                      style: UgamText.bodyStrong
                          .copyWith(color: c.ink, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.md,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: c.card,
                      borderRadius: BorderRadius.circular(UgamRadius.chip),
                    ),
                    child: Text(
                      _duration(tour),
                      style: UgamText.bodyStrong
                          .copyWith(color: c.ink, fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UgamSpacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.sm),
                child: Text(
                  tour.title,
                  style: UgamText.display.copyWith(
                    color: c.ink,
                    fontSize: 30,
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: UgamSpacing.md),
              ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: SizedBox(
                  height: 180,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      UgamBusBackdrop(seed: tour.id),
                      // Bottom row inside photo: chip toggle + arrow
                      Positioned(
                        left: UgamSpacing.md,
                        right: UgamSpacing.md,
                        bottom: UgamSpacing.md,
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.45),
                                borderRadius:
                                    BorderRadius.circular(UgamRadius.chip),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: c.accent,
                                      shape: BoxShape.circle,
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      Icons.confirmation_number_rounded,
                                      size: 16,
                                      color: c.onAccent,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Padding(
                                    padding: const EdgeInsets.only(right: 10),
                                    child: Text(
                                      'Tickets',
                                      style: UgamText.bodyStrong.copyWith(
                                        color: Colors.white,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Spacer(),
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: c.accent,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: Icon(
                                Icons.arrow_forward_rounded,
                                size: 20,
                                color: c.onAccent,
                              ),
                            ),
                          ],
                        ),
                      ),
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

  String _duration(Tour t) {
    if (t.returnDate != null) {
      final days = t.returnDate!.difference(t.departureDate).inDays;
      return days <= 1 ? '$days day' : '$days days';
    }
    return 'Day trip';
  }
}

class _HorizontalCarousel extends StatelessWidget {
  final List<Tour> tours;
  final UgamColorSet c;

  const _HorizontalCarousel({required this.tours, required this.c});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.gutter + 6,
        ),
        itemCount: tours.length,
        separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.md),
        itemBuilder: (_, i) => _MiniCard(tour: tours[i], c: c),
      ),
    );
  }
}

class _MiniCard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _MiniCard({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Get.to(
        () => CustomerTourDetailScreen(tour: tour),
        transition: Transition.cupertino,
      ),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 220,
        child: Container(
          padding: const EdgeInsets.all(UgamSpacing.sm - 2),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  height: 110,
                  child: UgamBusBackdrop(seed: tour.id),
                ),
              ),
              const SizedBox(height: UgamSpacing.sm),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.sm,
                ),
                child: Text(
                  tour.title,
                  style: UgamText.titleS
                      .copyWith(color: c.ink, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.sm,
                ),
                child: Row(
                  children: [
                    Text(
                      '₹${tour.pricePerSeat.toStringAsFixed(0)}',
                      style: UgamText.tabular(
                        UgamText.bodyStrong
                            .copyWith(color: c.accent, fontSize: 14),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _shortDate(tour.departureDate),
                      style: UgamText.tabular(
                        UgamText.caption
                            .copyWith(color: c.ink2, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  static String _shortDate(DateTime d) {
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${m[d.month - 1]}';
  }
}

class _CompactTourRow extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _CompactTourRow({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Get.to(
        () => CustomerTourDetailScreen(tour: tour),
        transition: Transition.cupertino,
      ),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.sm),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                width: 68,
                height: 68,
                child: UgamBusBackdrop(seed: tour.id),
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
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: c.accent,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_forward_rounded,
                  size: 16, color: c.onAccent),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnonDock extends StatelessWidget {
  final UgamColorSet c;
  const _AnonDock({required this.c});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.md,
          0,
          UgamSpacing.md,
          UgamSpacing.md,
        ),
        child: Container(
          padding: const EdgeInsets.all(UgamSpacing.sm),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _DockIcon(
                icon: Icons.home_rounded,
                active: true,
                c: c,
                onTap: () {},
              ),
              _DockIcon(
                icon: Icons.search_rounded,
                c: c,
                onTap: () {},
              ),
              _DockIcon(
                icon: Icons.inbox_rounded,
                c: c,
                onTap: () => Get.toNamed('/customer-my-requests'),
              ),
              _DockIcon(
                icon: Icons.person_outline_rounded,
                c: c,
                onTap: () => Get.toNamed('/login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DockIcon extends StatelessWidget {
  final IconData icon;
  final bool active;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _DockIcon({
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
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: active ? c.accent : c.card,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 19, color: active ? c.onAccent : c.ink2),
      ),
    );
  }
}

class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter + 6),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        SizedBox(height: UgamSpacing.lg),
        UgamSkeleton(height: 80, radius: 28),
        SizedBox(height: UgamSpacing.lg),
        UgamSkeleton(height: 280, radius: 28),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 24, width: 100, radius: 8),
        SizedBox(height: UgamSpacing.md),
        SizedBox(
          height: 200,
          child: Row(
            children: [
              Expanded(child: UgamSkeleton(height: 200, radius: 22)),
              SizedBox(width: UgamSpacing.md),
              Expanded(child: UgamSkeleton(height: 200, radius: 22)),
            ],
          ),
        ),
      ],
    );
  }
}
