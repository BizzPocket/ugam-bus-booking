import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';
import 'ugam_card.dart';

/// One line in a [UgamHeroStat] breakdown: a label on the left and a tabular
/// value on the right, with an optional per-line [tone] for the value.
class HeroStatLine {
  final String label;
  final String value;
  final Color? tone;

  const HeroStatLine(this.label, this.value, {this.tone});
}

/// The big single-number hero card — the money/capacity centrepiece of the
/// dashboard and detail headers. A `micro` caps [label] over a large tabular
/// [value] (tinted by [tone], default ink), with an optional [secondary]
/// caption.
///
/// When [breakdown] is supplied a chevron toggles an [AnimatedSize] column of
/// label/value rows, so a single "Collected ₹X" hero can expand into its
/// component lines without a second screen. When [onTap] is set AND there is
/// no [breakdown], the whole card is tappable instead.
class UgamHeroStat extends StatefulWidget {
  final String label;
  final String value;
  final Color? tone;
  final String? secondary;
  final List<HeroStatLine>? breakdown;
  final bool initiallyExpanded;
  final VoidCallback? onTap;

  /// When false, render the hero content directly (no wrapping [UgamCard]) so
  /// it can live inside a card the caller already owns — avoids card-in-card.
  final bool framed;

  const UgamHeroStat({
    super.key,
    required this.label,
    required this.value,
    this.tone,
    this.secondary,
    this.breakdown,
    this.initiallyExpanded = false,
    this.onTap,
    this.framed = true,
  });

  @override
  State<UgamHeroStat> createState() => _UgamHeroStatState();
}

class _UgamHeroStatState extends State<UgamHeroStat> {
  late bool _open = widget.initiallyExpanded;

  bool get _hasBreakdown =>
      widget.breakdown != null && widget.breakdown!.isNotEmpty;

  void _toggle() {
    HapticFeedback.selectionClick();
    setState(() => _open = !_open);
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.label.toUpperCase(),
                style: UgamText.micro.copyWith(color: c.ink2),
              ),
              const SizedBox(height: UgamSpacing.sm),
              Text(
                widget.value,
                style: UgamText.numXl.copyWith(color: widget.tone ?? c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (widget.secondary != null) ...[
                const SizedBox(height: UgamSpacing.xs),
                Text(
                  widget.secondary!,
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
        if (_hasBreakdown)
          AnimatedRotation(
            turns: _open ? 0.5 : 0,
            duration: UgamMotion.tab,
            curve: UgamMotion.easeOut,
            child: Icon(
              Icons.expand_more_rounded,
              size: 22,
              color: c.ink2,
            ),
          ),
      ],
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        header,
        if (_hasBreakdown)
          AnimatedSize(
            duration: UgamMotion.sheet,
            curve: UgamMotion.easeOut,
            alignment: Alignment.topCenter,
            child: _open
                ? Padding(
                    padding: const EdgeInsets.only(top: UgamSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final line in widget.breakdown!)
                          Padding(
                            padding:
                                const EdgeInsets.only(bottom: UgamSpacing.sm),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Flexible(
                                  child: Text(
                                    line.label,
                                    style: UgamText.body
                                        .copyWith(color: c.ink2),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: UgamSpacing.md),
                                Text(
                                  line.value,
                                  style: UgamText.tabular(
                                    UgamText.bodyStrong.copyWith(
                                      color: line.tone ?? c.ink,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
      ],
    );

    // A breakdown card owns its own tap (the chevron toggle); otherwise the
    // whole card taps when an [onTap] is given.
    if (_hasBreakdown) {
      final tappable = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        child: body,
      );
      return widget.framed ? UgamCard.plain(child: tappable) : tappable;
    }

    if (!widget.framed) {
      return widget.onTap == null
          ? body
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onTap,
              child: body,
            );
    }
    return UgamCard.plain(
      onTap: widget.onTap,
      child: body,
    );
  }
}
