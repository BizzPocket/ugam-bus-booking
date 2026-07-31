import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../services/wa_template_params.dart';
import '../utils/wa_param_error_text.dart';

/// The fixed Gujarati greeting + closing blessing that wrap EVERY per-bus
/// WhatsApp announcement. These live as static text in the approved Meta
/// `bus_msg` template body, around the single `{{1}}` variable — so the app
/// keeps sending ONLY the typed message text. They are intentionally NOT
/// localized: the template is approved in Gujarati (`gu`), so the delivered
/// WhatsApp message is always Gujarati regardless of the app's UI language.
/// Shown in the composer so the sender knows they're added automatically and
/// doesn't retype them.
const String kBusMessageGreeting = 'જય ગુરુદેવ';
const String kBusMessageBlessing = 'શુભ યાત્રા! 🙏';

/// Shared composer field for both per-bus announcement paths (admin
/// [notify_screen] and handler [handler_bus_chart_screen]): the fixed greeting,
/// the sender's free-text [controller] field (the `{{1}}` variable), and the
/// fixed closing blessing — so both surfaces present the message exactly as it
/// will arrive on WhatsApp.
class BusMessageComposerField extends StatefulWidget {
  final TextEditingController controller;

  const BusMessageComposerField({super.key, required this.controller});

  @override
  State<BusMessageComposerField> createState() =>
      _BusMessageComposerFieldState();
}

class _BusMessageComposerFieldState extends State<BusMessageComposerField> {
  /// Live Meta-rule verdict for what is currently typed. Recomputed on every
  /// keystroke so a paragraph break is flagged AS IT IS TYPED, rather than
  /// after a batch has already been fanned out to Meta and refused.
  List<WaParamViolation> _violations = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_revalidate);
    _violations = _validate();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_revalidate);
    super.dispose();
  }

  List<WaParamViolation> _validate() {
    final text = widget.controller.text;
    // An untouched field is "not ready", not "wrong" — don't scold the sender
    // before they have typed anything.
    if (text.isEmpty) return const [];
    return WaTemplateParams.validateOne(text);
  }

  void _revalidate() {
    final next = _validate();
    if (next.length == _violations.length &&
        next.every((v) => _violations.contains(v))) {
      return;
    }
    setState(() => _violations = next);
  }

  void _autoFix() {
    final fixed = WaTemplateParams.sanitize(widget.controller.text);
    widget.controller.value = TextEditingValue(
      text: fixed,
      selection: TextSelection.collapsed(offset: fixed.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final canFix = WaTemplateParams.canAutoFix(widget.controller.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.auto_awesome_rounded, size: 13, color: c.ink3),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr('bus_message.frame_note'),
                style: UgamText.micro.copyWith(color: c.ink2),
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.sm),
        // Fixed opening greeting — added automatically by the template.
        _FrameLine(text: kBusMessageGreeting, c: c),
        const SizedBox(height: UgamSpacing.sm),
        UgamInput(
          label: tr('bus_message.field_message'),
          controller: widget.controller,
          hint: tr('bus_message.field_message_hint'),
          maxLines: 5,
          minLines: 3,
          autofocus: true,
        ),
        // WhatsApp refuses a template variable containing a line break, a tab
        // or 5+ spaces. Say so HERE, while the sender can still fix it, instead
        // of letting Meta refuse every recipient after the send.
        if (_violations.isNotEmpty) ...[
          const SizedBox(height: UgamSpacing.sm),
          _ViolationNotice(
            text: waViolationsText(_violations),
            onFix: canFix ? _autoFix : null,
            c: c,
          ),
        ],
        const SizedBox(height: UgamSpacing.sm),
        // Fixed closing blessing — added automatically by the template.
        _FrameLine(text: kBusMessageBlessing, c: c),
      ],
    );
  }
}

/// Inline "WhatsApp will refuse this" notice under the message field, with the
/// one-tap repair when the text can be made legal without losing a word (line
/// breaks, tabs and long space runs all collapse to a single space). No fix
/// button is offered for an over-length message — that needs a human edit.
class _ViolationNotice extends StatelessWidget {
  final String text;
  final VoidCallback? onFix;
  final UgamColorSet c;

  const _ViolationNotice({required this.text, required this.onFix, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.dangerFill,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline_rounded, size: 15, color: c.danger),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  text,
                  style: UgamText.micro.copyWith(color: c.danger),
                ),
              ),
            ],
          ),
          if (onFix != null) ...[
            const SizedBox(height: UgamSpacing.sm),
            UgamButton(
              label: tr('bus_message.fix_auto'),
              icon: Icons.auto_fix_high_rounded,
              kind: UgamButtonKind.dangerTonal,
              onPressed: onFix,
            ),
          ],
        ],
      ),
    );
  }
}

/// One non-editable framing line (greeting / blessing) shown dimmed so it reads
/// as auto-added template text, not something the sender types.
class _FrameLine extends StatelessWidget {
  final String text;
  final UgamColorSet c;

  const _FrameLine({required this.text, required this.c});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        border: Border.all(color: c.border),
      ),
      child: Text(
        text,
        style: UgamText.body.copyWith(
          color: c.ink2,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
