import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/money_controller.dart';
import '../../design/ugam.dart';
import '../../models/tour.dart';
import '../../utils/formatters.dart';
import '../../utils/tour_detail_cockpit.dart';

/// Hero identity chip — seats left / price / fill (never a misleading ₹0).
class TourHeroChipBadge extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const TourHeroChipBadge({super.key, required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final chip = resolveTourHeroChip(tour);
    late final String primary;
    late final String secondary;
    switch (chip.kind) {
      case TourHeroChipKind.seatsLeft:
        primary = tr('tour_detail.chip_seats_left',
            namedArgs: {'n': '${chip.seatsLeft}'});
        secondary = tr('tour_detail.chip_seats_left_label');
      case TourHeroChipKind.pricePerSeat:
        primary = Formatters.formatMoneyInr(chip.pricePerSeat ?? 0);
        secondary = tr('tour_detail.per_seat');
      case TourHeroChipKind.seatsFilled:
        primary = tr('tour_detail.chip_filled', namedArgs: {
          'filled': '${chip.filled}',
          'total': '${chip.capacity}',
        });
        secondary = tr('tour_detail.vitals_bus_fill');
    }
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
    final free = (tour.totalBusSeats - tour.occupiedBerths).clamp(0, 1 << 30);

    String moneyDueLabel = '—';
    String moneySub = '';
    if (Get.isRegistered<MoneyController>()) {
      final summary = Get.find<MoneyController>().tourSummary();
      moneyDueLabel = Formatters.formatMoneyInr(summary.totalToCollect);
      moneySub = tr('tour_detail.vitals_collected', namedArgs: {
        'amount': Formatters.formatMoneyInr(summary.totalCollected),
      });
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
                onTap: onSwitchTab == null ? null : () => onSwitchTab!(1),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _VitalCard(
                c: c,
                label: tr('tour_detail.vitals_money_due'),
                value: moneyDueLabel,
                accent: false,
                sub: moneySub.isEmpty ? null : moneySub,
                onTap: onSwitchTab == null ? null : () => onSwitchTab!(3),
              ),
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
                onTap: onSwitchTab == null ? null : () => onSwitchTab!(1),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _VitalCard(
                c: c,
                label: tr('tour_detail.vitals_bus_fill'),
                value: tour.totalBusSeats == 0
                    ? '—'
                    : '${tour.occupiedBerths}/${tour.totalBusSeats}',
                accent: false,
                sub: tour.buses.isEmpty
                    ? null
                    : tr('tour_detail.vitals_buses_free', namedArgs: {
                        'buses': '${tour.buses.length}',
                        'free': '$free',
                      }),
                onTap: onSwitchTab == null ? null : () => onSwitchTab!(2),
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
