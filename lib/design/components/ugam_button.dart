import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';
import '../ui_scale.dart';

/// Visual weight of a [UgamButton]. Maps tone → fill/text so callers
/// pick intent ("this is the primary action", "this destroys data")
/// rather than re-deriving colors at every call site.
enum UgamButtonKind {
  /// Solid accent. The single affirmative action on a surface.
  ///
  /// **The accent-rationing law:** at most ONE solid-accent fill in a
  /// screen's own content area — normally the sticky [UgamCTA]. Every other
  /// "primary-ish" action is [tonal].
  ///
  /// The dock's active-tab pill (`ugam_dock_nav.dart`) and its badge are app
  /// chrome, not screen content, and are **exempt**: a tabbed screen with a
  /// sticky CTA is allowed to show the dock pill plus its own one solid
  /// accent. Do not "fix" the dock pill per-screen — that ruling is settled.
  primary,

  /// Tonal — full-contrast [UgamColorSet.ink] on the amber [accentFill], with
  /// a hairline accent border. The canonical "quiet primary": repeated/per-row
  /// primaries (Confirm, Collect, Send, Book, Apply) so solid gold stays
  /// rationed to one focal point per screen.
  ///
  /// **The ink is deliberately NOT the accent** (it was, until this was the
  /// last amber-inked control left in the app). Per [Brand] the accent means
  /// exactly one thing — "this is yours", a selection or an ownership state —
  /// and spending it on a *control* is what makes a UI read cheap, because
  /// then nothing is left to carry meaning. Every one of the ~22 call sites is
  /// a verb (Add, Collect, Call, Apply, Accept, Update, Send); none of them is
  /// a thing the user owns, so none of them earns the hue.
  ///
  /// The tonal WASH stays amber. A fill is a surface, not ink: it is what
  /// keeps this readable as the quiet primary rather than as [neutral], and it
  /// is the same construction [goodTonal] and [warmTonal] use. What was
  /// retired is the amber *lettering*, which is the part that reads as "an
  /// amber button". The swap also buys real contrast — worst surface in each
  /// theme, accent ink on this fill measured 4.57:1 (Daylight) and 6.37:1
  /// (Midnight); `ink` measures 17.05:1 and 9.27:1.
  tonal,

  /// Quiet, transparent. Cancel / dismiss — never competes with primary.
  ghost,

  /// Tonal neutral fill. A secondary action that still needs a hit area.
  neutral,

  /// Solid danger. A confirmed destructive action (delete, remove).
  danger,

  /// Tonal danger. A destructive action that shouldn't shout (inline
  /// "unassign", "clear") — danger-tinted but not a solid red slab.
  dangerTonal,

  /// Tonal success. A per-row affirmative whose meaning is "this completes /
  /// approves something" (Approve, Mark paid, Confirm) and that reads better
  /// in the good tone than in copper. Tonal by construction — there is no
  /// solid `good`, because a green slab would compete with the screen's one
  /// solid accent.
  goodTonal,

  /// Tonal attention. A per-row action that needs to read as pending or
  /// caution rather than affirmative or destructive (Cancel requested,
  /// Needs review) — warm-tinted, never a solid slab.
  warmTonal,
}

/// The one button used for dialog actions, sheet actions, and any
/// secondary CTA that isn't the full-width [UgamCTA]. Consistent height,
/// radius, loading + disabled handling — so destructive vs affirmative
/// reads the same on every screen instead of a color-only `TextButton`.
///
/// Lives in its own file (not inside `ugam_dialog.dart`) so a screen author
/// looking for "the button" actually finds it — six hand-rolled buttons were
/// written because it used to be hidden in the dialog file.
class UgamButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final UgamButtonKind kind;
  final bool loading;

  /// When true, the button stretches to fill its parent's width.
  final bool expand;

  const UgamButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.kind = UgamButtonKind.primary,
    this.loading = false,
    this.expand = false,
  });

  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final (Color bg, Color fg, Color? border) = switch (kind) {
      // Neutral by design — max contrast against the ground, no brand hue.
      // The accent is reserved for meaning ("this is yours"), not for controls.
      UgamButtonKind.primary => (c.action, c.onAction, null),
      // Ink, not accent — see [UgamButtonKind.tonal]. `c.ink` and `c.action`
      // carry the same value in both themes, but this is text on a surface,
      // so it takes the ink token rather than the control-FILL token.
      UgamButtonKind.tonal => (
        c.accentFill,
        c.ink,
        c.accent.withValues(alpha: 0.28),
      ),
      UgamButtonKind.ghost => (Colors.transparent, c.ink2, null),
      UgamButtonKind.neutral => (c.cardElev, c.ink, c.border),
      UgamButtonKind.danger => (c.danger, Colors.white, null),
      UgamButtonKind.dangerTonal => (
        c.danger.withValues(alpha: 0.12),
        c.danger,
        null,
      ),
      UgamButtonKind.goodTonal => (
        c.goodFill,
        c.good,
        c.good.withValues(alpha: 0.28),
      ),
      UgamButtonKind.warmTonal => (
        c.warmFill,
        c.warm,
        c.warm.withValues(alpha: 0.28),
      ),
    };

    final content = loading
        ? SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              valueColor: AlwaysStoppedAnimation(fg),
            ),
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: UgamSpacing.sm),
              ],
              Flexible(
                child: Text(
                  label,
                  style: UgamText.bodyStrong.copyWith(color: fg),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );

    return Opacity(
      opacity: _enabled ? 1 : 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _enabled
              ? () {
                  HapticFeedback.lightImpact();
                  onPressed!();
                }
              : null,
          borderRadius: BorderRadius.circular(UgamRadius.input),
          child: Container(
            // Interactive box: shrinks with the device but never below the
            // 44pt minimum tap target (50 -> 44 at the 0.85 floor).
            height: UgamScale.tap(context, 50),
            width: expand ? double.infinity : null,
            padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.lg),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(UgamRadius.input),
              border: border == null ? null : Border.all(color: border),
            ),
            child: content,
          ),
        ),
      ),
    );
  }
}
