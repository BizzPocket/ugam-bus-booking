import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../utils/formatters.dart';

/// "Cash so far ₹X" — the SECONDARY of a trip's two profit figures
/// ([TripPnl.cashSoFar]), printed under every admin headline that shows the
/// primary "Trip profit". One widget so the wording, size and tone rule (ink2;
/// danger when negative) are the same on every surface.
class CashSoFarLine extends StatelessWidget {
  const CashSoFarLine({
    super.key,
    required this.value,
    this.format = Formatters.formatMoneyInr,
    this.textAlign,
    this.dense = false,
  });

  /// Micro type instead of caption — for a list row whose old secondary line
  /// was micro, so the row keeps its height.
  final bool dense;

  final double value;

  /// How the rupee figure is spelled — surfaces whose headline is signed
  /// (`+₹` / `−₹`) pass their own formatter so the two lines match.
  final String Function(double) format;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final negative = value.round() < 0;
    return Text(
      tr('trip_pnl.cash_so_far_value', namedArgs: {'n': format(value)}),
      key: const ValueKey('cash-so-far'),
      style: UgamText.tabular(
        (dense ? UgamText.micro : UgamText.caption)
            .copyWith(color: negative ? c.danger : c.ink2),
      ),
      textAlign: textAlign,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
