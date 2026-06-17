import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';

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
class BusMessageComposerField extends StatelessWidget {
  final TextEditingController controller;

  const BusMessageComposerField({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
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
          controller: controller,
          hint: tr('bus_message.field_message_hint'),
          maxLines: 5,
          minLines: 3,
          autofocus: true,
        ),
        const SizedBox(height: UgamSpacing.sm),
        // Fixed closing blessing — added automatically by the template.
        _FrameLine(text: kBusMessageBlessing, c: c),
      ],
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
