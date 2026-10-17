part of '../bus_status_screen.dart';

class _StatusAppBar extends StatelessWidget {
  final Bus bus;
  final String tourTitle;

  /// Opens the money actions sheet (Collect / Bus money). Null hides the action
  /// (e.g. the not-found / no-layout app bars that reuse this widget elsewhere).
  final VoidCallback? onMoney;

  const _StatusAppBar({
    required this.bus,
    required this.tourTitle,
    this.onMoney,
  });

  @override
  Widget build(BuildContext context) {
    return UgamAppBar(
      title: bus.name,
      subtitle:
          '$tourTitle'
          '${bus.busNumber.isNotEmpty ? ' · ${bus.busNumber}' : ''}',
      actions: [
        if (onMoney != null)
          UgamAppBarAction(
            icon: Icons.payments_rounded,
            onTap: onMoney!,
            tooltip: tr('bus_status.action.collection_money'),
          ),
      ],
    );
  }
}

/// Compact tally row: big tabular count (assigned / total), label
/// underneath, and a thin Ugam-tinted progress bar.
class _Tally extends StatelessWidget {
  final int assigned;
  final int total;

  const _Tally({required this.assigned, required this.total});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final ratio = total == 0 ? 0.0 : assigned / total;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.md,
        vertical: UgamSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.row),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$assigned/$total',
                style: UgamText.numLg.copyWith(color: c.ink),
              ),
              Text(
                tr('bus_status.legend_booked').toUpperCase(),
                style: UgamText.micro.copyWith(color: c.ink2),
              ),
            ],
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // No percentage: "97%" restated the count above as a number no
                // one books by. Whole seats only — the free count instead.
                Text(
                  tr(
                    'capacity.free_n',
                    namedArgs: {'n': '${(total - assigned).clamp(0, total)}'},
                  ),
                  style: UgamText.tabular(
                    UgamText.bodyStrong.copyWith(color: c.ink2, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: ratio.clamp(0.0, 1.0),
                    minHeight: 6,
                    backgroundColor: c.card,
                    // Neutral fill — the status tally is meta, not a primary
                    // action, so copper stays rationed to the focal CTA.
                    valueColor: AlwaysStoppedAnimation(c.ink2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Hero card at the top of the bus status screen. Bus backdrop + bus
/// number + driver name/phone with quick-call and WhatsApp circle
/// buttons on the right.
class _DriverHeroCard extends StatelessWidget {
  final Bus bus;

  const _DriverHeroCard({required this.bus});

  Future<void> _openWhatsApp(String phone) async {
    final cleaned = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (cleaned.isEmpty) return;
    try {
      final ok = await WhatsAppService().openChat(phone: phone, message: '');
      if (!ok) {
        AppSnackBar.error(
          tr('bus_status.wa_open_failed', namedArgs: {'phone': phone}),
          title: tr('bus_status.wa_failed_title'),
        );
      }
    } catch (e) {
      AppSnackBar.error(
        tr('bus_status.wa_open_error', namedArgs: {'error': '$e'}),
        title: tr('bus_status.wa_failed_title'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final phone = bus.driverPhone;
    final hasPhone = phone.trim().isNotEmpty;
    return UgamCard.media(
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.photo),
            child: SizedBox(
              width: 84,
              height: 84,
              child: UgamBusBackdrop(seed: bus.id),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  bus.displayLabel,
                  style: UgamText.titleM.copyWith(color: c.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  bus.driverName.isEmpty
                      ? tr('bus_status.driver_pending')
                      : bus.driverName,
                  style: UgamText.bodyStrong.copyWith(
                    color: c.ink2,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (hasPhone)
                  Text(
                    phone,
                    style: UgamText.tabular(
                      UgamText.caption.copyWith(color: c.ink3, fontSize: 12),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          // Call / message only exist when there is a number to reach — two
          // greyed circles on a driver-less bus were dead controls.
          if (hasPhone) ...[
            const SizedBox(width: UgamSpacing.sm),
            _CircleAction(
              icon: Icons.phone_rounded,
              tint: c.accent,
              fill: c.accentFill,
              enabled: hasPhone,
              onTap: () => PhoneDialer.call(phone),
            ),
            const SizedBox(width: 6),
            _CircleAction(
              icon: Icons.chat_rounded,
              tint: c.good,
              fill: c.goodFill,
              enabled: hasPhone,
              onTap: () => _openWhatsApp(phone),
            ),
          ],
        ],
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final Color fill;
  final bool enabled;
  final VoidCallback onTap;

  const _CircleAction({
    required this.icon,
    required this.tint,
    required this.fill,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: enabled ? fill : c.card,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: enabled ? tint : c.ink3),
      ),
    );
  }
}
