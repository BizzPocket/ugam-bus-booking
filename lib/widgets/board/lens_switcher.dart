/// The Board's lens switcher — spec §5 / §11 of
/// `docs/superpowers/specs/2026-08-12-board-interaction-design.md`.
library;

import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
// `listEquals` — material.dart does not re-export foundation.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
// `SemanticsRole` is not re-exported by material.dart; the tab/tabBar roles
// below are the whole reason this control is a tab bar to a screen reader.
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../../design/components/ugam_tappable.dart';
import '../../design/text_styles.dart';
import '../../design/tokens.dart';
import '../../design/ui_scale.dart';
import '../../models/board_lens.dart';

/// How far the edge fade reaches into the strip. Wide enough that a pill
/// crossing it is visibly *dissolving* rather than sliced — the whole point of
/// the fade is that the cut reads as "there is more", never as a bug.
const double _kFadeExtent = UgamSpacing.huge2;

/// The active pill's leading dot. Small, but it is the switcher's one
/// non-colour "this is the live lens" cue, so it never scales away.
const double _kActiveDot = 6;

/// Gap between the active dot and the label it belongs to.
///
/// The scale has no named 6pt step for an INSIDE-a-control gap: `xs` (4) reads
/// as the dot touching the word, `sm` (8) reads as two separate things. The
/// codebase already hit this one step up and named it (`UgamSpacing.tight` is
/// literally "the `sm + 2` idiom, named"), so this follows that precedent
/// rather than leaving naked arithmetic at the call site. Reported as a token
/// gap; `tokens.dart` is not this task's to edit.
const double _kDotGap = UgamSpacing.sm - 2;

/// A horizontally scrollable row of lens pills — the Board's ONE navigation
/// control, standing in for the eleven screens the canvas replaces.
///
/// Everything it renders comes out of `lib/models/board_lens.dart`: it is handed
/// [BoardLensId]s and asks each one for its own translated [BoardLensId.label].
/// No lens name, colour or ordering is written down here, so adding the pickup
/// lens to the switcher is a one-word change at the call site and nothing at
/// all in this file.
///
/// Three things this control does that the `charts_screen` pill row it replaces
/// does not:
///
///  * **It is a tab bar to a screen reader, not a row of buttons.** Every pill
///    carries [SemanticsRole.tab] with its selected state set, inside a
///    [SemanticsRole.tabBar] container (spec §11: *"the lens switcher uses
///    proper tab semantics with selected state announced"*). TalkBack reads
///    "બેઠક, 1 of 2, selected" instead of five identical "button"s.
///  * **It never clips a label mid-word.** Each pill sizes to its own text
///    inside an unbounded scroll viewport — there is no `Expanded`, no
///    `ellipsis` and no shared flex to squeeze a long Gujarati label into. What
///    overflows is the STRIP, and the overflow is signalled honestly (below)
///    rather than by chopping a word in half at the viewport edge, which is the
///    exact bug on the chart screen today.
///  * **The overflow is legible.** An edge fade is painted on whichever side
///    still has content, so a half-visible pill at the edge reads as
///    "scrollable" rather than "broken". Selecting a lens also scrolls it into
///    view, so a pill can never be chosen and then invisible.
///
/// Gujarati is the primary language and runs ~30% longer than English, so the
/// strip is sized against `બોર્ડિંગ`, not `Boarding`; see
/// `test/widgets/board/lens_switcher_test.dart`, which pumps the Gujarati
/// labels on a 320pt viewport.
class BoardLensSwitcher extends StatefulWidget {
  /// The lenses to offer, in reading order — normally
  /// `BoardController.availableLenses`, ordered. Never empty.
  ///
  /// A single-lens strip still renders: with the eleven screens gone, this row
  /// is the only thing on the Board that NAMES what the colours mean, and a
  /// canvas whose colouring is unlabelled is worse than a tab bar with one tab.
  final List<BoardLensId> lenses;

  /// The lens being rendered right now — `BoardController.lens`, which already
  /// resolves manual choice over phase default (spec §6).
  final BoardLensId current;

  /// Fires on every tap, INCLUDING a tap on the already-active pill. That is
  /// deliberate: `BoardController.selectLens` treats a tap as the handler
  /// *saying* which lens they want, which pins it against a later phase change
  /// even when it already matched the default.
  final ValueChanged<BoardLensId> onChanged;

