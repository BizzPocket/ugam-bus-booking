import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../controllers/handler_controller.dart';
import '../../design/ugam.dart';
import '../../models/bus_details.dart';
import '../../models/bus_handover.dart';
import '../../models/collection.dart';
import '../../models/expense.dart';
import '../../models/handler_phase.dart';
import '../../models/income_entry.dart';
import '../../models/passenger.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/formatters.dart';
import '../../utils/passenger_display.dart';
import '../../utils/phone_dialer.dart';
import '../../utils/seat_money_state.dart';
import '../../utils/seat_occupants.dart';
import '../../widgets/handler/handler_collect_sheet.dart';
import '../../widgets/handler/handler_expense_section.dart';
import '../../widgets/handler/handler_income_section.dart';
import '../../widgets/handler/handler_money_hero.dart';
import '../../widgets/handler/handler_settlement.dart';

part 'handler_money_rows.dart';

/// Everything about cash, in one tab, in the order a handler needs it: what
/// they're holding, who still owes, what went out, what came in, what they owe
/// the agent.
///
/// Before this, collecting from a rider meant finding their seat on the grid —
/// there was no list of who still owed money, and the expense and income
/// ledgers were reachable only by scrolling past the seat chart in Grid view.
class HandlerMoneyTab extends StatefulWidget {
  final HandlerController controller;
  final Bus bus;

  /// Opens the handover sheet as soon as the tab mounts — the settle CTA on the
  /// phase banner routes here.
  final bool autoOpenSettle;

  const HandlerMoneyTab({
    super.key,
    required this.controller,
    required this.bus,
    this.autoOpenSettle = false,
  });

  @override
  State<HandlerMoneyTab> createState() => _HandlerMoneyTabState();
}

class _HandlerMoneyTabState extends State<HandlerMoneyTab> {
  HandlerController get c => widget.controller;

  /// Which riders the collect list shows.
  _MoneyFilter _filter = _MoneyFilter.due;

