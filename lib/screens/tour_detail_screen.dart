import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/payment_status.dart';
import 'edit_tour_screen.dart';
import 'manage_buses_screen.dart';
import 'tour_seat_assignment_screen.dart';

/// Admin's view of a single tour. Hero photo header + overlay summary
/// card + stat tiles + bus list + sticky CTA — same image-5 pattern as
/// the customer-side detail screen, with admin actions instead.
class TourDetailScreen extends StatelessWidget {
  final String tourId;
  const TourDetailScreen({super.key, required this.tourId});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);

    return Obx(() {
      final tour = tourCtrl.getTour(tourId);
      if (tour == null) {
        return Scaffold(
          backgroundColor: c.bg,
          body: SafeArea(
            child: UgamEmpty(
              icon: Icons.search_off_rounded,
              title: tr('tour_detail.not_found_title'),
              body: tr('tour_detail.not_found_body'),
              cta: UgamCTA(
                label: 'Back',
                leadingIcon: Icons.arrow_back_rounded,
                onPressed: () => Get.back(),
              ),
            ),
          ),
        );
      }

      final booked = tour.passengers
          .where((p) => p.paymentStatus == PaymentStatus.paid)
          .length;
      final pending = tour.passengers
          .where((p) => p.paymentStatus == PaymentStatus.notPaid)
          .length;

      return Scaffold(
        backgroundColor: c.bg,
        extendBody: true,
        body: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            color: c.accent,
            onRefresh: tourCtrl.refreshTours,
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(child: _HeroSection(tour: tour, c: c)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.huge,
                      UgamSpacing.gutter,
                      UgamSpacing.md,
                    ),
                    child: _StatsRow(
                      booked: booked,
                      pending: pending,
                      assigned: tour.totalSeatsAssigned,
                      capacity: tour.totalBusSeats,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: _SectionLabel(label: 'Tour info', c: c),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.gutter,
                    ),
                    child: _InfoCard(tour: tour, c: c),
                  ),
                ),
                SliverToBoxAdapter(
                  child: _SectionLabel(
                    label: tour.buses.isEmpty
                        ? 'Buses'
                        : 'Buses · ${tour.buses.length}',
                    c: c,
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    0,
                    UgamSpacing.gutter,
                    140,
                  ),
                  sliver: tour.buses.isEmpty
                      ? SliverToBoxAdapter(child: _EmptyBusInfo(c: c))
                      : SliverList.separated(
                          itemCount: tour.buses.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: UgamSpacing.md),
                          itemBuilder: (_, i) =>
                              _BusCard(bus: tour.buses[i], c: c),
                        ),
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: _StickyAction(
          tour: tour,
          c: c,
          onManage: () => Get.to(
            () => ManageBusesScreen(tourId: tourId),
            transition: Transition.cupertino,
          ),
          onAssign: () => Get.to(
            () => TourSeatAssignmentScreen(tourId: tourId),
            transition: Transition.cupertino,
          ),
          onEdit: () => Get.to(
            () => EditTourScreen(tourId: tourId),
            transition: Transition.cupertino,
          ),
        ),
      );
    });
  }
}

