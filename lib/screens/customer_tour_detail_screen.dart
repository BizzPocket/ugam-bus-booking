import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import '../utils/time_format.dart';
import 'customer_booking_request_screen.dart';

/// Public-facing tour detail — image-5 fidelity.
///
/// Layout mirrors the admin `tour_detail_screen.dart`:
///   [Hero (320 px) — UgamBusBackdrop + back chevron + share chevron]
///   [Overlay summary card (title / route header / date / price / seats)]
///   [Tab pills (About / Schedule)]
///   [Body — switches per tab]
///   [Sticky bottom CTA — "Request to book" / "Booked" / "Tour full"]
class CustomerTourDetailScreen extends StatefulWidget {
  final Tour tour;

  const CustomerTourDetailScreen({super.key, required this.tour});

  @override
  State<CustomerTourDetailScreen> createState() =>
      _CustomerTourDetailScreenState();
}

class _CustomerTourDetailScreenState extends State<CustomerTourDetailScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final t = widget.tour;

    return Scaffold(
      backgroundColor: c.bg,
      extendBody: true,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: _HeroSection(
              tour: t,
              onBack: () => Get.back(),
              onShare: () async {
                HapticFeedback.lightImpact();
                await WhatsAppService().copyAnnouncementToClipboard(tour: t);
              },
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.gutter,
                UgamSpacing.huge,
                UgamSpacing.gutter,
                UgamSpacing.lg,
              ),
              child: _TabBar(
                index: _tabIndex,
                onChanged: (i) => setState(() => _tabIndex = i),
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
            sliver: _tabIndex == 0
                ? _AboutTab(tour: t, c: c)
                : _ScheduleTab(tour: t, c: c),
          ),
        ],
      ),
      bottomNavigationBar: _StickyBookCta(tour: t),
    );
  }
}

// ─── HERO ─────────────────────────────────────────────────────────────

class _HeroSection extends StatelessWidget {
  final Tour tour;
  final VoidCallback onBack;
  final VoidCallback onShare;

