import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/bus_handover.dart';
import '../models/expense.dart';
import '../models/income_entry.dart';
import '../models/money_summary.dart';
import '../models/tour.dart';
import '../utils/formatters.dart';
import '../widgets/money_loading_skeleton.dart';
import 'collection_screen.dart';

part 'bus_money/bus_money_sheets.dart';
part 'bus_money/bus_money_cards.dart';
part 'bus_money/bus_money_rows.dart';

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

  /// The CURRENT bus row, re-resolved from [TourController] on every build.
  ///
  /// [widget.bus] is a snapshot taken when this screen was pushed. The money
  /// summaries read the owner's rent live (via `MoneyController._busRents()`),
  /// so rendering the rent ledger row from the snapshot let the two disagree
  /// the moment a rent was edited elsewhere — the ledger showed the old figure
  /// while the Expenses tile totalled the new one. Falls back to the snapshot
  /// when the tour/controller isn't resolvable, so this never renders nothing.
  Bus get _liveBus {
    if (!Get.isRegistered<TourController>()) return widget.bus;
    final tour = Get.find<TourController>().getTour(widget.tour.id);
    return tour?.buses.firstWhereOrNull((b) => b.id == widget.bus.id) ??
        widget.bus;
  }

  /// True only when the money load failed AND nothing is already held to keep —
  /// so a transient read failure shows a retry instead of an all-zero cockpit.
  /// Reads the money obs inside the calling [Obx], so a successful retry
  /// re-renders it.
  bool get _showLoadError =>
      controller.loadFailed.value &&
      controller.collections.isEmpty &&
      controller.expenses.isEmpty &&
      controller.handovers.isEmpty &&
      controller.incomes.isEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.loadForTour(widget.tour.id);
    });
  }

  /// Who the bus's "detached" cash was taken from — riders with a collection on
  /// THIS bus who hold no seat here any more (moved to another bus, or
  /// unseated). Mirrors [BusMoneySummary.detachedCash]'s rule exactly, so the
  /// amount above and the names below can never disagree. Deduped, in roster
  /// order; a payer who has since been removed from the tour falls back to a
  /// generic label rather than being silently dropped.
  List<String> _detachedPayerNames() {
    final passengers = widget.tour.passengers;
    final seatedHere = <String>{
      for (final p in passengers)
        if (p.assignedSeats.any((a) => a.busId == widget.bus.id)) p.id,
    };
    final names = <String>[];
    final seen = <String>{};
    for (final c in controller.collections) {
      if (c.busId != widget.bus.id) continue;
      if (seatedHere.contains(c.passengerId)) continue;
      if (!seen.add(c.passengerId)) continue;
      final p = passengers.firstWhereOrNull((p) => p.id == c.passengerId);
      final n = p?.name.trim() ?? '';
      names.add(n.isEmpty ? tr('bus_money.detached_unknown_rider') : n);
    }
    return names;
  }

  @override
  Widget build(BuildContext context) {
    return UgamScaffold(
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
                if (controller.isLoading.value &&
                    !controller.loadedOnce.value) {
                  return const MoneyLoadingSkeleton();
                }
                // A failed load leaves the money lists empty; show the shared
                // retry rather than a ₹0 cockpit that reads as a settled bus.
                if (_showLoadError) {
                  return UgamEmpty.error(
                    onRetry: () => controller.loadForTour(widget.tour.id),
                  );
                }

                final s = controller.summaryForBus(widget.bus.id);
                final expenses = controller.expenses
                    .where((e) => e.busId == widget.bus.id)
                    .toList();
                final handovers = controller.handovers
                    .where((h) => h.busId == widget.bus.id)
                    .toList();
                final incomes = controller.incomes
                    .where((i) => i.busId == widget.bus.id)
                    .toList();
                final t = controller.tourSummary();

                return Stack(
                  children: [
                    RefreshIndicator(
                      // Chrome, not ownership — the pull spinner is neutral
                      // ink2 in every screen, so it never changes hue between
                      // tabs. (Unset used to mean `colorScheme.primary`, i.e.
                      // the accent; there is no theme hook for a spinner.)
                      color: UgamColors.of(context).ink2,
                      onRefresh: () =>
                          controller.refreshForTour(widget.tour.id),
                      child: ListView(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(
                          UgamSpacing.gutter,
                          UgamSpacing.lg,
                          UgamSpacing.gutter,
                          UgamSpacing.dockClearance,
                        ),
                        children: [
                          // ── Hero figure: the ONE action number ─────────────
                          // Outstanding handover leads as a large tabular figure —
                          // it's what the agent must act on. Everything else is
                          // demoted to a quiet supporting row below.
                          _OutstandingHero(
                            // Clamp the *displayed* settlement figure at 0: the
                            // handover is rent-free (the admin settles the owner),
                            // but heavy ground spending before collections land can
                            // still take it negative, and "-30000 owed" is nonsense
                            // to show. Underlying net math is untouched.
                            amount: s.outstandingHandover < 0
                                ? 0.0
                                : s.outstandingHandover,
                            expected: s.expectedHandover < 0
                                ? 0.0
                                : s.expectedHandover,
                          ),
                          const SizedBox(height: UgamSpacing.xl),
                          _statTiles(s),
                          // Why the collected figure can exceed what this bus
                          // billed: cash stays with the bus that took it, while
                          // billed revenue follows whoever is seated NOW. Named
                          // here (the ledger is where the agent comes to ask
                          // "whose money is this?"), not just totalled.
                          if (s.detachedCash.abs() > 0.005) ...[
                            const SizedBox(height: UgamSpacing.md),
                            _DetachedCashCard(
                              amount: s.detachedCash,
                              names: _detachedPayerNames(),
                            ),
                          ],
                          const SizedBox(height: UgamSpacing.xl),

                          // The "Collect from passengers" jump now lives in the
                          // sticky bottom CTA (thumb-zone); the ledger scrolls under
                          // it thanks to the dockClearance bottom padding above.
                          ..._expensesSection(context, s, expenses),
                          const SizedBox(height: UgamSpacing.xl),
                          ..._incomeSection(context, incomes),
                          const SizedBox(height: UgamSpacing.xl),
                          ..._handoverSection(context, s, handovers),
                          const SizedBox(height: UgamSpacing.xl),

                          // ── Tour rollup ────────────────────────────────────
                          _TourRollupCard(summary: t),
                        ],
                      ),
                    ),
                    // ── Sticky thumb-zone CTA ──────────────────────────
                    // The screen's single solid-copper focal action: jump to
                    // per-passenger collection. Ledger scrolls under it.
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: UgamStickyCTA(
                        child: UgamCTA(
                          label: tr('bus_money.collect_from_passengers'),
                          leadingIcon: Icons.groups_rounded,
                          onPressed: () => Get.to(
                            () => CollectionScreen(
                              tour: widget.tour,
                              bus: widget.bus,
                            ),
                            transition: Transition.cupertino,
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  // ── Supporting stat grid (demoted) ─────────────────
  // Income only earns a tile once there IS extra income —
  // otherwise it's a ₹0 filler tile (§A3). Compact (₹1.2L)
  // values so large INR figures never blow out tile height.
  Widget _statTiles(BusMoneySummary s) {
    final tiles = <Widget>[
      Expanded(
        child: UgamStatTile(
          icon: Icons.payments_rounded,
          value: Formatters.formatMoneyInrCompact(s.collected),
          label: tr('bus_money.stat_collected'),
          variant: UgamStatVariant.good,
        ),
      ),
      if (s.income > 0.005)
        Expanded(
          child: UgamStatTile(
            icon: Icons.savings_rounded,
            value: Formatters.formatMoneyInrCompact(s.income),
            label: tr('bus_money.stat_income'),
            variant: UgamStatVariant.good,
          ),
        ),
      Expanded(
        child: UgamStatTile(
          icon: Icons.receipt_long_rounded,
          value: Formatters.formatMoneyInrCompact(s.expensesTotal),
          label: tr('bus_money.stat_expenses'),
          variant: UgamStatVariant.warm,
        ),
      ),
    ];
    return Row(
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: UgamSpacing.md),
          tiles[i],
        ],
      ],
    );
  }

  // ── Expenses ───────────────────────────────────────
  List<Widget> _expensesSection(
    BuildContext context,
    BusMoneySummary s,
    List<Expense> expenses,
  ) {
    return [
      _SectionHeader(
        title: tr('bus_money.section_expenses'),
        actionLabel: tr('app.action.add'),
        onAction: () => _openExpenseSheet(context),
      ),
      const SizedBox(height: UgamSpacing.sm),
      // The auto bus-owner rent is derived from the bus (the
      // single source of truth, already inside expensesTotal) —
      // so it counts as content for the empty check. Read
      // LIVE (not from the pushed snapshot) so this row can
      // never contradict the Expenses tile above it.
      if (_liveBus.busPrice <= 0 &&
          expenses.isEmpty &&
          s.fuelTotal <= 0 &&
          s.driverTotal <= 0 &&
          s.ownerAdvanceTotal <= 0)
        _sectionEmpty(
          Icons.receipt_long_rounded,
          tr('bus_money.expenses_empty'),
        )
      else ...[
        if (_liveBus.busPrice > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: UgamSpacing.md),
            child: _BusMalikSettlementCard(bus: _liveBus, summary: s),
          ),
        ...expenses
            .where((e) => !_rollupExpenseInMalikCard(e, s))
            .map(
              // Swipe-left to delete; tap still opens the edit
              // sheet. Money records are irreversible, so the
              // destructive swipe is gated by a confirm.
              (e) => _swipeDeleteRow(
                context,
                key: ValueKey('expense-${e.id}'),
                titleKey: 'bus_money.delete_expense_title',
                bodyKey: 'bus_money.delete_expense_body',
                delete: () => controller.deleteExpense(e.id),
                child: _ExpenseRow(
                  expense: e,
                  onTap: () => _openExpenseSheet(context, existing: e),
                ),
              ),
            ),
      ],
    ];
  }

  // ── Extra income ───────────────────────────────────
  // Handler logs Cabin/Gallery/Other extra cash on the
  // ground. The admin can now add/edit/delete it here
  // too: income feeds the handover expectation and both
  // profit figures, so leaving it handler-write-only
  // meant a mistyped entry was permanently uncorrectable
  // from the admin side.
  List<Widget> _incomeSection(BuildContext context, List<IncomeEntry> incomes) {
    return [
      _SectionHeader(
        title: tr('bus_money.section_income'),
        actionLabel: tr('app.action.add'),
        onAction: () => _openIncomeSheet(context),
      ),
      const SizedBox(height: UgamSpacing.sm),
      if (incomes.isEmpty)
        _sectionEmpty(Icons.savings_outlined, tr('bus_money.income_empty'))
      else
        ...incomes.map(
          // Same swipe-to-delete + tap-to-edit idiom as
          // the expense rows directly above.
          (i) => _swipeDeleteRow(
            context,
            key: ValueKey('income-${i.id}'),
            titleKey: 'bus_money.delete_income_title',
            bodyKey: 'bus_money.delete_income_body',
            delete: () => controller.deleteIncome(i.id),
            child: _IncomeRow(
              income: i,
              onTap: () => _openIncomeSheet(context, existing: i),
            ),
          ),
        ),
    ];
  }

  // ── Handover ───────────────────────────────────────
  List<Widget> _handoverSection(
    BuildContext context,
    BusMoneySummary s,
    List<BusHandover> handovers,
  ) {
    return [
      _SectionHeader(
        title: tr('bus_money.section_handover_to_admin'),
        actionLabel: tr('bus_money.action_record'),
        // What this NEW row is expected to settle: what is
        // still owed right now, not the GROSS the bus
        // generated. Identical on a FIRST handover (nothing
        // handed over yet, so outstanding == expected), and
        // divergent on every partial after it — where the
        // gross re-recorded money the admin already holds,
        // so the row below then read "Handed ₹5,000 of
        // ₹20,000" (`bus_money.handed_of`, in _HandoverRow) on a
        // row that only ever owed ₹15,000. The same correction
        // the handler's own sheet took
        // (handler_money_tab.dart:270). No cash figure
        // moves: `outstandingHandover` is derived from
        // `handedOver`, and the ledger trigger posts
        // `handed_over_amount` alone
        // (062_ledger_write_through.sql:311-321).
        onAction: () => _openHandoverSheet(context, s.outstandingHandover),
      ),
      const SizedBox(height: UgamSpacing.sm),
      if (handovers.isEmpty)
        _sectionEmpty(
          Icons.account_balance_rounded,
          tr('bus_money.handover_empty'),
        )
      else
        ...handovers.map(
          // Swipe-left to delete; tap still opens the edit
          // sheet. Irreversible record — gated by a confirm.
          (h) => _swipeDeleteRow(
            context,
            key: ValueKey('handover-${h.id}'),
            titleKey: 'bus_money.delete_handover_title',
            bodyKey: 'bus_money.delete_handover_body',
            delete: () => controller.deleteHandover(h.id),
            child: _HandoverRow(
              handover: h,
              onTap: () =>
                  _openHandoverSheet(context, h.expectedAmount, existing: h),
            ),
          ),
        ),
    ];
  }

  /// The empty state every ledger section shows when it has no rows.
  Widget _sectionEmpty(IconData icon, String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
      child: UgamEmpty(icon: icon, title: title),
    );
  }

  /// One ledger row behind the shared swipe-left-to-delete gesture, gated by a
  /// destructive confirm (money records are irreversible).
  ///
  /// [delete] is awaited and its error swallowed: the controller already rolls
  /// back and shows an error toast on failure; without this the rethrow
  /// becomes an uncaught async exception.
  Widget _swipeDeleteRow(
    BuildContext context, {
    required Key key,
    required String titleKey,
    required String bodyKey,
    required Future<void> Function() delete,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: UgamSwipeAction(
        key: key,
        confirmDelete: () => UgamDialog.confirm(
          context,
          title: tr(titleKey),
          message: tr(bodyKey),
          cancelLabel: tr('app.action.cancel'),
          confirmLabel: tr('bus_money.delete_confirm'),
          destructive: true,
          confirmIcon: Icons.delete_outline_rounded,
        ),
        onDelete: () async {
          try {
            await delete();
          } catch (_) {}
        },
        child: child,
      ),
    );
  }
}
