// Free-text broadcast composer, scoped to the handler's own bus.

import 'dart:async';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../components/bus_message_composer_field.dart';
import '../../design/ugam.dart';
import '../../services/wa_template_params.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/wa_param_error_text.dart';

// ─── Handler bus-message sheet (F4 handler path) ────────────────────────

/// The handler's per-bus announcement composer: a single free-text field
/// scoped to the handler's own [busLabel] (no bus picker — a handler only
/// owns/sees their own bus). On Send it routes the text to every seated
/// passenger on that bus via [onSend] (WhatsAppCloudService.sendBusMessageAsHandler)
/// and pops on success.
class HandlerBusMessageSheet extends StatefulWidget {
  final String busLabel;
  final Future<void> Function(String text) onSend;

  const HandlerBusMessageSheet({
    super.key,
    required this.busLabel,
    required this.onSend,
  });

  @override
  State<HandlerBusMessageSheet> createState() => _HandlerBusMessageSheetState();
}

class _HandlerBusMessageSheetState extends State<HandlerBusMessageSheet> {
  final TextEditingController _textCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    final raw = _textCtrl.text.trim();
    if (raw.isEmpty) {
      AppSnackBar.error(tr('bus_message.empty_text'));
      return;
    }

    // Same Meta pre-flight as the admin composer (shared rule set) — a line
    // break, tab or 5+ spaces is refused by Meta for EVERY recipient.
    //
    // A REPAIRABLE break is fixed and the send CONTINUES. The old flow rewrote
    // the field and returned, so the handler had to notice and press Send a
    // second time — which is how long multi-paragraph notices ended up never
    // going out at all. Show the exact wording that will travel, then send it.
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
      final ok = await UgamDialog.confirm(
        context,
        title: tr('bus_message.invalid_title'),
        message:
            '${waViolationsText(violations)}\n\n'
            '${tr('bus_message.invalid_repair_note')}\n$repaired',
        cancelLabel: tr('app.action.cancel'),
        confirmLabel: tr('bus_message.fix_and_send'),
        confirmIcon: Icons.auto_fix_high_rounded,
      );
      if (!ok || !mounted) return;
      _textCtrl.value = TextEditingValue(
        text: repaired,
        selection: TextSelection.collapsed(offset: repaired.length),
      );
      text = repaired;
    }

    setState(() => _sending = true);
    try {
      await widget.onSend(text);
      // Dismiss the keyboard so it animates out cleanly with the sheet.
      FocusManager.instance.primaryFocus?.unfocus();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _sending = false);
      // Carry the server's REAL reason (WhatsAppSendException.reason — the 403
      // gate text, or Meta's own rejection) instead of a generic "send failed"
      // the handler can do nothing with.
      AppSnackBar.error('${tr('bus_message.failed_body')}\n$e');
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
              'bus_message.handler_intro',
              namedArgs: {'bus': widget.busLabel},
            ),
            style: UgamText.body.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.lg),
          BusMessageComposerField(controller: _textCtrl),
          const SizedBox(height: UgamSpacing.lg),
          UgamCTA(
            label: _sending
                ? tr('bus_message.sending')
                : tr('bus_message.send_btn'),
            leadingIcon: Icons.send_rounded,
            loading: _sending,
            onPressed: _sending ? null : _send,
          ),
        ],
      ),
    );
  }
}
