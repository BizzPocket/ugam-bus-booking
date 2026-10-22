part of '../bus_money_screen.dart';

/// Add/edit sheets for this bus's expenses, income and handovers.
extension _BusMoneySheets on _BusMoneyScreenState {
  void _openExpenseSheet(BuildContext context, {Expense? existing}) {
    ExpenseCategory category = existing?.category ?? ExpenseCategory.other;
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final paidByCtrl = TextEditingController(text: existing?.paidBy ?? '');
    // ONE id per sheet, not per tap. On 2G a save can land and still time out;
    // the agent's second tap then re-sends the same row (insert → update by
    // id) instead of writing a duplicate expense into the books.
    final newId = const Uuid().v4();

    // Numpad-first money entry: a giant tabular amount up top, category as a
    // pill rail above it, and the label + paid-by tucked behind a collapsed
    // "Details" expander (progressive disclosure). The save call is unchanged.
    UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('bus_money.add_expense')
          : tr('bus_money.edit_expense'),
      builder: (sheetCtx) {
        return _MoneyEntrySheetBody<ExpenseCategory>(
          // Every category, busOwner included: this is the ADMIN's sheet and
          // the admin pays the owner's rent, so an advance to the Malik is
          // logged here (it reduces what is still owed on the Malik card).
          // Handler surfaces never see rent.
          categories: ExpenseCategory.values,
          categoryLabel: (cat) => cat.displayName,
          detailsTitleKey: 'bus_money.expense_details',
          personLabelKey: 'bus_money.field_paid_by',
          initialCategory: category,
          initialAmount: existing?.amount,
          labelCtrl: labelCtrl,
          personCtrl: paidByCtrl,
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
                      id: newId,
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

  /// Add/edit an extra-income entry (cabin / gallery / other) for this bus.
  /// Mirrors [_openExpenseSheet] exactly — same numpad-first sheet, same
  /// copyWith-on-edit rule so an edit updates the row instead of inserting a
  /// duplicate.
  void _openIncomeSheet(BuildContext context, {IncomeEntry? existing}) {
    IncomeCategory category = existing?.category ?? IncomeCategory.other;
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final receivedByCtrl = TextEditingController(
      text: existing?.receivedBy ?? '',
    );
    // One id per sheet — see [_openExpenseSheet].
    final newId = const Uuid().v4();

    UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('bus_money.add_income')
          : tr('bus_money.edit_income'),
      builder: (sheetCtx) {
        return _MoneyEntrySheetBody<IncomeCategory>(
          categories: IncomeCategory.values,
          categoryLabel: (cat) => cat.displayName,
          detailsTitleKey: 'bus_money.income_details',
          personLabelKey: 'bus_money.field_received_by',
          initialCategory: category,
          initialAmount: existing?.amount,
          labelCtrl: labelCtrl,
          personCtrl: receivedByCtrl,
          onCategory: (c) => category = c,
          confirmLabel: tr('bus_money.save_income'),
          onConfirm: (amount) async {
            final receivedBy = receivedByCtrl.text.trim();
            final label = labelCtrl.text.trim();
            await controller.upsertIncome(
              existing == null
                  ? IncomeEntry(
                      id: newId,
                      tourId: widget.tour.id,
                      busId: widget.bus.id,
                      category: category,
                      label: label,
                      amount: amount,
                      receivedBy: receivedBy.isEmpty ? null : receivedBy,
                    )
                  : existing.copyWith(
                      category: category,
                      label: label,
                      amount: amount,
                      receivedBy: receivedBy.isEmpty ? null : receivedBy,
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
    // One id per sheet — see [_openExpenseSheet]. A handover is money changing
    // hands; a duplicate row says the handler gave the cash twice.
    final newId = const Uuid().v4();
    var saving = false;

    UgamSheet.show<void>(
      context,
      title: existing == null
          ? tr('bus_money.record_handover')
          : tr('bus_money.edit_handover'),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) => SingleChildScrollView(
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
                  loading: saving,
                  onPressed: saving
                      ? null
                      : () async {
                          final note = noteCtrl.text.trim();
                          final handed =
                              double.tryParse(handedCtrl.text.trim()) ?? 0;
                          setSheetState(() => saving = true);
                          try {
                            await controller.recordHandover(
                              existing == null
                                  ? BusHandover(
                                      id: newId,
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
                          } catch (_) {
                            // The controller has already toasted the reason; keep
                            // the sheet open so the agent can retry the same row.
                            if (sheetCtx.mounted) {
                              setSheetState(() => saving = false);
                            }
                            return;
                          }
                          if (sheetCtx.mounted) Navigator.of(sheetCtx).pop();
                        },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Numpad-first body for the add/edit expense AND income sheets. Category pills
/// ride at the very top; a live [UgamAmountHero] + [UgamNumpad] own the middle;
/// the label and paid-by / received-by inputs hide behind a collapsed
/// "Details" [UgamExpander]; a sticky [UgamCTA] saves. The category selection
/// is reported back to the caller via [onCategory] so the unchanged controller
/// call can read it.
///
/// One body for both directions, deliberately: logging money IN and money OUT
/// must feel identical (category pills → amount hero → numpad → collapsed
/// details → sticky CTA). Every income category is loggable, as is every
/// expense category.
class _MoneyEntrySheetBody<T> extends StatefulWidget {
  final List<T> categories;
  final String Function(T) categoryLabel;
  final T initialCategory;
  final double? initialAmount;
  final TextEditingController labelCtrl;

  /// "Paid by" (expense) or "Received by" (income).
  final TextEditingController personCtrl;
  final String detailsTitleKey;
  final String personLabelKey;
  final ValueChanged<T> onCategory;
  final String confirmLabel;
  final Future<void> Function(double amount) onConfirm;

  const _MoneyEntrySheetBody({
    required this.categories,
    required this.categoryLabel,
    required this.initialCategory,
    required this.initialAmount,
    required this.labelCtrl,
    required this.personCtrl,
    required this.detailsTitleKey,
    required this.personLabelKey,
    required this.onCategory,
    required this.confirmLabel,
    required this.onConfirm,
  });

  @override
  State<_MoneyEntrySheetBody<T>> createState() =>
      _MoneyEntrySheetBodyState<T>();
}

class _MoneyEntrySheetBodyState<T> extends State<_MoneyEntrySheetBody<T>> {
  List<T> get _cats => widget.categories;

  late T _category = widget.initialCategory;
  bool _saving = false;
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
                .map(
                  (cat) => UgamSelectorItem(label: widget.categoryLabel(cat)),
                )
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
            title: tr(widget.detailsTitleKey),
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
                  label: tr(widget.personLabelKey),
                  controller: widget.personCtrl,
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
                loading: _saving,
                onPressed: amount > 0 && !_saving
                    ? () async {
                        // Busy guard: a second tap while a slow save is in
                        // flight would re-send it.
                        setState(() => _saving = true);
                        try {
                          await widget.onConfirm(amount);
                        } catch (_) {
                          // Toasted by the controller; stay open to retry.
                          if (mounted) setState(() => _saving = false);
                          return;
                        }
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
