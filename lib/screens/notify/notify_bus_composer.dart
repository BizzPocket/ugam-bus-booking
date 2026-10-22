part of '../notify_screen.dart';

/// The per-bus announcement composer sheet: a bus selector (hidden when the
/// tour has a single bus — that bus is auto-selected) and a multi-line text
/// field. On Send it routes the typed text to every seated passenger on the
/// chosen bus via [onSend] (WhatsAppOutbound.sendBusMessage) and pops.
class _BusMessageComposer extends StatefulWidget {
  final List<Bus> buses;
  final int Function(String busId) recipientCountFor;
  final Future<void> Function(String busId, String text) onSend;

  const _BusMessageComposer({
    required this.buses,
    required this.recipientCountFor,
    required this.onSend,
  });

  @override
  State<_BusMessageComposer> createState() => _BusMessageComposerState();
}

class _BusMessageComposerState extends State<_BusMessageComposer> {
  /// Null until the agent explicitly picks a bus. Deliberately NOT defaulted to
  /// `buses.first` when the tour has several: that default silently addressed a
  /// whole announcement to bus #1 whenever the agent typed one bus's text and
  /// forgot the pill, so riders on the wrong bus got the wrong bus's message.
  /// A single-bus tour has nothing to choose, so it stays auto-selected.
  String? _busId;
  final TextEditingController _textCtrl = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _busId = widget.buses.length == 1 ? widget.buses.first.id : null;
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  String _busLabel(Bus b) => b.displayLabel;

  Future<void> _send() async {
    if (_sending) return;
    final busId = _busId;
    if (busId == null) {
      AppSnackBar.error(tr('bus_message.pick_bus_first'));
      return;
    }
    final raw = _textCtrl.text.trim();
    if (raw.isEmpty) {
      AppSnackBar.error(tr('bus_message.empty_text'));
      return;
    }

    // Meta refuses a template variable holding a line break, a tab or 5+
    // spaces — the rule that silently killed every multi-paragraph
    // announcement.
    //
    // A REPAIRABLE break is fixed and the send CONTINUES. Rewriting the field
    // and returning meant the agent had to spot the change and press Send
    // again, so a long notice routinely went nowhere. Show the exact wording
    // that will travel, then carry on to the usual bus confirmation.
    var text = raw;
    final violations = WaTemplateParams.validateOne(text);
    if (violations.isNotEmpty) {
      if (!WaTemplateParams.canAutoFix(text)) {
        // Empty or over the character limit — only a human can resolve it.
        await UgamDialog.confirm(
          context,
          title: tr('bus_message.invalid_title'),
          message: waViolationsText(violations),
          cancelLabel: tr('app.action.cancel'),
          confirmLabel: tr('bus_message.invalid_edit'),
          confirmIcon: Icons.edit_rounded,
        );
        return;
      }
      final repaired = WaTemplateParams.sanitize(text);
      final proceed = await UgamDialog.confirm(
        context,
        title: tr('bus_message.invalid_title'),
        message: '${waViolationsText(violations)}\n\n'
            '${tr('bus_message.invalid_repair_note')}\n$repaired',
        cancelLabel: tr('app.action.cancel'),
        confirmLabel: tr('bus_message.fix_and_send'),
        confirmIcon: Icons.auto_fix_high_rounded,
      );
      if (!proceed || !mounted) return;
      _textCtrl.value = TextEditingValue(
        text: repaired,
        selection: TextSelection.collapsed(offset: repaired.length),
      );
      text = repaired;
    }

    // Name the destination bus one last time before anything leaves. The text
    // the agent types usually names a bus too, and the two can disagree — this
    // is the only place that mismatch is still recoverable.
    final busName = _busLabel(widget.buses.firstWhere((b) => b.id == busId));
    final ok = await UgamDialog.confirm(
      context,
      title: tr('bus_message.confirm_title', namedArgs: {'bus': busName}),
      message: tr('bus_message.confirm_body', namedArgs: {
        'bus': busName,
        'count': '${widget.recipientCountFor(busId)}',
      }),
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: tr('bus_message.send_btn'),
      confirmIcon: Icons.send_rounded,
    );
    if (!ok || !mounted) return;

    setState(() => _sending = true);
    try {
      await widget.onSend(busId, text);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _sending = false);
      // Classified cause + fix, never the raw exception's toString().
      AppSnackBar.error('${tr('bus_message.failed_body')}${waThrownAppendix(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final multiBus = widget.buses.length > 1;
    final busId = _busId;
    final count = busId == null ? 0 : widget.recipientCountFor(busId);
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('bus_message.composer_intro'),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.lg),
          if (multiBus) ...[
            // [UgamText.label], the script-safe eyebrow step. Not `micro`
            // (Latin/numeric only) and not [UgamSectionLabel], which still
            // uppercases onto micro — see the note in create_tour_screen.
            Text(
              tr('bus_message.pick_bus'),
              style: UgamText.label.copyWith(color: c.ink2),
            ),
            const SizedBox(height: UgamSpacing.sm),
            // The shared pill strip — this was a THIRD hand-rolled selector in
            // one file, and its "selected" state was a faint tint with no
            // border, so on a dark screen the agent could not reliably tell
            // which bus the announcement was about to go to.
            UgamSelectorPills(
              padding: EdgeInsets.zero,
              items: [
                for (final b in widget.buses)
                  UgamSelectorItem(label: _busLabel(b)),
              ],
              currentIndex: widget.buses.indexWhere((b) => b.id == _busId),
              onChanged: (i) =>
                  setState(() => _busId = widget.buses[i].id),
            ),
            const SizedBox(height: UgamSpacing.lg),
          ],
          // Recipient read-back. NOT the selector — the pills above are what
          // the agent picks, and they already wear the accent for it. This is
          // a confirmation line, so it splits on meaning instead: nothing
          // chosen yet is an unresolved blocker (warm attention), a resolved
          // destination is plain information (neutral surface, ink).
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: UgamSpacing.md,
              vertical: UgamSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: busId == null ? c.warmFill : c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            child: Row(
              children: [
                Icon(
                  busId == null
                      ? Icons.info_outline_rounded
                      : Icons.group_rounded,
                  size: 15,
                  color: busId == null ? c.warm : c.ink2,
                ),
                const SizedBox(width: 6),
                Expanded(
                  // Spell out WHICH bus is about to be messaged, not just how
                  // many riders: the count alone never revealed that the typed
                  // text and the selected bus disagreed.
                  child: Text(
                    busId == null
                        ? tr('bus_message.pick_bus_first')
                        : tr('bus_message.recipient_count_named', namedArgs: {
                            'bus': _busLabel(
                              widget.buses.firstWhere((b) => b.id == busId),
                            ),
                            'count': '$count',
                          }),
                    style: UgamText.caption.copyWith(
                      color: busId == null ? c.warm : c.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: UgamSpacing.lg),
          BusMessageComposerField(controller: _textCtrl),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _sending
                ? tr('bus_message.sending')
                : tr('bus_message.send_btn'),
            leadingIcon: Icons.send_rounded,
            onPressed: (_sending || count == 0) ? null : _send,
          ),
        ],
      ),
    );
  }
}

