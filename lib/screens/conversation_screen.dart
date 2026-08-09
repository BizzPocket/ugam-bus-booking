import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher.dart';

import '../controllers/inbox_controller.dart';
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
/// surfaces a [AppSnackBar] error. The 24-hour session window state is shown
/// as a subtle status line above the composer.
class ConversationScreen extends StatefulWidget {
  final WaConversation conversation;

  const ConversationScreen({super.key, required this.conversation});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  InboxController get _ctrl => Get.find<InboxController>();

  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  // Cached once so a rebuild doesn't re-subscribe the realtime stream.
  late final Stream<List<WaMessage>> _messages =
      _ctrl.watchMessages(widget.conversation.id);

  bool _sending = false;
  bool _hasText = false;

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// Jump to the newest message after the frame that rendered it.
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    // Optimistic: clear the field immediately, then send. Restore on failure.
    setState(() {
      _sending = true;
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
      // Put the draft back so the admin doesn't lose their typing.
      _textCtrl.text = text;
      _textCtrl.selection = TextSelection.collapsed(offset: text.length);
      setState(() {
        _sending = false;
        _hasText = true;
      });
      // Show WHY. `sendReply` has always returned Meta's own reason — "template
      // not found", "24h window closed", "invalid phone number" — and this
      // screen threw it away and printed "Couldn't send" instead, which is how a
      // broken reply path stayed undiagnosable from the field. The generic line
      // is now the TITLE and the real cause sits under it.
      final detail = reason?.trim();
      if (detail == null || detail.isEmpty) {
        AppSnackBar.error(tr('inbox.send_failed'));
      } else {
        debugPrint('wa reply failed — $detail');
        AppSnackBar.error(detail, title: tr('inbox.send_failed'));
      }
      return;
    }

    setState(() => _sending = false);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final title = widget.conversation.displayName.trim().isEmpty
        ? tr('inbox.unknown')
        : widget.conversation.displayName;

    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(title: title),
            Expanded(
              child: StreamBuilder<List<WaMessage>>(
                stream: _messages,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return UgamEmpty(
                      icon: Icons.error_outline_rounded,
                      title: tr('inbox.load_failed'),
                    );
                  }
                  if (!snapshot.hasData) {
                    return const _ThreadSkeleton();
                  }
                  final messages = snapshot.data!;
                  if (messages.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  // New batch arrived → pin to the latest message.
                  _scrollToBottom();
                  return ListView.separated(
                    controller: _scrollCtrl,
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.md,
                      UgamSpacing.gutter,
                      UgamSpacing.md,
                    ),
                    itemCount: messages.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UgamSpacing.sm),
                    itemBuilder: (_, i) =>
                        _MessageBubble(message: messages[i], c: c),
                  );
                },
              ),
            ),
            _WindowStatus(open: widget.conversation.windowOpen, c: c),
            _Composer(
              controller: _textCtrl,
              sending: _sending,
              canSend: _hasText && !_sending,
              onChanged: (v) {
                final has = v.trim().isNotEmpty;
                if (has != _hasText) setState(() => _hasText = has);
              },
              onSend: _send,
              c: c,
            ),
          ],
        ),
      ),
    );
  }
}

/// One chat bubble. Inbound sits left on a neutral surface; outbound sits right
/// on the accent surface (the "your side" signal).
///
/// An attachment renders ABOVE the text: a photo inline, everything else as a
/// tappable row that opens in the phone's own viewer. The text underneath is the
/// customer's caption when they typed one, and only falls back to a "📷 Photo"
/// style label when they didn't — a caption is often the whole point of the
/// message ("here's the payment, ref 4471") and used to be discarded.
class _MessageBubble extends StatelessWidget {
  final WaMessage message;
  final UgamColorSet c;

  const _MessageBubble({required this.message, required this.c});

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
    final bg = outbound ? c.accent : c.card;
    final fg = outbound ? c.onAccent : c.ink;
    final metaColor = outbound
        ? c.onAccent.withValues(alpha: 0.7)
        : c.ink3;
    final ml = MaterialLocalizations.of(context);
    final time = ml.formatTimeOfDay(
      TimeOfDay.fromDateTime(message.createdAt.toLocal()),
    );
    final text = _bodyText();