  const _HeroSection({
    required this.tour,
    required this.onBack,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final topInset = MediaQuery.of(context).padding.top;
    final capacity = tour.totalBusSeats;
    final seatsLeft = capacity - tour.totalSeatsAssigned;

    return SizedBox(
      height: 320,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: UgamBusBackdrop(seed: tour.id)),
          // Dark gradient for legibility.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.45),
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.35),
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          // Top chrome row.
          Positioned(
            left: UgamSpacing.gutter,
            right: UgamSpacing.gutter,
            top: topInset + UgamSpacing.sm,
            child: Row(
              children: [
                _ChromeCircle(icon: Icons.arrow_back_rounded, onTap: onBack),
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
                    style: UgamText.micro.copyWith(
                      color: Colors.white,
                      fontSize: 10,
                    ),
                  ),
                ),
                const Spacer(),
                _ChromeCircle(icon: Icons.ios_share_rounded, onTap: onShare),
              ],
            ),
          ),
          // Overlay summary card overhanging the hero bottom.
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
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tour.title,
                          style: UgamText.titleM.copyWith(
                            color: c.ink,
                            fontSize: 18,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(Icons.south_east_rounded, size: 12, color: c.ink2),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '${tour.fromCity} → ${tour.toCity}',
                          style: UgamText.caption.copyWith(
                            color: c.ink2,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: UgamSpacing.sm),
                      Text(
                        '·',
                        style: UgamText.caption.copyWith(
                          color: c.ink3,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(width: UgamSpacing.sm),
                      Text(
                        _formatDate(tour.departureDate),
                        style: UgamText.tabular(
                          UgamText.caption.copyWith(
                            color: c.ink2,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (capacity > 0)
                        UgamReqChip(
                          label: seatsLeft <= 0
                              ? tr('customer_tour_detail.chip_tour_full')
                              : tr(
                                  'customer_tour_detail.chip_seats_left',
                                  namedArgs: {'n': '$seatsLeft'},
                                ),
                          variant: seatsLeft <= 0
                              ? UgamChipVariant.warm
                              : UgamChipVariant.good,
                        )
                      else
                        UgamReqChip(
                          label: tr('customer_tour_detail.chip_open_requests'),
                          variant: UgamChipVariant.accent,
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

  static String _formatDate(DateTime d) {
    return '${d.day} ${_monthShort(d.month)}';
  }
}

/// Shared localized 3-letter month abbreviation used across customer screens.
String _monthShort(int month) {
  const keys = [
    'app.month.short.jan',
    'app.month.short.feb',
    'app.month.short.mar',
    'app.month.short.apr',
    'app.month.short.may',
    'app.month.short.jun',
    'app.month.short.jul',
    'app.month.short.aug',
    'app.month.short.sep',
    'app.month.short.oct',
    'app.month.short.nov',
    'app.month.short.dec',
  ];
  return tr(keys[month - 1]);
}

class _ChromeCircle extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ChromeCircle({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
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

// ─── TAB BAR ──────────────────────────────────────────────────────────

class _TabBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onChanged;

  const _TabBar({required this.index, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return UgamTabPills(
      currentIndex: index,
      onChanged: onChanged,
      items: [
        UgamTabItem(label: tr('customer_tour_detail.tab_about')),
        UgamTabItem(label: tr('customer_tour_detail.tab_schedule')),
      ],
    );
  }
}

// ─── ABOUT TAB ────────────────────────────────────────────────────────

class _AboutTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _AboutTab({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _SectionEyebrow(
          label: tr('customer_tour_detail.section_trip_summary'),
          c: c,
        ),
        const SizedBox(height: UgamSpacing.md),
        _InfoCard(
          c: c,
          rows: [
            (
              tr('customer_tour_detail.label_route'),
              '${tour.fromCity} → ${tour.toCity}',
            ),
            (
              tr('customer_tour_detail.label_departure'),
              _dateWithTime(tour.departureDate, tour.departureTime),
            ),
            if (tour.returnDate != null)
              (
                tr('customer_tour_detail.label_return'),
                _dateWithTime(tour.returnDate!, tour.returnTime),
              ),
          ],
        ),
        if (tour.description != null && tour.description!.isNotEmpty) ...[
          const SizedBox(height: UgamSpacing.xl),
          _SectionEyebrow(
            label: tr('customer_tour_detail.section_about_tour'),
            c: c,
          ),
          const SizedBox(height: UgamSpacing.md),
          Container(
            padding: const EdgeInsets.all(UgamSpacing.lg),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Text(
              tour.description!,
              style: UgamText.body.copyWith(
                color: c.ink,
                fontSize: 14,
                height: 1.55,
              ),
            ),
          ),
        ],
        if (tour.buses.isNotEmpty) ...[
          const SizedBox(height: UgamSpacing.xl),
          _SectionEyebrow(label: tr('customer_tour_detail.section_bus'), c: c),
          const SizedBox(height: UgamSpacing.md),
          _BusCard(tour: tour, c: c),
        ],
        if (tour.createdBy != null && tour.createdBy!.trim().isNotEmpty) ...[
          const SizedBox(height: UgamSpacing.xl),
          _SectionEyebrow(
            label: tr('customer_tour_detail.section_contact'),
            c: c,
          ),
          const SizedBox(height: UgamSpacing.md),
          _ContactOrganiserButton(tour: tour, c: c),
        ],
      ]),
    );
  }

  static String _formatLongDate(DateTime d) {
    return '${d.day} ${_monthShort(d.month)} ${d.year}';
  }

  /// Long date with the optional time-of-day appended ("14 Jun 2026 · 9:00 PM").
  /// Falls back to date-only when no time is set.
  static String _dateWithTime(DateTime d, String? hhmm) {
    final time = formatHhMm(hhmm);
    final date = _formatLongDate(d);
    return time != null ? '$date · $time' : date;
  }
}

/// Tappable "Contact organiser on WhatsApp" row shown on a tour's About tab
/// when the tour carries an organiser number ([Tour.createdBy]) — the same
/// number the booking flow sends requests to. Opens a WhatsApp chat with a
/// tour-aware greeting. Hidden entirely when the tour has no organiser number.
class _ContactOrganiserButton extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _ContactOrganiserButton({required this.tour, required this.c});

  Future<void> _open() async {
    HapticFeedback.selectionClick();
    final phone = tour.createdBy?.trim() ?? '';
    if (phone.isEmpty) return;
    final ok = await WhatsAppService().openChat(
      phone: phone,
      message: tr(
        'customer_tour_detail.contact_greeting',
        namedArgs: {
          'tour': tour.title,
          'code': WhatsAppService.tourCode(tour.id),
        },
      ),
    );
    if (!ok) {
      AppSnackBar.error(
        tr('customer_tour_detail.contact_error_body'),
        title: tr('customer_tour_detail.contact_error_title'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _open,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(UgamSpacing.lg),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 20,
                  color: c.accent,
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('customer_tour_detail.contact_organiser'),
                      style: UgamText.bodyStrong.copyWith(
                        color: c.ink,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('customer_tour_detail.contact_organiser_subtitle'),
                      style: UgamText.caption.copyWith(
                        color: c.ink2,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_rounded, size: 18, color: c.ink3),
            ],
          ),
        ),
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
    final departure = _busDeparture(bus.boardingPoint, bus.departureTime);
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
              child: UgamBusBackdrop(seed: '${bus.id}-bus'),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  bus.busNumber.isNotEmpty ? bus.busNumber : bus.name,
                  style: UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  bus.busType,
                  style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
                ),
                if (departure != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.place_outlined,
                        size: 12,
                        color: c.ink3,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          departure,
                          style: UgamText.caption.copyWith(
                            color: c.ink2,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: UgamSpacing.sm),
                Row(
                  children: [
                    if (bus.isAC) ...[
                      UgamReqChip(label: tr('customer_tour_detail.bus_ac')),
                      const SizedBox(width: 5),
                    ],
                    UgamReqChip(
                      label: tr(
                        'customer_tour_detail.chip_seats',
                        namedArgs: {'count': bus.totalSeats.toString()},
                      ),
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

  /// Per-bus boarding place + departure time, joined as `<place> · <time>` per
  /// the surfacing rule. Either part is omitted when empty/null; returns null
  /// when both are empty so the caller can hide the line entirely. Per-bus
  /// values override tour-level / chart-footer values.
  static String? _busDeparture(String boardingPoint, String? departureTime) {
    final place = boardingPoint.trim();
    final time = formatHhMm(departureTime);
    final parts = [
      if (place.isNotEmpty) place,
      ?time,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

// ─── SCHEDULE TAB ─────────────────────────────────────────────────────

class _ScheduleTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _ScheduleTab({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final events = _events();
    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _SectionEyebrow(
          label: tr('customer_tour_detail.section_timeline'),
          c: c,
        ),
        const SizedBox(height: UgamSpacing.md),
        for (var i = 0; i < events.length; i++)
          _TimelineRow(
            event: events[i],
            isFirst: i == 0,
            isLast: i == events.length - 1,
            c: c,
          ),
      ]),
    );
  }

  List<_ScheduleEvent> _events() {
    final out = <_ScheduleEvent>[
      _ScheduleEvent(
        icon: Icons.directions_bus_rounded,
        title: tr(
          'customer_tour_detail.schedule_departure_from',
          namedArgs: {'city': tour.fromCity},
        ),
        time: tour.departureDate,
        timeLabel: formatHhMm(tour.departureTime),
      ),
      _ScheduleEvent(
        icon: Icons.location_on_rounded,
        title: tr(
          'customer_tour_detail.schedule_arrive_in',
          namedArgs: {'city': tour.toCity},
        ),
        time: tour.departureDate,
      ),
    ];
    if (tour.returnDate != null) {
      out.add(
        _ScheduleEvent(
          icon: Icons.flag_rounded,
          title: tr(
            'customer_tour_detail.schedule_return_to',
            namedArgs: {'city': tour.fromCity},
          ),
          time: tour.returnDate!,
          timeLabel: formatHhMm(tour.returnTime),
        ),
      );
    }
    return out;
  }
}

class _ScheduleEvent {
  final IconData icon;
  final String title;
  final DateTime time;

  /// Optional time-of-day label ('9:00 PM') appended after the date. Null for
  /// events with no set time (e.g. arrival, or a tour created without times).
  final String? timeLabel;
  const _ScheduleEvent({
    required this.icon,
    required this.title,
    required this.time,
    this.timeLabel,
  });
}

class _TimelineRow extends StatelessWidget {
  final _ScheduleEvent event;
  final bool isFirst;
  final bool isLast;
  final UgamColorSet c;

  const _TimelineRow({
    required this.event,
    required this.isFirst,
    required this.isLast,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 36,
            child: Column(
              children: [
                if (isFirst)
                  const SizedBox(height: 8)
                else
                  Expanded(child: Container(width: 2, color: c.border)),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: c.accentFill,
                    shape: BoxShape.circle,
                    border: Border.all(color: c.accent, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Icon(event.icon, size: 13, color: c.accent),
                ),
                if (isLast)
                  const SizedBox(height: 8)
                else
                  Expanded(child: Container(width: 2, color: c.border)),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
              child: Container(
                padding: const EdgeInsets.all(UgamSpacing.md - 2),
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      event.title,
                      style: UgamText.bodyStrong.copyWith(
                        color: c.ink,
                        fontSize: 13,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      event.timeLabel != null
                          ? '${_formatDate(event.time)} · ${event.timeLabel}'
                          : _formatDate(event.time),
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(color: c.ink3, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime d) {
    return '${d.day} ${_monthShort(d.month)} ${d.year}';
  }
}

// ─── INFO CARD ────────────────────────────────────────────────────────

class _InfoCard extends StatelessWidget {
  final UgamColorSet c;
  final List<(String, String)> rows;
  const _InfoCard({required this.c, required this.rows});

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

class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: UgamText.micro.copyWith(color: c.ink3));
  }
}

// ─── STICKY CTA ───────────────────────────────────────────────────────

class _StickyBookCta extends StatelessWidget {
  final Tour tour;
  const _StickyBookCta({required this.tour});

  @override
  Widget build(BuildContext context) {
    final capacity = tour.totalBusSeats;
    final seatsLeft = capacity - tour.totalSeatsAssigned;
    final full = capacity > 0 && seatsLeft <= 0;
    final locked =
        tour.status == TourStatus.locked || tour.status == TourStatus.completed;

    final String label;
    final IconData icon;
    final VoidCallback? onTap;

    if (locked) {
      label = tr('customer_tour_detail.cta_bookings_closed');
      icon = Icons.lock_outline_rounded;
      onTap = null;
    } else if (full) {
      label = tr('customer_tour_detail.cta_join_waitlist');
      icon = Icons.hourglass_top_rounded;
      onTap = () => Get.to(
        () => CustomerBookingRequestScreen(tour: tour),
        transition: Transition.cupertino,
      );
    } else {
      label = tr('customer_tour_detail.cta_request_to_book');
      icon = Icons.send_rounded;
      onTap = () => Get.to(
        () => CustomerBookingRequestScreen(tour: tour),
        transition: Transition.cupertino,
      );
    }

    return UgamStickyCTA(
      child: UgamCTA(label: label, leadingIcon: icon, onPressed: onTap),
    );
  }
}
