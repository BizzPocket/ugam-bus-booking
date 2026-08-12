// Extra-income ledger and its add/edit sheet.

import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../design/ugam.dart';
import '../../models/income_entry.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/formatters.dart';
import 'handler_atoms.dart';

// ─── Income section ────────────────────────────────────────────────────

/// The handler's per-bus income ledger: a header with the running total + an
/// Add action, then one tappable row per logged income entry (tap to edit,
/// trash to delete). Mirrors [HandlerExpensesSection], scoped to the bus the handler
/// is currently viewing so they can log cabin / gallery cash taken in on the
/// ground — money that ADDS to what they hold, unlike an expense.
class HandlerIncomeSection extends StatelessWidget {
  final String busName;
  final List<IncomeEntry> incomes;
  final VoidCallback onAdd;
  final ValueChanged<IncomeEntry> onEdit;
  final ValueChanged<IncomeEntry> onDelete;

  const HandlerIncomeSection({
    super.key,
    required this.busName,
    required this.incomes,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final total = incomes.fold<double>(0, (sum, i) => sum + i.amount);
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
                    tr('handler_chart.bus_income'),
                    style: UgamText.titleM.copyWith(color: c.ink),
                  ),
                  if (incomes.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      tr(
                        'handler_chart.bus_income_total',
                        namedArgs: {
                          'bus': busName,
                          'amount': Formatters.formatMoneyInr(total),
                        },
                      ),
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
        if (incomes.isEmpty)
          UgamCard.plain(
            padding: const EdgeInsets.symmetric(
              vertical: UgamSpacing.lg,
              horizontal: UgamSpacing.md,
            ),
            child: Row(
              children: [
                Icon(Icons.savings_outlined, size: 18, color: c.ink3),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    tr('handler_chart.no_income'),
                    style: UgamText.caption.copyWith(color: c.ink3),
                  ),
                ),
              ],
            ),
          )
        else
          UgamCard.plain(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
            child: Column(
              children: [
                for (final i in incomes)
                  _HandlerIncomeRow(
                    income: i,
                    onTap: () => onEdit(i),
                    onDelete: () => onDelete(i),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One income line: category chip, label (+ "received by"), amount, and a
/// delete affordance. The whole row taps through to edit.
class _HandlerIncomeRow extends StatelessWidget {
  final IncomeEntry income;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _HandlerIncomeRow({
    required this.income,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final receivedBy = (income.receivedBy ?? '').trim();
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
              label: income.category.displayName,
              variant: UgamChipVariant.neutral,
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    income.label.isEmpty
                        ? income.category.displayName
                        : income.label,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (receivedBy.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      tr(
                        'handler_chart.received_by',
                        namedArgs: {'name': receivedBy},
                      ),
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              Formatters.formatMoneyInr(income.amount),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.good),
              ),
            ),
            const SizedBox(width: 2),
            Semantics(
              button: true,
              label: tr('handler_chart.delete_income'),
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

// ─── Income sheet ──────────────────────────────────────────────────────

/// Add / edit one bus income entry. Category chips (cabin / gallery / other) +
/// what-for label + amount + "received by", mirroring [HandlerExpenseSheet]. [onSave]
/// persists via the handler RPC and updates the ledger; this widget owns the
/// controllers and pops on success.
class HandlerIncomeSheet extends StatefulWidget {
  final IncomeEntry? existing;
  final Future<void> Function(
    IncomeCategory category,
    String label,
    double amount,
    String receivedBy,
  )
  onSave;

  const HandlerIncomeSheet({
    super.key,
    required this.existing,
    required this.onSave,
  });

  @override
  State<HandlerIncomeSheet> createState() => _HandlerIncomeSheetState();
}

class _HandlerIncomeSheetState extends State<HandlerIncomeSheet> {
  late IncomeCategory _category;
  late final TextEditingController _labelCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _receivedByCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final i = widget.existing;
    _category = i?.category ?? IncomeCategory.cabin;
    _labelCtrl = TextEditingController(text: i?.label ?? '');
    _amountCtrl = TextEditingController(
      text: (i?.amount ?? 0) == 0 ? '' : i!.amount.toStringAsFixed(0),
    );
    _receivedByCtrl = TextEditingController(text: i?.receivedBy ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _amountCtrl.dispose();
    _receivedByCtrl.dispose();
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
        _receivedByCtrl.text.trim(),
      );
      // Dismiss the keyboard so it animates out cleanly with the sheet.
      FocusManager.instance.primaryFocus?.unfocus();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      AppSnackBar.error(tr('handler_chart.error_save_income'));
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
            children: IncomeCategory.values
                .map(
                  (cat) => HandlerCategoryChip(
                    label: cat.displayName,
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
          UgamInput(
            label: tr('handler_chart.field_received_by'),
            controller: _receivedByCtrl,
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving
                ? tr('handler_chart.saving')
                : tr('handler_chart.save_income'),
            loading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}
