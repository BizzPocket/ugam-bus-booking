import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';
import '../ui_scale.dart';

/// The one search pill used across the app — Requests, Tour Groups, Notify,
/// Customer list, etc. Replaces the ~5 hand-rolled `Container + TextField`
/// search bars that each re-derived padding, radius, and icon colour.
///
///   * [controller] — optional; supply when the parent needs the text
///   * [hint] (required) — localized placeholder
///   * [onChanged] — live query callback
///   * [onClear] — when set AND the field is non-empty, a clear (×) button
///     shows; tapping it clears the controller and fires [onClear]
class UgamSearchField extends StatelessWidget {
  final TextEditingController? controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;
  final bool autofocus;

  const UgamSearchField({
    super.key,
    required this.hint,
    this.controller,
    this.onChanged,
    this.onClear,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final hasText = (controller?.text ?? '').isNotEmpty;

    return Container(
      // Interactive box (the whole pill focuses the field): scales down with
      // the device but never below the 44pt tap minimum.
      height: UgamScale.tap(context, 48),
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 18, color: c.ink2),
          const SizedBox(width: UgamSpacing.sm),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: autofocus,
              onChanged: onChanged,
              style: UgamText.body.copyWith(color: c.ink, fontSize: 14),
              cursorColor: c.accent,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: hint,
                hintStyle: UgamText.body.copyWith(color: c.ink3, fontSize: 14),
              ),
            ),
          ),
          if (onClear != null && hasText)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                controller?.clear();
                onChanged?.call('');
                onClear!.call();
              },
              // 44×44 hit box around an unchanged 18pt glyph — the painted
              // icon is identical, only the target grows.
              child: SizedBox(
                width: 44,
                height: 44,
                child: Center(
                  child: Icon(Icons.close_rounded, size: 18, color: c.ink2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
