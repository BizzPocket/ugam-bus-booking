import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../utils/band_options.dart';
import '../utils/formatters.dart';

/// What the customer chose: a band, and how many units of the seat type.
class BandPick {
  final BandOption option;
  final int qty;

  const BandPick({required this.option, required this.qty});
}

/// Ask which price band this seat is for, then how many.
///
/// *** WHY A BAND HAS TO BE ASKED AT ALL ***
/// This flow takes the money when the request is submitted, and the fare is not
/// one number — the bus is priced in bands by row. The customer therefore has
/// to say which band they are buying into BEFORE they can be charged, and what
/// they pick binds where they may be seated.
///
/// *** WHY BANDS ARE SHOWN BY PRICE, NOT BY NAME ***
/// The live tour carries three differently-priced bands ALL labelled `બેન્ડ`.
/// A list of three identical names is not a choice, so the price leads each row
/// and the rows it covers sit under it. An authored label is shown only when it
/// adds something the price and rows do not.
///
/// Resolves to null when dismissed — the caller leaves that cell untouched.
Future<BandPick?> showBandPickerDialog(
  BuildContext context, {
  required String seatTypeLabel,
  required List<BandOption> options,
  required int maxQty,
}) {
  return UgamDialog.show<BandPick>(
    context,
    title: seatTypeLabel,
    content: _BandPickerBody(options: options, maxQty: maxQty),
    actions: (ctx) => [
      UgamButton(
        label: tr('app.action.cancel'),
        kind: UgamButtonKind.ghost,
        onPressed: () => Navigator.of(ctx).pop(),
      ),
    ],
  );
}

class _BandPickerBody extends StatefulWidget {
  final List<BandOption> options;
  final int maxQty;

  const _BandPickerBody({required this.options, required this.maxQty});

  @override
  State<_BandPickerBody> createState() => _BandPickerBodyState();
}

class _BandPickerBodyState extends State<_BandPickerBody> {
  BandOption? _selected;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // Nothing sellable: the bus is unpriced, or every band that could hold this
    // seat type is gone. Say so plainly and name what happens instead — the
    // rider still gets a request, free, on the waiting list.
    if (widget.options.isEmpty) {
      return Column(
        key: const Key('band-empty'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('band_picker.unavailable_title'),
            style: UgamText.bodyStrong.copyWith(color: c.ink),
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            tr('band_picker.unavailable_body'),
            style: UgamText.caption.copyWith(color: c.ink2, height: 1.4),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr('band_picker.choose_band').toUpperCase(),
          style: UgamText.micro.copyWith(color: c.ink3),
        ),
        const SizedBox(height: UgamSpacing.sm),
        for (var i = 0; i < widget.options.length; i++) ...[
          if (i > 0) const SizedBox(height: UgamSpacing.xs),
          _BandRow(
            key: Key('band-${widget.options[i].key}'),
            option: widget.options[i],
            selected: widget.options[i] == _selected,
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _selected = widget.options[i]);
            },
          ),
        ],
        // Quantity appears only once a band is chosen: a number tapped before
        // a band would have to guess which band it belonged to.
        if (_selected != null) ...[
          const SizedBox(height: UgamSpacing.lg),
          Text(
            tr('band_picker.choose_qty').toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.sm),
          _QtyRow(
            max: widget.maxQty,
            onPick: (qty) {
              HapticFeedback.lightImpact();
              Navigator.of(context).pop(
                BandPick(option: _selected!, qty: qty),
              );
            },
          ),
        ],
      ],
    );
  }
}

/// One band, led by what a single unit of this seat type costs inside it.
class _BandRow extends StatelessWidget {
  final BandOption option;
  final bool selected;
  final VoidCallback onTap;

  const _BandRow({
    super.key,
    required this.option,
    required this.selected,
    required this.onTap,
  });

  /// Rows are 0-based in the layout and 1-based to a human counting them from
  /// the front of the coach.
  String get _rowsLabel {
    final from = option.band.fromRow + 1;
    final to = option.band.toRow + 1;
    return from == to
        ? tr('band_picker.row_one', namedArgs: {'row': '$from'})
        : tr('band_picker.rows', namedArgs: {'from': '$from', 'to': '$to'});
  }

  /// The authored label, shown only when it adds something. Blank labels and
  /// the synthesized standard option fall back to a generic word.
  String? get _labelChip {
    if (option.isStandard) return tr('band_picker.standard');
    final label = option.band.label.trim();
    return label.isEmpty ? null : label;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final chip = _labelChip;

    return UgamTappable(
      onTap: onTap,
      pressedScale: 0.98,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: selected ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.card),
          border: Border.all(
            color: selected ? c.accent : c.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 18,
              color: selected ? c.accent : c.ink3,
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    Formatters.formatMoneyInr(option.unitPricePaise / 100),
                    style: UgamText.tabular(
                      UgamText.titleS.copyWith(
                        color: selected ? c.accent : c.ink,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    chip == null ? _rowsLabel : '$_rowsLabel · $chip',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tappable quantities. Tapping one COMMITS — it is the dialog's confirm, which
/// is what makes the whole interaction two taps.
class _QtyRow extends StatelessWidget {
  final int max;
  final ValueChanged<int> onPick;

  const _QtyRow({required this.max, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final tap = UgamScale.tap(context, 44);

    return Wrap(
      spacing: UgamSpacing.xs,
      runSpacing: UgamSpacing.xs,
      children: [
        for (var n = 1; n <= max; n++)
          UgamTappable(
            key: Key('bandqty-$n'),
            onTap: () => onPick(n),
            pressedScale: 0.92,
            child: Container(
              width: tap,
              height: tap,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.chip),
                border: Border.all(color: c.border),
              ),
              child: Text(
                '$n',
                style: UgamText.tabular(
                  UgamText.titleS.copyWith(color: c.ink),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
