import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/payment_status.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../routes/app_routes.dart';
import '../services/whatsapp_service.dart';
import '../utils/app_snackbar.dart';
import 'add_bus_screen.dart';
import 'edit_tour_screen.dart';
import 'main_shell.dart';
import 'manage_buses_screen.dart';
import 'tour_seat_assignment_screen.dart';

/// Admin's single-tour workspace.
///
/// Layout:
///   [Hero (320px) — bus backdrop, floating back / status / edit chrome,
///    overlay summary card pulled up to overlap]
///   [Tab pills: Overview · Passengers · Buses · Activity]
///   [Body — switches per tab]
///   [Sticky bottom action — contextual per tab]
///
/// Business logic is unchanged from the previous incarnation:
/// `TourController.getTour`, `ManageBusesScreen`, `TourSeatAssignmentScreen`,
/// `EditTourScreen`, `AddBusScreen` are all reused as before.
class TourDetailScreen extends StatefulWidget {
  final String tourId;
  const TourDetailScreen({super.key, required this.tourId});

  @override
  State<TourDetailScreen> createState() => _TourDetailScreenState();
}

class _TourDetailScreenState extends State<TourDetailScreen> {
  int _tabIndex = 0;
  int _passengerFilter = 0; // 0 all, 1 new, 2 waitlist, 3 assigned

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);

    return Obx(() {
      final tour = tourCtrl.getTour(widget.tourId);
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

      return Scaffold(
        backgroundColor: c.bg,
        extendBody: true,
        body: RefreshIndicator(
          color: c.accent,
          onRefresh: tourCtrl.refreshTours,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(
                child: _HeroSection(
                  tour: tour,
                  onBack: () => Get.back(),
                  onEdit: () => Get.to(
                    () => EditTourScreen(tourId: widget.tourId),
                    transition: Transition.cupertino,
                  ),
                  // TODO(seat-ui): entry point into SLICE 1 — the Tour
                  // Overview / "Fill bus" auto-assignment cockpit.
                  onOverview: () => Get.toNamed(
                    AppRoutes.tourOverview,
                    arguments: {'tourId': widget.tourId},
                  ),
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
                    counts: [
                      null,
                      tour.passengerCount == 0 ? null : tour.passengerCount,
                      tour.buses.isEmpty ? null : tour.buses.length,
                      null,
                    ],
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
                sliver: _buildTabBody(tour, c),
              ),
            ],
          ),
        ),
        bottomNavigationBar: _StickyAction(
          tour: tour,
          tab: _tabIndex,
          c: c,
          onSwitchTab: (i) => setState(() => _tabIndex = i),
        ),
      );
    });
  }

  Widget _buildTabBody(Tour tour, UgamColorSet c) {
    switch (_tabIndex) {
      case 1:
        return _PassengersTab(
          tour: tour,
          c: c,
          filter: _passengerFilter,
          onFilter: (i) => setState(() => _passengerFilter = i),
        );
      case 2:
        return _BusesTab(tour: tour, c: c);
      case 3:
        return _ActivityTab(tour: tour, c: c);
      case 0:
      default:
        return _OverviewTab(tour: tour, c: c);
    }
  }
}

// ─── HERO ─────────────────────────────────────────────────────────────

class _HeroSection extends StatelessWidget {
  final Tour tour;
  final VoidCallback onBack;
  final VoidCallback onEdit;

  /// Opens the SLICE 1 Tour Overview / "Fill bus" cockpit.
  final VoidCallback onOverview;

