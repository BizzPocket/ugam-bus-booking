import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';
import '../ui_scale.dart';

/// A read-only, tappable field that opens a picker (date / time / selection).
/// Looks like a filled [UgamInput] but its job is to trigger [onTap] rather
/// than accept typing — the one shape for every date/time picker trigger so
/// they stop being hand-rolled per screen.
///
///   * [label] — optional caption above the field
///   * [value] — the chosen value to display; when empty, [placeholder] shows
///   * [icon] — leading glyph (calendar / clock / list)
///   * [onTap] — opens the picker (preceded by a selection haptic)
class UgamPickerField extends StatelessWidget {
  final String? label;
  final String value;
  final String? placeholder;
  final IconData icon;
  final VoidCallback onTap;
  final bool enabled;

  const UgamPickerField({
    super.key,
    required this.value,
    required this.icon,
    required this.onTap,
    this.label,
    this.placeholder,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final hasValue = value.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label!, style: UgamText.caption.copyWith(color: c.ink2)),
          const SizedBox(height: UgamSpacing.sm),
        ],
        Opacity(
          opacity: enabled ? 1 : 0.5,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled
                ? () {
                    HapticFeedback.selectionClick();
                    onTap();
                  }
                : null,
            child: Container(
              // Interactive box (the field IS the picker trigger): floored at
              // the 44pt tap minimum — 52 -> 44.2 at the 0.85 device floor.
              height: UgamScale.tap(context, 52),
              padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.input),
                border: Border.all(color: c.border),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 18, color: c.ink2),
                  const SizedBox(width: UgamSpacing.sm + 2),
                  Expanded(
                    child: Text(
                      hasValue ? value : (placeholder ?? ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: UgamText.body.copyWith(
                        color: hasValue ? c.ink : c.ink3,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Icon(Icons.expand_more_rounded, size: 20, color: c.ink3),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
