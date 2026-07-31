import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../design/ugam.dart';
import '../services/collection_reconciler.dart';
import '../utils/app_snackbar.dart';
import '../utils/formatters.dart';

/// Tells the agent what a cross-bus move just did to a paid rider's balance.
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
  /// buses are dropped — an unchanged balance is not worth interrupting for.
  static Future<void> show(List<SeatMoveMoneyDelta> deltas) async {
    final notable = deltas.where((d) => !d.isSquare).toList();
    if (notable.isEmpty) return;

    final ctx = Get.context;
    if (ctx == null || !ctx.mounted) {
      // No overlay to draw into (a headless or backgrounded write). Fall back
      // to a toast rather than dropping the number silently.
      AppSnackBar.warning(_summaryLine(notable));
      return;
    }

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
        UgamButton(
          label: tr('app.action.ok'),
          onPressed: () => Navigator.of(c).pop(),
        ),
      ],
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
    // Collecting more is the action-needed case (accent); handing money back is
    // the softer warm tone the collection screen already uses for "return".
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
              // Name wraps to 2 lines before ellipsising — app-wide rule, the
              // amount is the chrome that yields.
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