  final EdgeInsetsGeometry padding;

  const BoardLensSwitcher({
    super.key,
    required this.lenses,
    required this.current,
    required this.onChanged,
    this.padding = const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
  }) : assert(lenses.length > 0, 'the Board must have at least one lens');

  @override
  State<BoardLensSwitcher> createState() => _BoardLensSwitcherState();
}

class _BoardLensSwitcherState extends State<BoardLensSwitcher> {
  final ScrollController _scroll = ScrollController();

  /// One key per lens so the selected pill can be scrolled into view. Keyed by
  /// the lens rather than by index so reordering or narrowing
  /// [BoardLensSwitcher.lenses] cannot point a key at a different pill.
  final Map<BoardLensId, GlobalKey> _pillKeys = <BoardLensId, GlobalKey>{};

  bool _fadeStart = false;
  bool _fadeEnd = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncFades);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncFades();
      // No animation on the first frame — the strip arriving already
      // half-scrolled would read as a glitch, not as a reveal.
      _revealCurrent(animate: false);
    });
  }

  @override
  void didUpdateWidget(covariant BoardLensSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Compare the LIST, not just its length. A set that is reordered, or
    // swapped for a different set of the same size, moves the active pill to a
    // new offset and changes how far the strip overflows — and a length check
    // sees neither, leaving the active pill scrolled off-screen behind a stale
    // fade.
    final changed =
        oldWidget.current != widget.current ||
        !listEquals(oldWidget.lenses, widget.lenses);
    if (!changed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncFades();
      // Revealed on a set change as well as a lens change: the active lens can
      // keep its identity while its pill has moved out of view.
      _revealCurrent(animate: true);
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_syncFades);
    _scroll.dispose();
    super.dispose();
  }

  /// Which edges still have content behind them. Recomputed on every scroll
  /// tick AND after layout, because the answer also changes when the lens set
  /// grows or the text scale does, with no scroll involved.
  void _syncFades() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    // Half a pixel of slack: a fling settles on a fractional offset, and a fade
    // that flickers on and off at the extremes is worse than no fade.
    final start = position.pixels > position.minScrollExtent + 0.5;
    final end = position.pixels < position.maxScrollExtent - 0.5;
    if (start == _fadeStart && end == _fadeEnd) return;
    setState(() {
      _fadeStart = start;
      _fadeEnd = end;
    });
  }

  /// Brings the active pill into view. Honours `prefers-reduced-motion`
  /// (spec §11) by jumping instead of gliding.
  void _revealCurrent({required bool animate}) {
    if (!mounted || !_scroll.hasClients) return;
    final pill = _pillKeys[widget.current]?.currentContext?.findRenderObject();
    if (pill == null || !pill.attached) return;
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // THIS strip's offset and nothing else. `Scrollable.ensureVisible` walks up
    // and scrolls every ancestor viewport too, so once the Board drops this
    // switcher into a scrolling header, choosing a lens would also yank the
    // page vertically. Driving our own position keeps a lens tap to a
    // horizontal nudge of the pills.
    _scroll.position.ensureVisible(
      pill,
      // Centre it when there is room to; `ensureVisible` clamps to the scroll
      // extents, so the first and last pills still rest against their edge.
      alignment: 0.5,
      duration: (animate && !reduced) ? UgamMotion.tab : Duration.zero,
      curve: UgamMotion.easeOut,
    );
  }

  void _pick(BoardLensId lens) {
    // Spec §12: a lens change is a selection, not an impact.
    HapticFeedback.selectionClick();
    widget.onChanged(lens);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.lenses.length;
    final pills = <Widget>[
      for (var i = 0; i < total; i++)
        Padding(
          padding: EdgeInsets.only(left: i == 0 ? 0 : UgamSpacing.sm),
          child: _LensPill(
            key: _pillKeys.putIfAbsent(widget.lenses[i], GlobalKey.new),
            lens: widget.lenses[i],
            active: widget.lenses[i] == widget.current,
            index: i,
            total: total,
            onTap: () => _pick(widget.lenses[i]),
          ),
        ),
    ];

    final strip = SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: widget.padding,
      // The tab-bar node sits INSIDE the viewport so its semantic children are
      // the pills themselves; wrapping the scroll view instead would put the
      // scrollable's own node in between and the tab-bar contract
      // ("every child is a tab") would be broken by a node nobody can see.
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        role: SemanticsRole.tabBar,
        label: tr('board_lens_switcher.a11y_group'),
        child: Row(mainAxisSize: MainAxisSize.min, children: pills),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Nothing overflows — skip the mask entirely rather than pay for a
        // saveLayer, and avoid nibbling the outermost pixel of the end pills.
        if (!_fadeStart && !_fadeEnd) return strip;
        final width = constraints.maxWidth;
        if (!width.isFinite || width <= 0) return strip;
        final fade = math.min(_kFadeExtent, width / 4);
        final startStop = _fadeStart ? (fade / width).clamp(0.0, 0.5) : 0.0;
        final endStop = _fadeEnd ? (1 - fade / width).clamp(0.5, 1.0) : 1.0;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            // An ALPHA mask, not palette colour: `dstIn` multiplies the strip's
            // alpha by this gradient's, so only the alpha channel is read and
            // opaque-vs-transparent is the only thing these two values mean.
            colors: const [
              Colors.transparent,
              Colors.black,
              Colors.black,
              Colors.transparent,
            ],
            stops: [0, startStop, endStop, 1],
          ).createShader(rect),
          child: strip,
        );
      },
    );
  }
}

