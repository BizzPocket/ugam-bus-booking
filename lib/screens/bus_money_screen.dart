import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
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

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
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
                            // Clamp the *displayed* settlement figure at 0: before
                            // collections cover the bus rent the net can be
                            // negative, but a handler never pays rent out of pocket
                            // before collecting, so "-30000 owed" is nonsense to
                            // show. Underlying net math is untouched.
                            amount: s.outstandingHandover < 0
                                ? 0.0
                                : s.outstandingHandover,
                            expected: s.expectedHandover < 0
                                ? 0.0
                                : s.expectedHandover,
                          ),
                          const SizedBox(height: UgamSpacing.xl),
                          // ── Supporting stat grid (demoted) ─────────────────
                          // Income only earns a tile once there IS extra income —
                          // otherwise it's a ₹0 filler tile (§A3). Compact (₹1.2L)
                          // values so large INR figures never blow out tile height.
                          Builder(
                            builder: (_) {
                              final tiles = <Widget>[
                                Expanded(
                                  child: UgamStatTile(
                                    icon: Icons.payments_rounded,
                                    value: Formatters.formatMoneyInrCompact(
                                      s.collected,
                                    ),
                                    label: tr('bus_money.stat_collected'),
                                    variant: UgamStatVariant.good,
                                  ),
                                ),
                                if (s.income > 0.005)
                                  Expanded(
                                    child: UgamStatTile(
                                      icon: Icons.savings_rounded,
                                      value: Formatters.formatMoneyInrCompact(
                                        s.income,
                                      ),
                                      label: tr('bus_money.stat_income'),
                                      variant: UgamStatVariant.good,
                                    ),
                                  ),
                                Expanded(
                                  child: UgamStatTile(
                                    icon: Icons.receipt_long_rounded,
                                    value: Formatters.formatMoneyInrCompact(
                                      s.expensesTotal,
                                    ),
                                    label: tr('bus_money.stat_expenses'),
                                    variant: UgamStatVariant.warm,
                                  ),
                                ),
                              ];
                              return Row(
                                children: [
                                  for (var i = 0; i < tiles.length; i++) ...[
                                    if (i > 0)
                                      const SizedBox(width: UgamSpacing.md),
                                    tiles[i],
                                  ],
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: UgamSpacing.xl),

                          // The "Collect from passengers" jump now lives in the
                          // sticky bottom CTA (thumb-zone); the ledger scrolls under
                          // it thanks to the dockClearance bottom padding above.

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
                                // Swipe-left to delete; tap still opens the edit
                                // sheet. Money records are irreversible, so the
                                // destructive swipe is gated by a confirm.
                                child: UgamSwipeAction(
                                  key: ValueKey('expense-${e.id}'),
                                  confirmDelete: () => UgamDialog.confirm(
                                    context,
                                    title: tr('bus_money.delete_expense_title'),
                                    message: tr(
                                      'bus_money.delete_expense_body',
                                    ),
                                    cancelLabel: tr('app.action.cancel'),
                                    confirmLabel: tr(
                                      'bus_money.delete_confirm',
                                    ),
                                    destructive: true,
                                    confirmIcon: Icons.delete_outline_rounded,
                                  ),
                                  // await + swallow: the controller already rolls
                                  // back and shows an error toast on failure;
                                  // without this the rethrow becomes an uncaught
                                  // async exception.
                                  onDelete: () async {
                                    try {
                                      await controller.deleteExpense(e.id);
                                    } catch (_) {}
                                  },
                                  child: _ExpenseRow(
                                    expense: e,
                                    onTap: () =>
                                        _openExpenseSheet(context, existing: e),
                                  ),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: UgamSpacing.xl),

                          // ── Extra income (read-only) ───────────────────────
                          // Handler logs Cabin/Gallery/Other extra cash on the
                          // ground; the admin only views it here (no add/edit).
                          Text(
                            tr('bus_money.section_income'),
                            style: UgamText.titleM.copyWith(color: c.ink),
                          ),
                          const SizedBox(height: UgamSpacing.sm),
                          if (incomes.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: UgamSpacing.lg,
                              ),
                              child: UgamEmpty(
                                icon: Icons.savings_outlined,
                                title: tr('bus_money.income_empty'),
                              ),
                            )
                          else
                            ...incomes.map(
                              (i) => Padding(
                                padding: const EdgeInsets.only(
                                  bottom: UgamSpacing.sm,
                                ),
                                child: _IncomeRow(income: i),
                              ),
                            ),
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
                                // Swipe-left to delete; tap still opens the edit
                                // sheet. Irreversible record — gated by a confirm.
                                child: UgamSwipeAction(
                                  key: ValueKey('handover-${h.id}'),
                                  confirmDelete: () => UgamDialog.confirm(
                                    context,
                                    title: tr(
                                      'bus_money.delete_handover_title',
                                    ),
                                    message: tr(
                                      'bus_money.delete_handover_body',
                                    ),
                                    cancelLabel: tr('app.action.cancel'),
                                    confirmLabel: tr(
                                      'bus_money.delete_confirm',
                                    ),
                                    destructive: true,
                                    confirmIcon: Icons.delete_outline_rounded,
                                  ),
                                  onDelete: () async {
                                    try {
                                      await controller.deleteHandover(h.id);
                                    } catch (_) {}
                                  },
                                  child: _HandoverRow(
                                    handover: h,
                                    onTap: () => _openHandoverSheet(
                                      context,
                                      h.expectedAmount,
                                      existing: h,
                                    ),
                                  ),
                                ),
                              ),
                            ),
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

  void _openExpenseSheet(BuildContext context, {Expense? existing}) {
    ExpenseCategory category = existing?.category ?? ExpenseCategory.other;
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final paidByCtrl = TextEditingController(text: existing?.paidBy ?? '');

    // Numpad-first money entry: a giant tabular amount up top, category as a
    // pill rail above it, and the label + paid-by tucked behind a collapsed
    // "Details" expander (progressive disclosure). The save call is unchanged.
    UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('bus_money.add_expense')
          : tr('bus_money.edit_expense'),
      builder: (sheetCtx) {
        return _ExpenseSheetBody(
          initialCategory: category,
          initialAmount: existing?.amount,
          labelCtrl: labelCtrl,
          paidByCtrl: paidByCtrl,
          onCategory: (c) => category = c,
          confirmLabel: tr('bus_money.save_expense'),
          onConfirm: (amount) async {
            final paidBy = paidByCtrl.text.trim();
            final label = labelCtrl.text.trim();
            // Editing reuses the same id (an update, not a new row) by going
            // through copyWith, which preserves id/createdAt.
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
          },
        );
      },
    );
  }

  void _openHandoverSheet(
    BuildContext context,
    double expected, {
    BusHandover? existing,
  }) {
    // Whole-rupee seed: dues are rounded at source, so pre-fill the full
    // whole-rupee figure. Rounding (not truncating) a fractional expected is
    // belt-and-suspenders — it avoids a stuck sub-rupee residual that would
    // read as "not fully settled". Clamp at 0: a handler never hands over a
    // negative figure (i.e. pays the owner's rent out of pocket) before
    // collecting.
    final seed = existing?.handedOverAmount ?? (expected < 0 ? 0.0 : expected);
    final handedCtrl = TextEditingController(text: seed.round().toString());
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

/// Numpad-first body for the add/edit-expense sheet. Category pills ride at the
/// very top; a live [UgamAmountHero] + [UgamNumpad] own the middle; the label
/// and paid-by inputs hide behind a collapsed "Details" [UgamExpander]; a
/// sticky [UgamCTA] saves. The category selection is reported back to the
/// caller via [onCategory] so the unchanged controller call can read it.
class _ExpenseSheetBody extends StatefulWidget {
  final ExpenseCategory initialCategory;
  final double? initialAmount;
  final TextEditingController labelCtrl;
  final TextEditingController paidByCtrl;
  final ValueChanged<ExpenseCategory> onCategory;
  final String confirmLabel;
  final Future<void> Function(double amount) onConfirm;

  const _ExpenseSheetBody({
    required this.initialCategory,
    required this.initialAmount,
    required this.labelCtrl,
    required this.paidByCtrl,
    required this.onCategory,
    required this.confirmLabel,
    required this.onConfirm,
  });

  @override
  State<_ExpenseSheetBody> createState() => _ExpenseSheetBodyState();
}

class _ExpenseSheetBodyState extends State<_ExpenseSheetBody> {
  // busOwner is excluded: the bus rent is the single source of truth
  // (Bus.busPrice) and must never be added manually, or it double-counts.
  final List<ExpenseCategory> _cats = ExpenseCategory.values
      .where((c) => c != ExpenseCategory.busOwner)
      .toList();

  late ExpenseCategory _category = widget.initialCategory;
  late final ValueNotifier<String> _value = ValueNotifier<String>(_seed());

  String _seed() {
    final init = widget.initialAmount;
    if (init == null || init == 0) return '';
    if (init == init.roundToDouble()) return init.toInt().toString();
    return init.toString();
  }

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final selected = _cats.indexOf(_category);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr('bus_money.field_category'),
            style: UgamText.micro.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamSelectorPills(
            padding: EdgeInsets.zero,
            items: _cats
                .map((cat) => UgamSelectorItem(label: cat.displayName))
                .toList(),
            currentIndex: selected < 0 ? 0 : selected,
            onChanged: (i) {
              setState(() => _category = _cats[i]);
              widget.onCategory(_cats[i]);
            },
          ),
          const SizedBox(height: UgamSpacing.xl),
          ValueListenableBuilder<String>(
            valueListenable: _value,
            builder: (context, v, child) => UgamAmountHero(
              amount: v.isEmpty ? '0' : v,
              label: tr('bus_money.field_amount'),
            ),
          ),
          const SizedBox(height: UgamSpacing.xl),
          UgamNumpad(value: _value, allowDecimal: true),
          const SizedBox(height: UgamSpacing.lg),
          UgamExpander(
            title: tr('bus_money.expense_details'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UgamInput(
                  label: tr('bus_money.field_label'),
                  controller: widget.labelCtrl,
                ),
                const SizedBox(height: UgamSpacing.md),
                UgamInput(
                  label: tr('bus_money.field_paid_by'),
                  controller: widget.paidByCtrl,
                ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.xl),
          ValueListenableBuilder<String>(
            valueListenable: _value,
            builder: (context, v, child) {
              final amount = double.tryParse(v) ?? 0;
              return UgamCTA(
                label: widget.confirmLabel,
                onPressed: amount > 0
                    ? () async {
                        await widget.onConfirm(amount);
                        if (context.mounted) Navigator.of(context).pop();
                      }
                    : null,
              );
            },
          ),
        ],
      ),
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
    // Within-rupee residual reads as fully handed over: once dues are whole
    // rupees a handover of expected.round() may leave a sub-rupee remainder
    // that should still settle the tile to a calm `good` tone.
    final settled = amount.abs() < 0.5;
    final figureColor = settled ? c.good : c.accent;
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.lg,
      ),
      child: Column(
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
          const SizedBox(height: UgamSpacing.sm),
          // The screen's single focal figure — a big Sora number set over a
          // soft copper halo. Sized for the cockpit, not a showroom (§A5).
          SizedBox(
            height: 72,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [c.glow, c.glow.withValues(alpha: 0)],
                      stops: const [0.0, 0.7],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.lg,
                  ),
                  // Scale the focal figure down (never ellipsize) so lakh/crore
                  // amounts stay fully legible — mirrors trip_pnl's
                  // _TripTotalCard.
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      Formatters.formatMoneyInr(amount),
                      style: UgamText.tabular(
                        UgamText.hero.copyWith(
                          color: figureColor,
                          fontSize: 38,
                        ),
                      ),
                      maxLines: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.sm),
          // Expected handover sits beneath as quiet context.
          Text(
            tr('bus_money.stat_expected_handover').toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            Formatters.formatMoneyInr(expected),
            style: UgamText.tabular(UgamText.numLg.copyWith(color: c.ink2)),
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

  const _ExpenseRow({required this.expense, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Tapping the row opens the edit sheet; delete is a swipe-left gesture
    // owned by the enclosing UgamSwipeAction.
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: UgamCard.plain(
        radius: UgamRadius.row,
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
      radius: UgamRadius.row,
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

/// A single handler-entered income entry, shown read-only on the admin's
/// money screen. Mirrors [_ExpenseRow] styling but has no edit/delete — the
/// handler logs this extra cash (Cabin/Gallery/Other) on the ground.
class _IncomeRow extends StatelessWidget {
  final IncomeEntry income;

  const _IncomeRow({required this.income});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final receivedBy = income.receivedBy?.trim() ?? '';
    final label = income.label.isEmpty
        ? income.category.displayName
        : income.label;
    return UgamCard.plain(
      radius: UgamRadius.row,
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
              income.category.displayName,
              style: UgamText.micro.copyWith(color: c.ink2),
            ),
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
                if (receivedBy.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    receivedBy,
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
        ],
      ),
    );
  }
}

class _HandoverRow extends StatelessWidget {
  final BusHandover handover;
  final VoidCallback onTap;

  const _HandoverRow({required this.handover, required this.onTap});

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
        radius: UgamRadius.row,
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
                        'handed': Formatters.formatMoneyInr(
                          handover.handedOverAmount,
                        ),
                        'expected': Formatters.formatMoneyInr(
                          handover.expectedAmount,
                        ),
                      },
                    ),
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(date, style: UgamText.caption.copyWith(color: c.ink2)),
                ],
              ),
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
    // The whole tour rollup collapses into ONE hero: NET is the big figure;
    // the six component lines hide behind the chevron (progressive disclosure).
    final net = summary.totalNet;
    final netTone = net < -0.005 ? c.warm : c.good;
    return UgamHeroStat(
      label: tr('bus_money.tour_totals'),
      value: Formatters.formatMoneyInr(net),
      tone: netTone,
      secondary: tr('bus_money.rollup_net_caption'),
      breakdown: [
        HeroStatLine(
          tr('bus_money.rollup_total_collected'),
          Formatters.formatMoneyInr(summary.totalCollected),
          tone: c.good,
        ),
        HeroStatLine(
          tr('bus_money.rollup_total_income'),
          Formatters.formatMoneyInr(summary.totalIncome),
          tone: c.good,
        ),
        HeroStatLine(
          tr('bus_money.rollup_total_expenses'),
          Formatters.formatMoneyInr(summary.totalExpenses),
          tone: c.warm,
        ),
        HeroStatLine(
          tr('bus_money.stat_outstanding'),
          Formatters.formatMoneyInr(summary.totalOutstandingHandover),
        ),
        HeroStatLine(
          tr('bus_money.rollup_to_return'),
          Formatters.formatMoneyInr(summary.totalToReturn),
        ),
      ],
    );
  }
}

/// The "due" billboard shown at the top of the handover sheet: a tinted accent
/// card with a small caps label over a large tabular figure — the number the
/// agent is settling against. Replaces the thin label/value line.
class _ReadOnlyLine extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamCard.plain(
      tone: UgamCardTone.accent,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.lg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label.toUpperCase(),
            style: UgamText.micro.copyWith(color: c.accent),
          ),
          const SizedBox(width: UgamSpacing.md),
          Flexible(
            child: Text(
              value,
              style: UgamText.tabular(UgamText.numLg.copyWith(color: c.accent)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
