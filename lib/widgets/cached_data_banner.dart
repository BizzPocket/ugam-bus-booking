import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';

/// "Showing saved data from 20m ago" — the one place the app admits that what
/// is on screen came off the disk rather than off the wire.
///
/// THE POINT OF THIS WIDGET is the failure it prevents, not the pixels. The
/// previous offline layer was deleted partly because it "masked real fetch
/// failures", and an offline cache with no visible label is that same defect
/// wearing a nicer coat: the agent reads a seat chart, believes it, and seats
/// someone into a berth another device filled an hour ago. So this is
/// deliberately NOT dismissible — a staleness label the user can wave away is a
/// staleness label that is absent exactly when it matters. It disappears on its
/// own, and only when a fetch actually reaches the server.
///
/// It renders nothing at all when the data is live, so it is safe to place at
/// the top of any surface that reads the tour graph.
///
/// NEUTRAL, NEVER ACCENT. Amber means "this is yours" — a selected berth, an
/// owned row — and spending it on chrome is what dilutes it (see [Brand]). This
/// is a state, not an error and not a possession, so it uses the app's
/// neutral-chrome ink `ink2` on an elevated surface with the standard hairline,
/// the same rationing the RefreshIndicator colour follows.
class CachedDataBanner extends StatelessWidget {
  /// Retry affordance. Defaults to `TourController.refreshTours`; pass null to
  /// render the strip inert (e.g. inside a surface that already owns a refresh
  /// gesture and would double-fire).
  final Future<void> Function()? onRetry;

  const CachedDataBanner({super.key, this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<TourController>()) return const SizedBox.shrink();
    final ctrl = Get.find<TourController>();
    final c = UgamColors.of(context);

    return Obx(() {
      if (!ctrl.isShowingCachedData.value) return const SizedBox.shrink();
      final asOf = ctrl.dataAsOf.value;
      final retry = onRetry ?? ctrl.refreshTours;

      return Padding(
        // The strip owns its OWN vertical seam. Call sites therefore pass
        // horizontal padding only, and a live screen pays exactly zero height
        // for this widget instead of an 8pt ghost gap where a hidden banner
        // used to be.
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.md,
            vertical: UgamSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.row),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: UgamScale.px(context, 16),
                color: c.ink2,
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  asOf == null
                      ? tr('offline.showing_saved')
                      : tr(
                          'offline.showing_saved_at',
                          namedArgs: {'when': relativeAge(asOf)},
                        ),
                  style: UgamText.caption.copyWith(color: c.ink2, height: 1.3),
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              UgamTappable(
                onTap: () {
                  // ignore: unawaited_futures
                  retry();
                },
                pressedScale: 0.93,
                semanticLabel: tr('app.action.retry'),
                child: Padding(
                  // Padding, not a sized box: the strip is only ~34pt tall, so
                  // a 44pt tap target would set the height of the whole banner.
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.sm,
                    vertical: UgamSpacing.xs,
                  ),
                  child: Text(
                    tr('offline.retry'),
                    style: UgamText.captionStrong.copyWith(color: c.ink),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// "just now" / "20m ago" / "3h ago" / "2d ago".
///
/// Coarse ON PURPOSE. The agent needs to know whether the chart is minutes or
/// days out of date; a to-the-second figure would imply a precision the cache
/// does not have (the graph is saved once per load, and its parts can be
/// seconds apart). A future timestamp — a clock change, a device whose time
/// moved backwards — reads as "just now" rather than a negative age.
@visibleForTesting
String relativeAge(DateTime at, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(at);
  if (diff.inDays > 0) {
    return tr('offline.age_days', namedArgs: {'n': '${diff.inDays}'});
  }
  if (diff.inHours > 0) {
    return tr('offline.age_hours', namedArgs: {'n': '${diff.inHours}'});
  }
  if (diff.inMinutes > 0) {
    return tr('offline.age_minutes', namedArgs: {'n': '${diff.inMinutes}'});
  }
  return tr('offline.age_just_now');
}
