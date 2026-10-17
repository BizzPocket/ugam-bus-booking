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

part 'conversation/conversation_message.dart';
part 'conversation/conversation_chrome.dart';

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
