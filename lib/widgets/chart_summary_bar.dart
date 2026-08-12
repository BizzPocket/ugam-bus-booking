import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../models/trip_type.dart';
import '../utils/formatters.dart';

/// States, in plain words, what the chart has already done for this party.
///
/// *** WHY THE CHART NEEDS A SENTENCE ***
/// A seat map answers "which cells exist". It cannot answer the question a
/// customer actually arrives with — "are the four of us sorted, together, and
/// what does it cost?" — because that is a sentence, not a diagram. This is
/// that sentence, and it sits above the deck so it is read first.
///
/// It also carries the two facts a customer must never discover late: that the
/// party had to be SPLIT across buses, and that there was no room at all.
class ChartSummaryBar extends StatelessWidget {
  /// How many people the gate said were travelling.
  final int people;

  /// Berths currently selected, across every bus.
  final int pickedBerths;

  /// Of those, how many are lower berths — the ones elders need. The gate
  /// deliberately does not ask about this; the picker prefers them and this
  /// line is where that preference becomes visible.
  final int lowerBerths;

  final double total;

  /// Names of the buses involved. More than one means the party is split, and
  /// saying so here is the entire reason this field exists — discovering it at
  /// the boarding point is the failure being designed out.
  final List<String> busNames;

  /// Berths the picker could not place, per leg. Empty when everyone fits.
  ///
  /// This replaces a single `noRoom` flag, which could only say "nothing fits"
  /// — useless for a mixed party whose outbound leg is seated and whose return
  /// leg is not. That is a fact the customer must not discover at the counter.
  final Map<TripType, int> shortfall;

  const ChartSummaryBar({
    super.key,
    required this.people,
    required this.pickedBerths,
    required this.lowerBerths,
    required this.total,
    this.busNames = const [],
    this.shortfall = const {},
  });

  bool get _noRoom => shortfall.isNotEmpty;

  /// Ready means every bucket is seated. A party can have picked its full
  /// [people] count and still be short — four berths that are all on the way
  /// there leave the return leg empty — so the shortfall is checked first.
  bool get _ready => !_noRoom && pickedBerths >= people && pickedBerths > 0;
  bool get _split => busNames.length > 1;

  int get upperBerths =>
      (pickedBerths - lowerBerths) < 0 ? 0 : pickedBerths - lowerBerths;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final Color bg;
    final Color ink;
    final IconData icon;
    if (_noRoom) {
      bg = c.cardElev;
      ink = c.ink2;
      icon = Icons.info_outline_rounded;
    } else if (_ready) {
      bg = c.accentFill;
      ink = c.accent;
      icon = Icons.check_circle_outline_rounded;
    } else {
      bg = c.cardElev;
      ink = c.ink2;
      icon = Icons.event_seat_outlined;
    }

    return AnimatedContainer(
      duration: UgamMotion.tab,
      curve: UgamMotion.easeOut,
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(UgamRadius.card),
        border: Border.all(
          color: _ready ? c.accent.withValues(alpha: 0.32) : c.border,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: ink),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _headline(),
                  style: UgamText.bodyStrong.copyWith(color: ink, fontSize: 13),
                ),
                if (!_noRoom && pickedBerths > 0) ...[
                  const SizedBox(height: 2),
                  Text(
                    _detail(),
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ],
              ],
            ),
          ),
          if (!_noRoom && pickedBerths > 0) ...[
            const SizedBox(width: UgamSpacing.sm),
            Text(
              Formatters.formatMoneyInr(total),
              style: UgamText.tabular(
                UgamText.titleS.copyWith(color: ink),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _headline() {
    if (_noRoom) {
      // Name the leg. "No room" alone sends a customer away from a chart that
      // may well have seated three of their four buckets.
      final entry = shortfall.entries.first;
      return tr(
        switch (entry.key) {
          TripType.roundTrip => 'chart_summary.short_round',
          TripType.outboundOnly => 'chart_summary.short_go',
          TripType.returnOnly => 'chart_summary.short_return',
        },
        namedArgs: {'n': '${entry.value}'},
      );
    }
    if (pickedBerths == 0) {
      return tr('chart_summary.pick_prompt', namedArgs: {'n': '$people'});
    }
    if (pickedBerths < people) {
      return tr(
        'chart_summary.partial',
        namedArgs: {'got': '$pickedBerths', 'want': '$people'},
      );
    }
    // Split is stated in the HEADLINE, not buried in the detail line: a party
    // that will be on two different buses must not find that out at boarding.
    if (_split) {
      return tr(
        'chart_summary.ready_split',
        namedArgs: {'n': '$pickedBerths', 'buses': busNames.join(' + ')},
      );
    }
    return tr('chart_summary.ready', namedArgs: {'n': '$pickedBerths'});
  }

  String _detail() {
    final parts = <String>[
      if (lowerBerths > 0)
        tr('chart_summary.lower_n', namedArgs: {'n': '$lowerBerths'}),
      if (upperBerths > 0)
        tr('chart_summary.upper_n', namedArgs: {'n': '$upperBerths'}),
    ];
    return parts.join(' · ');
  }
}
