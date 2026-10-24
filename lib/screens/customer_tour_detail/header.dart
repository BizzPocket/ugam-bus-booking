part of '../customer_tour_detail_screen.dart';

// ─── HEADER ───────────────────────────────────────────────────────────

/// Photo strip + summary card, or — when the tour has no photo — just the
/// summary card under a bare chrome row.
class _Header extends StatelessWidget {
  final Tour tour;
  final TourPublicSummary summary;
  final bool summaryFailed;
  final VoidCallback onRetrySummary;
  final VoidCallback onBack;
  final VoidCallback onShare;

  const _Header({
    required this.tour,
    required this.summary,
    required this.summaryFailed,
    required this.onRetrySummary,
    required this.onBack,
    required this.onShare,
  });

  /// Decode the photo at the width we actually paint. The picker stores at
  /// maxWidth 1600, so without this a 200pt strip decodes a ~6.8 MB bitmap.
  /// Same guard the admin hero uses.
  static int _decodeWidth(BuildContext context) {
    final mq = MediaQuery.of(context);
    final physical = (mq.size.width * mq.devicePixelRatio).round();
    if (physical <= 0) return 800;
    return physical > 1600 ? 1600 : physical;
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final hasPhoto = (tour.broadcastImageUrl ?? '').trim().isNotEmpty;
    final card = _SummaryCard(
      tour: tour,
      summary: summary,
      summaryFailed: summaryFailed,
      onRetrySummary: onRetrySummary,
    );

    if (!hasPhoto) {
      // The 99% case. No photo means no illustration — a generated backdrop
      // conveys nothing and costs the whole top of the screen, so the card
      // starts right under the chrome and the price is above the fold.
      return Padding(
        padding: EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          topInset + UgamSpacing.sm,
          UgamSpacing.gutter,
          UgamSpacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ChromeRow(onBack: onBack, onShare: onShare, onPhoto: false),
            const SizedBox(height: UgamSpacing.lg),
            card,
          ],
        ),
      );
    }

    final photoHeight = UgamScale.px(context, 200);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: photoHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Disk-cached: the poster is the same file on every cold start,
              // and re-downloading it each launch cost a 2G rider ~seconds of
              // backdrop before the photo — the URL is the cache key.
              CachedNetworkImage(
                imageUrl: tour.broadcastImageUrl!.trim(),
                fit: BoxFit.cover,
                // Tour posters put people/deities at the top; centre-cropping
                // a 200px strip cut faces off at the forehead.
                alignment: Alignment.topCenter,
                memCacheWidth: _decodeWidth(context),
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                // While loading, or if the object is missing, fall back to the
                // backdrop so the strip never flashes raw or broken.
                placeholder: (_, _) => UgamBusBackdrop(
                  seed: tour.id,
                  label: customerRouteInitials(tour.fromCity, tour.toCity),
                ),
                errorWidget: (_, _, _) => UgamBusBackdrop(
                  seed: tour.id,
                  label: customerRouteInitials(tour.fromCity, tour.toCity),
                ),
              ),
              // Scrim only where the chrome sits — enough to keep the back and
              // share controls legible over any photo.
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x8C000000), Color(0x00000000)],
                    stops: [0.0, 0.55],
                  ),
                ),
              ),
              Positioned(
                left: UgamSpacing.gutter,
                right: UgamSpacing.gutter,
                top: topInset + UgamSpacing.sm,
                child: _ChromeRow(
                  onBack: onBack,
                  onShare: onShare,
                  onPhoto: true,
                ),
              ),
            ],
          ),
        ),
        // Pulled up so the card reads as one unit with the photo. Transform
        // does not affect layout, so the Column still reserves the card's full
        // height and the pull simply becomes the gap below it — no overlap
        // with the body, and no magic clearance constant to keep in sync.
        Transform.translate(
          offset: const Offset(0, -UgamSpacing.xl),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: UgamSpacing.gutter,
            ),
            child: card,
          ),
        ),
      ],
    );
  }
}

class _ChromeRow extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onShare;

  /// Over a photo the controls need a dark scrim and white glyphs; on the page
  /// they take the card fill and normal ink, or they read as floating blobs.
  final bool onPhoto;

  const _ChromeRow({
    required this.onBack,
    required this.onShare,
    required this.onPhoto,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _ChromeCircle(
          icon: Icons.arrow_back_rounded,
          onTap: onBack,
          onPhoto: onPhoto,
        ),
        const Spacer(),
        _ChromeCircle(
          icon: Icons.ios_share_rounded,
          onTap: onShare,
          onPhoto: onPhoto,
        ),
      ],
    );
  }
}

class _ChromeCircle extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool onPhoto;

  const _ChromeCircle({
    required this.icon,
    required this.onTap,
    required this.onPhoto,
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
      child: Container(
        width: UgamScale.tap(context, 44),
        height: UgamScale.tap(context, 44),
        decoration: BoxDecoration(
          // Over a photo neither of these can be a token: the control floats on
          // an arbitrary uploaded image, so its contrast cannot come from the
          // theme. Off the photo it is fully tokenized.
          color: onPhoto ? const Color(0x73000000) : c.cardElev,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          icon,
          size: 19,
          color: onPhoto ? Colors.white : c.ink,
        ),
      ),
    );
  }
}

// ─── SUMMARY CARD ─────────────────────────────────────────────────────

/// The glance: what it is, where and when it goes, and whether there is room.
/// Everything a customer needs to decide whether to keep reading, in one card
/// above the fold.
///
/// No price. This operator settles the fare over WhatsApp, so the page states
/// what the trip IS and leaves what it costs to the conversation.
class _SummaryCard extends StatelessWidget {
  final Tour tour;
  final TourPublicSummary summary;
  final bool summaryFailed;
  final VoidCallback onRetrySummary;

  const _SummaryCard({
    required this.tour,
    required this.summary,
    required this.summaryFailed,
    required this.onRetrySummary,
  });

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final countdown = departureCountdownLabel(tour.departureDate);

    return Container(
      padding: const EdgeInsets.all(UgamSpacing.lg),
      decoration: BoxDecoration(
        color: c.cardElev,
        borderRadius: BorderRadius.circular(UgamRadius.card),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // titleL, not titleM. This page has no app-bar title, so the tour
          // name IS the page heading and was being set two ladder steps below
          // the one the system reserves for a page title.
          Text(
            tour.title,
            style: UgamText.titleL.copyWith(color: c.ink),
            // Two lines before ellipsing: a tour title carries the festival
            // name AND the date, and truncating it to one line loses which
            // trip this is.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UgamSpacing.xs),
          // Wraps. "અમદાવાદ → અંબાજી" and its Hindi equivalent run well past
          // the width a single clamped line allows on a 375 pt phone, and the
          // route is not a fact this page can afford to clip.
          Text(
            '${tour.fromCity} → ${tour.toCity}',
            style: UgamText.bodyStrong.copyWith(color: c.ink2),
            maxLines: 2,
          ),
          if (countdown != null) ...[
            const SizedBox(height: 2),
            Text(
              countdown,
              style: UgamText.tabular(
                UgamText.caption.copyWith(color: c.ink3),
              ),
            ),
          ],
          const SizedBox(height: UgamSpacing.md),
          _AvailabilityBlock(
            tour: tour,
            summary: summary,
            summaryFailed: summaryFailed,
            onRetry: onRetrySummary,
          ),
        ],
      ),
    );
  }
}
