import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';
import '../ui_scale.dart';
import 'ugam_cta.dart';
import 'ugam_expander.dart';
import 'ugam_sheet.dart';

/// Big amount read-out. A large tabular numeral with a small `micro` caps
/// label above it — the hero figure of any money-entry surface. Pair with
/// [UgamNumpad] (which edits the underlying value) and read-only here.
class UgamAmountHero extends StatelessWidget {
  final String amount;
  final String? label;

  /// Optional tone for the numeral (e.g. [UgamColorSet.good] for a credit).
  /// Defaults to primary ink.
  final Color? tone;

  const UgamAmountHero({
    super.key,
    required this.amount,
    this.label,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(
            label!.toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
        ],
        Text(
          amount,
          style: UgamText.numXl.copyWith(color: tone ?? c.ink, fontSize: 48),
          maxLines: 1,
        ),
      ],
    );
  }
}

/// On-screen numeric keypad. A 3×4 grid of large (≥56dp) cardElev keys —
/// `1`-`9`, an optional decimal key (or a blank spacer when [allowDecimal]
/// is false), `0`, and a backspace — that edit [value].value in place. No
/// system keyboard, no [TextField]: this is the money-entry pad used inside
/// [UgamAmountSheet] and any collect/settle flow.
///
/// * [maxLen] caps the digit count (default 9).
/// * [allowDecimal] swaps the blank bottom-left key for a `.` key (only one
///   decimal point is ever inserted).
/// * [onSubmit] is an optional convenience for an external "done" affordance;
///   the pad itself has no submit key.
class UgamNumpad extends StatelessWidget {
  final ValueNotifier<String> value;
  final int maxLen;
  final bool allowDecimal;
  final VoidCallback? onSubmit;

  const UgamNumpad({
    super.key,
    required this.value,
    this.maxLen = 9,
    this.allowDecimal = false,
    this.onSubmit,
  });

  void _tap(String d) {
    final cur = value.value;
    if (d == '.') {
      if (cur.contains('.')) return;
      value.value = cur.isEmpty ? '0.' : '$cur.';
      return;
    }
    // Strip a leading zero so "0" + "5" -> "5" (but keep "0.x").
    if (cur == '0') {
      value.value = d;
      return;
    }
    if (cur.replaceAll('.', '').length >= maxLen) return;
    value.value = cur + d;
  }

  void _backspace() {
    final cur = value.value;
    if (cur.isEmpty) return;
    value.value = cur.substring(0, cur.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final keys = <_Key>[
      for (var n = 1; n <= 9; n++) _Key.digit('$n'),
      allowDecimal ? _Key.digit('.') : const _Key.blank(),
      _Key.digit('0'),
      const _Key.backspace(),
    ];

    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: UgamSpacing.sm,
      crossAxisSpacing: UgamSpacing.sm,
      childAspectRatio: 1.7,
      children: [
        for (final k in keys)
          _NumKey(spec: k, onDigit: _tap, onBackspace: _backspace),
      ],
    );
  }
}

enum _KeyKind { digit, backspace, blank }

class _Key {
  final _KeyKind kind;
  final String label;
  const _Key.digit(this.label) : kind = _KeyKind.digit;
  const _Key.backspace() : kind = _KeyKind.backspace, label = '';
  const _Key.blank() : kind = _KeyKind.blank, label = '';
}

class _NumKey extends StatelessWidget {
  final _Key spec;
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  const _NumKey({
    required this.spec,
    required this.onDigit,
    required this.onBackspace,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    if (spec.kind == _KeyKind.blank) {
      return const SizedBox.shrink();
    }

    final isBackspace = spec.kind == _KeyKind.backspace;

    return SizedBox(
      // Interactive key: floored at 44 (56 -> 47.6 at the 0.85 device floor),
      // so the pad gets shorter on a small phone without any key going
      // under-sized.
      height: UgamScale.tap(context, 56),
      child: Material(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        child: InkWell(
          borderRadius: BorderRadius.circular(UgamRadius.input),
          onTap: () {
            HapticFeedback.selectionClick();
            if (isBackspace) {
              onBackspace();
            } else {
              onDigit(spec.label);
            }
          },
          child: Center(
            child: isBackspace
                ? Icon(Icons.backspace_outlined, size: 20, color: c.ink2)
                : Text(
                    spec.label,
                    style: UgamText.numLg.copyWith(color: c.ink, fontSize: 22),
                  ),
          ),
        ),
      ),
    );
  }
}

/// Bottom-sheet money entry. Opens a [UgamSheet] with a title eyebrow, an
/// optional tinted "due" banner, a live [UgamAmountHero] bound to a seeded
/// [ValueNotifier], a [UgamNumpad], optional collapsible [details], and a
/// sticky full-width [UgamCTA] that pops the entered [num]. Returns `null`
/// when the sheet is dismissed without confirming.
class UgamAmountSheet {
  const UgamAmountSheet._();

