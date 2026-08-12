import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../config/whatsapp_cloud_config.dart';
import '../design/ugam.dart';
import '../services/wa_formatting.dart';
import '../services/wa_template_catalog.dart';
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

  /// Characters the approved `bus_msg` body spends on its own static text —
  /// the greeting, the blessing and everything between. Meta's 1024 limit
  /// covers the ASSEMBLED message, so this is subtracted from the sender's
  /// allowance. Falls back to a conservative figure when the template catalog
  /// has not loaded, which is stricter than Meta but never looser.
  int get _staticChars => WaTemplateCatalog.instance
      .staticCharsFor(WhatsAppCloudConfig.busMessageTemplate);

  int get _budget => WaTemplateParams.freeTextBudget(_staticChars);

  List<WaParamViolation> _validate() {
    final text = widget.controller.text;
    // An untouched field is "not ready", not "wrong" — don't scold the sender
    // before they have typed anything.
    if (text.isEmpty) return const [];
    // Measured against the RENDERED body, so the greeting and blessing the
    // sender never typed still count against the limit. Checking the typed
    // text alone is what let a "legal" message through to be refused by Meta.
    return WaTemplateParams.validateRendered(
      params: [text],
      staticBodyChars: _staticChars,
    );
  }

  void _revalidate() {
    final next = _validate();
    if (next.length == _violations.length &&
        next.every((v) => _violations.contains(v))) {
      // The count still moves even when the verdict does not, so the remaining
      // characters have to repaint regardless.
      setState(() {});
      return;
    }
    setState(() => _violations = next);
  }

  void _replaceText(String next) {
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
  }

  void _autoFix() => _replaceText(
        WaTemplateParams.sanitize(widget.controller.text),
      );

  /// Removes the paired `*`, `_`, `~` and backticks so the words arrive
  /// literally. Separate from [_autoFix] because formatting is LEGAL — Meta
  /// accepts it and some senders mean it — so it is offered, never imposed.
  void _makePlain() => _replaceText(
        WaFormatting.toPlain(widget.controller.text),
      );

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final canFix = WaTemplateParams.canAutoFix(widget.controller.text);
    final hasFormatting = WaFormatting.hasMarks(widget.controller.text);
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
        const SizedBox(height: UgamSpacing.xs),
        _RemainingCount(
          typed: WaTemplateParams.characterCount(widget.controller.text),
          budget: _budget,
          c: c,
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
        // WhatsApp renders *bold*, _italic_, ~strikethrough~ and `monospace`
        // in the delivered message. Meta accepts them without complaint, so
        // this is NOT a refusal — it is the sender seeing what will actually
        // arrive, and choosing.
        if (hasFormatting) ...[
          const SizedBox(height: UgamSpacing.sm),
          _FormattingNotice(
            spans: WaFormatting.parse(widget.controller.text),
            onPlain: _makePlain,
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

/// How much room is left, measured against the REAL budget: 1024 characters
/// minus whatever the approved template already spends on its greeting and
/// blessing. Shown quietly until it matters, then in the danger colour.
///
/// Counting only the typed text against 1024 is what let an announcement pass
/// the composer and be refused by Meta, so the number here deliberately
/// reflects the assembled message rather than the field's contents.
class _RemainingCount extends StatelessWidget {
  final int typed;
  final int budget;
  final UgamColorSet c;

  const _RemainingCount({
    required this.typed,
    required this.budget,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final left = budget - typed;
    final over = left < 0;
    // Silent until the sender is within a screenful of the limit — a counter
    // that is always visible reads as a target rather than a warning.
    if (!over && left > 120) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.centerRight,
      child: Text(
        over
            ? tr('bus_message.over_budget', namedArgs: {'count': '${-left}'})
            : tr(
                'bus_message.remaining',
                namedArgs: {'count': '$left', 'max': '$budget'},
              ),
        style: UgamText.micro.copyWith(color: over ? c.danger : c.ink3),
      ),
    );
  }
}

/// "This is how it will arrive" — the typed text with WhatsApp's own
/// formatting applied, plus a one-tap way to make it literal.
///
/// Deliberately NOT styled as an error: `*bold*` is legal, Meta accepts it,
/// and some senders mean it. The failure this prevents is the OTHER one —
/// an agent wrapping a departure time in asterisks for emphasis and never
/// learning that the asterisks vanished and the time went bold.
class _FormattingNotice extends StatelessWidget {
  final List<WaSpan> spans;
  final VoidCallback onPlain;
  final UgamColorSet c;

  const _FormattingNotice({
    required this.spans,
    required this.onPlain,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.visibility_outlined, size: 13, color: c.ink3),
              const SizedBox(width: 6),
              Text(
                tr('bus_message.preview_label'),
                style: UgamText.micro.copyWith(color: c.ink2),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text.rich(
            TextSpan(
              children: [
                for (final s in spans)
                  TextSpan(text: s.text, style: _styleFor(s.styles)),
              ],
            ),
            style: UgamText.body.copyWith(color: c.ink),
          ),
          const SizedBox(height: UgamSpacing.sm),
          Text(
            tr('bus_message.formatting_note'),
            style: UgamText.micro.copyWith(color: c.ink3),
          ),
          const SizedBox(height: UgamSpacing.sm),
          UgamButton(
            label: tr('bus_message.fix_plain'),
            icon: Icons.format_clear_rounded,
            kind: UgamButtonKind.tonal,
            onPressed: onPlain,
          ),
        ],
      ),
    );
  }

  /// The four WhatsApp styles compose, so a run can be bold AND italic.
  TextStyle _styleFor(Set<WaStyle> styles) => TextStyle(
        fontWeight: styles.contains(WaStyle.bold) ? FontWeight.w700 : null,
        fontStyle: styles.contains(WaStyle.italic) ? FontStyle.italic : null,
        decoration: styles.contains(WaStyle.strikethrough)
            ? TextDecoration.lineThrough
            : null,
        fontFamily: styles.contains(WaStyle.monospace) ? 'monospace' : null,
      );
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
