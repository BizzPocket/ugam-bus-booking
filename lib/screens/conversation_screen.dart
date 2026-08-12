import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/inbox_controller.dart';
import '../design/components/ugam_tappable.dart';
import '../design/ugam.dart';
import '../models/wa_conversation.dart';
import '../models/wa_message.dart';
import '../utils/app_snackbar.dart';

/// A single WhatsApp thread: the message history (inbound left, outbound right)
/// plus a pinned reply composer.
///
/// Messages stream live from [InboxController.watchMessages] (mirroring
/// `wa_messages` ordered `created_at asc`). Replies go through
/// [InboxController.sendReply]; a failed send restores the drafted text and
/// raises a persistent, retryable failure strip above the composer. The 24-hour
/// session window state is shown as a subtle status line above it.
///
/// **The list is [ListView.reverse]d, deliberately.** Anchoring a chat from the
/// bottom is what makes every other chat behaviour fall out for free: a short
/// thread rests on the composer instead of floating at the top of an empty
/// screen, the newest message is on screen the instant the route opens with no
/// scroll code at all, an arriving message keeps the view pinned only when the
/// reader is already at the bottom, and the keyboard shrinking the viewport
/// pushes the history up rather than scrolling the newest line out of sight.
/// The previous version jumped to `maxScrollExtent` from inside the
/// `StreamBuilder` callback, so *any* rebuild — including the `setState` that
/// fires on the first character typed — yanked the reader back down mid-scroll.
class ConversationScreen extends StatefulWidget {
  final WaConversation conversation;

  const ConversationScreen({super.key, required this.conversation});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

/// Messages from the same side within this window render as one visual burst:
/// tight spacing, a single tail notch, and ONE timestamp at the foot of the run
/// rather than a clock stamp on every line.
const Duration _kBurstWindow = Duration(minutes: 5);

class _ConversationScreenState extends State<ConversationScreen> {
  InboxController get _ctrl => Get.find<InboxController>();

  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  /// Held (not `late final`) so the error state can re-subscribe on retry.
  late Stream<List<WaMessage>> _messages;

  bool _sending = false;
  bool _hasText = false;

  /// Reason for the last failed send. Non-null renders the retry strip.
  String? _sendError;

  /// Newest message id already accounted for by [_syncRead], and whether the
  /// first (history) batch has landed.
  String? _readMarkerId;
  bool _sawFirstBatch = false;

  @override
  void initState() {
    super.initState();
    _messages = _ctrl.watchMessages(widget.conversation.id);
    // Opening the thread IS the read event, so it belongs here rather than on
    // the inbox row's tap handler: this also covers arriving from anywhere else
    // (a push tap, a future deep link) and pairs with [_syncRead], which clears
    // the badge again for messages that land while the thread is already open —
    // the case the old tap-side call could never see.
    _markRead();
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _markRead() {
    // Fire-and-forget, but never unhandled: an RPC failure here is cosmetic
    // (the badge stays until the next open) and must not surface as a zone
    // error on a screen the agent is typing in.
    unawaited(_ctrl.markRead(widget.conversation.id).catchError((Object _) {}));
  }

  /// Re-clears the badge when a NEW inbound message arrives while the thread is
  /// open. The first emission is the existing history, already covered by
  /// [initState].
  void _syncRead(List<WaMessage> messages) {
    final newest = messages.last;
    if (!_sawFirstBatch) {
      _sawFirstBatch = true;
      _readMarkerId = newest.id;
      return;
    }
    if (newest.id == _readMarkerId) return;
    _readMarkerId = newest.id;
    if (newest.isInbound) _markRead();
  }

  void _reload() {
    setState(() {
      _sawFirstBatch = false;
      _readMarkerId = null;
      _messages = _ctrl.watchMessages(widget.conversation.id);
    });
  }

  /// Reverse list ⇒ offset 0 IS the newest message. Used after the agent's own
  /// send, which is the one moment a jump is wanted even if they had scrolled
  /// up to re-read something.
  void _revealNewest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients || _scrollCtrl.offset == 0) return;
      _scrollCtrl.animateTo(
        0,
        duration: UgamMotion.sheet,
        curve: UgamMotion.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    // Optimistic: clear the field immediately, then send. Restore on failure.
    setState(() {
      _sending = true;
      _sendError = null;
      _textCtrl.clear();
      _hasText = false;
    });

    var ok = false;
    String? reason;
    try {
      final result = await _ctrl.sendReply(widget.conversation.id, text);
      ok = result.ok;
      reason = result.error;
    } catch (e) {
      ok = false;
      reason = e.toString();
    }

    if (!mounted) return;
    if (!ok) {
      // Put the draft back so the admin doesn't lose their typing, and keep the
      // failure on screen. `sendReply` has always returned Meta's own reason —
      // "template not found", "24h window closed", "invalid phone number" — and
      // this screen used to throw it away behind a generic "Couldn't send",
      // which is how a broken reply path stayed undiagnosable from the field.
      // A toast was the next attempt; it carried the reason but auto-dismissed
      // in four seconds and offered no way to act on it. The reason now sits in
      // a persistent strip WITH the retry, directly above the restored draft.
      _textCtrl.text = text;
      _textCtrl.selection = TextSelection.collapsed(offset: text.length);
      final detail = reason?.trim();
      if (detail != null && detail.isNotEmpty) {
        debugPrint('wa reply failed — $detail');
      }
      setState(() {
        _sending = false;
        _hasText = true;
        _sendError = (detail == null || detail.isEmpty)
            ? tr('inbox.send_failed')
            : tr('inbox.send_failed_reason', namedArgs: {'reason': detail});
      });
      HapticFeedback.mediumImpact();
      return;
    }

    setState(() => _sending = false);
    _revealNewest();
  }

