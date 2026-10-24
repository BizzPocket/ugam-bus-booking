import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../config/ui_flags.dart';
import '../../controllers/money_controller.dart';
import '../../controllers/tour_controller.dart';
import '../../design/ugam.dart';
import '../../models/tour.dart';
import '../../utils/formatters.dart';
import '../../utils/tour_detail_cockpit.dart';

/// Hero identity chip — the per-seat PRICE only (never a misleading ₹0).
///
/// It used to fall back to "seats left" / "x/y filled", which put the seat
/// fact in the header a third and fourth time (badge, meta line, vitals, next
/// step). Seats now live in the vitals grid + next-step card only; a tour with
/// no flat price (banded / not set) shows no badge at all.
class TourHeroChipBadge extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const TourHeroChipBadge({super.key, required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    if (tour.pricePerSeat <= 0) return const SizedBox.shrink();
    final primary = Formatters.formatMoneyInr(tour.pricePerSeat);
    final secondary = tr('tour_detail.per_seat');
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.accentFill,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            primary,
            style: UgamText.tabular(UgamText.titleM.copyWith(color: c.accent)),
          ),
          Text(
            secondary,
            style: UgamText.caption.copyWith(color: c.accent, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

/// Overview vitals 2×2 grid.
class TourOverviewVitals extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final ValueChanged<int>? onSwitchTab;

  const TourOverviewVitals({
    super.key,
    required this.tour,
    required this.c,
    this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    final pending = tour.pendingSeatsToAssign;
    final seatedOpen = tour.passengers.where(passengerNeedsSeat).length;
    final seated = tour.passengerCount - seatedOpen;
    // THE seat meter ([SeatMeter]) — the same "x / n" as the dashboard hero,
    // Requests banner and manage buses.
    final meter = Get.find<TourController>().seatMeterFor(tour);
    final free = meter.free;
    // Each vital opens the tab that owns its number, when the host can switch.
    VoidCallback? goTab(int i) =>
        onSwitchTab == null ? null : () => onSwitchTab!(i);

    Widget moneyVital() {
      String moneyDueLabel = '—';
      String moneySub = '';
      // The money controller holds ONE tour's rows at a time (often the
      // dashboard hero's). Only read its summary when that tour is THIS one —
      // otherwise another trip's money would show here; '—' is the honest
      // "not loaded" state (same guard as the dashboard trip hero).
      if (Get.isRegistered<MoneyController>()) {
        final money = Get.find<MoneyController>();
        if (money.loadedTourId == tour.id) {
          final summary = money.tourSummary();
          moneyDueLabel = Formatters.formatMoneyInr(summary.totalToCollect);
          moneySub = tr('tour_detail.vitals_collected', namedArgs: {
            'amount': Formatters.formatMoneyInr(summary.totalCollected),
          });
        }
      }
      return _VitalCard(
        c: c,
        label: tr('tour_detail.vitals_money_due'),
        value: moneyDueLabel,
        accent: false,
        sub: moneySub.isEmpty ? null : moneySub,
        onTap: goTab(3),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(tr('tour_detail.vitals_section'), c),
        const SizedBox(height: UgamSpacing.sm),
        Row(
          children: [
            Expanded(
              child: _VitalCard(
                c: c,
                label: tr('tour_detail.vitals_seats_left'),
                value: '$pending',
                accent: pending > 0,
                sub: null,
                onTap: goTab(1),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              // Reactive on the money controller's own state: a collection,
              // expense or ledger reload repaints this card by itself instead
              // of waiting for some unrelated tour change to rebuild the tab.
              // `isLoading`/`loadedOnce` are read explicitly because the ledger
              // rollups (not Rx) land inside a load, which ends by flipping
              // `isLoading` — that is the signal a ledger-only change emits.
              child: Get.isRegistered<MoneyController>()
                  ? Obx(() {
                      final money = Get.find<MoneyController>();
                      money.isLoading.value;
                      money.loadedOnce.value;
                      return moneyVital();
                    })
                  : moneyVital(),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.sm),
        Row(
          children: [
            Expanded(
              child: _VitalCard(
                c: c,
                label: tr('tour_detail.vitals_requests'),
                value: '${tour.passengerCount}',
                accent: false,
                sub: tour.passengerCount == 0
                    ? null
                    : tr('tour_detail.vitals_seated_open', namedArgs: {
                        'seated': '$seated',
                        'open': '$seatedOpen',
                      }),
                onTap: goTab(1),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _VitalCard(
                c: c,
                label: tr('tour_detail.vitals_bus_fill'),
                value: meter.capacity == 0
                    ? '—'
                    : '${meter.occupied}/${meter.capacity}',
                accent: false,
                sub: tour.buses.isEmpty
                    ? null
                    : tr('tour_detail.vitals_buses_free', namedArgs: {
                        'buses': '${tour.buses.length}',
                        'free': '$free',
                      }),
                onTap: goTab(2),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionLabel(this.label, this.c);

  @override
  Widget build(BuildContext context) {
    return Text(label, style: UgamText.micro.copyWith(color: c.ink3));
  }
}

class _VitalCard extends StatelessWidget {
  final UgamColorSet c;
  final String label;
  final String value;
  final String? sub;
  final bool accent;
  final VoidCallback? onTap;

  const _VitalCard({
    required this.c,
    required this.label,
    required this.value,
    required this.accent,
    this.sub,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      onTap: onTap,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: UgamText.caption.copyWith(color: c.ink2)),
          const SizedBox(height: 4),
          Text(
            value,
            style: UgamText.tabular(
              UgamText.titleM.copyWith(color: accent ? c.accent : c.ink),
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(sub!, style: UgamText.micro.copyWith(color: c.ink3)),
          ],
        ],
      ),
    );
  }
}

/// Needs-attention blocker rows.
///
/// Hidden while [UiFlags.showAttentionSections] is off — the tour Overview tab
/// already leads with the next-action card, and this block re-listed the same
/// blockers underneath it.
class TourNeedsAttention extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;
  final VoidCallback? onOpenManageBuses;

  const TourNeedsAttention({
    super.key,
    required this.tour,
    required this.c,
    required this.onSwitchTab,
    this.onOpenManageBuses,
  });

  @override
  Widget build(BuildContext context) {
    if (!UiFlags.showAttentionSections) return const SizedBox.shrink();
    final items = buildNeedsAttention(tour);
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(tr('tour_detail.needs_attention_section'), c),
        const SizedBox(height: UgamSpacing.sm),
        for (final item in items) ...[
          UgamCard.plain(
            onTap: () {
              if (item.kind == NeedsAttentionKind.unseated) {
                onSwitchTab(1);
              } else {
                onOpenManageBuses?.call();
                onSwitchTab(2);
              }
            },
            padding: const EdgeInsets.all(UgamSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.kind == NeedsAttentionKind.unseated
                            ? tr('tour_detail.needs_unseated_title',
                                namedArgs: {'n': item.primary})
                            : tr('tour_detail.needs_no_driver_title',
                                namedArgs: {'n': item.primary}),
                        style: UgamText.bodyStrong.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(item.secondary,
                          style: UgamText.caption.copyWith(color: c.ink2)),
                    ],
                  ),
                ),
                Text(
                  item.kind == NeedsAttentionKind.unseated
                      ? tr('tour_detail.needs_fix')
                      : tr('tour_detail.needs_set_driver'),
                  style: UgamText.caption.copyWith(
                    color: item.kind == NeedsAttentionKind.unseated
                        ? c.accent
                        : c.danger,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.sm),
        ],
      ],
    );
  }
}
