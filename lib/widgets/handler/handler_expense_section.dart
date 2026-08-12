// Ground-expense ledger and its add/edit sheet.

import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../design/ugam.dart';
import '../../models/expense.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/formatters.dart';
import 'handler_atoms.dart';

// ─── Expenses section ──────────────────────────────────────────────────

/// The handler's per-bus expense ledger: a header with the running total + an
/// Add action, then one tappable row per logged expense (tap to edit, trash to
/// delete). Mirrors the agent's BusMoneyScreen expense list, scoped to the bus
/// the handler is currently viewing so they can log fuel / tolls / food on the
/// ground and keep the bus's cash reconciled.
class HandlerExpensesSection extends StatelessWidget {
  final String busName;
  final List<Expense> expenses;
  final VoidCallback onAdd;
  final ValueChanged<Expense> onEdit;
  final ValueChanged<Expense> onDelete;

  const HandlerExpensesSection({
    super.key,
    required this.busName,
    required this.expenses,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final total = expenses.fold<double>(0, (sum, e) => sum + e.amount);
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
                    tr('handler_chart.bus_expenses'),
                    style: UgamText.titleM.copyWith(color: c.ink),
                  ),
                  if (expenses.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      tr(
                        'handler_chart.bus_expenses_total',
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
        if (expenses.isEmpty)
          UgamCard.plain(
            padding: const EdgeInsets.symmetric(
              vertical: UgamSpacing.lg,
              horizontal: UgamSpacing.md,
            ),
            child: Row(
              children: [
                Icon(Icons.receipt_long_outlined, size: 18, color: c.ink3),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    tr('handler_chart.no_expenses'),
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
                for (final e in expenses)
                  _HandlerExpenseRow(
                    expense: e,
                    onTap: () => onEdit(e),
                    onDelete: () => onDelete(e),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One expense line: category chip, label (+ "paid by"), amount, and a delete
/// affordance. The whole row taps through to edit.
class _HandlerExpenseRow extends StatelessWidget {
  final Expense expense;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _HandlerExpenseRow({
    required this.expense,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final paidBy = (expense.paidBy ?? '').trim();
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
              label: expense.category.displayName,
              variant: UgamChipVariant.neutral,
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    expense.label.isEmpty
                        ? expense.category.displayName
                        : expense.label,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (paidBy.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      tr('handler_chart.paid_by', namedArgs: {'name': paidBy}),
                      style: UgamText.micro.copyWith(color: c.ink2),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Text(
              Formatters.formatMoneyInr(expense.amount),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(width: 2),
            Semantics(
              button: true,
              label: tr('handler_chart.delete_expense'),
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

// ─── Expense sheet ─────────────────────────────────────────────────────

/// Add / edit one bus expense. Category chips + label + amount + "paid by",
/// mirroring the agent's BusMoneyScreen expense form. [onSave] persists via the
/// handler RPC and updates the ledger; this widget owns the controllers and
/// pops on success.
class HandlerExpenseSheet extends StatefulWidget {
  final Expense? existing;
  final Future<void> Function(
    ExpenseCategory category,
    String label,
    double amount,
    String paidBy,
  )
  onSave;

  const HandlerExpenseSheet({
    super.key,
    required this.existing,
    required this.onSave,
  });

  @override
  State<HandlerExpenseSheet> createState() => _HandlerExpenseSheetState();
}

class _HandlerExpenseSheetState extends State<HandlerExpenseSheet> {
  late ExpenseCategory _category;
  late final TextEditingController _labelCtrl;
  late final TextEditingController _amountCtrl;
  late final TextEditingController _paidByCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _category = e?.category ?? ExpenseCategory.fuel;
    _labelCtrl = TextEditingController(text: e?.label ?? '');
    _amountCtrl = TextEditingController(
      text: (e?.amount ?? 0) == 0 ? '' : e!.amount.toStringAsFixed(0),
    );
    _paidByCtrl = TextEditingController(text: e?.paidBy ?? '');
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _amountCtrl.dispose();
    _paidByCtrl.dispose();
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
        _paidByCtrl.text.trim(),
      );
      // Dismiss the keyboard so it animates out cleanly with the sheet.
      FocusManager.instance.primaryFocus?.unfocus();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      AppSnackBar.error(tr('handler_chart.error_save_expense'));
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
            // busOwner is excluded: the bus rent is the single source
            // of truth (Bus.busPrice) and must never be added manually,
            // or it would be double-counted.
            children: ExpenseCategory.values
                .where((cat) => cat != ExpenseCategory.busOwner)
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
            label: tr('handler_chart.field_paid_by'),
            controller: _paidByCtrl,
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving
                ? tr('handler_chart.saving')
                : tr('handler_chart.save_expense'),
            loading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}
