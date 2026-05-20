import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../services/whatsapp_service.dart';
import 'customer_booking_request_screen.dart';

/// Public-facing tour detail. Customers see route, dates, price, bus
/// info if confirmed, and a single CTA that opens the booking-request
/// composer.
class CustomerTourDetailScreen extends StatelessWidget {
  final Tour tour;

  const CustomerTourDetailScreen({super.key, required this.tour});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(c: c),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.sm,
                  UgamSpacing.gutter,
                  UgamSpacing.xl,
                ),
                children: [
                  _HeroPhoto(tour: tour, c: c),
                  const SizedBox(height: UgamSpacing.lg),
                  _statusDot(),
                  const SizedBox(height: UgamSpacing.md),
                  Text(
                    tour.title,
                    style: UgamText.titleXl.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: UgamSpacing.xs),
                  Text(
                    '${tour.fromCity} → ${tour.toCity}',
                    style: UgamText.body.copyWith(color: c.ink2, fontSize: 15),
                  ),
                  const SizedBox(height: UgamSpacing.xs),
                  Text(
                    tr('customer_tour_detail.tour_id_label',
                        namedArgs: {'code': WhatsAppService.tourCode(tour.id)}),
                    style: UgamText.tabular(
                      UgamText.caption.copyWith(color: c.ink3),
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                  UgamRouteHeader(
                    fromCode: _code(tour.fromCity),
                    fromName: tour.fromCity,
                    fromTime: _formatDate(tour.departureDate),
                    toCode: _code(tour.toCity),
                    toName: tour.toCity,
                    toTime: tour.returnDate != null
                        ? _formatDate(tour.returnDate!)
                        : null,
                    duration: tour.returnDate != null ? 'Round trip' : 'One way',
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  _PriceTile(tour: tour, c: c),
                  if (tour.buses.isNotEmpty) ...[
                    const SizedBox(height: UgamSpacing.md),
                    _BusCard(tour: tour, c: c),
                  ],
                  if (tour.description != null &&
                      tour.description!.isNotEmpty) ...[
                    const SizedBox(height: UgamSpacing.xl),
                    Text(
                      tr('customer_tour_detail.about_section').toUpperCase(),
                      style: UgamText.micro.copyWith(color: c.ink3),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    Text(
                      tour.description!,
                      style: UgamText.body
                          .copyWith(color: c.ink, fontSize: 15, height: 1.55),
                    ),
                  ],
                ],
              ),
            ),
            UgamStickyCTA(
              child: UgamCTA(
                label: tr('customer_tour_detail.request_seats_cta'),
                leadingIcon: Icons.event_seat_rounded,
                trailingValue: '₹${tour.pricePerSeat.toStringAsFixed(0)}',
                onPressed: () => Get.to(
                  () => CustomerBookingRequestScreen(tour: tour),
                  transition: Transition.cupertino,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusDot() {
    final tone = switch (tour.status) {
      TourStatus.collecting => UgamStatusTone.good,
      TourStatus.planning || TourStatus.busBooked || TourStatus.assigning =>
        UgamStatusTone.accent,
      TourStatus.locked => UgamStatusTone.warm,
      TourStatus.completed => UgamStatusTone.neutral,
    };
    return UgamStatusDot(label: tour.status.displayName, tone: tone);
  }

  static String _code(String city) {
    if (city.isEmpty) return '—';
    final cleaned = city.replaceAll(RegExp(r'[^A-Za-z]'), '');
    return cleaned.length >= 3
        ? cleaned.substring(0, 3).toUpperCase()
        : cleaned.toUpperCase();
  }

  static String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]}';
  }
}

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  const _TopBar({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.md,
        UgamSpacing.sm,
        UgamSpacing.md,
        UgamSpacing.sm,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Get.back(),
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: c.card,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_back_rounded, size: 18, color: c.ink),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              tr('customer_tour_detail.title'),
              style: UgamText.titleS.copyWith(color: c.ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroPhoto extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _HeroPhoto({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(UgamRadius.card),
      child: SizedBox(
        height: 200,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    c.accent.withValues(alpha: 0.9),
                    Color.alphaBlend(
                      c.accent.withValues(alpha: 0.5),
                      Colors.black,
                    ),
                  ],
                ),
              ),
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(UgamSpacing.lg),
                  child: Icon(
                    Icons.directions_bus_rounded,
                    size: 56,
                    color: Colors.white.withValues(alpha: 0.28),
                  ),
                ),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0x66000000)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PriceTile extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _PriceTile({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.gutter,
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.currency_rupee_rounded,
                size: 18, color: c.accent),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('customer_tour_detail.label_price_per_seat')
                      .toUpperCase(),
                  style: UgamText.micro.copyWith(color: c.ink3),
                ),
                const SizedBox(height: 2),
                Text(
                  '₹${tour.pricePerSeat.toStringAsFixed(0)}',
                  style: UgamText.numLg.copyWith(color: c.ink),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BusCard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _BusCard({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final bus = tour.buses.first;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c.goodFill,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.directions_bus_rounded,
                    size: 16, color: c.good),
              ),
              const SizedBox(width: UgamSpacing.md),
              Text(
                tr('customer_tour_detail.bus_confirmed').toUpperCase(),
                style: UgamText.micro.copyWith(color: c.good),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Text(
            bus.busNumber,
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          Text(
            '${bus.isAC ? tr('customer_tour_detail.bus_ac') : tr('customer_tour_detail.bus_non_ac')} · ${bus.busType} · ${bus.driverName}',
            style: UgamText.caption.copyWith(color: c.ink2, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
