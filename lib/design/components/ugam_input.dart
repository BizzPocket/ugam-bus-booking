import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/phone_normalize.dart';
import '../text_styles.dart';
import '../tokens.dart';
import '../ui_scale.dart';

/// The border width the FOCUSED and ERROR states paint. The resting hairline is
/// thinner ([_lineRest]); the difference is given back as container padding so
/// the field's painted size never changes between states and focusing a field
/// cannot nudge the form below it.
const double _lineFocus = 1.5;
const double _lineRest = 1.0;

/// Labelled filled input. Label sits above the field in `micro` caps style.
///
/// The field paints its OWN surface (fill + hairline border) instead of leaning
/// on the ambient `InputDecorationTheme`, for two reasons:
///
///   * **It must never read as a skeleton.** `UgamSkeleton` is a borderless,
///     text-free rounded rectangle pulsing between `card` and `cardElev` — i.e.
///     exactly what a hint-less, border-less filled field looks like. A resting
///     field is therefore always drawn with a visible hairline in [c.border] and
///     always carries hint ink at `ink2` (see the ratio note on [_UgamInputState]),
///     so "ready for input" and "still loading" can never collide.
///   * **Motion is ours.** `InputDecorator` animates its own border on a
///     hard-coded 167 ms curve; painting the box here lets focus ride
///     [UgamMotion] like the rest of the app.
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

  /// Only created when the caller does NOT supply a focus node. Owned nodes are
  /// disposed here; a caller's node never is.
  FocusNode? _ownNode;
  bool _focused = false;

  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocusChanged);
    _focused = _node.hasFocus;
  }

  @override
  void didUpdateWidget(covariant UgamInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownNode)?.removeListener(_onFocusChanged);
      _node.addListener(_onFocusChanged);
      _focused = _node.hasFocus;
    }
  }

  void _onFocusChanged() {
    if (!mounted || _node.hasFocus == _focused) return;
    setState(() => _focused = _node.hasFocus);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocusChanged);
    _ownNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;

    // One style drives both the value and the hint, so the text does not jump
    // size the moment the user types the first character. The hint is `ink2`,
    // not `ink3`: on `cardElev`, ink3 measures 2.76:1 (fails AA) while ink2
    // measures 5.66:1 dark / 5.52:1 light — still visibly lighter than the
    // value ink (14.2:1 / 16.9:1), so a hint never passes for real input.
    final valueStyle = UgamText.body.copyWith(
      color: widget.enabled ? c.ink : c.ink3,
      fontSize: 15,
    );

    // Resting → focused → error. Error outranks focus: a field you are typing
    // into while it is invalid must keep showing that it is invalid.
    final Color line = hasError
        ? c.danger
        : _focused
            ? c.accent
            : c.border;
    final double lineWidth = (hasError || _focused) ? _lineFocus : _lineRest;

    // When obscureToggle is on, the eye icon becomes the field's suffix. An
    // explicitly-passed suffix takes precedence (no caller passes both today).
    Widget? suffix = widget.suffix;
    if (widget.obscureToggle && suffix == null) {
      final tapBox = UgamScale.tap(context, 44);
      suffix = GestureDetector(
        onTap: () => setState(() => _obscured = !_obscured),
        behavior: HitTestBehavior.opaque,
        child: Semantics(
          button: true,
          label: tr(_obscured ? 'login.show_password' : 'login.hide_password'),
          // 44×44 hit box around the UNCHANGED 20pt glyph. The decoration
          // slot centres it, so the field's painted height is untouched.
          child: SizedBox(
            width: tapBox,
            height: tapBox,
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
          // The label tracks the field's state too, so the active row is
          // findable without hunting for the amber ring.
          AnimatedDefaultTextStyle(
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            style: UgamText.micro.copyWith(
              color: hasError
                  ? c.danger
                  : _focused
                      ? c.accent
                      : c.ink2,
            ),
            child: Text(widget.label!.toUpperCase()),
          ),
          const SizedBox(height: UgamSpacing.sm),
        ],
        AnimatedContainer(
          duration: UgamMotion.tab,
          curve: UgamMotion.easeOut,
          // Floor, never a fixed height: the natural height (~52 at baseline)
          // already clears this, so the constraint only defends the tap target
          // on the smallest phones and never freezes the responsive shrink.
          constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
          // Gives back exactly what the thicker focus/error ring takes, so the
          // box measures the same in every state.
          padding: EdgeInsets.all(_lineFocus - lineWidth),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.input),
            border: Border.all(color: line, width: lineWidth),
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: _node,
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
            cursorColor: c.accent,
            // Single-line fields centre inside the (rarely binding) minimum
            // height; multi-line notes stay top-aligned.
            textAlignVertical:
                widget.maxLines > 1 ? TextAlignVertical.top : TextAlignVertical.center,
            style: valueStyle,
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: valueStyle.copyWith(color: c.ink2),
              // The surface is painted by the container above; the decorator
              // must not paint a second, square-cornered one underneath it.
              filled: false,
              isDense: false,
              counterText: '',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.lg,
                vertical: UgamSpacing.gutter,
              ),
              prefixIcon: widget.prefix,
              suffixIcon: suffix,
            ),
          ),
        ),
        if (hasError) _UgamFieldError(message: widget.errorText!),
      ],
    );
  }
}

