import 'package:flutter/material.dart';

import '../text_styles.dart';
import '../tokens.dart';
import 'ugam_card.dart';

/// City-to-city journey header. Used at the top of trip-detail and
/// seat-select screens.
class UgamRouteHeader extends StatelessWidget {
  final String fromCode;
  final String fromName;
  final String? fromTime;
  final String toCode;
  final String toName;
  final String? toTime;
  final String? duration;
  final IconData icon;

  const UgamRouteHeader({
    super.key,
    required this.fromCode,
    required this.fromName,
    this.fromTime,
    required this.toCode,
    required this.toName,
    this.toTime,
    this.duration,
    this.icon = Icons.directions_bus_rounded,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamCard.plain(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.lg,
        vertical: UgamSpacing.gutter,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fromCode,
                    style:
                        UgamText.titleM.copyWith(color: c.ink, fontSize: 18)),
                const SizedBox(height: 4),
                Text(
                  fromTime != null ? '$fromName · $fromTime' : fromName,
                  style:
                      UgamText.caption.copyWith(color: c.ink2, fontSize: 10.5),
                ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c.accentFill,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 14, color: c.accent),
              ),
              if (duration != null) ...[
                const SizedBox(height: 4),
                Text(duration!,
                    style:
                        UgamText.micro.copyWith(color: c.ink3, fontSize: 9.5)),
              ],
            ],
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(toCode,
                    style:
                        UgamText.titleM.copyWith(color: c.ink, fontSize: 18)),
                const SizedBox(height: 4),
                Text(
                  toTime != null ? '$toName · $toTime' : toName,
                  style:
                      UgamText.caption.copyWith(color: c.ink2, fontSize: 10.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
