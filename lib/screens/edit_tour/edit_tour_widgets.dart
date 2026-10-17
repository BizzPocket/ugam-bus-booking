part of '../edit_tour_screen.dart';

/// One-tap entry into the "apply this price sheet to all buses" flow. Only
/// shown when the tour has two or more buses (nothing to copy with one).
class _ApplyPriceSheetCard extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback? onTap;

  const _ApplyPriceSheetCard({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return UgamCard.plain(
      onTap: onTap,
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        children: [
          Container(
            // Decorative medallion — scales with the device, never a tap box
            // of its own (the whole card is the target).
            width: UgamScale.px(context, 38),
            height: UgamScale.px(context, 38),
            decoration: BoxDecoration(
              // Neutral, not accentFill: copying a price sheet is an action,
              // not something the agent owns, and this screen already spends
              // its one amber on the focused field.
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.stat),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.content_copy_rounded,
              size: UgamScale.px(context, 18),
              color: enabled ? c.ink2 : c.ink3,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('edit_tour.price_sheet.card_title'),
                  // `bodyStrong` IS 14 — the override was a no-op that made
                  // this look like a deliberate off-ladder size.
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  tr('edit_tour.price_sheet.card_subtitle'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Icon(Icons.chevron_right_rounded, color: c.ink3),
        ],
      ),
    );
  }
}

class _TourPreviewCard extends StatelessWidget {
  final UgamColorSet c;
  final String title;
  final String fromCity;
  final String toCity;
  final DateTime? departureDate;
  final String price;

  const _TourPreviewCard({
    required this.c,
    required this.title,
    required this.fromCity,
    required this.toCity,
    required this.departureDate,
    required this.price,
  });

  /// Route-initials monogram for the graphite backdrop, e.g. "S→M".
  String? _routeLabel() {
    final f = fromCity.trim();
    final t = toCity.trim();
    if (f.isEmpty || t.isEmpty) return null;
    return '${f.characters.first.toUpperCase()}→${t.characters.first.toUpperCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final shownTitle = title.isNotEmpty ? title : tr('edit_tour.preview.untitled');
    final from = fromCity.isNotEmpty ? fromCity : tr('edit_tour.hint_from_city');
    final to = toCity.isNotEmpty ? toCity : tr('edit_tour.hint_to_city');
    final route = '$from → $to';
    final dateText = departureDate != null
        ? Formatters.formatDateMedium(
            departureDate!,
            locale: context.locale.languageCode,
          )
        : tr('edit_tour.preview.pick_date');
    final setPriceLabel = tr('edit_tour.preview.set_price');
    final priceText = () {
      final n = double.tryParse(price);
      if (n == null || n <= 0) return setPriceLabel;
      return tr(
        'edit_tour.preview.per_seat',
        namedArgs: {'price': n.toStringAsFixed(0)},
      );
    }();

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.photo),
            child: SizedBox(
              // Decorative thumbnail — scales down with the device so it does
              // not eat a fixed 64pt of a 375pt-wide card.
              width: UgamScale.px(context, 64),
              height: UgamScale.px(context, 64),
              child: UgamBusBackdrop(
                seed: 'preview-${fromCity}_$toCity',
                label: _routeLabel(),
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    UgamReqChip(label: tr('edit_tour.preview.eyebrow')),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        tr('edit_tour.preview.as_customer'),
                        style: UgamText.caption.copyWith(color: c.ink3),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  shownTitle,
                  style: UgamText.titleM.copyWith(
                    color: title.isNotEmpty ? c.ink : c.ink3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  route,
                  style: UgamText.caption.copyWith(
                    color: (fromCity.isNotEmpty && toCity.isNotEmpty)
                        ? c.ink2
                        : c.ink3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: UgamSpacing.sm),
                Wrap(
                  // 6 is off-ladder (xs=4, sm=8) but is the pill gutter the
                  // rest of this card already uses; see the reported gap.
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _PreviewPill(
                      c: c,
                      icon: Icons.calendar_today_rounded,
                      label: dateText,
                      muted: departureDate == null,
                    ),
                    _PreviewPill(
                      c: c,
                      icon: Icons.currency_rupee_rounded,
                      label: priceText,
                      muted: priceText == setPriceLabel,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A single fact in the customer-preview card: the departure date, the fare.
///
/// `muted` means "not set yet". That distinction used to be carried by copper
/// vs grey — two amber pills side by side on a screen whose amber is supposed
/// to mean "this is yours". It is carried by INK now (set = `ink`, unset =
/// `ink3`) on one shared neutral fill, which reads the same in both themes and
/// leaves the accent to the focused field.
class _PreviewPill extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final bool muted;

  const _PreviewPill({
    required this.c,
    required this.icon,
    required this.label,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final ink = muted ? c.ink3 : c.ink;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.sm,
        vertical: UgamSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: UgamScale.px(context, 12), color: ink),
          const SizedBox(width: UgamSpacing.xs),
          Flexible(
            child: Text(
              label,
              // Was `caption` forced down to 11 — an off-ladder size invented
              // for this one pill. `caption` (12) with the weight bumped says
              // the same thing on the scale the rest of the app uses.
              style: UgamText.tabular(
                UgamText.caption.copyWith(
                  color: ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