/// One lens pill.
///
/// The active state is carried FOUR ways, only one of which is hue, so it
/// survives both a colour-blind reader and a screen reader (spec §11):
/// a tonal fill, a heavier accent hairline, a leading dot the inactive pills do
/// not have, and `selected: true` on a [SemanticsRole.tab] node.
class _LensPill extends StatelessWidget {
  final BoardLensId lens;
  final bool active;
  final int index;
  final int total;
  final VoidCallback onTap;

  const _LensPill({
    super.key,
    required this.lens,
    required this.active,
    required this.index,
    required this.total,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // ONE node per pill, built explicitly rather than left to merge. A tab that
    // does not carry its own tap action is not a tab (the framework asserts
    // exactly that), and nesting an annotation over `UgamTappable`'s internal
    // Semantics produced two nodes — the role on the outer one, the tap action
    // on the inner. So the node is declared here in full and the wrapper's own
    // semantics are excluded; the pill keeps its press animation and its
    // gesture, and the accessibility tree sees a single, correct tab.
    return Semantics(
      container: true,
      role: SemanticsRole.tab,
      selected: active,
      button: true,
      label: tr(
        'board_lens_switcher.a11y_tab',
        namedArgs: {
          'lens': lens.label,
          'index': '${index + 1}',
          'total': '$total',
        },
      ),
      onTap: onTap,
      child: ExcludeSemantics(
        child: UgamTappable(
          onTap: onTap,
          // The haptic is fired by the switcher as a `selectionClick`; letting
          // the wrapper add its own `lightImpact` would double-buzz the tap.
          haptic: false,
          // Small chrome needs more travel than a card to read as pressed.
          pressedScale: 0.93,
          child: ConstrainedBox(
            // 44pt hit box around a pill that paints smaller. The `Center` is
            // load-bearing: without it the minHeight propagates into the
            // container and inflates the visible pill.
            constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
            child: Center(
              child: AnimatedContainer(
                duration: UgamMotion.tab,
                curve: UgamMotion.easeOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: UgamSpacing.gutter,
                  vertical: UgamSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: active ? c.accentFill : c.card,
                  borderRadius: BorderRadius.circular(UgamRadius.chip),
                  border: Border.all(
                    color: active ? c.accent.withValues(alpha: 0.55) : c.border,
                    width: active ? 1.4 : 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (active) ...[
                      Container(
                        width: _kActiveDot,
                        height: _kActiveDot,
                        decoration: BoxDecoration(
                          color: c.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: _kDotGap),
                    ],
                    // No `overflow`, no `Flexible`, no shared flex: the pill is
                    // as wide as its label, and the STRIP scrolls. This one
                    // line is why a Gujarati name cannot be cut mid-word.
                    Text(
                      lens.label,
                      maxLines: 1,
                      softWrap: false,
                      style: UgamText.bodyStrong.copyWith(
                        color: active ? c.accent : c.ink2,
                        fontWeight: active
                            ? FontWeight.w700
                            : FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
