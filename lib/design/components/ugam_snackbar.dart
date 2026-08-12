import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';
import '../ui_scale.dart';
import 'ugam_tappable.dart';

enum UgamSnackTone { success, error, info }

/// A trailing action on a [UgamSnackbar] — in practice almost always **undo**.
///
/// Every Board mutation (assign, move, collect, check in) writes real
/// operational state, at speed, usually by a tired person at 5am. The toast
/// that confirms the write is the ONLY place the write can be taken back
/// before it syncs, so the action is not decoration: it is the safety net.
/// See the Board interaction spec, section 8.
///
/// Label and callback travel together as one object so "an action with no
/// handler" (or a handler with nothing to tap) is unrepresentable.
@immutable
class UgamSnackAction {
  /// Visible label. Keep it to one or two words — it shares a short bar with
  /// the message, and Gujarati runs ~30% longer than the English.
  final String label;

  final VoidCallback onPressed;

  /// Optional leading glyph. Colour is never the only signal, and a bare word
  /// in a busy toast is easy to miss at a glance; the glyph is what the eye
  /// actually lands on.
  final IconData? icon;

  /// Screen-reader label. Defaults to [label], but a bare "Undo" tells a
  /// TalkBack user nothing about *what* — prefer the specific
  /// "undo moving Priti Patel to DL3".
  final String? semanticLabel;

  const UgamSnackAction({
    required this.label,
    required this.onPressed,
    this.icon,
    this.semanticLabel,
  });

  /// The undo action, pre-labelled and pre-glyphed.
  ///
  /// A factory (not a const constructor) because the label is translated at
  /// construction time. Pass [semanticLabel] whenever the call site knows what
  /// is being undone.
  factory UgamSnackAction.undo({
    required VoidCallback onUndo,
    String? semanticLabel,
  }) => UgamSnackAction(
    label: tr('actions.undo'),
    onPressed: onUndo,
    icon: Icons.undo_rounded,
    semanticLabel: semanticLabel ?? tr('actions.undo_semantic'),
  );
}

/// Floating toast content widget. Pure widget — does NOT call
/// `ScaffoldMessenger`. The imperative API lives in
/// `lib/utils/app_snackbar.dart` so this stays decoupled from `Get` /
/// the app's specific routing setup.
class UgamSnackbar extends StatelessWidget {
  final String message;
  final String? title;
  final UgamSnackTone tone;

  /// Optional trailing action. Null (the default) renders exactly the tree
  /// this widget has always rendered — no action, no extra height.
  final UgamSnackAction? action;

  const UgamSnackbar({
    super.key,
    required this.message,
    this.title,
    this.tone = UgamSnackTone.info,
    this.action,
  });

  /// How long a toast **carrying an action** should stay up.
  ///
  /// The plain toast dwell is [UgamMotion.snackbar] (3.2s), which is fine for
  /// something you only have to read. It is far too short for something you
  /// have to read, *realise is wrong*, and then reach for — the undo case is
  /// three cognitive steps, not one, and the person doing them is standing in
  /// a coach aisle at 5am holding a cash bag. Doubling the base dwell puts it
  /// inside the 4–10s band platform guidance reserves for actionable toasts.
  ///
  /// Derived from the motion token rather than restated, so retuning the base
  /// dwell retunes this with it.
  static final Duration actionDuration = UgamMotion.snackbar * 2;

  /// Vertical space the floating dock occupies above the bottom safe area, and
  /// therefore the minimum a bottom-anchored toast must be lifted by so the
  /// two never overlap. The host adds the safe-area inset itself.
  ///
  /// Derived, not measured: the dock is its lateral padding (`lg` above, `md`
  /// below) around a capsule whose cells are floored at the 44pt tap minimum
  /// plus `xs` of vertical padding each side. Kept in sync with `UgamDockNav`.
  static const double dockClearance =
      UgamSpacing.lg + (44 + UgamSpacing.xs * 2) + UgamSpacing.md;

