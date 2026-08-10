import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../design/ugam.dart';
import '../services/location_tracker_service.dart';

/// The handler's one window onto location sharing: what is happening, and the
/// single thing they can do about it.
///
/// Hidden entirely when idle — a handler on a tour that is not locked should
/// not be shown machinery that does not apply to them yet.
class TrackingStatusCard extends StatelessWidget {
  final TrackingStatus status;
  final DateTime? lastUploadAt;

  /// Stop sharing. Only offered while actually sharing.
  final VoidCallback onStop;

  /// The recovery action. Its meaning follows [status]: request permission,
  /// open app settings, or open the OS location settings.
  final VoidCallback onFix;

  const TrackingStatusCard({
    super.key,
    required this.status,
    this.lastUploadAt,
    required this.onStop,
    required this.onFix,
  });

  @override
  Widget build(BuildContext context) {
    if (status == TrackingStatus.idle) return const SizedBox.shrink();

    final c = UgamColors.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: switch (status) {
          TrackingStatus.live => _sharing(c, tone: UgamStatusTone.good),
          TrackingStatus.foregroundOnly => _sharing(
            c,
            tone: UgamStatusTone.warm,
            note: tr('tracking.card_foreground_only'),
          ),
          TrackingStatus.awaitingPermission => Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Expanded(
                child: Text(
                  tr('tracking.card_starting'),
                  style: UgamText.caption.copyWith(color: c.ink3),
                ),
              ),
            ],
          ),
          TrackingStatus.denied => _needsAction(
            c,
            title: tr('tracking.card_denied_title'),
            body: tr('tracking.card_denied_body'),
            cta: tr('tracking.card_denied_cta'),
          ),
          TrackingStatus.deniedForever => _needsAction(
            c,
            title: tr('tracking.card_denied_title'),
            body: tr('tracking.card_denied_body'),
            cta: tr('tracking.card_settings_cta'),
          ),
          TrackingStatus.serviceDisabled => _needsAction(
            c,
            title: tr('tracking.card_service_off_title'),
            body: tr('tracking.card_service_off_body'),
            cta: tr('tracking.card_service_off_cta'),
          ),
          TrackingStatus.windowClosed => _quiet(
            tr('tracking.card_window_closed'),
          ),
          // Deliberately vague: the handler cannot act on an authorisation
          // failure, and naming it would leak the bus-ownership model.
          TrackingStatus.forbidden => _quiet(tr('tracking.card_unavailable')),
          TrackingStatus.idle => const SizedBox.shrink(),
        },
      ),
    );
  }

  Widget _sharing(UgamColorSet c, {required UgamStatusTone tone, String? note}) {
    final ago = lastUploadAt == null
        ? null
        : tr(
            'tracking.card_updated_ago',
            namedArgs: {'n': _ago(lastUploadAt!)},
          );
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              UgamStatusDot(
                label: ago == null
                    ? tr('tracking.card_live')
                    : '${tr('tracking.card_live')} · $ago',
                tone: tone,
              ),
              if (note != null) ...[
                const SizedBox(height: 2),
                Text(note, style: UgamText.micro.copyWith(color: c.ink3)),
              ],
            ],
          ),
        ),
        TextButton(
          onPressed: onStop,
          child: Text(
            tr('tracking.card_stop'),
            style: UgamText.caption.copyWith(color: c.ink3),
          ),
        ),
      ],
    );
  }

  Widget _needsAction(
    UgamColorSet c, {
    required String title,
    required String body,
    required String cta,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        UgamStatusDot(label: title, tone: UgamStatusTone.warm),
        const SizedBox(height: 4),
        Text(body, style: UgamText.micro.copyWith(color: c.ink3)),
        const SizedBox(height: UgamSpacing.sm),
        UgamCTA(
          label: cta,
          leadingIcon: Icons.location_on_outlined,
          onPressed: onFix,
        ),
      ],
    );
  }

  Widget _quiet(String label) =>
      UgamStatusDot(label: label, tone: UgamStatusTone.neutral);

  /// Deliberately plain Dart rather than `plural()`: this rebuilds inside a
  /// handler's chart constantly, and `plural()` throws in widget tests unless a
  /// locale is loaded in setUpAll.
  static String _ago(DateTime t) {
    final m = DateTime.now().difference(t).inMinutes;
    if (m < 1) return 'now';
    if (m < 60) return '${m}m';
    return '${(m / 60).floor()}h';
  }
}
