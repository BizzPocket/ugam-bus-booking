part of '../customer_tour_list_screen.dart';

class _GroupHeader extends StatelessWidget {
  final String label;
  final int count;
  final UgamColorSet c;

  const _GroupHeader({
    required this.label,
    required this.count,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            label,
            style: UgamText.titleM.copyWith(color: c.ink),
            maxLines: 2,
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.badgeH,
            vertical: UgamSpacing.badgeV,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Text(
            '$count',
            style: UgamText.tabular(UgamText.micro.copyWith(color: c.ink2)),
          ),
        ),
      ],
    );
  }
}

class _TourRow extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final VoidCallback onTap;
  final VoidCallback onBook;

  const _TourRow({
    required this.tour,
    required this.c,
    required this.onTap,
    required this.onBook,
  });

  /// Decode the banner at the width we paint, not the width uploaded. The
  /// picker stores at maxWidth 1600, so a full-bleed card banner would
  /// otherwise decode a ~6.8 MB bitmap PER ROW.
  static int _decodeWidth(BuildContext context) {
    final mq = MediaQuery.of(context);
    final physical = (mq.size.width * mq.devicePixelRatio).round();
    if (physical <= 0) return 800;
    return physical > 1600 ? 1600 : physical;
  }

  @override
  Widget build(BuildContext context) {
    // NOTE: there is deliberately no seats-left chip here any more. It read
    // `tour.totalBusSeats`, and `buses` has no anon SELECT policy — so on the
    // customer side that sum is ALWAYS 0, `hasCapacity` was always false, and
    // every row on every tour showed the same generic "open" chip. A count we
    // cannot know is worse than no count; the detail screen fetches the real
    // one through the public RPC and states it there.
    final closed = !tour.acceptsBookings;
    final countdown = departureCountdownLabel(tour.departureDate);
    final hasPhoto = (tour.broadcastImageUrl ?? '').trim().isNotEmpty;
    final meta = _metaLine(tour, includeTime: hasPhoto);
    final description = (tour.description ?? '').trim();
    final blurb = description.isEmpty ? null : description;

    return UgamCard.plain(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(UgamRadius.card),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // TWO different headers, and which one you get depends on whether
            // there is anything real to show.
            //
            // With a photo: the organiser's own broadcast image — the same one
            // that goes out on WhatsApp, and the reason a customer recognises
            // the trip. It earns 148 px.
            //
            // Without one: a ROUTE BOARD, not a placeholder. The old row filled
            // the same 148 px with a generated graphite gradient, which is
            // indistinguishable from an image that failed to load and tells the
            // customer nothing. The board spends that space on the two facts
            // they are actually scanning for — where it goes and when it leaves.
            if (hasPhoto)
              _PhotoBanner(tour: tour, decodeWidth: _decodeWidth(context))
            else
              _RouteBoard(tour: tour, c: c),
            Padding(
              padding: const EdgeInsets.all(UgamSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tour.title,
                    style: UgamText.titleM.copyWith(color: c.ink),
                    // Two lines: these titles carry the festival name AND the
                    // date, and one line cut every one of them mid-word.
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  // The route only belongs here on the photo variant — the
                  // board already states it, and saying it twice in one card
                  // is what the detail page was cleaned up for.
                  if (hasPhoto) ...[
                    const SizedBox(height: 3),
                    Text(
                      // No leading arrow icon. A south-east glyph next to a
                      // route encodes nothing — the "→" between the cities
                      // already says which way the bus goes.
                      '${tour.fromCity} → ${tour.toCity}',
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 2,
                    ),
                  ],
                  // A two-line teaser of the organiser's own blurb. The field
                  // was already fetched and only ever read on the detail page,
                  // so the card threw away the one thing that says what the
                  // trip actually IS. Omitted entirely when unset — never a
                  // reserved blank.
                  if (blurb != null) ...[
                    const SizedBox(height: UgamSpacing.sm),
                    Text(
                      blurb,
                      style: UgamText.body.copyWith(color: c.ink2),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (meta != null) ...[
                    const SizedBox(height: UgamSpacing.sm),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            Icons.schedule_rounded,
                            size: 13,
                            color: c.ink3,
                          ),
                        ),
                        const SizedBox(width: 5),
                        // Departure time and the return date — both already on
                        // the model, both previously thrown away, and both the
                        // first thing anyone asks about a trip.
                        Expanded(
                          child: Text(
                            meta,
                            style: UgamText.tabular(
                              UgamText.caption.copyWith(color: c.ink2),
                            ),
                            maxLines: 2,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: UgamSpacing.md),
                  // Both sides are flexible and the free space goes BETWEEN
                  // them, so the pill stays pinned right while neither child
                  // can push the other off the card. A trailing widget sized to
                  // its own natural width is unbounded in a Row: one long
                  // translation of "Book" and the countdown silently clips.
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // No price. It is withheld on the detail page — the fare
                      // is settled over WhatsApp — and a figure here would
                      // contradict that the moment the customer taps through.
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(right: UgamSpacing.sm),
                          child: countdown == null
                              ? const SizedBox.shrink()
                              : Text(
                                  countdown,
                                  style: UgamText.tabular(
                                    UgamText.caption.copyWith(color: c.ink3),
                                  ),
                                  maxLines: 2,
                                ),
                        ),
                      ),
                      // One-tap Book pill — jumps straight to the booking step,
                      // collapsing list → detail → form to a single nav. Its
                      // own gesture, so it doesn't bubble to tap-to-detail.
                      Flexible(child: _BookPill(c: c, closed: closed, onTap: onBook)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The secondary facts line: departure time · return date. Null when the
  /// organiser has recorded neither, so the row simply omits it rather than
  /// reserving space for a blank.
  ///
  /// Both values come straight off [Tour] and were already fetched — the row
  /// just never rendered them, which is a large part of why a card that was
  /// mostly grey block had so little to say.
  ///
  /// [includeTime] is false on the no-photo variant, where [_RouteBoard] has
  /// already stated the departure time next to the route.
  static String? _metaLine(Tour tour, {required bool includeTime}) {
    final parts = <String>[
      if (includeTime) ?formatHhMm(tour.departureTime),
      if (tour.returnDate != null)
        tr(
          'customer_tour_list.returns_on',
          namedArgs: {'date': _formatDate(tour.returnDate!)},
        ),
    ];
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  /// `12 Sep` in the active locale.
  ///
  /// No `.toUpperCase()`: Gujarati and Hindi have no case, so it did nothing at
  /// all on the primary language and only ever styled the English build.
  static String _formatDate(DateTime d) => '${d.day} ${customerMonthShort(d.month)}';
}

/// The organiser's broadcast photo, with the departure date badged over it.
///
/// While the image is in flight the strip is a plain surface. If it FAILS the
/// whole banner becomes the [_RouteBoard] the no-photo card already uses — it
/// used to fall back to a bus backdrop stamped with a route monogram
/// ("સુ→ત"), which read as a broken image with a cipher on it.
class _PhotoBanner extends StatefulWidget {
  final Tour tour;
  final int decodeWidth;

  const _PhotoBanner({required this.tour, required this.decodeWidth});

  @override
  State<_PhotoBanner> createState() => _PhotoBannerState();
}

class _PhotoBannerState extends State<_PhotoBanner> {
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final tour = widget.tour;
    if (_failed) return _RouteBoard(tour: tour, c: c);
    final loading = ColoredBox(color: c.cardElev);
    return SizedBox(
      height: UgamScale.px(context, 148),
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Disk-cached across cold starts (the URL is the cache key): the
          // list used to re-download every poster on every launch.
          CachedNetworkImage(
            imageUrl: tour.broadcastImageUrl!.trim(),
            fit: BoxFit.cover,
            // Posters put faces at the top; a centre crop cut them off.
            alignment: Alignment.topCenter,
            memCacheWidth: widget.decodeWidth,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            placeholder: (_, _) => loading,
            errorWidget: (_, _, _) {
              // Swap to the route board after this frame — the error arrives
              // mid-build, where setState is not allowed.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !_failed) setState(() => _failed = true);
              });
              return loading;
            },
          ),
          // Scrim top and bottom only — enough to hold the date badge over any
          // photo without flattening it. These four values are NOT theme
          // colours and deliberately have no token: the badge floats on an
          // arbitrary uploaded image, so its contrast can't come from the page.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x8C000000),
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0x66000000),
                ],
                stops: [0.0, 0.35, 0.65, 1.0],
              ),
            ),
          ),
          Positioned(
            left: UgamSpacing.tight,
            top: UgamSpacing.tight,
            child: _BannerBadge(
              label: _TourRow._formatDate(tour.departureDate),
            ),
          ),
        ],
      ),
    );
  }
}

