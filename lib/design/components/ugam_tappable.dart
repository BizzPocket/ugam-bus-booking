import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

/// Press feedback for anything that isn't already a design-system control.
///
/// The app hand-rolls ~120 bare `GestureDetector`s — rows, tiles, chips,
/// avatars, inline "change" affordances. None of them acknowledge the finger:
/// no scale, no haptic, no fill change. A control that does not answer a touch
/// reads as a mockup no matter how good it looks, and the fix is not to make
/// every screen invent its own [AnimationController]. Wrap the child in this.
///
/// It is a *pure* wrapper: no padding, no decoration, no size of its own. It
/// occupies exactly the space its [child] does, so dropping it in cannot move
/// a pixel of layout — the press is a [Transform], which paints smaller
/// without ever shrinking the box the finger actually hits.
///
/// ```dart
/// // BEFORE — fires, but the finger gets nothing back:
/// GestureDetector(
///   onTap: () => _openTour(t),
///   behavior: HitTestBehavior.opaque,
///   child: _tourRow(t),
/// )
///
/// // AFTER — same tree, same hit behaviour, plus scale + haptic + a11y:
/// UgamTappable(
///   onTap: () => _openTour(t),
///   semanticLabel: tr('tours.open_semantic'),
///   child: _tourRow(t),
/// )
/// ```
///
/// **Reach for the specific component first.** A round chrome action is
/// [UgamIconButton]; a card surface is `UgamCard(onTap: …)`; a labelled button
/// is [UgamButton] / `UgamCTA`. Each already ships this feedback. This exists
/// for the leftovers those three don't cover.
class UgamTappable extends StatefulWidget {
  final Widget child;

  /// Null (with a null [onLongPress]) renders the child inert — no gesture and
  /// no press animation — which is the drop-in equivalent of the common
  /// `onTap: enabled ? _do : null` idiom.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Screen-reader label. Supply it whenever the child isn't self-describing
  /// text; the wrapper marks the subtree as a button either way.
  final String? semanticLabel;

  /// Tap-down [HapticFeedback.lightImpact] (and [HapticFeedback.mediumImpact]
  /// on long-press). On by default — matching `UgamCard`. Pass false only when
  /// the callback itself already fires one, or when the site can repeat fast
  /// enough that buzzing would turn into a rattle.
  final bool haptic;

  /// Scale at full press. Defaults to `UgamCard`'s 0.97, which is tuned for a
  /// row/tile-sized surface. Small chrome (a chip, a 20pt glyph) needs more
  /// travel to read the same — pass ~0.93 there.
  final double pressedScale;

  /// Mirrors [GestureDetector.behavior]. Opaque by default so transparent gaps
  /// inside the child still take the tap — the setting most of the hand-rolled
  /// detectors already pass.
  final HitTestBehavior behavior;

  const UgamTappable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
    this.haptic = true,
    this.pressedScale = 0.97,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<UgamTappable> createState() => _UgamTappableState();
}

class _UgamTappableState extends State<UgamTappable>
    with SingleTickerProviderStateMixin {
  // Same controller shape as [UgamCard] and [UgamIconButton]: rests at 1 and
  // REVERSES into the press, so `duration` is the release and
  // `reverseDuration` the press-down. Built eagerly (not via a `late final`
  // initializer) so it is always created while the element is active — a lazy
  // one on an inert instance would first run inside dispose(), where the
  // TickerMode ancestor lookup throws.
  late final AnimationController _ctrl;
  late Animation<double> _scale;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  Animation<double> _buildScale() => Tween<double>(
    begin: widget.pressedScale,
    end: 1,
  ).chain(CurveTween(curve: UgamMotion.easeOut)).animate(_ctrl);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: UgamMotion.tapOut,
      reverseDuration: UgamMotion.tapIn,
      lowerBound: 0,
      upperBound: 1,
      value: 1,
    );
    _scale = _buildScale();
  }

  @override
  void didUpdateWidget(covariant UgamTappable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pressedScale != oldWidget.pressedScale) _scale = _buildScale();
    // Losing both handlers mid-press would otherwise strand the child at the
    // pressed scale with no gesture left to release it.
    if (!_enabled && _ctrl.value != 1) _ctrl.value = 1;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _down(TapDownDetails _) {
    if (!_enabled) return;
    _ctrl.reverse();
    if (widget.haptic) HapticFeedback.lightImpact();
  }

  void _up(TapUpDetails _) {
    if (!_enabled) return;
    _ctrl.forward();
  }

  void _cancel() {
    if (!_enabled) return;
    _ctrl.forward();
  }

  void _longPress() {
    // The long-press recognizer winning the arena already cancels the tap (and
    // so releases the scale); forwarding again is idempotent and keeps the
    // restore honest if that ever stops being true.
    _ctrl.forward();
    if (widget.haptic) HapticFeedback.mediumImpact();
    widget.onLongPress!();
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) {
      if (widget.semanticLabel == null) return widget.child;
      return Semantics(
        button: true,
        enabled: false,
        label: widget.semanticLabel,
        child: widget.child,
      );
    }

    return Semantics(
      button: true,
      enabled: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress == null ? null : _longPress,
        onTapDown: _down,
        onTapUp: _up,
        onTapCancel: _cancel,
        behavior: widget.behavior,
        // Transform-based: the painted child shrinks, the laid-out box does
        // not, so a 44pt target stays 44pt for the whole press.
        child: ScaleTransition(scale: _scale, child: widget.child),
      ),
    );
  }
}
