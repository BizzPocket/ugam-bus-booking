import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/tour.dart';
import '../screens/collection_screen.dart';
import '../services/collection_reconciler.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';

/// Tells the agent what a seat move just did to a paid rider's balance.
///
/// Buses price by their own bands, so carrying a paid rider from a ₹1,500 band
/// into a ₹2,000 one leaves ₹500 to collect — and the reverse leaves money to
/// hand back. The cash itself has already been carried across by
/// [CollectionReconciler]; this is the prompt so nobody discovers the gap at
/// the roadside.
///
/// Nothing is charged or refunded here. The difference is recorded on the
/// collection screen when money actually changes hands.
class SeatMoveMoneyNotice {
  const SeatMoveMoneyNotice._();

  /// Show the deltas from a move. Riders whose fare happened to match on both
  /// sides are dropped — an unchanged balance is not worth interrupting for.
  ///
  /// [onCollectNow] / [onReturnLater] are injectable for tests; defaults open
  /// [CollectionScreen] / show a reminder toast.
  static Future<void> show(
    List<SeatMoveMoneyDelta> deltas, {
    required Tour tour,
    void Function(SeatMoveMoneyDelta d)? onCollectNow,
    VoidCallback? onReturnLater,
  }) async {
    final notable = deltas.where((d) => !d.isSquare).toList();
    if (notable.isEmpty) return;

    final ctx = Get.context;
    if (ctx == null || !ctx.mounted) {
      AppSnackBar.warning(_summaryLine(notable));
      return;
    }

    final hasCollect = notable.any((d) => d.isCollectMore);
    final hasReturn = notable.any((d) => d.isReturnDue);

    await UgamDialog.show<void>(
      ctx,
      title: tr('seat_move_money.title'),
      message: tr('seat_move_money.subtitle'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final d in notable) ...[
            _DeltaRow(delta: d),
            if (d != notable.last) const SizedBox(height: UgamSpacing.md),
          ],
        ],
      ),
      actions: (c) => [
        if (hasCollect)
          UgamButton(
            label: tr('seat_move_money.action_collect'),
            onPressed: () {
              Navigator.of(c).pop();
              final target = notable.firstWhere((d) => d.isCollectMore);
              if (onCollectNow != null) {
                onCollectNow(target);
              } else {
                _openCollection(tour, target);
              }
            },
          ),
        if (hasReturn)
          UgamButton(
            label: tr('seat_move_money.action_return_later'),
            kind: UgamButtonKind.neutral,
            onPressed: () {
              Navigator.of(c).pop();
              if (onReturnLater != null) {
                onReturnLater();
              } else {
                AppSnackBar.info(tr('seat_move_money.return_later_toast'));
              }
            },
          ),
        UgamButton(
          label: tr('seat_move_money.action_dismiss'),
          kind: UgamButtonKind.neutral,
          onPressed: () => Navigator.of(c).pop(),
        ),
      ],
    );
  }

  static void _openCollection(Tour tour, SeatMoveMoneyDelta delta) {
    Bus? bus;
    for (final id in delta.toBusIds) {
      bus = tour.buses.firstWhereOrNull((b) => b.id == id);
      if (bus != null) break;
    }
    bus ??= tour.buses.firstWhereOrNull(
      (b) => delta.toBusNames.contains(b.name),
    );
    if (bus == null) {
      AppSnackBar.warning(_summaryLine([delta]));
      return;
    }
    Get.to(
      () => CollectionScreen(
        tour: tour,
        bus: bus!,
        highlightPassengerId: delta.passengerId,
      ),
      transition: Transition.cupertino,
    );
  }

  static String _summaryLine(List<SeatMoveMoneyDelta> deltas) {
    final collect = deltas.fold<double>(0, (s, d) => s + d.toCollect);
    final give = deltas.fold<double>(0, (s, d) => s + d.toReturn);
    if (give <= 0) {
      return tr(
        'seat_move_money.toast_collect',
        namedArgs: {'amount': Formatters.formatMoneyInr(collect)},
      );
    }
    if (collect <= 0) {
      return tr(
        'seat_move_money.toast_return',
        namedArgs: {'amount': Formatters.formatMoneyInr(give)},
      );
    }
    return tr(
      'seat_move_money.toast_both',
      namedArgs: {
        'collect': Formatters.formatMoneyInr(collect),
        'give': Formatters.formatMoneyInr(give),
      },
    );
  }
}

class _DeltaRow extends StatelessWidget {
  final SeatMoveMoneyDelta delta;

  const _DeltaRow({required this.delta});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final isCollect = delta.isCollectMore;
    final tone = isCollect ? c.accent : c.warm;
    final fill = isCollect ? c.accentFill : c.warmFill;

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  delta.passengerName,
                  style: UgamText.titleS.copyWith(color: c.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Text(
                Formatters.formatMoneyInr(
                  isCollect ? delta.toCollect : delta.toReturn,
                ),
                style: UgamText.numLg.copyWith(color: tone),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            tr(
              isCollect
                  ? 'seat_move_money.line_collect'
                  : 'seat_move_money.line_return',
              namedArgs: {
                'paid': Formatters.formatMoneyInr(delta.paid),
                'from': delta.fromBusNames.join(', '),
                'due': Formatters.formatMoneyInr(delta.due),
                'to': delta.toBusNames.join(', '),
              },
            ),
            style: UgamText.caption.copyWith(color: c.ink2, height: 1.4),
          ),
        ],
      ),
    );
  }
}