/// The header for a tour with no photo: a date medallion beside the route.
///
/// This is the replacement for the generated grey gradient. Every pixel of it
/// is a fact the customer came for, it needs no network, and it cannot be
/// mistaken for a broken image.
class _RouteBoard extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _RouteBoard({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final side = UgamScale.px(context, 58);
    return Container(
      width: double.infinity,
      color: c.cardElev,
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: Row(
        children: [
          Container(
            width: side,
            height: side,
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${tour.departureDate.day}',
                  style: UgamText.tabular(
                    UgamText.numLg.copyWith(color: c.ink),
                  ),
                ),
                const SizedBox(height: 2),
                // caption, not micro: micro's 1.4 letter-spacing pulls a
                // Gujarati month ("સપ્ટે") apart at the conjuncts and pushes it
                // past the medallion.
                Text(
                  customerMonthShort(tour.departureDate.month),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Wraps to a second line rather than ellipsing — a route is the
                // one fact on the card that must READ, and Gujarati city names
                // ("અમદાવાદ → અંબાજી") are long.
                Text(
                  '${tour.fromCity} → ${tour.toCity}',
                  style: UgamText.titleS.copyWith(color: c.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                // The departure time sits here, where a real departure board
                // puts it — beside the route, under the date. On the photo
                // variant there is no board, so it moves into the meta line
                // below instead; it is never shown twice.
                if (formatHhMm(tour.departureTime) case final time?) ...[
                  const SizedBox(height: 3),
                  Text(
                    time,
                    style: UgamText.tabular(
                      UgamText.caption.copyWith(color: c.ink2),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A small label that sits ON the card banner — the date, or the closed state.
///
/// Uses its own dark scrim and white ink rather than the theme's chip colours:
/// the badge floats over an arbitrary photo, so it cannot rely on the page
/// background for contrast the way `UgamReqChip` does.
class _BannerBadge extends StatelessWidget {
  final String label;

  const _BannerBadge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UgamSpacing.sm,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: const Color(0x99000000),
        borderRadius: BorderRadius.circular(UgamRadius.chip),
      ),
      child: Text(
        label,
        style: UgamText.tabular(
          UgamText.caption.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Trailing "Book" pill on a tour row. Its own gesture (so it doesn't bubble up
/// to the row's tap-to-detail) takes the customer straight to the booking form.
///
/// Once the tour is locked there is no tappable affordance at all — it becomes
/// a warm CLOSED chip. That replaced a 30 px lock circle, which was both under
/// the 44 pt tap floor (while looking pressable) and mute: a padlock glyph does
/// not say whether the bus left, filled up, or was cancelled, and the word does.
class _BookPill extends StatelessWidget {
  final UgamColorSet c;
  final bool closed;
  final VoidCallback onTap;

  const _BookPill({required this.c, required this.closed, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (closed) {
      return UgamReqChip(
        label: tr('customer_tour_list.chip_closed'),
        variant: UgamChipVariant.warm,
        leading: Icons.lock_outline_rounded,
      );
    }
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: UgamScale.tap(context, 44),
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.lg),
        alignment: Alignment.center,
        // No hand-rolled shadow. The card this sits in is already at
        // UgamElevationSet.rest; a second, differently-tuned drop shadow on a
        // chip inside it read as a floating blob rather than depth.
        decoration: BoxDecoration(
          // Neutral, not amber: the accent means "this is yours", never
          // "press me". Uber's buttonPrimaryFill is #000000 and Ola ships a
          // black booking button despite a green brand — spending the brand
          // hue on controls is what leaves nothing to carry meaning.
          color: c.action,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                tr('customer_tour_list.book_button'),
                style: UgamText.bodyStrong.copyWith(color: c.onAction),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.arrow_forward_rounded, size: 15, color: c.onAction),
          ],
        ),
      ),
    );
  }
}

/// First-load state: the finished page with the words taken out.
///
/// Every block is the size and position of the thing that replaces it, so the
/// list does not jump when the tours land. The old version stacked three flat
/// 110 px bars — less than half the height of a real row — so the page visibly
/// re-laid itself out on arrival, which is the "prototype" tell.
class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.xl,
      ),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 22, width: 128, radius: 6),
        SizedBox(height: UgamSpacing.md),
        _TourRowSkeleton(),
        SizedBox(height: UgamSpacing.tight),
        _TourRowSkeleton(),
        SizedBox(height: UgamSpacing.xl),
        UgamSkeleton(height: 22, width: 96, radius: 6),
        SizedBox(height: UgamSpacing.md),
        _TourRowSkeleton(),
      ],
    );
  }
}

/// One [_TourRow] with its content greyed out — route board, title, meta line
/// and the Book pill, each in its final place.
class _TourRowSkeleton extends StatelessWidget {
  const _TourRowSkeleton();

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamCard.plain(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(UgamSpacing.md),
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(UgamRadius.card),
              ),
            ),
            child: Row(
              children: [
                UgamSkeleton(
                  width: UgamScale.px(context, 58),
                  height: UgamScale.px(context, 58),
                  radius: UgamRadius.input,
                ),
                const SizedBox(width: UgamSpacing.md),
                const Expanded(child: UgamSkeleton(height: 18, radius: 6)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(UgamSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const UgamSkeleton(height: 17, radius: 6),
                const SizedBox(height: UgamSpacing.sm),
                const UgamSkeleton(height: 13, width: 190, radius: 6),
                const SizedBox(height: UgamSpacing.md),
                Row(
                  children: [
                    const UgamSkeleton(height: 13, width: 104, radius: 6),
                    const Spacer(),
                    UgamSkeleton(
                      width: 96,
                      height: UgamScale.tap(context, 44),
                      radius: UgamRadius.chip,
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
