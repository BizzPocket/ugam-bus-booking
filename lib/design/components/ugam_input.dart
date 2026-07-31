import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/phone_normalize.dart';
import '../text_styles.dart';
import '../tokens.dart';
import '../ui_scale.dart';

/// Labelled filled input. Label sits above the field in `micro` caps
/// style. The field itself inherits the `InputDecorationTheme` from
/// `UgamTheme.dark()` / `UgamTheme.light()`.
class UgamInput extends StatefulWidget {
  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final List<TextInputFormatter> inputFormatters;
  final bool obscure;
  final bool obscureToggle;
  final List<String>? autofillHints;
  final bool autofocus;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? errorText;
  final Widget? prefix;
  final Widget? suffix;
  final bool readOnly;
  final bool enabled;
  final int maxLines;
  final int? minLines;

  const UgamInput({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.focusNode,
    this.keyboardType,
    this.inputFormatters = const [],
    this.obscure = false,
    this.obscureToggle = false,
    this.autofillHints,
    this.autofocus = false,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.prefix,
    this.suffix,
    this.readOnly = false,
    this.enabled = true,
    this.maxLines = 1,
    this.minLines,
  });

  @override
  State<UgamInput> createState() => _UgamInputState();
}

class _UgamInputState extends State<UgamInput> {
  late bool _obscured = widget.obscure;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    // When obscureToggle is on, the eye icon becomes the field's suffix. An
    // explicitly-passed suffix takes precedence (no caller passes both today).
    Widget? suffix = widget.suffix;
    if (widget.obscureToggle && suffix == null) {
      suffix = GestureDetector(
        onTap: () => setState(() => _obscured = !_obscured),
        behavior: HitTestBehavior.opaque,
        child: Semantics(
          button: true,
          label: tr(_obscured ? 'login.show_password' : 'login.hide_password'),
          // 44×44 hit box around the UNCHANGED 20pt glyph. The decoration
          // slot centres it, so the field's painted height is untouched.
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: Icon(
                _obscured
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 20,
                color: c.ink3,
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null) ...[
          Text(
            widget.label!.toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
        ],
        TextField(
          controller: widget.controller,
          focusNode: widget.focusNode,
          keyboardType: widget.keyboardType,
          inputFormatters: widget.inputFormatters,
          obscureText: _obscured,
          autofillHints: widget.autofillHints,
          autofocus: widget.autofocus,
          maxLength: widget.maxLength,
          maxLines: _obscured ? 1 : widget.maxLines,
          minLines: widget.minLines,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          readOnly: widget.readOnly,
          enabled: widget.enabled,
          style: UgamText.body.copyWith(
            color: widget.enabled ? c.ink : c.ink3,
            fontSize: 15,
          ),
          decoration: InputDecoration(
            hintText: widget.hint,
            errorText: widget.errorText,
            counterText: '',
            prefixIcon: widget.prefix,
            suffixIcon: suffix,
          ),
        ),
      ],
    );
  }
}

/// Keeps a phone field to the 10 significant digits. Strips every non-digit
/// and, when a pasted value carries a country code (`+91 98765 43210`,
/// `919876543210`, …), drops the leading prefix by keeping the *last* 10
/// digits — instead of letting `maxLength` truncate the wrong (trailing) end.
class IndianMobileFormatter extends TextInputFormatter {
  const IndianMobileFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalised = normalisePhone(newValue.text);
    if (normalised == newValue.text) return newValue;
    return TextEditingValue(
      text: normalised,
      selection: TextSelection.collapsed(offset: normalised.length),
    );
  }
}

/// Two-input row: country-code pill on the left, 10-digit phone field
/// on the right. Country code is fixed to `+91` in this build.
class UgamPhoneInput extends StatelessWidget {
  final TextEditingController controller;
  final String? label;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final List<String>? autofillHints;

  const UgamPhoneInput({
    super.key,
    required this.controller,
    this.label,
    this.errorText,
    this.onChanged,
    this.onSubmitted,
    this.autofillHints,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // Field height scales with the device but never below 44px (the min tap
    // target) — at the 0.85 floor that's 54 * 0.85 ≈ 46px, still tappable.
    final s = UgamScale.of(context);
    final fieldH = 54 * s;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(
            label!.toUpperCase(),
            style: UgamText.micro.copyWith(color: c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
        ],
        Row(
          children: [
            Container(
              width: 90 * s,
              height: fieldH,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              child: Row(
                children: [
                  const Text('🇮🇳', style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 6),
                  Text(
                    '+91',
                    style: UgamText.body.copyWith(color: c.ink, fontSize: 15),
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: SizedBox(
                height: fieldH,
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.phone,
                  maxLength: 10,
                  inputFormatters: const [IndianMobileFormatter()],
                  autofillHints: autofillHints,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  style: UgamText.body.copyWith(color: c.ink, fontSize: 16),
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '98765 43210',
                    errorText: errorText,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