  /// Share of the bar's width the action may claim before its label wraps.
  ///
  /// A fraction rather than a pixel cap because the whole point is to survive
  /// Gujarati: the same action is "Undo" in English and "પાછું લો" in the
  /// primary language, and the message beside it must keep a usable column on
  /// a 320pt phone either way.
  static const double _actionWidthShare = 0.45;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final (bg, fg, icon) = switch (tone) {
      UgamSnackTone.success => (
          c.goodFill,
          c.good,
          Icons.check_circle_rounded
        ),
      UgamSnackTone.error => (
          c.dangerFill,
          c.danger,
          Icons.error_rounded
        ),
      UgamSnackTone.info => (
          c.accentFill,
          c.accent,
          Icons.info_rounded
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.md,
      ),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(UgamRadius.input),
        border: Border.all(color: c.border),
        // A toast floats above everything, which is exactly the level-2
        // contract — previously a hand-rolled shadow predating the scale.
        boxShadow: UgamElevation.of(context).raised,
      ),
      // No action → the original tree, untouched, with no LayoutBuilder in it.
      child: action == null
          ? _row(context, c, bg, fg, icon, null)
          : LayoutBuilder(
              builder: (context, box) => _row(
                context,
                c,
                bg,
                fg,
                icon,
                box.maxWidth * _actionWidthShare,
              ),
            ),
    );
  }

  Widget _row(
    BuildContext context,
    UgamColorSet c,
    Color bg,
    Color fg,
    IconData icon,
    double? actionMaxWidth,
  ) {
    final a = action;
    return Row(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 16, color: fg),
        ),
        const SizedBox(width: UgamSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null)
                Text(title!,
                    style:
                        UgamText.bodyStrong.copyWith(color: c.ink)),
              Text(message, style: UgamText.body.copyWith(color: c.ink2)),
            ],
          ),
        ),
        if (a != null) ...[
          const SizedBox(width: UgamSpacing.md),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: actionMaxWidth ?? double.infinity,
            ),
            child: _SnackActionButton(action: a),
          ),
        ],
      ],
    );
  }
}

/// The trailing action control.
///
/// Deliberately built on [UgamTappable] (a `GestureDetector`) rather than a
/// `TextButton`: a toast arrives unbidden, often while the user is mid-typing,
/// and a focusable control inserted into the overlay can pull focus off the
/// field they were filling. A gesture detector cannot take focus, so the bar
/// is inert to the focus system while staying a first-class button to
/// TalkBack / VoiceOver, which traverse the semantics tree instead.
class _SnackActionButton extends StatelessWidget {
  final UgamSnackAction action;

  const _SnackActionButton({required this.action});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final pill = Container(
      // The bar is short — roughly 56pt with a one-line message — but the
      // action inside it is still a finger target and gets the full 44pt
      // floor. This is what makes an action toast taller than a plain one.
      constraints: BoxConstraints(
        minHeight: UgamScale.tap(context, 44),
        minWidth: UgamScale.tap(context, 44),
      ),
      padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.lg),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // `action`/`onAction` — the design system's primary-control pair, the
        // highest contrast available against the card. Not the amber accent:
        // that token means "this is yours", and an undo button is not a
        // selection. Findability at 5am is the whole requirement here.
        color: c.action,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (action.icon != null) ...[
            Icon(
              action.icon,
              size: UgamScale.px(context, 16),
              color: c.onAction,
            ),
            const SizedBox(width: UgamSpacing.sm),
          ],
          Flexible(
            child: Text(
              action.label,
              style: UgamText.bodyStrong.copyWith(color: c.onAction),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );

    return UgamTappable(
      onTap: action.onPressed,
      semanticLabel: action.semanticLabel ?? action.label,
      // Small chrome needs more travel than a card to read as pressed.
      pressedScale: 0.93,
      // One node, one label. Without this the pill's own Text would surface
      // as a second child node and a screen reader would announce the button
      // twice — once with the descriptive label, once with the bare word.
      child: ExcludeSemantics(child: pill),
    );
  }
}