  /// True while WhatsApp's free-reply window is open.
  ///
  /// Derived from the live thread, not from the [WaConversation] snapshot the
  /// route was pushed with: that value is frozen at push time, so a customer
  /// messaging *while* the agent has the thread open re-opened the window on
  /// the server but left this line reading "closed" until the screen was popped
  /// and re-entered.
  bool _windowOpen(List<WaMessage> messages) {
    DateTime? lastInbound;
    for (var i = messages.length - 1; i >= 0; i--) {
      if (messages[i].isInbound) {
        lastInbound = messages[i].createdAt;
        break;
      }
    }
    lastInbound ??= widget.conversation.lastInboundAt;
    if (lastInbound == null) return false;
    return DateTime.now().difference(lastInbound) <= const Duration(hours: 24);
  }

  /// Day dividers + burst grouping, computed once per emission in chronological
  /// order; the list renders it back-to-front.
  List<_ThreadEntry> _entries(List<WaMessage> messages) {
    final out = <_ThreadEntry>[];
    DateTime? lastDay;

    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      final local = m.createdAt.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      final newDay = lastDay == null || day != lastDay;

      if (newDay) {
        out.add(
          _ThreadEntry.divider(
            day,
            gap: out.isEmpty ? 0 : UgamSpacing.xl,
          ),
        );
        lastDay = day;
      }

      final prev = i == 0 ? null : messages[i - 1];
      final next = i == messages.length - 1 ? null : messages[i + 1];

      final head =
          newDay ||
          prev == null ||
          prev.isOutbound != m.isOutbound ||
          local.difference(prev.createdAt.toLocal()) > _kBurstWindow;

      final tail =
          next == null ||
          next.isOutbound != m.isOutbound ||
          !_sameDay(next.createdAt.toLocal(), local) ||
          next.createdAt.toLocal().difference(local) > _kBurstWindow;

      out.add(
        _ThreadEntry.bubble(
          m,
          tail: tail,
          gap: head ? UgamSpacing.md : UgamSpacing.xs,
        ),
      );
    }
    return out;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// The phone under the header name. Only shown when the title is a NAME —
  /// when it isn't, [WaConversation.displayName] is already the number.
  String? _headerSubtitle() {
    final name = widget.conversation.customerName?.trim();
    if (name == null || name.isEmpty) return null;
    final digits = widget.conversation.customerPhone.replaceAll(
      RegExp(r'[^\d]'),
      '',
    );
    if (digits.isEmpty) return null;
    if (digits.length == 12 && digits.startsWith('91')) {
      return '+91 ${digits.substring(2)}';
    }
    return digits;
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final title = widget.conversation.displayName.trim().isEmpty
        ? tr('inbox.unknown')
        : widget.conversation.displayName;

    return UgamScaffold(
      // `bottom: false` — the composer owns the bottom inset so its hairline
      // and fill run to the true screen edge behind the home indicator.
      body: SafeArea(
        bottom: false,
        child: StreamBuilder<List<WaMessage>>(
          stream: _messages,
          builder: (context, snapshot) {
            final messages = snapshot.data ?? const <WaMessage>[];
            if (messages.isNotEmpty) _syncRead(messages);
            // A stream error AFTER data has landed is a transient realtime drop
            // that reconnects on its own — keep the thread on screen. Only a
            // failure with nothing to show becomes the error state.
            final failed = snapshot.hasError && messages.isEmpty;
            final waiting = !snapshot.hasData && !snapshot.hasError;

            return Column(
              children: [
                UgamAppBar(title: title, subtitle: _headerSubtitle()),
                Expanded(
                  child: _thread(
                    context,
                    c: c,
                    messages: messages,
                    waiting: waiting,
                    failed: failed,
                  ),
                ),
                _WindowStatus(open: _windowOpen(messages)),
                if (_sendError != null)
                  _SendFailure(message: _sendError!, onRetry: _send),
                _Composer(
                  controller: _textCtrl,
                  sending: _sending,
                  canSend: _hasText && !_sending,
                  onChanged: (v) {
                    final has = v.trim().isNotEmpty;
                    if (has == _hasText && _sendError == null) return;
                    setState(() {
                      _hasText = has;
                      _sendError = null;
                    });
                  },
                  onSend: _send,
                  c: c,
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _thread(
    BuildContext context, {
    required UgamColorSet c,
    required List<WaMessage> messages,
    required bool waiting,
    required bool failed,
  }) {
    if (failed) {
      return UgamEmpty.error(title: tr('inbox.load_failed'), onRetry: _reload);
    }
    if (waiting) return const _ThreadSkeleton();
    if (messages.isEmpty) {
      // Distinguishes "this thread has no messages" from "still loading" —
      // the old code returned a blank SizedBox for both once loading finished.
      return UgamEmpty(
        icon: Icons.chat_bubble_outline_rounded,
        title: tr('inbox.thread_empty_title'),
        body: tr('inbox.thread_empty_body'),
      );
    }

    final entries = _entries(messages);
    final maxBubble =
        (MediaQuery.sizeOf(context).width - UgamSpacing.gutter * 2) * 0.82;

    return ListView.builder(
      controller: _scrollCtrl,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[entries.length - 1 - i];
        final day = e.day;
        return Padding(
          padding: EdgeInsets.only(top: e.gap),
          child: day != null
              ? _DayDivider(label: _dayLabel(context, day))
              : _MessageBubble(
                  message: e.message!,
                  tail: e.tail,
                  maxWidth: maxBubble,
                  c: c,
                ),
        );
      },
    );
  }

  String _dayLabel(BuildContext context, DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final delta = today.difference(day).inDays;
    if (delta == 0) return tr('inbox.today');
    if (delta == 1) return tr('inbox.yesterday');
    return MaterialLocalizations.of(context).formatMediumDate(day);
  }
}

/// One rendered row of the thread: either a day divider or a bubble, plus the
/// space that sits above it.
@immutable
class _ThreadEntry {
  final WaMessage? message;
  final DateTime? day;

  /// Last message of a same-side burst — carries the tail notch and the single
  /// timestamp for the whole run.
  final bool tail;
  final double gap;

  const _ThreadEntry.bubble(
    WaMessage this.message, {
    required this.tail,
    required this.gap,
  }) : day = null;

  const _ThreadEntry.divider(DateTime this.day, {required this.gap})
      : message = null,
        tail = false;
}

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
    switch (message.msgType) {
      case 'image':
        return tr('inbox.photo');
      case 'document':
        return tr('inbox.document');
      case 'audio':
        return tr('inbox.audio');
      case 'video':
        return tr('inbox.video');
      default:
        return message.displayBody;
    }
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

/// Subtle line above the composer telling the admin whether the free-form 24h
/// reply window is open (positive) or closed (muted — sends fall back to a
/// template).
class _WindowStatus extends StatelessWidget {
  final bool open;

  const _WindowStatus({required this.open});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.sm,
        UgamSpacing.gutter,
        UgamSpacing.xs,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: UgamStatusDot(
          label: open ? tr('inbox.window_open') : tr('inbox.window_closed'),
          tone: open ? UgamStatusTone.good : UgamStatusTone.neutral,
        ),
      ),
    );
  }
}

/// Persistent, retryable failure strip for the last send. Sits directly above
/// the composer, next to the draft it restored.
class _SendFailure extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _SendFailure({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        0,
        UgamSpacing.gutter,
        UgamSpacing.sm,
      ),
      child: Row(
        children: [
          // Wraps rather than truncating: Meta's own reason is the whole value
          // of this strip and Gujarati runs ~30% longer than the English.
          Expanded(
            child: UgamCaveat(
              message: message,
              tone: UgamCaveatTone.danger,
              icon: Icons.error_outline_rounded,
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          UgamButton(
            label: tr('actions.retry'),
            kind: UgamButtonKind.dangerTonal,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

/// Bottom-pinned reply composer: multiline input + circular send button. The
/// enclosing [UgamScaffold] resizes for the keyboard, so this row rides just
/// above the on-screen keyboard; the hairline separates it from the transcript
/// scrolling behind it.
class _Composer extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final bool canSend;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final UgamColorSet c;

  const _Composer({
    required this.controller,
    required this.sending,
    required this.canSend,
    required this.onChanged,
    required this.onSend,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final box = UgamScale.tap(context, 44);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.bg,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            UgamSpacing.gutter,
            UgamSpacing.sm,
            UgamSpacing.gutter,
            UgamSpacing.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: UgamInput(
                  controller: controller,
                  hint: tr('inbox.reply_hint'),
                  keyboardType: TextInputType.multiline,
                  minLines: 1,
                  maxLines: 5,
                  enabled: !sending,
                  onChanged: onChanged,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              // Circular send action. Disabled (muted) while empty or in-flight;
              // shows an inline spinner during the send round-trip.
              sending
                  ? Container(
                      width: box,
                      height: box,
                      decoration: BoxDecoration(
                        color: c.cardElev,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          valueColor: AlwaysStoppedAnimation(c.ink3),
                        ),
                      ),
                    )
                  : UgamIconButton(
                      icon: Icons.arrow_upward_rounded,
                      onTap: canSend ? onSend : null,
                      semanticLabel: tr('inbox.send'),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shimmer placeholder while the first message page loads.
///
/// Bottom-anchored and alternating side/width, so it stands where the real
/// transcript will stand instead of stacking three identical slabs at the top
/// of an otherwise empty screen.
class _ThreadSkeleton extends StatelessWidget {
  const _ThreadSkeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.md,
        UgamSpacing.gutter,
        UgamSpacing.md,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: const [
          _SkeletonBubble(alignEnd: false, width: 208, height: 56),
          SizedBox(height: UgamSpacing.md),
          _SkeletonBubble(alignEnd: true, width: 152, height: 40),
          SizedBox(height: UgamSpacing.xs),
          _SkeletonBubble(alignEnd: true, width: 224, height: 40),
          SizedBox(height: UgamSpacing.md),
          _SkeletonBubble(alignEnd: false, width: 176, height: 40),
        ],
      ),
    );
  }
}

class _SkeletonBubble extends StatelessWidget {
  final bool alignEnd;
  final double width;
  final double height;

  const _SkeletonBubble({
    required this.alignEnd,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment:
          alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        UgamSkeleton(
          // Decorative — never a tap target.
          width: UgamScale.px(context, width),
          height: UgamScale.px(context, height),
          radius: UgamRadius.row,
        ),
      ],
    );
  }
}
