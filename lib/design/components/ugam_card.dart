import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

/// Optional semantic tint for a [UgamCard]. `none` is the default neutral
/// surface; the others tint the fill + add a hairline tone border so
/// attention/danger/success cards stop being hand-rolled per screen.
enum UgamCardTone { none, accent, good, warm, danger }

/// Base card surface. Two variants:
///
/// * [UgamCard.plain] — text-only card, default 14 px inner padding.
/// * [UgamCard.media] — card whose top region holds a hero photo
///   (16 px radius, 124 px tall by default), with the photo positioned
///   inside an 8 px outer padding so the card edge surrounds it. The
///   [child] sits below the photo with its own padding.
///
/// Cards never nest other cards. Use the `elev: true` flag when you
/// need a slightly raised inner surface — it swaps fill from
/// [UgamColorSet.card] to [UgamColorSet.cardElev].
///
/// Every card sits at [UgamElevationSet.rest] — level 1 — regardless of theme,
/// tone or the `elev` flag. This is the single edit that gives the whole app
/// depth, so a screen that wants a card flush with the page should not be
/// using a card.
class UgamCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool elev;
  final double radius;
  final UgamCardTone tone;

  const UgamCard.plain({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(UgamSpacing.gutter),
    this.onTap,
    this.elev = false,
    this.radius = UgamRadius.card,
    this.tone = UgamCardTone.none,
  });

  /// Media variant: caller is responsible for placing a photo as the
  /// first child inside [child] (typically a [ClipRRect] with
  /// [UgamRadius.photo]). This factory just standardises the outer
  /// padding (8) and corner radius.
  const UgamCard.media({
    super.key,
    required this.child,
    this.onTap,
    this.elev = false,
    this.radius = UgamRadius.card,
    this.tone = UgamCardTone.none,
  }) : padding = const EdgeInsets.all(UgamSpacing.sm);

  @override
  State<UgamCard> createState() => _UgamCardState();
}

class _UgamCardState extends State<UgamCard>
    with SingleTickerProviderStateMixin {
  // Created only for a TAPPABLE card (PERF: most cards on a roster/money
  // screen are display-only, and each used to allocate a controller + ticker
  // it never ran). Still created while the element is ACTIVE — in initState, or
  // in didUpdateWidget the first time an onTap arrives — never lazily from
  // build/dispose: a lazy initializer would run inside dispose() on a
  // deactivated element and the TickerMode ancestor lookup would throw.
  AnimationController? _ctrl;
  Animation<double>? _scale;

  void _ensureCtrl() {
    if (_ctrl != null) return;
    final ctrl = AnimationController(
      vsync: this,
      duration: UgamMotion.tapOut,
      reverseDuration: UgamMotion.tapIn,
      lowerBound: 0,
      upperBound: 1,
      value: 1,
    );
    _ctrl = ctrl;
    _scale = Tween<double>(begin: 0.97, end: 1)
        .chain(CurveTween(curve: UgamMotion.easeOut))
        .animate(ctrl);
  }

  @override
  void initState() {
    super.initState();
    if (widget.onTap != null) _ensureCtrl();
  }

  @override
  void didUpdateWidget(covariant UgamCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onTap != null) _ensureCtrl();
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  void _down(_) {
    if (widget.onTap == null) return;
    _ctrl?.reverse();
    HapticFeedback.lightImpact();
  }

  void _up(_) {
    if (widget.onTap == null) return;
    _ctrl?.forward();
  }

  void _cancel() {
    if (widget.onTap == null) return;
    _ctrl?.forward();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final e = UgamElevation.of(context);

    // Semantic tone → tinted fill + hairline border. `none` falls back to the
    // neutral card/cardElev surface.
    final (Color? toneFill, Color? toneBorder) = switch (widget.tone) {
      UgamCardTone.none => (null, null),
      UgamCardTone.accent => (c.accentFill, c.accent.withValues(alpha: 0.30)),
      UgamCardTone.good => (c.goodFill, c.good.withValues(alpha: 0.30)),
      UgamCardTone.warm => (c.warmFill, c.warm.withValues(alpha: 0.30)),
      UgamCardTone.danger => (
        c.danger.withValues(alpha: 0.12),
        c.danger.withValues(alpha: 0.32),
      ),
    };

    Widget surface = Container(
      decoration: BoxDecoration(
        color: toneFill ?? (widget.elev ? c.cardElev : c.card),
        borderRadius: BorderRadius.circular(widget.radius),
        border: toneBorder == null ? null : Border.all(color: toneBorder),
        // Level 1 for EVERY card, in both themes and both tones. This used to
        // be a single hand-rolled shadow that only painted on light-mode
        // untinted cards, which is why the app read as one flat plane: dark
        // mode had no depth at all and tinted cards dropped back to the page.
        // A card is the same object whatever colour it is wearing, so it sits
        // at the same height. See [UgamElevation].
        boxShadow: e.rest,
      ),
      child: Padding(padding: widget.padding, child: widget.child),
    );

    if (widget.onTap == null) return surface;

    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: _down,
      onTapUp: _up,
      onTapCancel: _cancel,
      behavior: HitTestBehavior.opaque,
      child: ScaleTransition(scale: _scale!, child: surface),
    );
  }
}
