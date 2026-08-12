// Cash handover to the agent: the settlement card and its sheet.

import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../design/ugam.dart';
import '../../models/bus_handover.dart';
import '../../models/handler_bus_money.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/formatters.dart';

// ─── Settlement (handover to admin) ────────────────────────────────────

/// The handler's settlement ledger for one bus: what is still owed to the
/// admin, a CTA to record a handover, and the rows already handed over.
///
/// Before this existed the handler's screen kept reading the full "in hand"
/// figure forever — the cash physically changed hands on the roadside and
/// nothing on the phone ever moved.
class HandlerSettlementCard extends StatelessWidget {
  final HandlerBusMoney summary;
  final List<BusHandover> handovers;
  final UgamColorSet c;
  final VoidCallback onSettle;
  final void Function(BusHandover) onDelete;

  const HandlerSettlementCard({
    super.key,
    required this.summary,
    required this.handovers,
    required this.c,
    required this.onSettle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final settled = summary.isSettled;
    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                settled
                    ? Icons.verified_rounded
                    : Icons.account_balance_wallet_rounded,
                size: 18,
                color: settled ? c.good : c.accent,
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  tr('handler_chart.settle_title'),
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
              ),
              Text(
                Formatters.formatMoneyInr(summary.outstanding),
                style: UgamText.bodyStrong.copyWith(
                  color: settled ? c.good : c.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.xs),
          Text(
            settled
                ? tr('handler_chart.settle_done')
                : tr('handler_chart.settle_hint'),
            style: UgamText.caption.copyWith(color: c.ink2),
          ),
          if (handovers.isNotEmpty) ...[
            const SizedBox(height: UgamSpacing.md),
            for (final h in handovers)
              Padding(
                padding: const EdgeInsets.only(bottom: UgamSpacing.tight),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle_outline_rounded,
                      size: 15,
                      color: c.good,
                    ),
                    const SizedBox(width: UgamSpacing.sm),
                    Expanded(
                      child: Text(
                        (h.note ?? '').trim().isEmpty
                            ? Formatters.formatMoneyInr(h.handedOverAmount)
                            : '${Formatters.formatMoneyInr(h.handedOverAmount)} · ${h.note!.trim()}',
                        style: UgamText.caption.copyWith(color: c.ink),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Admin-recorded settlements stay read-only here — the
                    // server refuses the delete too, so never offer the action.
                    if (h.byHandler)
                      UgamIconButton(
                        icon: Icons.close_rounded,
                        onTap: () => onDelete(h),
                      ),
                  ],
                ),
              ),
          ],
          if (!settled) ...[
            const SizedBox(height: UgamSpacing.md),
            UgamCTA(
              label: tr('handler_chart.settle_cta'),
              leadingIcon: Icons.south_east_rounded,
              onPressed: onSettle,
            ),
          ],
        ],
      ),
    );
  }
}

/// Records one cash handover. The amount pre-fills with everything still
/// outstanding, since handing over the whole remaining balance at once is by
/// far the common case.
class HandlerHandoverSheet extends StatefulWidget {
  final double expected;
  final Future<void> Function(double amount, String? note) onSave;

  const HandlerHandoverSheet({
    super.key,
    required this.expected,
    required this.onSave,
  });

  @override
  State<HandlerHandoverSheet> createState() => _HandlerHandoverSheetState();
}

class _HandlerHandoverSheetState extends State<HandlerHandoverSheet> {
  late final TextEditingController _amountCtrl;
  final TextEditingController _noteCtrl = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController(
      text: widget.expected <= 0 ? '' : widget.expected.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _noteCtrl.dispose();
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
      final note = _noteCtrl.text.trim();
      await widget.onSave(amount, note.isEmpty ? null : note);
      FocusManager.instance.primaryFocus?.unfocus();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      AppSnackBar.error(tr('handler_chart.handover_failed'));
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
            tr(
              'handler_chart.handover_intro',
              namedArgs: {'amount': Formatters.formatMoneyInr(widget.expected)},
            ),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamInput(
            label: tr('handler_chart.handover_amount'),
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          UgamInput(
            label: tr('handler_chart.handover_note'),
            controller: _noteCtrl,
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _saving
                ? tr('handler_chart.saving')
                : tr('handler_chart.handover_save'),
            loading: _saving,
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}
