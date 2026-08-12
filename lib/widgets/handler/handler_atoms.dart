// Small shared pieces of the handler surface: the call button, the leg
// badge, the delete glyph, the category pill, a read-only key/value line
// and the pickup chip. Extracted so the four tabs share ONE implementation
// each — several of these previously existed as byte-identical copies
// inside one 4,000-line file, free to drift apart.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../../controllers/pickup_controller.dart';
import '../../design/group_color.dart';
import '../../design/ugam.dart';
import '../../models/passenger.dart';
import '../../models/trip_type.dart';
import '../../utils/phone_dialer.dart';

// ─── Call button ───────────────────────────────────────────────────────

/// The round tap-to-call button shared by the shared-seat chooser, the driver
/// card, and the attendance list. Dials [phone] via the platform dialer.
///
/// The circle itself is [UgamIconButton] with the tonal `accent` tone, so it is
/// 44×44 (was a hand-rolled 40) and reads identically to every other round
/// chrome action in the app. This class survives only as the one place the
/// dialer call, the haptic and the a11y label are wired up — the driver card
/// used to re-roll the whole stack a second time.
class HandlerCallButton extends StatelessWidget {
  final String phone;

  const HandlerCallButton({super.key, required this.phone});

  @override
  Widget build(BuildContext context) {
    return UgamIconButton(
      icon: Icons.call_rounded,
      tone: UgamIconButtonTone.accent,
      onTapFeedback: HapticFeedback.selectionClick,
      onTap: () => PhoneDialer.call(phone),
      semanticLabel: tr(
        'handler_chart.call_semantic',
        namedArgs: {'phone': phone},
      ),
    );
  }
}

/// A small trip-type pill. Round-trip is muted (the common case); a one-way leg
/// uses its leg tint — GO cyan [kOneWayTint], RET violet [kReturnTint] — with a
/// "½" half-fare marker so the roster matches the grid's leg badge and the
/// handler sees who pays a different amount.
class HandlerTripBadge extends StatelessWidget {
  final TripType tripType;
  final UgamColorSet c;

  const HandlerTripBadge({super.key, required this.tripType, required this.c});

  @override
  Widget build(BuildContext context) {
    final oneWay = tripType.isOneWay;
    final isRet = tripType.usesReturn && !tripType.usesOutbound;
    final tint = isRet ? kReturnTint : kOneWayTint;
    final base = !oneWay
        ? tr('handler_chart.badge_round_trip')
        : (isRet
              ? tr('handler_chart.badge_ret')
              : tr('handler_chart.badge_go'));
    final label = oneWay
        ? tr('handler_chart.badge_half_suffix', namedArgs: {'leg': base})
        : base;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.badgeH,
        vertical: UgamSpacing.badgeV,
      ),
      decoration: BoxDecoration(
        color: oneWay ? tint : c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Text(
        label,
        style: UgamText.micro.copyWith(
          // Dark ground on the bright leg tint; muted ink on the neutral pill.
          color: oneWay ? c.bg : c.ink2,
          // No fontSize override: micro (10) is already the smallest step on
          // the scale. The old fork to 8 became ~6.8 once the root text scaler
          // multiplied it on a small phone, and the handler could not read
          // which leg a rider was on before choosing whom to collect from.
          letterSpacing: 0.3,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

/// The trash affordance on an expense / income ledger row.
///
/// Deliberately NOT a [UgamIconButton]: its `danger` tone paints a filled
/// circle, and one per row would turn a dense ledger into a column of red
/// discs. Instead the painted glyph is untouched (18pt, ink3) and only its
/// hit box grows — an invisible 44×44 box around it, so the handler stops
/// fat-fingering delete on a row they meant to tap-to-edit.
class HandlerDeleteGlyph extends StatelessWidget {
  const HandlerDeleteGlyph({super.key});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: Icon(Icons.delete_outline_rounded, size: 18, color: c.ink3),
      ),
    );
  }
}

/// The category selector pill shared by the expense and income sheets — one
/// implementation where the two sheets each carried a byte-identical copy that
/// could silently drift apart.
///
/// Styling is the tonal treatment `UgamSelectorPills` uses (accentFill + accent
/// ink + accent hairline when active). The `minHeight` is the tap-target floor:
/// the pill's own padding lands it near 40 and the caption inside shrinks with
/// the text scaler, so without the floor it drops under 44 on a small phone.
class HandlerCategoryChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const HandlerCategoryChip({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: UgamMotion.tab,
        curve: UgamMotion.easeOut,
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.lg,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: active ? c.accentFill : c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
          border: Border.all(color: active ? c.accent : c.border),
        ),
        child: Text(
          label,
          style: UgamText.caption.copyWith(
            color: active ? c.accent : c.ink2,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class HandlerReadOnlyLine extends StatelessWidget {
  final String label;
  final String value;

  const HandlerReadOnlyLine({
    super.key,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: UgamText.body.copyWith(color: c.ink2)),
        Text(
          value,
          style: UgamText.tabular(UgamText.titleS.copyWith(color: c.ink)),
        ),
      ],
    );
  }
}

/// The rider's pickup point, shown inline on the attendance row. Prefers the
/// admin-facing short CODE from [PickupController] (e.g. "ST"), falling back to
/// the name snapshot stored on the booking when no code / no controller (e.g.
/// under `flutter test`) is available. Renders nothing when neither exists.
class HandlerPickupChip extends StatelessWidget {
  final Passenger passenger;
  const HandlerPickupChip({super.key, required this.passenger});

  String? _label(PickupController? pk) {
    final code = pk?.codeFor(passenger.pickupLocationId);
    if (code != null && code.isNotEmpty) return code;
    final name = passenger.pickupLocationName;
    return (name != null && name.isNotEmpty) ? name : null;
  }

  Widget _chip(String? label) => (label == null || label.isEmpty)
      ? const SizedBox.shrink()
      : UgamReqChip(label: label, variant: UgamChipVariant.neutral);

  @override
  Widget build(BuildContext context) {
    final pk = Get.isRegistered<PickupController>()
        ? Get.find<PickupController>()
        : null;
    // Obx repaints once the async pickup list arrives.
    if (pk == null) return _chip(_label(null));
    return Obx(() => _chip(_label(pk)));
  }
}
