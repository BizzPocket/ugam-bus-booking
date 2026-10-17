// Extra-income ledger and its add/edit sheet.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../models/income_entry.dart';
import '../../utils/formatters.dart';
import 'handler_ledger.dart';

// ─── Income section ────────────────────────────────────────────────────

/// The handler's per-bus income ledger: a header with the running total + an
/// Add action, then one tappable row per logged income entry (tap to edit,
/// trash to delete). Mirrors [HandlerExpensesSection], scoped to the bus the
/// handler is currently viewing so they can log cabin / gallery cash taken in
/// on the ground — money that ADDS to what they hold, unlike an expense.
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
    final total = incomes.fold<double>(0, (sum, i) => sum + i.amount);
    return HandlerLedgerSection(
      title: tr('handler_chart.bus_income'),
      totalLabel: incomes.isEmpty
          ? null
          : tr(
              'handler_chart.bus_income_total',
              namedArgs: {
                'bus': busName,
                'amount': Formatters.formatMoneyInr(total),
              },
            ),
      emptyIcon: Icons.savings_outlined,
      emptyLabel: tr('handler_chart.no_income'),
      onAdd: onAdd,
      rows: [
        for (final i in incomes)
          _HandlerIncomeRow(
            income: i,
            onTap: () => onEdit(i),
            onDelete: () => onDelete(i),
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
    final receivedBy = (income.receivedBy ?? '').trim();
    return HandlerLedgerRow(
      categoryLabel: income.category.displayName,
      label: income.label.isEmpty ? income.category.displayName : income.label,
      byLine: receivedBy.isEmpty
          ? null
          : tr('handler_chart.received_by', namedArgs: {'name': receivedBy}),
      amount: income.amount,
      amountIsGood: true,
      deleteLabel: tr('handler_chart.delete_income'),
      onTap: onTap,
      onDelete: onDelete,
    );
  }
}

// ─── Income sheet ──────────────────────────────────────────────────────

/// Add / edit one bus income entry. Category chips (cabin / gallery / other) +
/// what-for label + amount + "received by", mirroring [HandlerExpenseSheet].
/// [onSave] persists via the handler RPC and updates the ledger; the form owns
/// the controllers and pops on success.
class HandlerIncomeSheet extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final i = existing;
    return HandlerLedgerForm<IncomeCategory>(
      categories: IncomeCategory.values,
      categoryLabel: (cat) => cat.displayName,
      initialCategory: i?.category ?? IncomeCategory.cabin,
      initialLabel: i?.label ?? '',
      initialAmount: i?.amount,
      initialBy: i?.receivedBy ?? '',
      byFieldLabel: tr('handler_chart.field_received_by'),
      saveLabel: tr('handler_chart.save_income'),
      saveErrorKey: 'handler_chart.error_save_income',
      onSave: onSave,
    );
  }
}