/// Non-dismissible progress dialog shown while seat-allotment messages are
/// being prepared + sent. Tracks the chart build/upload phase (the slow part)
/// via [progress]; once it reaches [total] it shows an indeterminate spinner
/// while the batched Cloud API send finishes.
class _SendProgressDialog extends StatelessWidget {
  const _SendProgressDialog({required this.progress, required this.total});

  final ValueNotifier<int> progress;
  final int total;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return PopScope(
      canPop: false,
      child: Dialog(
        // Card surface token + grid-aligned radius/padding, matching UgamDialog
        // (this progress variant needs a non-dismissible ValueListenableBuilder
        // body, so it stays a bespoke Dialog rather than UgamDialog.show).
        backgroundColor: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UgamRadius.card),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.xxl,
            vertical: UgamSpacing.huge,
          ),
          child: ValueListenableBuilder<int>(
            valueListenable: progress,
            builder: (_, done, _) {
              final ready = done >= total;
              final pct = total == 0 ? 0.0 : done / total;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: UgamScale.px(context, 52),
                    width: UgamScale.px(context, 52),
                    child: CircularProgressIndicator(
                      // Progress, not ownership — ink, like the bar on
                      // [_ProgressCard].
                      value: ready ? null : pct,
                      color: c.ink,
                      backgroundColor: c.cardElev,
                      strokeWidth: 4,
                    ),
                  ),
                  const SizedBox(height: UgamSpacing.xl),
                  Text(
                    ready
                        ? tr('notify.alloc_sending_now')
                        : tr('notify.alloc_preparing', namedArgs: {
                            'done': '$done',
                            'total': '$total',
                          }),
                    textAlign: TextAlign.center,
                    style: UgamText.titleS.copyWith(color: c.ink),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
