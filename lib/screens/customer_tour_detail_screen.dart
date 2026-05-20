import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';
import '../models/tour.dart';
import '../services/whatsapp_service.dart';
import 'customer_booking_request_screen.dart';

/// Public-facing tour detail. Layout mirrors the image-5 "My Bookings"
/// detail: full-bleed photo + floating overlay card carrying title +
/// rating + price + back/notify icons; pill tab row (Deals / Details /
/// Reviews); list of journey/bus cards; sticky bottom CTA with seat
/// count + total + "Book Now" pill.
class CustomerTourDetailScreen extends StatefulWidget {
  final Tour tour;

  const CustomerTourDetailScreen({super.key, required this.tour});

  @override
  State<CustomerTourDetailScreen> createState() =>
      _CustomerTourDetailScreenState();
}

enum _DetailTab { deals, details, reviews }

class _CustomerTourDetailScreenState extends State<CustomerTourDetailScreen> {
  _DetailTab _tab = _DetailTab.details;
  int _seats = 1;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final t = widget.tour;
    final totalPrice = t.pricePerSeat * _seats;

    return Scaffold(
      backgroundColor: c.bg,
      extendBody: true,
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(child: _HeroSection(tour: t, c: c)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  UgamSpacing.gutter,
                  UgamSpacing.md,
                  UgamSpacing.gutter,
                  UgamSpacing.md,
                ),
                child: _TabPills(
                  current: _tab,
                  onChanged: (v) => setState(() => _tab = v),
                  c: c,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.gutter,
                0,
                UgamSpacing.gutter,
                140,
              ),
              sliver: switch (_tab) {
                _DetailTab.deals => SliverList.list(
                    children: [
                      _BusOptionCard(
                        title: t.fromCity.isEmpty
                            ? 'Outbound Route'
                            : '${t.fromCity} Departure',
                        subtitle: '${t.fromCity} → ${t.toCity}',
                        price: t.pricePerSeat,
                        c: c,
                        seed: '${t.id}-1',
                      ),
                      const SizedBox(height: UgamSpacing.md),
                      if (t.returnDate != null)
                        _BusOptionCard(
                          title: 'Return Route',
                          subtitle: '${t.toCity} → ${t.fromCity}',
                          price: t.pricePerSeat,
                          c: c,
                          seed: '${t.id}-2',
                        ),
                    ],
                  ),
                _DetailTab.details =>
                  SliverList.list(children: _detailsBlocks(c)),
                _DetailTab.reviews => SliverList.list(
                    children: [
                      _ReviewsEmpty(c: c),
                    ],
                  ),
              },
            ),
          ],
        ),
      ),
      bottomNavigationBar: _StickyBookBar(
        seats: _seats,
        total: totalPrice,
        c: c,
        onMinus: _seats > 1 ? () => setState(() => _seats--) : null,
        onPlus: () => setState(() => _seats++),
        onBook: () => Get.to(
          () => CustomerBookingRequestScreen(tour: t),
          transition: Transition.cupertino,
        ),
      ),
    );
  }

  List<Widget> _detailsBlocks(UgamColorSet c) {
    final t = widget.tour;
    return [
      _InfoCard(
        c: c,
        title: t.title,
        rows: [
          ('Route', '${t.fromCity} → ${t.toCity}'),
          ('Departure', _formatDate(t.departureDate)),
          if (t.returnDate != null) ('Return', _formatDate(t.returnDate!)),
          ('Tour ID', WhatsAppService.tourCode(t.id)),
        ],
      ),
      if (t.buses.isNotEmpty) ...[
        const SizedBox(height: UgamSpacing.md),
        _BusOptionCard(
          title: t.buses.first.busNumber,
          subtitle:
              '${t.buses.first.isAC ? "AC" : "Non-AC"} · ${t.buses.first.busType} · ${t.buses.first.driverName}',
          price: t.pricePerSeat,
          c: c,
          seed: '${t.id}-bus',
        ),
      ],
      if (t.description != null && t.description!.isNotEmpty) ...[
        const SizedBox(height: UgamSpacing.md),
        Container(
          padding: const EdgeInsets.all(UgamSpacing.lg),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('About this tour'.toUpperCase(),
                  style: UgamText.micro.copyWith(color: c.ink3)),
              const SizedBox(height: UgamSpacing.sm),
              Text(
                t.description!,
                style: UgamText.body.copyWith(
                  color: c.ink,
                  fontSize: 14,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      ],
    ];
  }

  static String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

class _HeroSection extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _HeroSection({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 360,
      child: Stack(
        children: [
          Positioned.fill(child: UgamBusBackdrop(seed: tour.id)),
          // Top action row over the hero photo
          Positioned(
            left: UgamSpacing.gutter,
            right: UgamSpacing.gutter,
            top: UgamSpacing.md,
            child: Row(
              children: [
                _HeroBtn(
                  icon: Icons.arrow_back_rounded,
                  onTap: () => Get.back(),
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
                    'My Bookings',
                    style: UgamText.bodyStrong
                        .copyWith(color: Colors.white, fontSize: 13),
                  ),
                ),
                const Spacer(),
                _HeroBtn(
                  icon: Icons.notifications_none_rounded,
                  onTap: () {},
                ),
              ],
            ),
          ),
          // Overlay card pinned to the bottom of the hero
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
                        Text(
                          tour.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: UgamText.titleM
                              .copyWith(color: c.ink, fontSize: 17),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(Icons.location_on_rounded,
                                size: 12, color: c.ink2),
                            const SizedBox(width: 3),
                            Flexible(
                              child: Text(
                                '${tour.fromCity}, IN',
                                style: UgamText.caption
                                    .copyWith(color: c.ink2, fontSize: 11),
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
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UgamSpacing.sm,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: c.warm,
                          borderRadius:
                              BorderRadius.circular(UgamRadius.chip),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.star_rounded,
                                size: 11, color: Colors.white),
                            const SizedBox(width: 2),
                            Text(
                              '4.6',
                              style: UgamText.bodyStrong.copyWith(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '₹${tour.pricePerSeat.toStringAsFixed(0)}',
                        style: UgamText.tabular(
                          UgamText.titleM.copyWith(
                            color: c.accent,
                            fontSize: 18,
                          ),
                        ),
                      ),
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

class _HeroBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _HeroBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 19, color: Colors.white),
      ),
    );
  }
}

class _TabPills extends StatelessWidget {
  final _DetailTab current;
  final ValueChanged<_DetailTab> onChanged;
  final UgamColorSet c;

  const _TabPills({
    required this.current,
    required this.onChanged,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final items = const [
      (_DetailTab.deals, Icons.local_offer_rounded, 'Deals'),
      (_DetailTab.details, Icons.list_alt_rounded, 'Details'),
      (_DetailTab.reviews, Icons.star_outline_rounded, 'Reviews'),
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        padding: EdgeInsets.zero,
        separatorBuilder: (_, _) => const SizedBox(width: UgamSpacing.sm),
        itemBuilder: (_, i) {
          final (tab, icon, label) = items[i];
          final active = tab == current;
          return GestureDetector(
            onTap: () => onChanged(tab),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: UgamMotion.tab,
              curve: UgamMotion.easeOut,
              padding: const EdgeInsets.fromLTRB(4, 4, UgamSpacing.md, 4),
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
              ),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: active ? c.accent : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(icon,
                        size: 16, color: active ? c.onAccent : c.ink2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: UgamText.bodyStrong.copyWith(
                      color: active ? c.ink : c.ink2,
                      fontSize: 13,
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

class _BusOptionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final double price;
  final UgamColorSet c;
  final String seed;

  const _BusOptionCard({
    required this.title,
    required this.subtitle,
    required this.price,
    required this.c,
    required this.seed,
  });

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
              width: 84,
              height: 84,
              child: UgamBusBackdrop(seed: seed),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: UgamText.titleS
                            .copyWith(color: c.ink, fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: c.warm,
                        borderRadius:
                            BorderRadius.circular(UgamRadius.chip),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.star_rounded,
                              size: 10, color: Colors.white),
                          const SizedBox(width: 2),
                          Text(
                            '4.6',
                            style: UgamText.bodyStrong.copyWith(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: UgamText.caption
                      .copyWith(color: c.ink2, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '₹${price.toStringAsFixed(0)}',
                      style: UgamText.tabular(
                        UgamText.titleM.copyWith(
                          color: c.accent,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '/ seat',
                        style: UgamText.caption
                            .copyWith(color: c.ink3, fontSize: 10),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: c.card,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.arrow_forward_rounded,
                          size: 16, color: c.ink),
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

class _InfoCard extends StatelessWidget {
  final UgamColorSet c;
  final String title;
  final List<(String, String)> rows;

  const _InfoCard({
    required this.c,
    required this.title,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
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
          Text(title, style: UgamText.titleM.copyWith(color: c.ink)),
          const SizedBox(height: UgamSpacing.md),
          for (final (label, value) in rows) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 90,
                  child: Text(
                    label,
                    style: UgamText.caption.copyWith(color: c.ink3),
                  ),
                ),
                Expanded(
                  child: Text(
                    value,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                ),
              ],
            ),
            if (label != rows.last.$1) const SizedBox(height: UgamSpacing.sm),
          ],
        ],
      ),
    );
  }
}

class _ReviewsEmpty extends StatelessWidget {
  final UgamColorSet c;
  const _ReviewsEmpty({required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.huge),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          Icon(Icons.star_outline_rounded, size: 40, color: c.ink3),
          const SizedBox(height: UgamSpacing.sm),
          Text('No reviews yet',
              style: UgamText.titleS.copyWith(color: c.ink2)),
          const SizedBox(height: 4),
          Text(
            'Be the first to travel and review.',
            style: UgamText.caption.copyWith(color: c.ink3),
          ),
        ],
      ),
    );
  }
}

class _StickyBookBar extends StatelessWidget {
  final int seats;
  final double total;
  final UgamColorSet c;
  final VoidCallback? onMinus;
  final VoidCallback onPlus;
  final VoidCallback onBook;

  const _StickyBookBar({
    required this.seats,
    required this.total,
    required this.c,
    required this.onMinus,
    required this.onPlus,
    required this.onBook,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.md,
          UgamSpacing.gutter,
          UgamSpacing.md,
        ),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: c.accent,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: c.onAccent,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(Icons.person_outline_rounded,
                    size: 19, color: c.accent),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SeatStep(
                          icon: Icons.remove_rounded,
                          enabled: onMinus != null,
                          onTap: onMinus,
                          c: c,
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '$seats Seats',
                            style: UgamText.tabular(
                              UgamText.bodyStrong.copyWith(
                                color: c.onAccent,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                        _SeatStep(
                          icon: Icons.add_rounded,
                          enabled: true,
                          onTap: onPlus,
                          c: c,
                        ),
                      ],
                    ),
                    Text(
                      '₹${total.toStringAsFixed(0)}',
                      style: UgamText.tabular(
                        UgamText.titleM.copyWith(
                          color: c.onAccent,
                          fontSize: 17,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: onBook,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.lg + 2,
                    vertical: UgamSpacing.md - 2,
                  ),
                  decoration: BoxDecoration(
                    color: c.onAccent,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Text(
                    'Book Now',
                    style: UgamText.titleS.copyWith(
                      color: c.accent,
                      fontSize: 14,
                    ),
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

class _SeatStep extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;
  final UgamColorSet c;

  const _SeatStep({
    required this.icon,
    required this.enabled,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: enabled
              ? c.onAccent.withValues(alpha: 0.18)
              : c.onAccent.withValues(alpha: 0.08),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon,
            size: 13,
            color: enabled
                ? c.onAccent
                : c.onAccent.withValues(alpha: 0.4)),
      ),
    );
  }
}
