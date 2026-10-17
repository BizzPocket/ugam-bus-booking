// Ground-expense ledger and its add/edit sheet.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../models/expense.dart';
import '../../utils/formatters.dart';
import 'handler_ledger.dart';

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
    final total = expenses.fold<double>(0, (sum, e) => sum + e.amount);
    return HandlerLedgerSection(
      title: tr('handler_chart.bus_expenses'),
      totalLabel: expenses.isEmpty
          ? null
          : tr(
              'handler_chart.bus_expenses_total',
              namedArgs: {
                'bus': busName,
                'amount': Formatters.formatMoneyInr(total),
              },
            ),
      emptyIcon: Icons.receipt_long_outlined,
      emptyLabel: tr('handler_chart.no_expenses'),
      onAdd: onAdd,
      rows: [
        for (final e in expenses)
          _HandlerExpenseRow(
            expense: e,
            onTap: () => onEdit(e),
            onDelete: () => onDelete(e),
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
    final paidBy = (expense.paidBy ?? '').trim();
    return HandlerLedgerRow(
      categoryLabel: expense.category.displayName,
      label: expense.label.isEmpty
          ? expense.category.displayName
          : expense.label,
      byLine: paidBy.isEmpty
          ? null
          : tr('handler_chart.paid_by', namedArgs: {'name': paidBy}),
      amount: expense.amount,
      amountIsGood: false,
      deleteLabel: tr('handler_chart.delete_expense'),
      onTap: onTap,
      onDelete: onDelete,
    );
  }
}

// ─── Expense sheet ─────────────────────────────────────────────────────

/// Add / edit one bus expense. Category chips + label + amount + "paid by",
/// mirroring the agent's BusMoneyScreen expense form. [onSave] persists via the
/// handler RPC and updates the ledger; the form owns the controllers and pops
/// on success.
class HandlerExpenseSheet extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final e = existing;
    return HandlerLedgerForm<ExpenseCategory>(
      // busOwner is excluded: the bus rent is the single source of truth
      // (Bus.busPrice) and must never be added manually, or it would be
      // double-counted.
      categories: ExpenseCategory.values
          .where((cat) => cat != ExpenseCategory.busOwner)
          .toList(),
      categoryLabel: (cat) => cat.displayName,
      initialCategory: e?.category ?? ExpenseCategory.fuel,
      initialLabel: e?.label ?? '',
      initialAmount: e?.amount,
      initialBy: e?.paidBy ?? '',
      byFieldLabel: tr('handler_chart.field_paid_by'),
      saveLabel: tr('handler_chart.save_expense'),
      saveErrorKey: 'handler_chart.error_save_expense',
      onSave: onSave,
    );
  }
}
