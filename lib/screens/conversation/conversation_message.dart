part of '../conversation_screen.dart';

/// Centred date pill separating one day's messages from the next, so a
/// timestamp is stated once per day instead of once per line.
class _DayDivider extends StatelessWidget {
  final String label;

  const _DayDivider({required this.label});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.tight,
          vertical: UgamSpacing.badgeV + 1,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        child: Text(
          label,
          style: UgamText.caption.copyWith(
            color: c.ink2,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// One chat bubble. Inbound sits left on the neutral card surface; outbound
/// sits right on the TONAL accent surface — `accentFill` plus an accent
/// hairline, never a solid copper slab.
///
/// Solid accent is what this used to paint on every reply, which spent the
/// screen's one rationed accent point dozens of times over (see
/// `UgamButtonKind.primary`) and made a long thread read as a wall of amber.
/// Four cues now separate the two sides at a glance — side, tail notch, fill
/// hue and edge colour — and a send that Meta rejected swaps the edge to
/// `danger`, so a failed reply is visible in the transcript rather than only in
/// a toast that has long since gone.
///
/// An attachment renders ABOVE the text: a photo inline, everything else as a
/// tappable row that opens in the phone's own viewer. The text underneath is the
/// customer's caption when they typed one, and only falls back to a "📷 Photo"
/// style label when they didn't — a caption is often the whole point of the
/// message ("here's the payment, ref 4471") and used to be discarded.
class _MessageBubble extends StatelessWidget {
  final WaMessage message;
  final bool tail;
  final double maxWidth;
  final UgamColorSet c;

  const _MessageBubble({
    required this.message,
    required this.tail,
    required this.maxWidth,
    required this.c,
  });

  /// The text line under an attachment. Empty means "the picture says it all" —
  /// a photo with no caption shows no redundant "📷 Photo" label under it.
  String _bodyText() {
    final caption = message.caption;
    if (caption != null) return caption;
    if (message.isText) return message.displayBody;
    // Stored image: the thumbnail IS the content, so no label.
    if (message.isImage && message.hasStoredMedia) return '';
    return switch (message.msgType) {
      'image' => tr('inbox.photo'),
      'document' => tr('inbox.document'),
      'audio' => tr('inbox.audio'),
      'video' => tr('inbox.video'),
      // A kind the webhook does not model ('other', a future Meta type):
      // the model's fallback is a raw "[other]", so say what it is instead.
      _ => tr('inbox.unsupported'),
    };
  }

  @override
  Widget build(BuildContext context) {
    final outbound = message.isOutbound;
    final failed = outbound && message.status == 'failed';
    final bg = outbound ? c.accentFill : c.card;
    final edge = failed
        ? c.danger
        : outbound
            ? c.accent.withValues(alpha: 0.28)
            : c.border;
    // Both surfaces are now tonal, so one ink pair serves both. `ink2` (not
    // `ink3`) for the meta line: ink3 measures ~2.6:1 on the pale amber fill in
    // Daylight and the clock stamp disappeared.
    final fg = c.ink;
    final metaColor = c.ink2;

    final ml = MaterialLocalizations.of(context);
    final time = ml.formatTimeOfDay(
      TimeOfDay.fromDateTime(message.createdAt.toLocal()),
    );
    final text = _bodyText();

    const soft = Radius.circular(UgamRadius.row);
    const notch = Radius.circular(UgamSpacing.xs);
    final radius = BorderRadius.only(
      topLeft: soft,
      topRight: soft,
      bottomLeft: (!outbound && tail) ? notch : soft,
      bottomRight: (outbound && tail) ? notch : soft,
    );

    return Semantics(
      label: outbound ? tr('inbox.you') : null,
      child: Row(
        mainAxisAlignment:
            outbound ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.tight,
              ),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: radius,
                border: Border.all(color: edge),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.hasAttachment) ...[
                    _WaAttachment(message: message, c: c),
                    if (text.isNotEmpty) const SizedBox(height: UgamSpacing.xs),
                  ],
                  if (text.isNotEmpty)
                    Text(text, style: UgamText.body.copyWith(color: fg)),
                  // One timestamp per burst, at its foot — a clock stamp on
                  // every line is noise in a run of four quick replies. A
                  // rejected send always states itself, mid-burst or not.
                  if (tail || failed) ...[
                    const SizedBox(height: 3),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          time,
                          style: UgamText.tabular(
                            UgamText.micro.copyWith(color: metaColor),
                          ),
                        ),
                        if (outbound) ...[
                          const SizedBox(width: UgamSpacing.xs),
                          _SendStatus(status: message.status, c: c),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Delivery state of an outbound reply, from `wa_messages.status` (patched by
/// the webhook's status receipts). Previously stored and never shown, so the
/// agent had no way to tell a reply Meta accepted from one it dropped.
class _SendStatus extends StatelessWidget {
  final String? status;
  final UgamColorSet c;

  const _SendStatus({required this.status, required this.c});

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color tint, String label) = switch (status) {
      'read' => (Icons.done_all_rounded, c.good, tr('inbox.status_read')),
      'delivered' => (
        Icons.done_all_rounded,
        c.ink2,
        tr('inbox.status_delivered'),
      ),
      'sent' => (Icons.check_rounded, c.ink2, tr('inbox.status_sent')),
      'failed' => (
        Icons.error_outline_rounded,
        c.danger,
        tr('inbox.status_failed'),
      ),
      _ => (Icons.schedule_rounded, c.ink2, tr('inbox.status_sending')),
    };

    return Semantics(
      label: label,
      child: Icon(icon, size: UgamScale.px(context, 13), color: tint),
    );
  }
}

/// The attachment half of a bubble.
///
/// A photo renders inline — that is the whole point of receiving one, and
/// making the admin tap through to a viewer to find out whether a customer sent
/// a payment screenshot or a selfie would defeat it. Audio, video and documents
/// render as a compact row and open in the phone's own player/viewer on tap;
/// building an in-app audio player and video surface is a far larger change than
/// "media should arrive", and the OS handles every codec WhatsApp can send.
///
/// The bucket is private (059), so every URL here is a short-lived signed one
/// fetched on demand. A null URL and a missing `media_path` collapse to the same
/// muted "couldn't be downloaded" note: in both cases the admin knows something
/// was sent and that they need to ask for it again.
class _WaAttachment extends StatelessWidget {
  final WaMessage message;
  final UgamColorSet c;

  const _WaAttachment({required this.message, required this.c});

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && context.mounted) {
      AppSnackBar.error(tr('inbox.media_open_failed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (message.mediaMissing) {
      return _note(context, tr('inbox.media_unavailable'));
    }

    final path = message.mediaPath!;
    return FutureBuilder<String?>(
      // Keyed by the path so a rebuild reuses the same future instead of
      // re-signing (the service caches, but this also keeps the placeholder
      // from flashing on every realtime tick).
      key: ValueKey(path),
      future: Get.find<InboxController>().mediaUrl(path),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _placeholder(context);
        }
        final url = snap.data;
        if (url == null) return _note(context, tr('inbox.media_unavailable'));

        if (message.isImage) {
          return UgamTappable(
            onTap: () => _open(context, url),
            semanticLabel: tr('inbox.photo'),
            child: ClipRRect(
              // `photo` (16), NOT `chip` (999) — the pill radius was clipping
              // every received photo into a stadium and shearing off its top
              // and bottom corners.
              borderRadius: BorderRadius.circular(UgamRadius.photo),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: UgamScale.px(context, 240),
                ),
                child: Image.network(
                  url,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  // A decode cap: these come straight from a phone camera and an
                  // undecoded 12MP JPEG in a scrolling list is an OOM on the
                  // cheap Android handsets this app runs on.
                  cacheWidth: 900,
                  errorBuilder: (_, _, _) =>
                      _note(context, tr('inbox.media_unavailable')),
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : _placeholder(context),
                ),
              ),
            ),
          );
        }

        return _fileRow(context, url);
      },
    );
  }

  Widget _fileRow(BuildContext context, String url) {
    final icon = message.isAudio
        ? Icons.mic_rounded
        : message.isVideo
            ? Icons.play_circle_fill_rounded
            : Icons.insert_drive_file_rounded;
    final label = message.mediaFilename?.trim().isNotEmpty == true
        ? message.mediaFilename!.trim()
        : message.isAudio
            ? tr('inbox.audio')
            : message.isVideo
                ? tr('inbox.video')
                : tr('inbox.document');
    final size = message.mediaSizeLabel;

    return UgamTappable(
      onTap: () => _open(context, url),
      semanticLabel: tr('inbox.open_attachment'),
      child: ConstrainedBox(
        // The row is its own tap target, so it has to clear 44pt.
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 44)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: UgamScale.px(context, 24), color: c.ink),
            const SizedBox(width: UgamSpacing.sm),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: UgamText.bodyStrong.copyWith(color: c.ink),
                  ),
                  Text(
                    size == null
                        ? tr('inbox.open_attachment')
                        : '$size · ${tr('inbox.open_attachment')}',
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shaped like the photo it stands in for. A centred spinner inside a grey
  /// box is the prototype tell the rest of the app already removed.
  Widget _placeholder(BuildContext context) => UgamSkeleton(
        width: UgamScale.px(context, 200),
        height: UgamScale.px(context, 132),
        radius: UgamRadius.photo,
      );

  Widget _note(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: UgamScale.px(context, 18),
              color: c.ink2,
            ),
            const SizedBox(width: UgamSpacing.xs),
            Flexible(
              child: Text(
                text,
                style: UgamText.caption.copyWith(color: c.ink2),
              ),
            ),
          ],
        ),
      );
}
