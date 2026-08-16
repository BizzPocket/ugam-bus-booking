import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../design/ugam.dart';
import '../../services/location_tracker_service.dart';

/// The one-line "the office cannot see this bus" strip, pinned in the handler
/// shell above the tab body so it is on screen from every tab.
///
/// [TrackingStatusCard] is the full account of location sharing, and it lives
/// on the TRIP tab — the fourth of four, on a shell that opens on the Board. So
/// every way sharing can fail was effectively invisible: the tracker calls
/// `_stopAndClear(forbidden)` / `_stopAndClear(windowClosed)` in silence
/// (location_tracker_service.dart:316), a revoked permission or a flipped-off
/// location switch announced nothing either, and the agent's live map simply
/// stayed empty — with no way to tell a parked bus from a phone that had
/// quietly stopped reporting hours ago.
///
/// Deliberately NOT a second copy of the card: one line, one action, and
/// NOTHING AT ALL while sharing is healthy. A strip that is always on screen is
/// chrome, and chrome is the thing a handler learns to stop reading.
class HandlerTrackingStrip extends StatelessWidget {
  final TrackingStatus status;

  /// Runs the shell's recovery flow — the very same `_onTrackingFix` the Trip
  /// tab's card fires, so the two surfaces can never drift into two behaviours.
  final VoidCallback onFix;

  const HandlerTrackingStrip({
    super.key,
    required this.status,
    required this.onFix,
  });

  /// The copy for a state worth a line, or null for one that isn't.
  ///
  /// `live` and `foregroundOnly` are working states and say nothing here.
  /// `awaitingPermission` is a moment, not a problem — the strip would flash on
  /// every cold start. `idle` means tracking never applied to this handler.
  ///
  /// `actionable` splits the two halves of the list: the first three are the
  /// handler's own device refusing, which a tap genuinely fixes. The last two
  /// are the SERVER having closed the door — a tap only re-asks, so they are
  /// stated rather than alarmed about.
  static ({String label, String cta, bool actionable})? copyFor(
    TrackingStatus status,
  ) => switch (status) {
    TrackingStatus.denied => (
      label: tr('tracking.card_denied_title'),
      cta: tr('tracking.card_denied_cta'),
      actionable: true,
    ),
    TrackingStatus.deniedForever => (
      label: tr('tracking.card_denied_title'),
      cta: tr('tracking.card_settings_cta'),
      actionable: true,
    ),
    TrackingStatus.serviceDisabled => (
      label: tr('tracking.card_service_off_title'),
      cta: tr('tracking.card_service_off_cta'),
      actionable: true,
    ),
    TrackingStatus.windowClosed => (
      label: tr('tracking.card_window_closed'),
      cta: tr('tracking.strip_retry'),
      actionable: false,
    ),
    // Deliberately vague, exactly as the card is: the handler cannot act on an
    // authorisation failure, and naming it would leak the bus-ownership model.
    TrackingStatus.forbidden => (
      label: tr('tracking.card_unavailable'),
      cta: tr('tracking.strip_retry'),
      actionable: false,
    ),
    TrackingStatus.idle ||
    TrackingStatus.awaitingPermission ||
    TrackingStatus.live ||
    TrackingStatus.foregroundOnly => null,
  };

  @override
  Widget build(BuildContext context) {
    final copy = copyFor(status);
    if (copy == null) return const SizedBox.shrink();

    final c = UgamColors.of(context);
    // `danger` is the palette's "something needs you", which is precisely what
    // a bus that has stopped reporting is; the server-side states drop to plain
    // ink3 because there is nothing for the handler to do about them. NOT the
    // accent under any circumstance — amber means "this is yours" (a berth, a
    // leg), and spending it on an alert is what empties it of meaning.
    final tone = copy.actionable ? c.danger : c.ink3;
    final fill = copy.actionable ? c.dangerFill : c.cardElev;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        0,
      ),
      child: Semantics(
        button: true,
        label: '${copy.label}. ${copy.cta}',
        child: Material(
          color: fill,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          child: InkWell(
            onTap: onFix,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            child: Container(
              // The strip is the whole tap target, so it carries the 44 floor
              // itself — its own padding lands near 34 once the caption inside
              // shrinks with the text scaler.
              constraints: BoxConstraints(
                minHeight: UgamScale.tap(context, 44),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.sm,
              ),
              child: Row(
                children: [
                  Icon(Icons.location_off_rounded, size: 16, color: tone),
                  const SizedBox(width: UgamSpacing.sm),
                  Expanded(
                    child: Text(
                      copy.label,
                      // Two lines before ellipsing: Gujarati and Hindi run
                      // noticeably longer than the English here, and a truncated
                      // "Location permission ne…" states nothing at all.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: UgamText.caption.copyWith(
                        color: tone,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: UgamSpacing.sm),
                  Text(
                    copy.cta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: UgamText.caption.copyWith(
                      color: tone,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 16, color: tone),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
