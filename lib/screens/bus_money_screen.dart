import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';

import '../controllers/money_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/bus_handover.dart';
import '../models/expense.dart';
import '../models/money_summary.dart';
import '../models/tour.dart';
import 'collection_screen.dart';

String _money(num v) => '₹${v.toStringAsFixed(0)}';

/// Per-bus money cockpit: collection summary, expense ledger, and the
/// cash-handover record for one bus on a tour. Reads everything live from
/// [MoneyController]'s obs lists and exposes add/delete sheets for
/// expenses and handovers, plus a jump into the per-passenger collection
/// screen. A tour-wide rollup card sits at the bottom.
class BusMoneyScreen extends StatefulWidget {
  final Tour tour;
  final Bus bus;

  const BusMoneyScreen({super.key, required this.tour, required this.bus});

  @override
  State<BusMoneyScreen> createState() => _BusMoneyScreenState();
}

class _BusMoneyScreenState extends State<BusMoneyScreen> {
  final MoneyController controller = Get.find<MoneyController>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.loadForTour(widget.tour.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        title: Text('Money · ${widget.bus.name}'),
      ),
      body: SafeArea(
        top: false,
        child: Obx(() {
          final s = controller.summaryForBus(widget.bus.id);
          final expenses = controller.expenses
              .where((e) => e.busId == widget.bus.id)
              .toList();
          final handovers = controller.handovers
              .where((h) => h.busId == widget.bus.id)
              .toList();
          final t = controller.tourSummary();

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              UgamSpacing.gutter,
              UgamSpacing.sm,
              UgamSpacing.gutter,
              UgamSpacing.huge,
            ),
            children: [
              // ── Stat grid ──────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: UgamStatTile(
                      icon: Icons.payments_rounded,
                      value: _money(s.collected),
                      label: 'Collected',
                      variant: UgamStatVariant.good,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: UgamStatTile(
                      icon: Icons.receipt_long_rounded,
                      value: _money(s.expensesTotal),
                      label: 'Expenses',
                      variant: UgamStatVariant.warm,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UgamSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: UgamStatTile(
                      icon: Icons.account_balance_rounded,
                      value: _money(s.expectedHandover),
                      label: 'Expected handover',
                      variant: UgamStatVariant.accent,
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.md),
                  Expanded(
                    child: UgamStatTile(
                      icon: Icons.pending_actions_rounded,
                      value: _money(s.outstandingHandover),
                      label: 'Outstanding',
                      variant: UgamStatVariant.neutral,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UgamSpacing.lg),
              UgamCTA(
                label: 'Collect from passengers',
                leadingIcon: Icons.groups_rounded,
                onPressed: () => Get.to(
                  () => CollectionScreen(tour: widget.tour, bus: widget.bus),
                  transition: Transition.cupertino,
                ),
              ),
              const SizedBox(height: UgamSpacing.xl),

              // ── Expenses ───────────────────────────────────────
              _SectionHeader(
                title: 'Expenses',
                actionLabel: 'Add',
                onAction: () => _openExpenseSheet(context),
              ),
              const SizedBox(height: UgamSpacing.sm),
              if (expenses.isEmpty)
                _EmptyLine(text: 'No expenses logged for this bus yet.')
              else
                ...expenses.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
                    child: _ExpenseRow(
                      expense: e,
                      onDelete: () => controller.deleteExpense(e.id),
                    ),
                  ),
                ),
              const SizedBox(height: UgamSpacing.xl),

              // ── Handover ───────────────────────────────────────
              _SectionHeader(
                title: 'Handover to admin',
                actionLabel: 'Record',
                onAction: () =>
                    _openHandoverSheet(context, s.expectedHandover),
              ),
              const SizedBox(height: UgamSpacing.sm),
              if (handovers.isEmpty)
                _EmptyLine(text: 'No handover recorded yet.')
              else
                ...handovers.map(
                  (h) => Padding(
                    padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
                    child: _HandoverRow(
                      handover: h,
                      onDelete: () => controller.deleteHandover(h.id),
                    ),
                  ),
                ),
              const SizedBox(height: UgamSpacing.xl),

              // ── Tour rollup ────────────────────────────────────
              _TourRollupCard(summary: t),
            ],
          );
        }),
      ),
    );
  }

  void _openExpenseSheet(BuildContext context) {
    ExpenseCategory category = ExpenseCategory.other;
    final labelCtrl = TextEditingController();
    final amountCtrl = TextEditingController();
    final paidByCtrl = TextEditingController();

    UgamSheet.show<void>(
      context,
      title: 'Add expense',
      builder: (sheetCtx) {
        final sc = UgamColors.of(sheetCtx);
        return SingleChildScrollView(
          child: StatefulBuilder(
            builder: (innerCtx, setSheetState) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CATEGORY',
                    style: UgamText.micro.copyWith(color: sc.ink2),
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  Wrap(
                    spacing: UgamSpacing.sm,
                    runSpacing: UgamSpacing.sm,
                    children: ExpenseCategory.values.map((cat) {
                      final active = cat == category;
                      return GestureDetector(
                        onTap: () => setSheetState(() => category = cat),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UgamSpacing.lg,
                            vertical: UgamSpacing.sm + 2,
                          ),
                          decoration: BoxDecoration(
                            color: active ? sc.accentFill : sc.cardElev,
                            borderRadius:
                                BorderRadius.circular(UgamRadius.chip),
                            border: Border.all(
                              color: active ? sc.accent : sc.border,
                            ),
                          ),
                          child: Text(
                            cat.displayName,
                            style: UgamText.caption.copyWith(
                              color: active ? sc.accent : sc.ink2,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  UgamInput(label: 'Label', controller: labelCtrl),
                  const SizedBox(height: UgamSpacing.md),
                  UgamInput(
                    label: 'Amount',
                    controller: amountCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  UgamInput(label: 'Paid by', controller: paidByCtrl),
                  const SizedBox(height: UgamSpacing.lg),
                  UgamCTA(
                    label: 'Save expense',
                    onPressed: () async {
                      final paidBy = paidByCtrl.text.trim();
                      await controller.upsertExpense(
                        Expense(
                          tourId: widget.tour.id,
                          busId: widget.bus.id,
                          category: category,
                          label: labelCtrl.text.trim(),
                          amount:
                              double.tryParse(amountCtrl.text.trim()) ?? 0,
                          paidBy: paidBy.isEmpty ? null : paidBy,
                        ),
                      );
                      if (innerCtx.mounted) Navigator.of(innerCtx).pop();
                    },
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  void _openHandoverSheet(BuildContext context, double expected) {
    final handedCtrl = TextEditingController(text: expected.toStringAsFixed(0));
    final noteCtrl = TextEditingController();

    UgamSheet.show<void>(
      context,
      title: 'Record handover',
      builder: (sheetCtx) {
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ReadOnlyLine(label: 'Expected', value: _money(expected)),
              const SizedBox(height: UgamSpacing.lg),
              UgamInput(
                label: 'Handed over',
                controller: handedCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
              ),
              const SizedBox(height: UgamSpacing.md),
              UgamInput(label: 'Note', controller: noteCtrl),
              const SizedBox(height: UgamSpacing.lg),
              UgamCTA(
                label: 'Save handover',
                onPressed: () async {
                  final note = noteCtrl.text.trim();
                  await controller.recordHandover(
                    BusHandover(
                      tourId: widget.tour.id,
                      busId: widget.bus.id,
                      expectedAmount: expected,
                      handedOverAmount:
                          double.tryParse(handedCtrl.text.trim()) ?? 0,
                      note: note.isEmpty ? null : note,
                    ),
                  );
                  if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String actionLabel;
  final VoidCallback onAction;

  const _SectionHeader({
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: UgamText.titleM.copyWith(color: c.ink)),
        GestureDetector(
          onTap: onAction,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: UgamSpacing.md,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_rounded, size: 15, color: c.accent),
                const SizedBox(width: 4),
                Text(
                  actionLabel,
                  style: UgamText.caption.copyWith(
                    color: c.accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ExpenseRow extends StatelessWidget {
  final Expense expense;
  final VoidCallback onDelete;

  const _ExpenseRow({required this.expense, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
            ),
            child: Text(
              expense.category.displayName,
              style: UgamText.micro.copyWith(color: c.ink2),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              expense.label.isEmpty ? '—' : expense.label,
              style: UgamText.bodyStrong.copyWith(color: c.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            _money(expense.amount),
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onDelete,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.delete_outline_rounded,
                  size: 18, color: c.ink3),
            ),
          ),
        ],
      ),
    );
  }
}

class _HandoverRow extends StatelessWidget {
  final BusHandover handover;
  final VoidCallback onDelete;

  const _HandoverRow({required this.handover, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final date = DateFormat('d MMM, h:mm a').format(handover.settledAt);
    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.gutter,
        vertical: UgamSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Handed ${_money(handover.handedOverAmount)} of '
                  '${_money(handover.expectedAmount)}',
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(date, style: UgamText.caption.copyWith(color: c.ink2)),
              ],
            ),
          ),
          GestureDetector(
            onTap: onDelete,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.delete_outline_rounded,
                  size: 18, color: c.ink3),
            ),
          ),
        ],
      ),
    );
  }
}

class _TourRollupCard extends StatelessWidget {
  final TourMoneySummary summary;

  const _TourRollupCard({required this.summary});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamCard.plain(
      elev: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Tour totals', style: UgamText.titleM.copyWith(color: c.ink)),
          const SizedBox(height: UgamSpacing.md),
          _RollupRow(label: 'Total collected', value: _money(summary.totalCollected)),
          _RollupRow(label: 'Total expenses', value: _money(summary.totalExpenses)),
          _RollupRow(label: 'Net', value: _money(summary.totalNet)),
          _RollupRow(
            label: 'Outstanding',
            value: _money(summary.totalOutstandingHandover),
          ),
          _RollupRow(label: 'To return', value: _money(summary.totalToReturn)),
        ],
      ),
    );
  }
}

class _RollupRow extends StatelessWidget {
  final String label;
  final String value;

  const _RollupRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: UgamText.body.copyWith(color: c.ink2)),
          Text(
            value,
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(color: c.ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  final String text;

  const _EmptyLine({required this.text});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
      child: Text(text, style: UgamText.caption.copyWith(color: c.ink3)),
    );
  }
}

class _ReadOnlyLine extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: UgamText.body.copyWith(color: c.ink2)),
        Text(
          value,
          style: UgamText.tabular(
            UgamText.titleS.copyWith(color: c.ink),
          ),
        ),
      ],
    );
  }
}
