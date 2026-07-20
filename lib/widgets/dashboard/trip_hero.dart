import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/money_controller.dart';
import '../../controllers/tour_controller.dart';
import '../../design/components/ugam_capacity_meter.dart';
import '../../design/ugam.dart';
import '../../models/money_summary.dart';
import '../../models/tour.dart';
import '../../models/tour_status.dart';
import '../../screens/create_tour_screen.dart';
import '../../screens/tour_detail_screen.dart';
import '../../screens/trip_pnl_screen.dart';
import '../../utils/formatters.dart';
import '../../utils/passenger_display.dart';
import '../../utils/tour_capacity.dart';

/// Dashboard hero — "both, stacked". A tour picker, then one card that reads
/// top-to-bottom: route · phase / the single most-urgent action (the only
/// accent-eligible line) / a money strip / a pax · seats-left · open footer.
/// No giant vanity figure. Loads the selected tour's money so the strip and
/// the settlement attention branch reflect live numbers.
class DashboardTripHero extends StatefulWidget {
  final UgamColorSet c;
  const DashboardTripHero({super.key, required this.c});

  @override
  State<DashboardTripHero> createState() => _DashboardTripHeroState();
}

class _DashboardTripHeroState extends State<DashboardTripHero> {
  String? _selectedId;
  String? _moneyLoadedFor;

