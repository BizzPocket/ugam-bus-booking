import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../design/ugam.dart';
import '../../models/handler_report.dart';
import '../../utils/app_snackbar.dart';
import 'handler_atoms.dart';

/// Raises a problem with the agent from the bus.
///
/// The handler could already broadcast to their passengers and phone the
/// driver, but had no way at all to reach the AGENT — so a seat problem, which
/// they are deliberately not allowed to fix themselves, had nowhere to go
/// except a phone call the agent might not answer while driving.
///
/// Deliberately not a chat: one kind, one message, sent. What matters on a dark
/// bus is that it lands, and the Trip tab shows whether the agent has seen it.
class HandlerReportSheet extends StatefulWidget {
  /// Persists the report. Throws to keep the sheet open with the text intact.
  final Future<void> Function(HandlerReportKind kind, String message) onSend;

  const HandlerReportSheet({super.key, required this.onSend});

  @override
  State<HandlerReportSheet> createState() => _HandlerReportSheetState();
}

class _HandlerReportSheetState extends State<HandlerReportSheet> {
  final _text = TextEditingController();
  HandlerReportKind _kind = HandlerReportKind.breakdown;
  bool _sending = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final message = _text.text.trim();
    if (message.isEmpty) {
      AppSnackBar.error(tr('handler_report.error_empty'));
      return;
    }
    setState(() => _sending = true);
    try {
      await widget.onSend(_kind, message);
      if (!mounted) return;
      Navigator.of(context).pop();
      AppSnackBar.success(tr('handler_report.sent'));
    } catch (_) {
      if (!mounted) return;
      // Sheet stays up with the text intact — retyping a breakdown report on a
      // roadside is not something to ask of anyone.
      setState(() => _sending = false);
      AppSnackBar.error(tr('handler_report.error_send'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('handler_report.kind_label'),
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
        const SizedBox(height: UgamSpacing.sm),
        Wrap(
          spacing: UgamSpacing.sm,
          runSpacing: UgamSpacing.sm,
          children: [
            for (final k in HandlerReportKind.values)
              HandlerCategoryChip(
                label: k.displayName,
                active: _kind == k,
                onTap: () => setState(() => _kind = k),
              ),
          ],
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamInput(
          controller: _text,
          label: tr('handler_report.message_label'),
          hint: tr('handler_report.message_hint'),
          maxLines: 4,
          keyboardType: TextInputType.multiline,
        ),
        const SizedBox(height: UgamSpacing.xs),
        Text(
          // Says plainly what happens next, because a message with no visible
          // consequence reads as shouting into a void.
          _kind.isUrgent
              ? tr('handler_report.note_urgent')
              : tr('handler_report.note_normal'),
          style: UgamText.caption.copyWith(color: c.ink2),
        ),
        const SizedBox(height: UgamSpacing.lg),
        UgamCTA(
          label: tr('handler_report.send'),
          leadingIcon: Icons.support_agent_rounded,
          loading: _sending,
          onPressed: _sending ? null : _send,
        ),
      ],
    );
  }
}