  static Future<num?> show(
    BuildContext context, {
    required String title,
    String? dueLabel,
    num? due,
    num? initial,
    String confirmLabel = 'Confirm',
    Widget Function(BuildContext)? details,
    Widget Function(BuildContext, num amount)? statusBuilder,
  }) {
    return UgamSheet.show<num>(
      context,
      title: title,
      builder: (ctx) => _AmountSheetBody(
        dueLabel: dueLabel,
        due: due,
        initial: initial,
        confirmLabel: confirmLabel,
        details: details,
        statusBuilder: statusBuilder,
      ),
    );
  }
}

class _AmountSheetBody extends StatefulWidget {
  final String? dueLabel;
  final num? due;
  final num? initial;
  final String confirmLabel;
  final Widget Function(BuildContext)? details;
  final Widget Function(BuildContext, num amount)? statusBuilder;

  const _AmountSheetBody({
    this.dueLabel,
    this.due,
    this.initial,
    required this.confirmLabel,
    this.details,
    this.statusBuilder,
  });

  @override
  State<_AmountSheetBody> createState() => _AmountSheetBodyState();
}

class _AmountSheetBodyState extends State<_AmountSheetBody> {
  late final ValueNotifier<String> _value = ValueNotifier<String>(_seed());

  String _seed() {
    final init = widget.initial;
    if (init == null || init == 0) return '';
    // Drop a trailing ".0" so a whole-number seed shows as "500" not "500.0".
    if (init == init.roundToDouble()) return init.toInt().toString();
    return init.toString();
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  num _parsed() => num.tryParse(_value.value) ?? 0;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // Scroll when due + hero + status + numpad + details exceed the sheet's
    // max height (common on short phones / large text). Matches the expense
    // / income sheet bodies so the confirm CTA stays reachable.
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.due != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.lg,
                vertical: UgamSpacing.md,
              ),
              decoration: BoxDecoration(
                color: c.accentFill,
                borderRadius: BorderRadius.circular(UgamRadius.input),
                border: Border.all(color: c.accent.withValues(alpha: 0.28)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    (widget.dueLabel ?? 'Due').toUpperCase(),
                    style: UgamText.micro.copyWith(color: c.accent),
                  ),
                  Text(
                    '${widget.due}',
                    style: UgamText.tabular(
                      UgamText.bodyStrong.copyWith(color: c.accent),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: UgamSpacing.xl),
          ],
          ValueListenableBuilder<String>(
            valueListenable: _value,
            builder: (context, v, child) =>
                UgamAmountHero(amount: v.isEmpty ? '0' : v),
          ),
          if (widget.statusBuilder != null) ...[
            const SizedBox(height: UgamSpacing.md),
            ValueListenableBuilder<String>(
              valueListenable: _value,
              builder: (context, v, child) =>
                  widget.statusBuilder!(context, _parsed()),
            ),
          ],
          const SizedBox(height: UgamSpacing.xl),
          UgamNumpad(value: _value),
          if (widget.details != null) ...[
            const SizedBox(height: UgamSpacing.lg),
            UgamExpander(title: 'Details', child: widget.details!(context)),
          ],
          const SizedBox(height: UgamSpacing.xl),
          ValueListenableBuilder<String>(
            valueListenable: _value,
            builder: (context, v, child) {
              final amount = _parsed();
              return UgamCTA(
                label: widget.confirmLabel,
                onPressed: amount > 0
                    ? () => Navigator.of(context).pop<num>(amount)
                    : null,
              );
            },
          ),
        ],
      ),
    );
  }
}
