import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';

/// Labelled filled input. Label sits above the field in `micro` caps
/// style. The field itself inherits the `InputDecorationTheme` from
/// `UgamTheme.dark()` / `UgamTheme.light()`.
class UgamInput extends StatelessWidget {
  final String? label;
  final String? hint;
  final TextEditingController? controller;
  final TextInputType? keyboardType;
  final List<TextInputFormatter> inputFormatters;
  final bool obscure;
  final bool autofocus;
  final int? maxLength;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? errorText;
  final Widget? prefix;
  final Widget? suffix;

  const UgamInput({
    super.key,
    this.label,
    this.hint,
    this.controller,
    this.keyboardType,
    this.inputFormatters = const [],
    this.obscure = false,
    this.autofocus = false,
    this.maxLength,
    this.onChanged,
    this.onSubmitted,
    this.errorText,
    this.prefix,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label!.toUpperCase(),
              style: UgamText.micro.copyWith(color: c.ink2)),
          const SizedBox(height: UgamSpacing.sm),
        ],
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          obscureText: obscure,
          autofocus: autofocus,
          maxLength: maxLength,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          style: UgamText.body.copyWith(color: c.ink, fontSize: 15),
          decoration: InputDecoration(
            hintText: hint,
            errorText: errorText,
            counterText: '',
            prefixIcon: prefix,
            suffixIcon: suffix,
          ),
        ),
      ],
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

  const UgamPhoneInput({
    super.key,
    required this.controller,
    this.label,
    this.errorText,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(label!.toUpperCase(),
              style: UgamText.micro.copyWith(color: c.ink2)),
          const SizedBox(height: UgamSpacing.sm),
        ],
        Row(
          children: [
            Container(
              width: 90,
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: c.cardElev,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              child: Row(
                children: [
                  const Text('🇮🇳', style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 6),
                  Text('+91',
                      style: UgamText.body
                          .copyWith(color: c.ink, fontSize: 15)),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: SizedBox(
                height: 54,
                child: TextField(
                  controller: controller,
                  keyboardType: TextInputType.phone,
                  maxLength: 10,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  style:
                      UgamText.body.copyWith(color: c.ink, fontSize: 16),
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