  List<Tour> _upcoming(List<Tour> tours) {
    // Active (non-completed) tours, soonest departure first. We don't drop
    // already-departed tours — an agent still manages a trip up to and around
    // its run date, so the "nearest" trip stays relevant after departure.
    return tours.where((t) => t.status != TourStatus.completed).toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));
  }

  /// Phase label: "Phase {step}/{total}" off the tour's lifecycle status.
  String _phaseLabel(Tour tour) => tr('dashboard.phase_step', namedArgs: {
        'step': '${tour.status.stepIndex + 1}',
        'total': '${TourStatus.totalSteps}',
      });

  /// Make sure the selected tour's money is loaded so the strip + the money
  /// settlement attention branch have live numbers. Runs post-frame to avoid
  /// mutating controller state during build.
  void _ensureMoney(String tourId) {
    if (_moneyLoadedFor == tourId) return;
    _moneyLoadedFor = tourId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Get.find<MoneyController>().loadForTour(tourId);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final tourCtrl = Get.find<TourController>();
    final money = Get.find<MoneyController>();
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
      _ensureMoney(tour.id);
      final cap = tourCtrl.capacityFor(tour);

      return Column(
        children: [
          _picker(context, c, tour, upcoming),
          const SizedBox(height: UgamSpacing.md),
          _heroCard(context, c, tour, cap, money),
        ],
      );
    });
  }

  /// The tour selector. A neutral tappable card (UgamCard) — never the solid
  /// accent. Opens a UgamSheet picker when more than one tour exists.
  Widget _picker(BuildContext context, UgamColorSet c, Tour tour,
      List<Tour> all) {
    final multi = all.length > 1;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      radius: UgamRadius.row,
      onTap: multi ? () => _openPicker(context, c, all) : null,
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
            child: Icon(Icons.directions_bus_rounded, size: 18, color: c.ink2),
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
                    '${tour.title} ${tr('dashboard.picker_phase_suffix', namedArgs: {
                          'step': '${tour.status.stepIndex + 1}',
                          'total': '${TourStatus.totalSteps}',
                        })}',
                    style: UgamText.caption.copyWith(color: c.ink3),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (multi)
            Semantics(
              label: tr('dashboard.choose_trip'),
              button: true,
              child: SizedBox(
                width: 48,
                height: 48,
                child: Icon(Icons.expand_more_rounded, color: c.ink2),
              ),
            ),
        ],
      ),
    );
  }

  /// The "both, stacked" hero card. While the agent is still filling the bus
  /// the lower panel is a seat-fill gauge; once the tour is locked AND its
  /// departure date has arrived it flips to an inline P&L breakdown. Card tap
  /// opens the tour workspace (or the full P&L screen in P&L mode).
  Widget _heroCard(BuildContext context, UgamColorSet c, Tour tour,
      TourCapacity cap, MoneyController money) {
    final dateStr = Formatters.formatDateShort(
      tour.departureDate,
      locale: context.locale.languageCode,
    );
    final blocker = _topAction(context, tour, cap);
    final isReturn = tour.isReturnPhase;
    final pnl = _isPnlMode(tour);
    final m = money.loadedTourId == tour.id ? money.tourSummary() : null;

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.xl),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => pnl
              ? TripPnlScreen(tourId: tour.id)
              : TourDetailScreen(tourId: tour.id),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line 1 — route · phase. Return-phase badges the phase warm.
          Row(
            children: [
              Expanded(
                child: Text(
                  '${tour.fromCity} → ${tour.toCity}',
                  style: UgamText.titleM.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              UgamReqChip(
                label: isReturn
                    ? '${tr('dashboard.leg_return')} · ${_phaseLabel(tour)}'
                    : _phaseLabel(tour),
                variant:
                    isReturn ? UgamChipVariant.warm : UgamChipVariant.neutral,
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(dateStr, style: UgamText.caption.copyWith(color: c.ink3)),
          const SizedBox(height: UgamSpacing.md),
          // Line 2 — the SINGLE most-urgent action. The one accent-eligible
          // element in the hero (accent ink when there's a live blocker).
          Text(
            blocker.label,
            style: UgamText.titleS.copyWith(
              color: blocker.urgent ? c.accent : c.ink2,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UgamSpacing.lg),
          Container(height: 1, color: c.border),
          const SizedBox(height: UgamSpacing.lg),
          // Lower panel: seat-fill gauge while filling, inline P&L once the
          // tour is locked and its departure date has arrived.
          if (pnl) _pnlBreakdown(c, m) else _seatGauge(c, tour, cap),
          const SizedBox(height: UgamSpacing.lg),
          // Footer — pax + open affordance.
          Row(
            children: [
              Text(
                tr('dashboard.pax',
                    namedArgs: {'count': '${tour.passengerCount}'}),
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
              const Spacer(),
              Icon(Icons.chevron_right_rounded, size: 20, color: c.ink2),
            ],
          ),
        ],
      ),
    );
  }

  /// P&L mode = the tour is locked AND its departure date has arrived (today or
  /// earlier). Before that, the agent is still filling the bus, so the hero
  /// stays operational.
  bool _isPnlMode(Tour tour) {
    if (tour.status != TourStatus.locked) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dep = DateTime(
        tour.departureDate.year, tour.departureDate.month,
        tour.departureDate.day);
    return !dep.isAfter(today);
  }

  /// Seat-fill gauge + people: the two-leg whole-seat capacity meter (Going /
  /// Return, each "placed / cap" + free), and how many passengers are
  /// waitlisted (left behind). No money here — the filling phase is about
  /// seats, not P&L.
  Widget _seatGauge(UgamColorSet c, Tour tour, TourCapacity cap) {
    if (!cap.hasBuses) {
      return Text(tr('dashboard.no_bus_added'),
          style: UgamText.caption.copyWith(color: c.ink3));
    }
    final behind = tour.passengers.where((p) => p.isWaitlisted).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UgamCapacityMeter.hero(cap),
        if (behind > 0) ...[
          const SizedBox(height: UgamSpacing.sm),
          Row(
            children: [
              Icon(Icons.person_off_rounded, size: 14, color: c.warm),
              const SizedBox(width: UgamSpacing.xs),
              Flexible(
                child: Text(
                  tr('dashboard.left_behind', namedArgs: {'n': '$behind'}),
                  style: UgamText.caption.copyWith(color: c.warm),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Inline P&L: revenue / costs (/ income) and the net profit or loss — the
  /// same `totalNetBilled` basis as the full Trip P&L screen, so they agree.
  Widget _pnlBreakdown(UgamColorSet c, TourMoneySummary? m) {
    if (m == null) {
      return Text('—', style: UgamText.caption.copyWith(color: c.ink3));
    }
    final profit = m.totalNetBilled;
    final isProfit = profit >= 0;
    final tone = isProfit ? c.good : c.danger;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _pnlLine(c, tr('trip_pnl.revenue'),
            Formatters.formatMoneyInr(m.totalRevenueBilled), c.ink),
        const SizedBox(height: UgamSpacing.sm),
        _pnlLine(c, tr('trip_pnl.costs'),
            Formatters.formatMoneyInr(m.totalExpenses), c.warm),
        if (m.totalIncome != 0) ...[
          const SizedBox(height: UgamSpacing.sm),
          _pnlLine(c, tr('bus_money.stat_income'),
              Formatters.formatMoneyInr(m.totalIncome), c.ink2),
        ],
        const SizedBox(height: UgamSpacing.md),
        Container(height: 1, color: c.border),
        const SizedBox(height: UgamSpacing.md),
        Row(
          children: [
            Expanded(
              child: Text(
                isProfit ? tr('trip_pnl.net_profit') : tr('trip_pnl.net_loss'),
                style: UgamText.micro.copyWith(color: c.ink3),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Flexible(
              child: Text(
                Formatters.formatMoneyInr(profit.abs()),
                style: UgamText.tabular(UgamText.numXl.copyWith(color: tone)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _pnlLine(UgamColorSet c, String label, String value, Color tone) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: UgamText.caption.copyWith(color: c.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Text(value,
            style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: tone))),
      ],
    );
  }

  /// The single most-urgent action label for the hero line, derived from the
  /// same priority order as [DashboardScreen]'s attention list. `urgent` marks
  /// whether it's a live blocker (accent-eligible) vs an on-track affirmation.
  _HeroAction _topAction(BuildContext context, Tour tour, TourCapacity cap) {
    final money = Get.find<MoneyController>();
    if (money.loadedTourId == tour.id) {
      final m = money.tourSummary();
      if (m.totalOutstandingHandover > 0.005) {
        final amount = Formatters.formatMoneyInr(m.totalOutstandingHandover);
        final handler = tour.handler?.displayName;
        return _HeroAction(
          handler != null && handler.isNotEmpty
              ? tr('dashboard.settle_from_handler',
                  namedArgs: {'amount': amount, 'handler': handler})
              : tr('dashboard.settle_amount', namedArgs: {'amount': amount}),
          urgent: true,
        );
      }
    }
    if (tour.passengers.isNotEmpty && tour.buses.isEmpty) {
      return _HeroAction(
        tr('dashboard.attention_no_bus',
            namedArgs: {'n': '${tour.passengers.length}'}),
        urgent: true,
      );
    }
    if (tour.buses.isNotEmpty && cap.needsDecision > 0) {
      return _HeroAction(
        tr('dashboard.attention_seating_decisions',
            namedArgs: {'n': '${cap.needsDecision}'}),
        urgent: true,
      );
    }
    if (tour.buses.isNotEmpty && tour.pendingSeatsToAssign > 0) {
      return _HeroAction(
        tr('dashboard.attention_unassigned',
            namedArgs: {'n': '${tour.pendingSeatsToAssign}'}),
        urgent: true,
      );
    }
    if (tour.allSeatsAssigned && tour.handlerId == null) {
      return _HeroAction(tr('dashboard.attention_pick_handler'), urgent: true);
    }
    if (tour.allSeatsAssigned && tour.handlerId != null) {
      return _HeroAction(tr('dashboard.attention_ready_lock'), urgent: true);
    }
    // Nothing blocking — restate the phase, neutrally.
    return _HeroAction(tour.status.displayName, urgent: false);
  }

  Widget _emptyHero(BuildContext context, UgamColorSet c) {
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.xl),
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
    UgamSheet.show<void>(
      context,
      title: tr('dashboard.choose_trip'),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final t in all) ...[
            _PickerRow(
              tour: t,
              c: c,
              onTap: () {
                setState(() => _selectedId = t.id);
                Navigator.of(ctx).pop();
              },
            ),
            const SizedBox(height: UgamSpacing.sm),
          ],
        ],
      ),
    );
  }
}

/// The hero's single-action line: its text + whether it's a live blocker.
class _HeroAction {
  final String label;
  final bool urgent;
  const _HeroAction(this.label, {required this.urgent});
}

/// One row in the tour picker sheet — route + phase + the top blocker so the
/// agent can pick by what's actually pending, not just the passenger count.
class _PickerRow extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final VoidCallback onTap;
  const _PickerRow({required this.tour, required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final phase = tr('dashboard.picker_phase_suffix', namedArgs: {
      'step': '${tour.status.stepIndex + 1}',
      'total': '${TourStatus.totalSteps}',
    });
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.md),
      radius: UgamRadius.row,
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${tour.fromCity} → ${tour.toCity}',
                    style: UgamText.titleS.copyWith(color: c.ink),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text('${tour.title} $phase',
                    style: UgamText.caption.copyWith(color: c.ink3),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          UgamReqChip(
            label: tr('dashboard.pax',
                namedArgs: {'count': '${tour.passengerCount}'}),
            variant: UgamChipVariant.neutral,
          ),
        ],
      ),
    );
  }
}
