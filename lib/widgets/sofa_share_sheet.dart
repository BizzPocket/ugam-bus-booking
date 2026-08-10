import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../utils/formatters.dart';

/// Ask how a two-person sofa should be taken: whole, or half and shared.
///
/// *** WHY THIS REPLACES A GESTURE ***
/// Taking half a sofa means an unrelated person sleeps on the other berth. That
/// used to be expressed by a hidden tap-cycle — one tap took half, a second
/// took the whole thing — which nobody discovers, and which communicates the
/// stranger only by a tile splitting and a price quietly halving.
///
/// In this market that is one of the most consequential facts in the booking,
/// particularly for a woman travelling alone. It gets stated in words, with
/// both prices visible, before any money is committed.
///
/// Returns the berths to take (2 = whole, 1 = half), or null when dismissed.
Future<int?> showSofaShareSheet(
  BuildContext context, {
  /// Price of ONE berth. The whole sofa is quoted as twice this.
  required double halfPrice,
  bool canTakeWhole = true,
  bool canTakeHalf = true,

  /// True when one berth is already sold, so the customer would be joining
  /// someone who is already there rather than inviting an unknown later.
  bool someoneAlreadyThere = false,
}) {
  return UgamSheet.show<int>(
    context,
    title: tr('sofa_share.title'),
    builder: (_) => SofaShareSheet(
      halfPrice: halfPrice,
      canTakeWhole: canTakeWhole,
      canTakeHalf: canTakeHalf,
      someoneAlreadyThere: someoneAlreadyThere,
    ),
  );
}

class SofaShareSheet extends StatelessWidget {
  final double halfPrice;
  final bool canTakeWhole;
  final bool canTakeHalf;
  final bool someoneAlreadyThere;

  const SofaShareSheet({
    super.key,
    required this.halfPrice,
    this.canTakeWhole = true,
    this.canTakeHalf = true,
    this.someoneAlreadyThere = false,
  });

  static const wholeKey = Key('sofa_take_whole');
  static const halfKey = Key('sofa_take_half');

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (canTakeWhole)
            _Choice(
              key: SofaShareSheet.wholeKey,
              c: c,
              icon: Icons.lock_outline_rounded,
              label: tr('sofa_share.whole'),
              detail: tr('sofa_share.whole_detail'),
              price: halfPrice * 2,
              onTap: () => Navigator.of(context).pop(2),
            ),
          if (canTakeWhole && canTakeHalf)
            const SizedBox(height: UgamSpacing.sm),
          if (canTakeHalf)
            _Choice(
              key: SofaShareSheet.halfKey,
              c: c,
              icon: Icons.group_outlined,
              label: tr('sofa_share.half'),
              // The stranger is named. "Someone else will come" and "someone is
              // already here" are different facts and the customer deserves the
              // right one.
              detail: someoneAlreadyThere
                  ? tr('sofa_share.half_detail_occupied')
                  : tr('sofa_share.half_detail'),
              price: halfPrice,
              onTap: () => Navigator.of(context).pop(1),
            ),
        ],
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final String detail;
  final double price;
  final VoidCallback onTap;

  const _Choice({
    super.key,
    required this.c,
    required this.icon,
    required this.label,
    required this.detail,
    required this.price,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.card),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: c.ink3),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              Formatters.formatMoneyInr(price),
              style: UgamText.tabular(
                UgamText.titleS.copyWith(color: c.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
