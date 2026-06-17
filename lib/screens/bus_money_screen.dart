import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/bus_handover.dart';
import '../models/expense.dart';
import '../models/money_summary.dart';
import '../models/tour.dart';
import '../utils/formatters.dart';
import 'collection_screen.dart';

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
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(
              eyebrow: tr('bus_money.eyebrow'),
              title: tr(
                'bus_money.app_bar_title',
                namedArgs: {'name': widget.bus.name},
              ),
            ),
            Expanded(
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
                    // ── Hero figure: the ONE action number ─────────────
                    // Outstanding handover leads as a large tabular figure —
                    // it's what the agent must act on. Everything else is
                    // demoted to a quiet supporting row below.
                    _OutstandingHero(
                      amount: s.outstandingHandover,
                      expected: s.expectedHandover,
                    ),
                    const SizedBox(height: UgamSpacing.md),
                    // ── Supporting stat grid (demoted) ─────────────────
                    Row(
                      children: [
                        Expanded(
                          child: UgamStatTile(
                            icon: Icons.payments_rounded,
                            value: Formatters.formatMoneyInr(s.collected),
                            label: tr('bus_money.stat_collected'),
                            variant: UgamStatVariant.good,
                          ),
                        ),
                        const SizedBox(width: UgamSpacing.md),
                        Expanded(
                          child: UgamStatTile(
                            icon: Icons.receipt_long_rounded,
                            value: Formatters.formatMoneyInr(s.expensesTotal),
                            label: tr('bus_money.stat_expenses'),
                            variant: UgamStatVariant.warm,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: UgamSpacing.lg),
                    // Demoted to a TONAL quiet-primary: this is a navigation
                    // jump, not the screen's single focal action, so solid
                    // champagne stays rationed (accent-rationing law).
                    UgamButton(
                      label: tr('bus_money.collect_from_passengers'),
                      icon: Icons.groups_rounded,
                      kind: UgamButtonKind.tonal,
                      expand: true,
                      onPressed: () => Get.to(
                        () => CollectionScreen(
                          tour: widget.tour,
                          bus: widget.bus,
                        ),
                        transition: Transition.cupertino,
                      ),
                    ),
                    const SizedBox(height: UgamSpacing.xl),

                    // ── Expenses ───────────────────────────────────────
                    _SectionHeader(
                      title: tr('bus_money.section_expenses'),
                      actionLabel: tr('app.action.add'),
                      onAction: () => _openExpenseSheet(context),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    // The auto bus-owner rent is derived from the bus (the
                    // single source of truth, already inside expensesTotal) —
                    // so it counts as content for the empty check.
                    if (widget.bus.busPrice <= 0 && expenses.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: UgamSpacing.lg,
                        ),
                        child: UgamEmpty(
                          icon: Icons.receipt_long_rounded,
                          title: tr('bus_money.expenses_empty'),
                        ),
                      )
                    else ...[
                      // Fixed, non-deletable rent row at the top: derived from
                      // the bus, not a DB row, so it has no delete icon.
                      if (widget.bus.busPrice > 0)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.sm,
                          ),
                          child: _BusOwnerRentRow(
                            busPrice: widget.bus.busPrice,
                          ),
                        ),
                      ...expenses.map(
                        (e) => Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.sm,
                          ),
                          child: _ExpenseRow(
                            expense: e,
                            onTap: () =>
                                _openExpenseSheet(context, existing: e),
                            // await + swallow: the controller already rolls
                            // back and shows an error toast on failure;
                            // without this the rethrow becomes an uncaught
                            // async exception.
                            onDelete: () async {
                              // Money records are irreversible — gate the delete
                              // behind a destructive confirm (was a one-tap
                              // data-loss footgun on a small icon).
                              final ok = await UgamDialog.confirm(
                                context,
                                title: tr('bus_money.delete_expense_title'),
                                message: tr('bus_money.delete_expense_body'),
                                cancelLabel: tr('app.action.cancel'),
                                confirmLabel: tr('bus_money.delete_confirm'),
                                destructive: true,
                                confirmIcon: Icons.delete_outline_rounded,
                              );
                              if (!ok) return;
                              try {
                                await controller.deleteExpense(e.id);
                              } catch (_) {}
                            },
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: UgamSpacing.xl),

                    // ── Handover ───────────────────────────────────────
                    _SectionHeader(
                      title: tr('bus_money.section_handover_to_admin'),
                      actionLabel: tr('bus_money.action_record'),
                      onAction: () =>
                          _openHandoverSheet(context, s.expectedHandover),
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    if (handovers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: UgamSpacing.lg,
                        ),
                        child: UgamEmpty(
                          icon: Icons.account_balance_rounded,
                          title: tr('bus_money.handover_empty'),
                        ),
                      )
                    else
                      ...handovers.map(
                        (h) => Padding(
                          padding: const EdgeInsets.only(
                            bottom: UgamSpacing.sm,
                          ),
                          child: _HandoverRow(
                            handover: h,
                            onTap: () => _openHandoverSheet(
                              context,
                              h.expectedAmount,
                              existing: h,
                            ),
                            onDelete: () async {
                              // Irreversible handover record — destructive
                              // confirm before delete.
                              final ok = await UgamDialog.confirm(
                                context,
                                title: tr('bus_money.delete_handover_title'),
                                message: tr('bus_money.delete_handover_body'),
                                cancelLabel: tr('app.action.cancel'),
                                confirmLabel: tr('bus_money.delete_confirm'),
                                destructive: true,
                                confirmIcon: Icons.delete_outline_rounded,
                              );
                              if (!ok) return;
                              try {
                                await controller.deleteHandover(h.id);
                              } catch (_) {}
                            },
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
          ],
        ),
      ),
    );
  }

  void _openExpenseSheet(BuildContext context, {Expense? existing}) {
    ExpenseCategory category = existing?.category ?? ExpenseCategory.other;
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final amountCtrl = TextEditingController(
      text: (existing == null || existing.amount == 0)
          ? ''
          : existing.amount.toStringAsFixed(0),
    );
    final paidByCtrl = TextEditingController(text: existing?.paidBy ?? '');

    UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('bus_money.add_expense')
          : tr('bus_money.edit_expense'),
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
                    tr('bus_money.field_category'),
                    style: UgamText.micro.copyWith(color: sc.ink2),
                  ),
                  const SizedBox(height: UgamSpacing.sm),
                  // busOwner is excluded: the bus rent is the single source of
                  // truth (Bus.busPrice) and must never be added manually, or
                  // it would be double-counted.
                  Builder(
                    builder: (_) {
                      final cats = ExpenseCategory.values
                          .where((c) => c != ExpenseCategory.busOwner)
                          .toList();
                      final selected = cats.indexOf(category);
                      return UgamSelectorPills(
                        padding: EdgeInsets.zero,
                        items: cats
                            .map(
                              (cat) => UgamSelectorItem(label: cat.displayName),
                            )
                            .toList(),
                        currentIndex: selected < 0 ? 0 : selected,
                        onChanged: (i) =>
                            setSheetState(() => category = cats[i]),
                      );
                    },
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  UgamInput(
                    label: tr('bus_money.field_label'),
                    controller: labelCtrl,
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  UgamInput(
                    label: tr('bus_money.field_amount'),
                    controller: amountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    ],
                  ),
                  const SizedBox(height: UgamSpacing.md),
                  UgamInput(
                    label: tr('bus_money.field_paid_by'),
                    controller: paidByCtrl,
                  ),
                  const SizedBox(height: UgamSpacing.lg),
                  UgamCTA(
                    label: tr('bus_money.save_expense'),
                    onPressed: () async {
                      final paidBy = paidByCtrl.text.trim();
                      final amount =
                          double.tryParse(amountCtrl.text.trim()) ?? 0;
                      final label = labelCtrl.text.trim();
                      // Editing reuses the same id (an update, not a new row)
                      // by going through copyWith, which preserves id/createdAt.
                      await controller.upsertExpense(
                        existing == null
                            ? Expense(
                                tourId: widget.tour.id,
                                busId: widget.bus.id,
                                category: category,
                                label: label,
                                amount: amount,
                                paidBy: paidBy.isEmpty ? null : paidBy,
                              )
                            : existing.copyWith(
                                category: category,
                                label: label,
                                amount: amount,
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

  void _openHandoverSheet(
    BuildContext context,
    double expected, {
    BusHandover? existing,
  }) {
    final handedCtrl = TextEditingController(
      text: (existing?.handedOverAmount ?? expected).toStringAsFixed(0),
    );
    final noteCtrl = TextEditingController(text: existing?.note ?? '');

    UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('bus_money.record_handover')
          : tr('bus_money.edit_handover'),
      builder: (sheetCtx) {
        return SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ReadOnlyLine(
                label: tr('bus_money.field_expected'),
                value: Formatters.formatMoneyInr(expected),
              ),
              const SizedBox(height: UgamSpacing.lg),
              UgamInput(
                label: tr('bus_money.field_handed_over'),
                controller: handedCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
              ),
              const SizedBox(height: UgamSpacing.md),
              UgamInput(
                label: tr('bus_money.field_note'),
                controller: noteCtrl,
              ),
              const SizedBox(height: UgamSpacing.lg),
              UgamCTA(
                label: tr('bus_money.save_handover'),
                onPressed: () async {
                  final note = noteCtrl.text.trim();
                  final handed = double.tryParse(handedCtrl.text.trim()) ?? 0;
                  await controller.recordHandover(
                    existing == null
                        ? BusHandover(
                            tourId: widget.tour.id,
                            busId: widget.bus.id,
                            expectedAmount: expected,
                            handedOverAmount: handed,
                            note: note.isEmpty ? null : note,
                          )
                        : existing.copyWith(
                            handedOverAmount: handed,
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

/// The screen's single focal figure: the outstanding handover this bus still
/// owes the admin, shown as a large tabular number. Expected handover sits
/// beneath it as quiet context. Carries the view's one champagne signal when
/// money is still owed; settles to a calm `good` tone at zero.
class _OutstandingHero extends StatelessWidget {
  final double amount;
  final double expected;

  const _OutstandingHero({required this.amount, required this.expected});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final settled = amount.abs() <= 0.005;
    final figureColor = settled ? c.good : c.accent;
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('bus_money.stat_outstanding').toUpperCase(),
                  style: UgamText.micro.copyWith(
                    color: c.ink3,
                    letterSpacing: 0.6,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UgamSpacing.xs),
                Text(
                  Formatters.formatMoneyInr(amount),
                  style: UgamText.tabular(
                    UgamText.numLg.copyWith(color: figureColor, fontSize: 30),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  tr('bus_money.stat_expected_handover'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Text(
            Formatters.formatMoneyInr(expected),
            style: UgamText.tabular(
              UgamText.bodyStrong.copyWith(color: c.ink2),
            ),
          ),
        ],
      ),
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
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            title,
            style: UgamText.titleM.copyWith(color: c.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        // Section add/record action — TONAL quiet-primary, never solid gold.
        UgamButton(
          label: actionLabel,
          icon: Icons.add_rounded,
          kind: UgamButtonKind.tonal,
          onPressed: onAction,
        ),
      ],
    );
  }
}

class _ExpenseRow extends StatelessWidget {
  final Expense expense;
  final VoidCallback onTap;
  // Null for a derived (non-DB) row such as the auto bus-owner rent: the
  // trash icon is hidden and the row can't be deleted.
  final VoidCallback? onDelete;

  const _ExpenseRow({
    required this.expense,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Tapping the row opens the edit sheet; the inner delete GestureDetector
    // (opaque) swallows its own taps so deleting never also triggers an edit.
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: UgamCard.plain(
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
              Formatters.formatMoneyInr(expense.amount),
              style: UgamText.tabular(
                UgamText.bodyStrong.copyWith(color: c.ink),
              ),
            ),
            if (onDelete != null) ...[
              const SizedBox(width: UgamSpacing.sm),
              UgamIconButton(
                icon: Icons.delete_outline_rounded,
                tone: UgamIconButtonTone.danger,
                onTap: onDelete,
                semanticLabel: tr('bus_money.delete_expense_title'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The auto bus-owner rent shown at the top of the expense ledger. It mirrors
/// [_ExpenseRow] styling but is derived from [Bus.busPrice] (the single source
/// of truth, already folded into expensesTotal) — so it is non-deletable and
/// not editable.
class _BusOwnerRentRow extends StatelessWidget {
  final double busPrice;

  const _BusOwnerRentRow({required this.busPrice});

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
              ExpenseCategory.busOwner.displayName,
              style: UgamText.micro.copyWith(color: c.ink2),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              tr('bus_money.bus_owner_rent'),
              style: UgamText.bodyStrong.copyWith(color: c.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Text(
            Formatters.formatMoneyInr(busPrice),
            style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: c.ink)),
          ),
        ],
      ),
    );
  }
}

class _HandoverRow extends StatelessWidget {
  final BusHandover handover;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _HandoverRow({
    required this.handover,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Locale-aware date (month name follows app locale) + a stable AM/PM time.
    final date =
        '${Formatters.formatDateShort(handover.settledAt, locale: context.locale.languageCode)}, '
        '${DateFormat('h:mm a', 'en_US').format(handover.settledAt)}';
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: UgamCard.plain(
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
                    tr(
                      'bus_money.handed_of',
                      namedArgs: {
                        'handed': Formatters.formatMoneyInr(handover.handedOverAmount),
                        'expected': Formatters.formatMoneyInr(handover.expectedAmount),
                      },
                    ),
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(date, style: UgamText.caption.copyWith(color: c.ink2)),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            UgamIconButton(
              icon: Icons.delete_outline_rounded,
              tone: UgamIconButtonTone.danger,
              onTap: onDelete,
              semanticLabel: tr('bus_money.delete_handover_title'),
            ),
          ],
        ),
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
          Text(
            tr('bus_money.tour_totals'),
            style: UgamText.titleM.copyWith(color: c.ink),
          ),
          const SizedBox(height: UgamSpacing.md),
          _RollupRow(
            label: tr('bus_money.rollup_total_collected'),
            value: Formatters.formatMoneyInr(summary.totalCollected),
          ),
          _RollupRow(
            label: tr('bus_money.rollup_total_expenses'),
            value: Formatters.formatMoneyInr(summary.totalExpenses),
          ),
          _RollupRow(
            label: tr('bus_money.rollup_net'),
            value: Formatters.formatMoneyInr(summary.totalNet),
          ),
          _RollupRow(
            label: tr('bus_money.stat_outstanding'),
            value: Formatters.formatMoneyInr(summary.totalOutstandingHandover),
          ),
          _RollupRow(
            label: tr('bus_money.rollup_to_return'),
            value: Formatters.formatMoneyInr(summary.totalToReturn),
          ),
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
            style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: c.ink)),
          ),
        ],
      ),
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
          style: UgamText.tabular(UgamText.titleS.copyWith(color: c.ink)),
        ),
      ],
    );
  }
}