/// Error line under a field: danger ink AND a glyph AND words, so the failure
/// survives a colour-blind reader or a greyscale screenshot. Wraps rather than
/// truncating — Gujarati strings run ~30% longer than the English source.
class _UgamFieldError extends StatelessWidget {
  final String message;

  const _UgamFieldError({required this.message});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              Icons.error_outline_rounded,
              size: UgamScale.px(context, 14),
              color: c.danger,
            ),
          ),
          const SizedBox(width: UgamSpacing.xs),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                message,
                style: UgamText.caption.copyWith(color: c.danger),
              ),
            ),
          ),
        ],
      ),
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
    // target) — `tap` enforces that floor instead of relying on the raw factor.
    final fieldH = UgamScale.tap(context, 54);
    final hasError = errorText != null && errorText!.isNotEmpty;
    // Same rule as UgamInput: hint ink at ink2 (5.5:1 on the fill), value ink
    // well above it, so the hint reads as a prompt and not as typed input.
    final valueStyle = UgamText.body.copyWith(color: c.ink, fontSize: 16);
    // The error is rendered BELOW the row rather than through the decorator:
    // this field lives in a fixed-height box, and an in-decorator error line
    // overflowed it. The red ring therefore has to be set by hand, on every
    // border slot, so focusing an invalid field does not flip it back to amber.
    final InputBorder? errorRing = hasError
        ? OutlineInputBorder(
            borderRadius: BorderRadius.circular(UgamRadius.input),
            borderSide: BorderSide(color: c.danger, width: _lineFocus),
          )
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(
            label!.toUpperCase(),
            style: UgamText.micro.copyWith(color: hasError ? c.danger : c.ink2),
          ),
          const SizedBox(height: UgamSpacing.sm),
        ],
        Row(
          children: [
            // The pill USED to be pinned to a hard 90 while its contents scale
            // with the user's text-size setting, so on a 320pt phone at text
            // x1.3 the flag plus '+91' overflowed it by ~46px. It is now a
            // floor, not a cage: 90 (scaled) keeps the default-scale alignment
            // identical to before, and the box grows toward the 140 ceiling
            // when the type gets bigger. The ceiling is what guarantees the
            // Expanded field beside it always keeps usable width.
            ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: UgamScale.px(context, 90),
                maxWidth: UgamScale.px(context, 140),
              ),
              child: Container(
                height: fieldH,
                // Tightened from 12 to give the new hairline its 2px back.
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.tight,
                ),
                decoration: BoxDecoration(
                  color: c.cardElev,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                  // Matches the field beside it — a bare filled rectangle is
                  // the skeleton silhouette.
                  border: Border.all(color: c.border, width: _lineRest),
                ),
                // Last resort only. Up to the ceiling the box grows and this
                // scales nothing; past it the prefix shrinks a little rather
                // than spilling a striped overflow bar across the field.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('🇮🇳', style: TextStyle(fontSize: 18)),
                      const SizedBox(width: 6),
                      Text('+91', style: valueStyle),
                    ],
                  ),
                ),
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
                  cursorColor: c.accent,
                  textAlignVertical: TextAlignVertical.center,
                  style: valueStyle,
                  decoration: InputDecoration(
                    counterText: '',
                    hintText: '98765 43210',
                    hintStyle: valueStyle.copyWith(color: c.ink2),
                    border: errorRing,
                    enabledBorder: errorRing,
                    focusedBorder: errorRing,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (hasError) _UgamFieldError(message: errorText!),
      ],
    );
  }
}
