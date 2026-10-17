part of '../create_tour_screen.dart';

/// Compact live-preview card that mirrors a tour list row. Updates as
/// the agent types so they see what the customer will see.
class _TourPreviewCard extends StatelessWidget {
  final UgamColorSet c;
  final String title;
  final String fromCity;
  final String toCity;
  final DateTime? departureDate;
  final XFile? coverImage;

  const _TourPreviewCard({
    required this.c,
    required this.title,
    required this.fromCity,
    required this.toCity,
    required this.departureDate,
    this.coverImage,
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
    final shownTitle = title.isNotEmpty
        ? title
        : tr('create_tour.preview.untitled');
    final from = fromCity.isNotEmpty
        ? fromCity
        : tr('create_tour.hint.from_city');
    final to = toCity.isNotEmpty ? toCity : tr('create_tour.hint.to_city');
    final route = '$from → $to';
    final dateText = departureDate != null
        ? Formatters.formatDateMedium(
            departureDate!,
            locale: context.locale.languageCode,
          )
        : tr('create_tour.preview.pick_date');

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.photo),
            child: SizedBox(
              width: 64,
              height: 64,
              child: coverImage != null
                  ? Image.file(File(coverImage!.path), fit: BoxFit.cover)
                  : UgamBusBackdrop(
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
                    // A section eyebrow, not a selection: [UgamReqChip]'s
                    // DEFAULT variant is `accent`, which spent the one "this is
                    // yours" colour on the word PREVIEW. Neutral.
                    UgamReqChip(
                      label: tr('create_tour.preview.eyebrow'),
                      variant: UgamChipVariant.neutral,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        tr('create_tour.preview.as_customer'),
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
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    // The ONE accent on this screen, and it is the rule's own
                    // case: "the currently-selected value" — the date the agent
                    // picked. Still un-picked → neutral, because there is
                    // nothing of theirs in it yet.
                    UgamReqChip(
                      label: dateText,
                      variant: departureDate == null
                          ? UgamChipVariant.neutral
                          : UgamChipVariant.accent,
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

/// Optional broadcast hero image: an "add image" tile when empty, or a
/// thumbnail preview with a remove button once picked. The image rides along
/// with the WhatsApp broadcast template's header.
class _BroadcastImagePicker extends StatelessWidget {
  final UgamColorSet c;
  final XFile? image;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  const _BroadcastImagePicker({
    required this.c,
    required this.image,
    required this.onPick,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    if (image == null) {
      return UgamTappable(
        onTap: onPick,
        semanticLabel: tr('create_tour.broadcast_add_image'),
        child: Container(
          // Tappable box → UgamScale.tap, which shrinks with the device but
          // never below the 44pt floor. A bare `52` shrank nothing and a bare
          // UgamScale.px would have taken it to 44.2 on a small phone.
          height: UgamScale.tap(context, 52),
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.input),
          ),
          child: Row(
            children: [
              Icon(Icons.add_photo_alternate_rounded, size: 18, color: c.ink2),
              const SizedBox(width: UgamSpacing.sm + 2),
              Expanded(
                child: Text(
                  tr('create_tour.broadcast_add_image'),
                  style: UgamText.body.copyWith(color: c.ink2),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.sm),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.input),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(UgamRadius.photo),
            child: Image.file(
              File(image!.path),
              width: 56,
              height: 56,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Text(
              tr('create_tour.broadcast_image_added'),
              style: UgamText.caption.copyWith(color: c.ink),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Was a bare GestureDetector around an 18pt glyph in 6pt padding —
          // a 30×30 target with no press feedback at all.
          //
          // NOT [UgamIconButton]: its neutral tone paints a `cardElev` disc,
          // and this strip is already `cardElev`, so the button would have
          // been an invisible circle. [UgamTappable] is the documented case
          // for the leftovers the three components don't fit — same scale +
          // haptic + a11y, no fill of its own — and the box is squared up to
          // the 44pt floor via [UgamScale.tap].
          UgamTappable(
            onTap: onRemove,
            semanticLabel: tr('create_tour.broadcast_remove_image'),
            pressedScale: 0.93,
            child: SizedBox(
              width: UgamScale.tap(context, 44),
              height: UgamScale.tap(context, 44),
              child: Center(
                child: Icon(Icons.close_rounded, size: 18, color: c.ink2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