class _HeroSection extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _HeroSection({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 320,
      child: Stack(
        children: [
          Positioned.fill(child: UgamBusBackdrop(seed: tour.id)),
          Positioned(
            left: UgamSpacing.gutter,
            right: UgamSpacing.gutter,
            top: UgamSpacing.md,
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Get.back(),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.arrow_back_rounded,
                        size: 19, color: Colors.white),
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Text(
                    tour.status.displayName.toUpperCase(),
                    style: UgamText.micro
                        .copyWith(color: Colors.white, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: UgamSpacing.gutter,
            right: UgamSpacing.gutter,
            bottom: -28,
            child: Container(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.lg,
                UgamSpacing.md,
                UgamSpacing.md,
                UgamSpacing.md,
              ),
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tour.title,
                            style: UgamText.titleM
                                .copyWith(color: c.ink, fontSize: 18),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.south_east_rounded,
                                size: 12, color: c.ink2),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '${tour.fromCity} → ${tour.toCity}',
                                style: UgamText.caption.copyWith(
                                    color: c.ink2, fontSize: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '₹${tour.pricePerSeat.toStringAsFixed(0)}',
                        style: UgamText.tabular(
                          UgamText.titleM
                              .copyWith(color: c.accent, fontSize: 18),
                        ),
                      ),
                      Text('/ seat',
                          style: UgamText.caption
                              .copyWith(color: c.ink3, fontSize: 10)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  final int booked;
  final int pending;
  final int assigned;
  final int capacity;

  const _StatsRow({
    required this.booked,
    required this.pending,
    required this.assigned,
    required this.capacity,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: UgamStatTile(
            icon: Icons.check_circle_rounded,
            value: '$booked',
            label: tr('tour_detail.stat_booked'),
            variant: UgamStatVariant.good,
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: UgamStatTile(
            icon: Icons.access_time_rounded,
            value: '$pending',
            label: tr('tour_detail.stat_pending'),
            variant: UgamStatVariant.warm,
          ),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: UgamStatTile(
            icon: Icons.event_seat_rounded,
            value: capacity > 0 ? '$assigned' : '—',
            ofTotal: capacity > 0 ? '/$capacity' : null,
            label: 'Assigned',
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionLabel({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.xl,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Text(
        label.toUpperCase(),
        style: UgamText.micro.copyWith(color: UgamColors.of(context).ink3),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _InfoCard({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('MMM d, yyyy');
    final start = fmt.format(tour.departureDate);
    final dateRange = tour.returnDate != null
        ? '$start – ${fmt.format(tour.returnDate!)}'
        : start;

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _row(c, Icons.calendar_today_rounded,
              tr('tour_detail.label_date_range'), dateRange),
          const SizedBox(height: UgamSpacing.md),
          _row(c, Icons.south_east_rounded,
              tr('tour_detail.label_route'), tour.route),
          const SizedBox(height: UgamSpacing.md),
          _row(
            c,
            Icons.currency_rupee_rounded,
            tr('tour_detail.label_price'),
            tr('tour_detail.price_per_seat', namedArgs: {
              'price': tour.pricePerSeat.toStringAsFixed(0)
            }),
          ),
        ],
      ),
    );
  }

  Widget _row(UgamColorSet c, IconData icon, String label, String value) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: c.accentFill,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 16, color: c.accent),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label.toUpperCase(),
                  style: UgamText.micro.copyWith(color: c.ink3)),
              const SizedBox(height: 2),
              Text(value,
                  style: UgamText.bodyStrong
                      .copyWith(color: c.ink, fontSize: 14)),
            ],
          ),
        ),
      ],
    );
  }
}

class _BusCard extends StatelessWidget {
  final dynamic bus;
  final UgamColorSet c;
  const _BusCard({required this.bus, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
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
              width: 76,
              height: 76,
              child: UgamBusBackdrop(seed: '${bus.id ?? bus.busNumber}-bus'),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  bus.busNumber ?? 'Bus',
                  style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  tr('tour_detail.driver_label',
                      namedArgs: {'name': bus.driverName ?? ''}),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: UgamSpacing.sm),
                Row(
                  children: [
                    if (bus.isAC == true)
                      const UgamReqChip(label: 'AC'),
                    if (bus.isAC == true) const SizedBox(width: 5),
                    UgamReqChip(
                      label: '${bus.totalSeats ?? 0} SEATS',
                      variant: UgamChipVariant.neutral,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyBusInfo extends StatelessWidget {
  final UgamColorSet c;
  const _EmptyBusInfo({required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.xl),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.bus_alert_rounded, color: c.ink3),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              tr('tour_detail.no_bus_assigned'),
              style: UgamText.body.copyWith(color: c.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

class _StickyAction extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final VoidCallback onManage;
  final VoidCallback onAssign;
  final VoidCallback onEdit;

  const _StickyAction({
    required this.tour,
    required this.c,
    required this.onManage,
    required this.onAssign,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final hasBus = tour.buses.isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.md,
          UgamSpacing.gutter,
          UgamSpacing.md,
        ),
        child: Row(
          children: [
            GestureDetector(
              onTap: onEdit,
              behavior: HitTestBehavior.opaque,
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: c.cardElev,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(Icons.edit_rounded, size: 20, color: c.ink),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: UgamCTA(
                label: hasBus
                    ? tr('tour_detail.btn_assign_seats', namedArgs: {
                        'assigned': tour.totalSeatsAssigned.toString(),
                        'total': tour.totalSeatsRequested.toString(),
                      })
                    : tr('tour_detail.btn_add_bus'),
                leadingIcon: hasBus
                    ? Icons.grid_view_rounded
                    : Icons.directions_bus_rounded,
                onPressed: hasBus ? onAssign : onManage,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