    final radius = BorderRadius.only(
      topLeft: const Radius.circular(UgamRadius.row),
      topRight: const Radius.circular(UgamRadius.row),
      bottomLeft: Radius.circular(outbound ? UgamRadius.row : UgamSpacing.xs),
      bottomRight: Radius.circular(outbound ? UgamSpacing.xs : UgamRadius.row),
    );

    return Semantics(
      label: outbound ? tr('inbox.you') : null,
      child: Row(
        mainAxisAlignment:
            outbound ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.76,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: UgamSpacing.md,
                vertical: UgamSpacing.sm + 2,
              ),
              decoration: BoxDecoration(color: bg, borderRadius: radius),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.hasAttachment) ...[
                    _WaAttachment(message: message, fg: fg),
                    if (text.isNotEmpty) const SizedBox(height: UgamSpacing.xs),
                  ],
                  if (text.isNotEmpty)
                    Text(
                      text,
                      style: UgamText.body.copyWith(color: fg, fontSize: 15),
                    ),
                  const SizedBox(height: 3),
                  Text(
                    time,
                    style: UgamText.tabular(
                      UgamText.micro.copyWith(color: metaColor, fontSize: 10),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
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
  final Color fg;

  const _WaAttachment({required this.message, required this.fg});

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
    if (message.mediaMissing) return _note(tr('inbox.media_unavailable'));

    final path = message.mediaPath!;
    return FutureBuilder<String?>(
      // Keyed by the path so a rebuild reuses the same future instead of
      // re-signing (the service caches, but this also keeps the placeholder
      // from flashing on every realtime tick).
      key: ValueKey(path),
      future: Get.find<InboxController>().mediaUrl(path),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _frame(
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final url = snap.data;
        if (url == null) return _note(tr('inbox.media_unavailable'));

        if (message.isImage) {
          return GestureDetector(
            onTap: () => _open(context, url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: Image.network(
                  url,
                  fit: BoxFit.cover,
                  // A decode cap: these come straight from a phone camera and an
                  // undecoded 12MP JPEG in a scrolling list is an OOM on the
                  // cheap Android handsets this app runs on.
                  cacheWidth: 900,
                  errorBuilder: (_, _, _) =>
                      _note(tr('inbox.media_unavailable')),
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                      : _frame(
                          child: const Center(
                            child: SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
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

    return InkWell(
      onTap: () => _open(context, url),
      borderRadius: BorderRadius.circular(UgamRadius.chip),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: fg),
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
                    style: UgamText.body.copyWith(color: fg, fontSize: 14),
                  ),
                  Text(
                    size == null
                        ? tr('inbox.open_attachment')
                        : '$size · ${tr('inbox.open_attachment')}',
                    style: UgamText.micro.copyWith(
                      color: fg.withValues(alpha: 0.7),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _frame({required Widget child}) => SizedBox(
        height: 120,
        width: 180,
        child: child,
      );

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 18,
              color: fg.withValues(alpha: 0.7),
            ),
            const SizedBox(width: UgamSpacing.xs),
            Flexible(
              child: Text(
                text,
                style: UgamText.micro.copyWith(
                  color: fg.withValues(alpha: 0.7),
                  fontSize: 12,
                ),
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
  final UgamColorSet c;

  const _WindowStatus({required this.open, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        UgamSpacing.xs,
        UgamSpacing.gutter,
        0,
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

/// Bottom-pinned reply composer: multiline input + circular send button. The
/// enclosing [UgamScaffold] resizes for the keyboard, so this row rides just
/// above the on-screen keyboard.
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
    return SafeArea(
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
                    width: 44,
                    height: 44,
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
    );
  }
}

/// Shimmer placeholder while the first message page loads.
class _ThreadSkeleton extends StatelessWidget {
  const _ThreadSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      children: const [
        _SkeletonBubble(alignEnd: false),
        SizedBox(height: UgamSpacing.md),
        _SkeletonBubble(alignEnd: true),
        SizedBox(height: UgamSpacing.md),
        _SkeletonBubble(alignEnd: false),
      ],
    );
  }
}

class _SkeletonBubble extends StatelessWidget {
  final bool alignEnd;
  const _SkeletonBubble({required this.alignEnd});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment:
          alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: const [
        UgamSkeleton(width: 180, height: 44, radius: UgamRadius.row),
      ],
    );
  }
}
