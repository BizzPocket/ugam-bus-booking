// The shared body of the handler's two per-bus ledgers — ground expenses
// (handler_expense_section.dart) and extra income (handler_income_section.dart).
// The two were line-for-line twins; only the words, the category enum and the
// amount ink differ, and those are passed in.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../design/ugam.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/formatters.dart';
import 'handler_atoms.dart';

// ─── Ledger section ────────────────────────────────────────────────────

/// A header with the running total + an Add action, then [rows] in one card —
/// or the empty line when there are none.
class HandlerLedgerSection extends StatelessWidget {
  final String title;

  /// The running-total line under the title; null hides it (an empty ledger).
  final String? totalLabel;
  final IconData emptyIcon;
  final String emptyLabel;
  final VoidCallback onAdd;
  final List<Widget> rows;

  const HandlerLedgerSection({
    super.key,
    required this.title,
    required this.totalLabel,
    required this.emptyIcon,
    required this.emptyLabel,
    required this.onAdd,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: UgamText.titleM.copyWith(color: c.ink),
                  ),
                  if (totalLabel != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      totalLabel!,
                      style: UgamText.caption.copyWith(color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
            UgamButton(
              label: tr('app.action.add'),
              icon: Icons.add_rounded,
              kind: UgamButtonKind.tonal,
              onPressed: onAdd,
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.sm),
        if (rows.isEmpty)
          UgamCard.plain(
            padding: const EdgeInsets.symmetric(
              vertical: UgamSpacing.lg,
              horizontal: UgamSpacing.md,
            ),
            child: Row(
              children: [
                Icon(emptyIcon, size: 18, color: c.ink3),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    emptyLabel,
                    style: UgamText.caption.copyWith(color: c.ink3),
                  ),
                ),
              ],
            ),
          )
        else
          UgamCard.plain(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
            child: Column(children: rows),
          ),
      ],
    );
  }
}

/// One ledger line: category chip, label (+ who paid / received it), amount,
/// and a delete affordance. The whole row taps through to edit.
class HandlerLedgerRow extends StatelessWidget {
  final String categoryLabel;
  final String label;

  /// "Paid by X" / "Received by X"; null when nobody was named.
  final String? byLine;
  final double amount;

  /// Income is money IN, so its amount reads good; an expense stays plain ink.
  final bool amountIsGood;
  final String deleteLabel;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const HandlerLedgerRow({
    super.key,
    required this.categoryLabel,
    required this.label,
    required this.byLine,
    required this.amount,
    required this.amountIsGood,
    required this.deleteLabel,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.md,
        ),
        child: Row(
          children: [
            UgamReqChip(
              label: categoryLabel,
              variant: UgamChipVariant.neutral,
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (byLine != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      byLine!,
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              Formatters.formatMoneyInr(amount),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(
                  color: amountIsGood ? c.good : c.ink,
                ),
              ),
            ),
            const SizedBox(width: 2),
            Semantics(
              button: true,
              label: deleteLabel,
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  onDelete();
                },
                behavior: HitTestBehavior.opaque,
                child: const HandlerDeleteGlyph(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Ledger sheet ──────────────────────────────────────────────────────

/// Add / edit one ledger entry: category chips + what-for label + amount +
/// who paid / received it. [onSave] persists via the handler RPC and updates
/// the ledger; this widget owns the controllers and pops on success.
class HandlerLedgerForm<C> extends StatefulWidget {
  final List<C> categories;
  final String Function(C category) categoryLabel;
  final C initialCategory;
  final String initialLabel;
  final double? initialAmount;
  final String initialBy;

  /// Label of the "paid by" / "received by" field.
  final String byFieldLabel;
  final String saveLabel;

  /// Translation key toasted when [onSave] throws.
  final String saveErrorKey;
  final Future<void> Function(
    C category,
    String label,
    double amount,
    String by,
  )
  onSave;

  const HandlerLedgerForm({
    super.key,
    required this.categories,
    required this.categoryLabel,
    required this.initialCategory,
    required this.initialLabel,
    required this.initialAmount,
    required this.initialBy,
    required this.byFieldLabel,
    required this.saveLabel,
    required this.saveErrorKey,
    required this.onSave,
  });

  @override
  State<HandlerLedgerForm<C>> createState() => _HandlerLedgerFormState<C>();
}

class _HandlerLedgerFormState<C> extends State<HandlerLedgerForm<C>> {
  late C _category;
  late final TextEditingController _labelCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _byCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory;
    _labelCtrl = TextEditingController(text: widget.initialLabel);
    final amount = widget.initialAmount;
    _amountCtrl = TextEditingController(
      text: (amount ?? 0) == 0 ? '' : amount!.toStringAsFixed(0),
    );
    _byCtrl = TextEditingController(text: widget.initialBy);
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _amountCtrl.dispose();
    _byCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      AppSnackBar.error(tr('handler_chart.error_amount_zero'));
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(
        _category,
        _labelCtrl.text.trim(),
        amount,
        _byCtrl.text.trim(),
      );
      // Dismiss the keyboard so it animates out cleanly with the sheet.
      FocusManager.instance.primaryFocus?.unfocus();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      AppSnackBar.error(tr(widget.saveErrorKey));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('handler_chart.category'),
            style: UgamText.micro.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
          Wrap(
            spacing: UgamSpacing.sm,
            runSpacing: UgamSpacing.sm,
            children: widget.categories
                .map(
                  (cat) => HandlerCategoryChip(
                    label: widget.categoryLabel(cat),
                    active: cat == _category,
                    onTap: () => setState(() => _category = cat),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('handler_chart.field_what_for'),
            controller: _labelCtrl,
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: tr('handler_chart.field_amount'),
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(label: widget.byFieldLabel, controller: _byCtrl),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving ? tr('handler_chart.saving') : widget.saveLabel,
            loading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}