  @override
  void initState() {
    super.initState();
    if (widget.autoOpenSettle) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openHandoverSheet();
      });
    }
  }

  // ── Collect ───────────────────────────────────────────────

  /// One line per distinct seat a rider holds on this bus. A whole double sofa
  /// stored as two entries under one seat id collapses to ONE line, because
  /// `amountDueForSeat` already charges the full sofa — listing it twice would
  /// ask for the money twice.
  List<_CollectLine> _lines() {
    final occupants = occupantListForBus(
      c.manifest.value?.passengers ?? const [],
      widget.bus.id,
    );
    final lines = <_CollectLine>[];
    final seen = <String>{};
    occupants.forEach((seatId, riders) {
      for (final p in riders) {
        final key = '${p.id}|$seatId';
        if (!seen.add(key)) continue;
        final due = widget.bus.amountDueForSeat(p, seatId);
        final row = c.collectionFor(p, widget.bus.id, seatId);
        lines.add(
          _CollectLine(
            passenger: p,
            seatId: seatId,
            due: due,
            collection: row,
            state: riderMoneyStateOf(due, row),
            claimedOnline: c.pendingClaimedFor(p.id),
          ),
        );
      }
    });
    lines.sort((a, b) {
      // Money owing first — that is what the handler is walking the aisle for.
      final ra = a.state == SeatMoneyState.paid ? 1 : 0;
      final rb = b.state == SeatMoneyState.paid ? 1 : 0;
      if (ra != rb) return ra.compareTo(rb);
      return a.passenger.displayName.toLowerCase().compareTo(
        b.passenger.displayName.toLowerCase(),
      );
    });
    return lines;
  }

  Future<void> _openCollect(_CollectLine line) async {
    await UgamSheet.show<bool>(
      context,
      title: tr('handler_chart.collect_title'),
      builder: (_) => HandlerCollectSheet(
        passenger: line.passenger,
        seatId: line.seatId,
        due: line.due,
        existing: line.collection,
        claims: c.claimsFor(line.passenger.id),
        onSave: (received, returned, collectedBy, note) => c.saveCollection(
          bus: widget.bus,
          passenger: line.passenger,
          seatId: line.seatId,
          due: line.due,
          received: received,
          manualReturned: returned,
          collectedBy: collectedBy,
          note: note,
        ),
      ),
    );
  }

  // ── Ledgers ───────────────────────────────────────────────

  Future<void> _openExpense({Expense? existing}) async {
    final draftId = c.newDraftId();
    await UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('handler_chart.add_expense')
          : tr('handler_chart.edit_expense'),
      builder: (_) => HandlerExpenseSheet(
        existing: existing,
        onSave: (category, label, amount, paidBy) => c.saveExpense(
          bus: widget.bus,
          draftId: draftId,
          existing: existing,
          category: category,
          label: label,
          amount: amount,
          paidBy: paidBy,
        ),
      ),
    );
  }

  Future<void> _deleteExpense(Expense e) async {
    final ok = await UgamDialog.confirm(
      context,
      title: tr('handler_chart.delete_expense_title'),
      message: e.label.isEmpty
          ? tr(
              'handler_chart.delete_expense_msg_category',
              namedArgs: {
                'category': e.category.displayName.toLowerCase(),
                'amount': Formatters.formatMoneyInr(e.amount),
              },
            )
          : tr(
              'handler_chart.delete_expense_msg_label',
              namedArgs: {
                'label': e.label,
                'amount': Formatters.formatMoneyInr(e.amount),
              },
            ),
      confirmLabel: tr('app.action.delete'),
      destructive: true,
    );
    if (ok != true) return;
    await _deleteOrToast(
      () => c.deleteExpense(e),
      'handler_chart.error_delete_expense',
    );
  }

  Future<void> _openIncome({IncomeEntry? existing}) async {
    final draftId = c.newDraftId();
    await UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('handler_chart.add_income')
          : tr('handler_chart.edit_income'),
      builder: (_) => HandlerIncomeSheet(
        existing: existing,
        onSave: (category, label, amount, receivedBy) => c.saveIncome(
          bus: widget.bus,
          draftId: draftId,
          existing: existing,
          category: category,
          label: label,
          amount: amount,
          receivedBy: receivedBy,
        ),
      ),
    );
  }

  Future<void> _deleteIncome(IncomeEntry i) async {
    final ok = await UgamDialog.confirm(
      context,
      title: tr('handler_chart.delete_income_title'),
      message: i.label.isEmpty
          ? tr(
              'handler_chart.delete_income_msg_category',
              namedArgs: {
                'category': i.category.displayName.toLowerCase(),
                'amount': Formatters.formatMoneyInr(i.amount),
              },
            )
          : tr(
              'handler_chart.delete_income_msg_label',
              namedArgs: {
                'label': i.label,
                'amount': Formatters.formatMoneyInr(i.amount),
              },
            ),
      confirmLabel: tr('app.action.delete'),
      destructive: true,
    );
    if (ok != true) return;
    await _deleteOrToast(
      () => c.deleteIncome(i),
      'handler_chart.error_delete_income',
    );
  }

  /// Runs a ledger delete; a refusal (false) and a throw both toast [errorKey].
  Future<void> _deleteOrToast(
    Future<bool> Function() delete,
    String errorKey,
  ) async {
    try {
      if (!await delete()) AppSnackBar.error(tr(errorKey));
    } catch (_) {
      AppSnackBar.error(tr(errorKey));
    }
  }

  // ── Settlement ────────────────────────────────────────────

  /// Public so the shell's settle CTA can drive it straight from the banner.
  Future<void> openHandoverSheet() async {
    final summary = c.summaryFor(widget.bus);
    // Minted ONCE per sheet, not per save attempt: the RPCs honour the client
    // id and conflict only on (id), so a fresh id per retry turned a lost
    // response into a second INSERT the ledger sync then double-posted.
    final draftId = c.newDraftId();
    await UgamSheet.show<void>(
      context,
      title: tr('handler_chart.handover_title'),
      builder: (_) => HandlerHandoverSheet(
        expected: summary.outstanding,
        onSave: (amount, note) => c.saveHandover(
          bus: widget.bus,
          draftId: draftId,
          // What this row was EXPECTED to settle, which is what is still owed
          // right now — the same figure the sheet pre-fills and asks for. It
          // used to persist `inHand`, the GROSS the bus generated: identical on
          // a first handover (nothing handed over yet), but on every LATER
          // partial it re-recorded money already remitted, so the admin's
          // ledger read "handed ₹5,000 of ₹20,000" (`bus_money.handed_of`,
          // bus_money_screen.dart:1316) on a row that only ever owed ₹15,000,
          // and `BusHandover.shortfall` overstated the gap by the earlier
          // handover. Cash totals are untouched: outstanding is computed from
          // `handedOverAmount`, and the ledger trigger posts that column alone
          // (062_ledger_write_through.sql:311-321).
          expected: summary.outstanding,
          amount: amount,
          note: note,
        ),
      ),
    );
  }

  Future<void> _deleteHandover(BusHandover h) async {
    final ok = await UgamDialog.confirm(
      context,
      title: tr('handler_chart.handover_delete_title'),
      message: tr(
        'handler_chart.handover_delete_body',
        namedArgs: {'amount': Formatters.formatMoneyInr(h.handedOverAmount)},
      ),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('app.action.delete'),
      confirmIcon: Icons.delete_outline_rounded,
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      if (!await c.deleteHandover(h)) {
        AppSnackBar.error(tr('handler_chart.handover_failed'));
      }
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('handler_chart.handover_failed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = UgamColors.of(context);
    return Obx(() {
      final summary = c.summaryFor(widget.bus);
      final all = _lines();
      final shown = all.where(_filter.matches).toList();

      return ListView(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.md,
          UgamSpacing.gutter,
          UgamSpacing.huge3,
        ),
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        children: [
          HandlerMoneyHero(
            collected: summary.collected,
            toReturn: summary.toReturn,
            toCollect: summary.toCollect,
            spent: summary.spent,
            income: summary.income,
            inHand: summary.inHand,
            handedOver: summary.handedOver,
            outstanding: summary.outstanding,
            settled: summary.isSettled,
          ),
          const SizedBox(height: UgamSpacing.lg),

          UgamSectionLabel(tr('handler_chart.collect_section')),
          const SizedBox(height: UgamSpacing.sm),
          UgamSelectorPills(
            items: [
              for (final f in _MoneyFilter.values)
                UgamSelectorItem(label: f.label),
            ],
            currentIndex: _MoneyFilter.values.indexOf(_filter),
            onChanged: (i) => setState(() => _filter = _MoneyFilter.values[i]),
          ),
          const SizedBox(height: UgamSpacing.sm),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
              child: Center(
                child: Text(
                  all.isEmpty
                      ? tr('handler_chart.no_passengers_on_bus')
                      : tr('collection.empty_no_match'),
                  style: UgamText.caption.copyWith(color: colors.ink2),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            for (final line in shown)
              _CollectRow(
                line: line,
                c: colors,
                // Under the "to collect" filter every row is uncollected or
                // part-paid by definition, so a "● To collect" status line
                // just repeats the selected pill.
                inDueFilter: _filter == _MoneyFilter.due,
                onTap: () => _openCollect(line),
              ),

          const SizedBox(height: UgamSpacing.xl),
          HandlerExpensesSection(
            busName: widget.bus.name,
            expenses: c.expensesForBus(widget.bus.id),
            onAdd: _openExpense,
            onEdit: (e) => _openExpense(existing: e),
            onDelete: _deleteExpense,
          ),
          const SizedBox(height: UgamSpacing.xl),
          HandlerIncomeSection(
            busName: widget.bus.name,
            incomes: c.incomesForBus(widget.bus.id),
            onAdd: _openIncome,
            onEdit: (i) => _openIncome(existing: i),
            onDelete: _deleteIncome,
          ),
          const SizedBox(height: UgamSpacing.xl),
          HandlerSettlementCard(
            summary: summary,
            handovers: c.handoversForBus(widget.bus.id),
            c: colors,
            onSettle: openHandoverSheet,
            onDelete: _deleteHandover,
            canRecord: c.phaseForBus(widget.bus) != HandlerPhase.boardingGo,
          ),
        ],
      );
    });
  }
}