  const _HeroSection({
    required this.tour,
    required this.onBack,
    required this.onEdit,
    required this.onOverview,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final topInset = MediaQuery.of(context).padding.top;
    final statusTone = _toneFor(tour.status);
    return SizedBox(
      height: 320,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: UgamBusBackdrop(seed: tour.id)),
          // Top chrome row.
          Positioned(
            left: UgamSpacing.gutter,
            right: UgamSpacing.gutter,
            top: topInset + UgamSpacing.sm,
            child: Row(
              children: [
                _ChromeCircle(
                  icon: Icons.arrow_back_rounded,
                  onTap: onBack,
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _toneColor(statusTone, c),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        tour.status.displayName.toUpperCase(),
                        style: UgamText.micro
                            .copyWith(color: Colors.white, fontSize: 10),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                // TODO(seat-ui): entry point to the Tour Overview screen
                // (auto seat-fill cockpit). Kept next to Edit in the chrome.
                _ChromeCircle(
                  icon: Icons.auto_awesome_rounded,
                  onTap: onOverview,
                ),
                const SizedBox(width: UgamSpacing.sm),
                _ChromeCircle(
                  icon: Icons.edit_rounded,
                  onTap: onEdit,
                ),
              ],
            ),
          ),
          // Overlay card pulled past the hero bottom so it overlaps.
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
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          tour.title,
                          style:
                              UgamText.titleM.copyWith(color: c.ink, fontSize: 18),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
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
                            const SizedBox(width: UgamSpacing.sm),
                            Text(
                              '·',
                              style: UgamText.caption
                                  .copyWith(color: c.ink3, fontSize: 11),
                            ),
                            const SizedBox(width: UgamSpacing.sm),
                            Text(
                              _durationLabel(tour),
                              style: UgamText.tabular(
                                UgamText.caption
                                    .copyWith(color: c.ink2, fontSize: 11),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        UgamStatusDot(
                          label: tour.status.description,
                          tone: statusTone,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UgamSpacing.md,
                      vertical: UgamSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: c.accentFill,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
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
                                .copyWith(color: c.accent, fontSize: 10)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _durationLabel(Tour t) {
    final r = t.returnDate;
    if (r == null) return DateFormat('MMM d').format(t.departureDate);
    final days = r.difference(t.departureDate).inDays + 1;
    return '$days day${days == 1 ? "" : "s"}';
  }
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
  final List<int?> counts;
  final ValueChanged<int> onChanged;

  const _TabBar({
    required this.index,
    required this.counts,
    required this.onChanged,
  });

  static const _labels = ['Overview', 'Passengers', 'Buses', 'Activity'];

  @override
  Widget build(BuildContext context) {
    return UgamTabPills(
      currentIndex: index,
      onChanged: onChanged,
      items: List.generate(_labels.length, (i) {
        return UgamTabItem(label: _labels[i], count: counts[i]);
      }),
    );
  }
}

// ─── OVERVIEW TAB ─────────────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _OverviewTab({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final action = _nextActionFor(tour);
    final paid = tour.passengers
        .where((p) => p.paymentStatus == PaymentStatus.paid)
        .length;
    final pending = tour.passengers
        .where((p) => p.paymentStatus == PaymentStatus.notPaid)
        .length;
    final revenue = paid * tour.pricePerSeat;

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _NextActionCard(tour: tour, action: action, c: c),
        const SizedBox(height: UgamSpacing.lg),
        _SectionEyebrow(label: 'AT A GLANCE', c: c),
        const SizedBox(height: UgamSpacing.md),
        Row(
          children: [
            Expanded(
              child: UgamStatTile(
                icon: Icons.check_circle_rounded,
                value: '$paid',
                label: 'Booked',
                variant: UgamStatVariant.good,
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: UgamStatTile(
                icon: Icons.access_time_rounded,
                value: '$pending',
                label: 'Pending pay',
                variant: UgamStatVariant.warm,
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.md),
        Row(
          children: [
            Expanded(
              child: UgamStatTile(
                icon: Icons.event_seat_rounded,
                value: tour.totalBusSeats > 0
                    ? '${tour.totalSeatsAssigned}'
                    : '—',
                ofTotal: tour.totalBusSeats > 0
                    ? '/${tour.totalBusSeats}'
                    : null,
                label: 'Assigned',
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: UgamStatTile(
                icon: Icons.currency_rupee_rounded,
                value: _formatMoney(revenue),
                label: 'Revenue',
                variant: UgamStatVariant.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.xl),
        _BroadcastCard(tour: tour, c: c),
      ]),
    );
  }

  static String _formatMoney(double v) {
    if (v >= 100000) {
      final l = v / 100000;
      return l == l.roundToDouble()
          ? '₹${l.toInt()}L'
          : '₹${l.toStringAsFixed(1)}L';
    }
    if (v >= 1000) {
      final k = v / 1000;
      return k == k.roundToDouble()
          ? '₹${k.toInt()}K'
          : '₹${k.toStringAsFixed(1)}K';
    }
    return '₹${v.toInt()}';
  }
}

class _NextActionCard extends StatelessWidget {
  final Tour tour;
  final _NextAction action;
  final UgamColorSet c;

  const _NextActionCard({
    required this.tour,
    required this.action,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final tone = action.tone;
    final fill = _toneFill(tone, c);
    final fg = _toneColor(tone, c);
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: fg.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(action.icon, size: 20, color: fg),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'NEXT ACTION',
                      style: UgamText.micro.copyWith(color: fg),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      action.title,
                      style:
                          UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (action.subtitle != null) ...[
            const SizedBox(height: UgamSpacing.sm + 2),
            Text(
              action.subtitle!,
              style: UgamText.caption.copyWith(color: c.ink2, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _BroadcastCard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _BroadcastCard({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        HapticFeedback.lightImpact();
        await WhatsAppService().copyAnnouncementToClipboard(tour: tour);
        AppSnackBar.success('Broadcast message copied');
      },
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.lg - 2),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: c.goodFill,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.campaign_rounded, size: 22, color: c.good),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Broadcast this tour',
                    style: UgamText.titleS.copyWith(color: c.ink, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Copy a ready-to-paste WhatsApp message',
                    style:
                        UgamText.caption.copyWith(color: c.ink2, fontSize: 11.5),
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
                color: c.good,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.copy_rounded, size: 17, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── PASSENGERS TAB ───────────────────────────────────────────────────

class _PassengersTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final int filter;
  final ValueChanged<int> onFilter;

  const _PassengersTab({
    required this.tour,
    required this.c,
    required this.filter,
    required this.onFilter,
  });

  @override
  Widget build(BuildContext context) {
    final all = tour.passengers;
    final visible = _filtered(all);

    if (all.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.huge),
          child: UgamEmpty(
            icon: Icons.people_outline_rounded,
            title: 'No passengers yet',
            body: 'Share this tour on WhatsApp to start collecting requests.',
            cta: UgamCTA(
              label: 'Copy broadcast message',
              leadingIcon: Icons.copy_rounded,
              onPressed: () async {
                HapticFeedback.lightImpact();
                await WhatsAppService()
                    .copyAnnouncementToClipboard(tour: tour);
                AppSnackBar.success('Broadcast message copied');
              },
            ),
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        UgamTabPills(
          currentIndex: filter,
          onChanged: onFilter,
          items: [
            UgamTabItem(label: 'All', count: all.length),
            UgamTabItem(
              label: 'New',
              count: all.where((p) => p.assignedSeats.isEmpty && !p.isWaitlisted).length,
            ),
            UgamTabItem(
              label: 'Waitlist',
              count: all.where((p) => p.isWaitlisted).length,
            ),
            UgamTabItem(
              label: 'Assigned',
              count: all.where((p) => p.totalSeatsAssigned > 0).length,
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.lg),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: UgamSpacing.huge),
            child: UgamEmpty(
              icon: Icons.filter_alt_off_rounded,
              title: 'No matches',
              body: 'Nothing in this filter — try "All".',
            ),
          )
        else
          for (var i = 0; i < visible.length; i++) ...[
            _PassengerRow(passenger: visible[i], c: c),
            if (i != visible.length - 1)
              const SizedBox(height: UgamSpacing.sm + 2),
          ],
      ]),
    );
  }

  List<Passenger> _filtered(List<Passenger> all) {
    switch (filter) {
      case 1:
        return all
            .where((p) => p.assignedSeats.isEmpty && !p.isWaitlisted)
            .toList();
      case 2:
        return all.where((p) => p.isWaitlisted).toList();
      case 3:
        return all.where((p) => p.totalSeatsAssigned > 0).toList();
      case 0:
      default:
        return List.of(all);
    }
  }
}

class _PassengerRow extends StatelessWidget {
  final Passenger passenger;
  final UgamColorSet c;

  const _PassengerRow({required this.passenger, required this.c});

  @override
  Widget build(BuildContext context) {
    final tone = _passengerTone(passenger);
    final dotColor = _toneColor(tone, c);
    return Container(
      padding: const EdgeInsets.all(UgamSpacing.md - 2),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: c.card,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _initials(passenger.name),
              style:
                  UgamText.bodyStrong.copyWith(color: c.ink, fontSize: 12),
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
                        passenger.name,
                        style: UgamText.bodyStrong
                            .copyWith(color: c.ink, fontSize: 13),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      _ago(passenger.createdAt),
                      style: UgamText.tabular(
                        UgamText.caption
                            .copyWith(color: c.ink3, fontSize: 10.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        passenger.requestSummary,
                        style: UgamText.caption
                            .copyWith(color: c.ink2, fontSize: 11.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      passenger.progressLabel,
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(
                          color: dotColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
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

  UgamStatusTone _passengerTone(Passenger p) {
    if (p.isFullyAssigned) return UgamStatusTone.good;
    if (p.isPartiallyAssigned) return UgamStatusTone.accent;
    if (p.isWaitlisted) return UgamStatusTone.warm;
    return UgamStatusTone.neutral;
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays > 0) return '${d.inDays}d';
    if (d.inHours > 0) return '${d.inHours}h';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return 'now';
  }
}

// ─── BUSES TAB ────────────────────────────────────────────────────────

class _BusesTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _BusesTab({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    if (tour.buses.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.huge),
          child: UgamEmpty(
            icon: Icons.directions_bus_outlined,
            title: 'No buses yet',
            body: 'Add a bus once the owner gives you the details.',
            cta: UgamCTA(
              label: 'Add bus',
              leadingIcon: Icons.add_rounded,
              onPressed: () => Get.to(
                () => AddBusScreen(tourId: tour.id),
                transition: Transition.cupertino,
              ),
            ),
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        for (var i = 0; i < tour.buses.length; i++) ...[
          _BusListItem(bus: tour.buses[i], c: c),
          if (i != tour.buses.length - 1)
            const SizedBox(height: UgamSpacing.md),
        ],
        const SizedBox(height: UgamSpacing.md),
        _AddBusTile(tourId: tour.id, c: c),
      ]),
    );
  }
}

class _BusListItem extends StatelessWidget {
  final Bus bus;
  final UgamColorSet c;
  const _BusListItem({required this.bus, required this.c});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        Get.to(
          () => ManageBusesScreen(tourId: bus.tourId ?? ''),
          transition: Transition.cupertino,
        );
      },
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
                    style:
                        UgamText.titleS.copyWith(color: c.ink, fontSize: 15),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    bus.driverName.isNotEmpty
                        ? bus.driverName
                        : 'Driver not set',
                    style: UgamText.caption.copyWith(
                      color: bus.driverName.isNotEmpty ? c.ink2 : c.ink3,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  Row(
                    children: [
                      if (bus.isAC) ...[
                        const UgamReqChip(label: 'AC'),
                        const SizedBox(width: 5),
                      ],
                      UgamReqChip(
                        label: '${bus.totalSeats} SEATS',
                        variant: UgamChipVariant.neutral,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.accentFill,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.arrow_forward_rounded,
                  size: 16, color: c.accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddBusTile extends StatelessWidget {
  final String tourId;
  final UgamColorSet c;
  const _AddBusTile({required this.tourId, required this.c});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.lightImpact();
        Get.to(
          () => AddBusScreen(tourId: tourId),
          transition: Transition.cupertino,
        );
      },
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.lg - 2),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: c.accent.withValues(alpha: 0.3),
            style: BorderStyle.solid,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.add_rounded, size: 22, color: c.accent),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                'Add another bus',
                style: UgamText.titleS.copyWith(color: c.ink, fontSize: 14),
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.ink2),
          ],
        ),
      ),
    );
  }
}

// ─── ACTIVITY TAB ─────────────────────────────────────────────────────

class _ActivityTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _ActivityTab({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final events = _buildEvents(tour);
    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _SectionEyebrow(label: 'TIMELINE', c: c),
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

  List<_TimelineEvent> _buildEvents(Tour t) {
    final events = <_TimelineEvent>[];

    events.add(_TimelineEvent(
      icon: Icons.add_circle_rounded,
      title: 'Tour created',
      time: t.createdAt,
      tone: UgamStatusTone.neutral,
    ));

    if (t.passengers.isNotEmpty) {
      final earliest = t.passengers
          .map((p) => p.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final first = t.passengers.firstWhere(
        (p) => p.createdAt == earliest,
        orElse: () => t.passengers.first,
      );
      events.add(_TimelineEvent(
        icon: Icons.person_add_alt_1_rounded,
        title: 'First request · ${first.name}',
        time: earliest,
        tone: UgamStatusTone.accent,
      ));

      if (t.passengers.length > 1) {
        final latestReq = t.passengers
            .map((p) => p.createdAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);
        if (latestReq != earliest) {
          events.add(_TimelineEvent(
            icon: Icons.groups_rounded,
            title: '${t.passengers.length} requests total',
            time: latestReq,
            tone: UgamStatusTone.accent,
          ));
        }
      }
    }

    if (t.buses.isNotEmpty) {
      final earliestBus = t.buses
          .map((b) => b.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      events.add(_TimelineEvent(
        icon: Icons.directions_bus_rounded,
        title: t.buses.length == 1
            ? 'Bus added'
            : '${t.buses.length} buses added',
        time: earliestBus,
        tone: UgamStatusTone.accent,
      ));
    }

    if (t.totalSeatsAssigned > 0) {
      events.add(_TimelineEvent(
        icon: Icons.event_seat_rounded,
        title:
            '${t.totalSeatsAssigned} seat${t.totalSeatsAssigned == 1 ? "" : "s"} assigned',
        time: t.updatedAt,
        tone: UgamStatusTone.accent,
      ));
    }

    if (t.allSeatsAssigned) {
      events.add(_TimelineEvent(
        icon: Icons.check_circle_rounded,
        title: 'All seats assigned',
        time: t.updatedAt,
        tone: UgamStatusTone.good,
      ));
    }

    if (t.status == TourStatus.locked || t.status == TourStatus.completed) {
      events.add(_TimelineEvent(
        icon: Icons.lock_rounded,
        title: 'Tour locked',
        time: t.updatedAt,
        tone: UgamStatusTone.good,
      ));
    }

    if (t.status == TourStatus.completed) {
      events.add(_TimelineEvent(
        icon: Icons.flag_rounded,
        title: 'Trip completed',
        time: t.updatedAt,
        tone: UgamStatusTone.neutral,
      ));
    }

    events.sort((a, b) => a.time.compareTo(b.time));
    return events;
  }
}

class _TimelineEvent {
  final IconData icon;
  final String title;
  final DateTime time;
  final UgamStatusTone tone;
  const _TimelineEvent({
    required this.icon,
    required this.title,
    required this.time,
    required this.tone,
  });
}

class _TimelineRow extends StatelessWidget {
  final _TimelineEvent event;
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
    final tone = _toneColor(event.tone, c);
    final fill = _toneFill(event.tone, c);
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
                  Expanded(
                    child: Container(
                      width: 2,
                      color: c.border,
                    ),
                  ),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                    border: Border.all(color: tone, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Icon(event.icon, size: 13, color: tone),
                ),
                if (isLast)
                  const SizedBox(height: 8)
                else
                  Expanded(
                    child: Container(
                      width: 2,
                      color: c.border,
                    ),
                  ),
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
                      style: UgamText.bodyStrong
                          .copyWith(color: c.ink, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _agoLine(event.time),
                      style: UgamText.tabular(
                        UgamText.caption
                            .copyWith(color: c.ink3, fontSize: 11),
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

  String _agoLine(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays > 6) return DateFormat('MMM d · h:mm a').format(t);
    if (d.inDays > 0) return '${d.inDays} day${d.inDays == 1 ? "" : "s"} ago';
    if (d.inHours > 0) return '${d.inHours}h ago';
    if (d.inMinutes > 0) return '${d.inMinutes}m ago';
    return 'just now';
  }
}

// ─── STICKY ACTION BAR ────────────────────────────────────────────────

class _StickyAction extends StatelessWidget {
  final Tour tour;
  final int tab;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;

  const _StickyAction({
    required this.tour,
    required this.tab,
    required this.c,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    if (tab == 3) {
      // Activity tab → no sticky action (back button is enough).
      return const SizedBox.shrink();
    }

    final cta = _buildCta(context);
    if (cta == null) return const SizedBox.shrink();

    return UgamStickyCTA(child: cta);
  }

  Widget? _buildCta(BuildContext context) {
    switch (tab) {
      case 1:
        return UgamCTA(
          label: 'Open seat assignment',
          leadingIcon: Icons.grid_view_rounded,
          trailingValue: tour.totalBusSeats > 0
              ? '${tour.totalSeatsAssigned}/${tour.totalBusSeats}'
              : null,
          onPressed: tour.buses.isEmpty
              ? null
              : () => Get.to(
                    () => TourSeatAssignmentScreen(tourId: tour.id),
                    transition: Transition.cupertino,
                  ),
        );
      case 2:
        return UgamCTA(
          label: tour.buses.isEmpty ? 'Add bus' : 'Add another bus',
          leadingIcon: Icons.add_rounded,
          onPressed: () => Get.to(
            () => AddBusScreen(tourId: tour.id),
            transition: Transition.cupertino,
          ),
        );
      case 0:
      default:
        final action = _nextActionFor(tour);
        return UgamCTA(
          label: action.ctaLabel,
          leadingIcon: action.icon,
          onPressed: () => _runAction(action, tour, onSwitchTab),
        );
    }
  }
}

void _runAction(
  _NextAction action,
  Tour tour,
  ValueChanged<int> onSwitchTab,
) {
  switch (action.kind) {
    case _NextActionKind.addBus:
      Get.to(
        () => ManageBusesScreen(tourId: tour.id),
        transition: Transition.cupertino,
      );
      break;
    case _NextActionKind.assignSeats:
      Get.to(
        () => TourSeatAssignmentScreen(tourId: tour.id),
        transition: Transition.cupertino,
      );
      break;
    case _NextActionKind.pickHandler:
      // Handler picking lives on the seat-assignment / notify flows;
      // route the agent to seat assignment where the handler chip is set.
      Get.to(
        () => TourSeatAssignmentScreen(tourId: tour.id),
        transition: Transition.cupertino,
      );
      break;
    case _NextActionKind.lockAndNotify:
      Get.find<ShellController>().switchTab(4);
      Get.until((r) => r.isFirst);
      break;
    case _NextActionKind.allSet:
      onSwitchTab(3); // jump to activity
      break;
  }
}

// ─── HELPERS / SHARED MODELS ──────────────────────────────────────────

class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: UgamText.micro.copyWith(color: c.ink3));
  }
}

enum _NextActionKind {
  addBus,
  assignSeats,
  pickHandler,
  lockAndNotify,
  allSet,
}

class _NextAction {
  final _NextActionKind kind;
  final String title;
  final String? subtitle;
  final String ctaLabel;
  final IconData icon;
  final UgamStatusTone tone;
  const _NextAction({
    required this.kind,
    required this.title,
    this.subtitle,
    required this.ctaLabel,
    required this.icon,
    required this.tone,
  });
}

_NextAction _nextActionFor(Tour tour) {
  if (tour.passengers.isNotEmpty && tour.buses.isEmpty) {
    return _NextAction(
      kind: _NextActionKind.addBus,
      title: 'Add a bus to start assigning seats',
      subtitle:
          '${tour.passengers.length} request${tour.passengers.length == 1 ? "" : "s"} waiting on a bus.',
      ctaLabel: 'Add bus',
      icon: Icons.directions_bus_rounded,
      tone: UgamStatusTone.warm,
    );
  }
  if (tour.buses.isNotEmpty &&
      tour.totalSeatsAssigned < tour.totalSeatsRequested) {
    final remaining = tour.totalSeatsRequested - tour.totalSeatsAssigned;
    return _NextAction(
      kind: _NextActionKind.assignSeats,
      title: 'Assign $remaining more seat${remaining == 1 ? "" : "s"}',
      subtitle:
          '${tour.totalSeatsAssigned} of ${tour.totalSeatsRequested} requested seats placed so far.',
      ctaLabel: 'Open seat assignment',
      icon: Icons.grid_view_rounded,
      tone: UgamStatusTone.accent,
    );
  }
  if (tour.allSeatsAssigned && tour.handlerId == null) {
    return _NextAction(
      kind: _NextActionKind.pickHandler,
      title: 'Pick a handler before locking',
      subtitle: 'Choose one passenger to handle on-trip coordination.',
      ctaLabel: 'Pick handler',
      icon: Icons.person_pin_rounded,
      tone: UgamStatusTone.good,
    );
  }
  if (tour.allSeatsAssigned &&
      tour.handlerId != null &&
      tour.status != TourStatus.locked &&
      tour.status != TourStatus.completed) {
    return _NextAction(
      kind: _NextActionKind.lockAndNotify,
      title: 'Ready to lock and notify',
      subtitle: 'All seats placed and a handler is set.',
      ctaLabel: 'Go to Notify',
      icon: Icons.lock_rounded,
      tone: UgamStatusTone.good,
    );
  }
  return _NextAction(
    kind: _NextActionKind.allSet,
    title: tour.status == TourStatus.completed
        ? 'Trip completed'
        : 'All set for departure',
    subtitle: tour.status == TourStatus.completed
        ? 'This tour is in the archive.'
        : 'Nothing blocking — sit tight until departure.',
    ctaLabel: 'View timeline',
    icon: Icons.check_circle_rounded,
    tone: UgamStatusTone.good,
  );
}

UgamStatusTone _toneFor(TourStatus s) => switch (s) {
      TourStatus.planning => UgamStatusTone.accent,
      TourStatus.collecting => UgamStatusTone.warm,
      TourStatus.busBooked => UgamStatusTone.accent,
      TourStatus.assigning => UgamStatusTone.accent,
      TourStatus.locked => UgamStatusTone.good,
      TourStatus.completed => UgamStatusTone.neutral,
    };

Color _toneColor(UgamStatusTone t, UgamColorSet c) => switch (t) {
      UgamStatusTone.accent => c.accent,
      UgamStatusTone.good => c.good,
      UgamStatusTone.warm => c.warm,
      UgamStatusTone.neutral => c.ink2,
    };

Color _toneFill(UgamStatusTone t, UgamColorSet c) => switch (t) {
      UgamStatusTone.accent => c.accentFill,
      UgamStatusTone.good => c.goodFill,
      UgamStatusTone.warm => c.warmFill,
      UgamStatusTone.neutral => c.cardElev,
    };
