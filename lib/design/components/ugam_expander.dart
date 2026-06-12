import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../text_styles.dart';
import '../tokens.dart';
import 'ugam_card.dart';

/// A collapsible card section: a tappable header (icon + title + optional
/// subtitle + rotating chevron) over a body that animates open/closed.
/// Replaces the hand-rolled "Container + chevron + setState" collapsible
/// blocks (e.g. add-bus price bands / overrides).
///
///   * [title] (required) — header label
///   * [subtitle] — optional muted line under the title
///   * [icon] — optional leading glyph
///   * [child] — the body revealed when expanded
///   * [initiallyExpanded] — open on first build (default `false`)
///   * [trailing] — optional widget shown left of the chevron (e.g. a count)
class UgamExpander extends StatefulWidget {
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget child;
  final bool initiallyExpanded;
  final Widget? trailing;

  const UgamExpander({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.icon,
    this.initiallyExpanded = false,
    this.trailing,
  });

  @override
  State<UgamExpander> createState() => _UgamExpanderState();
}

class _UgamExpanderState extends State<UgamExpander> {
  late bool _open = widget.initiallyExpanded;

  void _toggle() {
    HapticFeedback.selectionClick();
    setState(() => _open = !_open);
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggle,
            child: Row(
              children: [
                if (widget.icon != null) ...[
                  Icon(widget.icon, size: 18, color: c.ink2),
                  const SizedBox(width: UgamSpacing.sm + 2),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        style: UgamText.bodyStrong.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle!,
                          style: UgamText.caption.copyWith(color: c.ink3),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.trailing != null) ...[
                  widget.trailing!,
                  const SizedBox(width: UgamSpacing.sm),
                ],
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
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.only(top: UgamSpacing.md),
              child: widget.child,
            ),
            crossFadeState:
                _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: UgamMotion.sheet,
            sizeCurve: UgamMotion.easeOut,
          ),
        ],
      ),
    );
  }
}
