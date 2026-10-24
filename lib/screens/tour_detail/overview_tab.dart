part of '../tour_detail_screen.dart';

// ─── OVERVIEW TAB ─────────────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;

  const _OverviewTab({
    required this.tour,
    required this.c,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    final action = _nextActionFor(tour);
    final card = _NextActionCard(
      tour: tour,
      action: action,
      c: c,
      onSwitchTab: onSwitchTab,
    );

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        // An un-hydrated tour has no buses yet — its "Add a bus" next step is
        // only true once the roster has answered.
        if (action.kind == _NextActionKind.addBus)
          TourRosterGate(
            tourId: tour.id,
            loading: const UgamSkeleton(height: 120, radius: UgamRadius.card),
            empty: card,
          )
        else
          card,
        const SizedBox(height: UgamSpacing.lg),
        TourOverviewVitals(tour: tour, c: c, onSwitchTab: onSwitchTab),
        const SizedBox(height: UgamSpacing.lg),
        _OverviewToolsRow(tour: tour, c: c, onSwitchTab: onSwitchTab),
        // Blocker list — off by default (UiFlags.showAttentionSections). Its
        // leading gap is inside the guard so hiding it doesn't leave a double
        // gap between the tools row and the broadcast card.
        if (UiFlags.showAttentionSections) ...[
          const SizedBox(height: UgamSpacing.lg),
          TourNeedsAttention(
            tour: tour,
            c: c,
            onSwitchTab: onSwitchTab,
            onOpenManageBuses: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ManageBusesScreen(tourId: tour.id),
              ),
            ),
          ),
        ],
        const SizedBox(height: UgamSpacing.md),
        // The broadcast poster. It used to be the screen's HEADER on this tab
        // only — which is what made the same tour look like two different
        // screens. It sits with the broadcast card because that is what it is
        // for, and below the working cards because the agent's next action
        // outranks decoration.
        // Carries its own bottom gap so a failed photo collapses cleanly.
        if ((tour.broadcastImageUrl ?? '').trim().isNotEmpty)
          _TourCoverCard(tour: tour),
        _BroadcastCard(tour: tour, c: c),
      ]),
    );
  }
}

/// Compact tools row: Money · Broadcast · More (sheet with every other tool).
///
/// Stateful only to own the Broadcast tile's in-flight flag. That tile used to
/// call the clipboard-only `copy` path, so a control labelled "Broadcast" put a
/// message on the clipboard and never opened WhatsApp — indistinguishable from
/// a dead button. It now runs the SAME [_TourBroadcast.send] as the Overview
/// Broadcast card's primary CTA, which needs a `sending` flag to drive.
class _OverviewToolsRow extends StatefulWidget {
  final Tour tour;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;

  const _OverviewToolsRow({
    required this.tour,
    required this.c,
    required this.onSwitchTab,
  });

  @override
  State<_OverviewToolsRow> createState() => _OverviewToolsRowState();
}

class _OverviewToolsRowState extends State<_OverviewToolsRow> {
  bool _sending = false;

  Future<void> _broadcast() => _TourBroadcast.send(
        widget.tour,
        isSending: _sending,
        setSending: (v) => setState(() => _sending = v),
        isMounted: () => mounted,
      );

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('tour_detail.tools_section'),
            style: UgamText.micro.copyWith(color: c.ink3)),
        const SizedBox(height: UgamSpacing.sm),
        Row(
          children: [
            Expanded(
              child: _ToolTile(
                c: c,
                icon: Icons.account_balance_wallet_rounded,
                label: tr('tour_detail.tool_money'),
                onTap: () => widget.onSwitchTab(3),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _ToolTile(
                c: c,
                icon: Icons.campaign_rounded,
                label: tr('tour_detail.tool_broadcast'),
                busy: _sending,
                onTap: _broadcast,
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _ToolTile(
                c: c,
                icon: Icons.apps_rounded,
                label: tr('tour_detail.tool_more'),
                onTap: () {
                  // Every remaining per-tour workspace, flat — see [_ActionsGrid].
                  UgamSheet.show<void>(
                    context,
                    title: tr('tour_detail.more_tools'),
                    builder: (_) => _ActionsGrid(tour: widget.tour, c: c),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ToolTile extends StatelessWidget {
  final UgamColorSet c;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// Swaps the icon for a spinner and swallows taps while the tile's action is
  /// in flight — the Broadcast tile hands off to WhatsApp, which takes a beat.
  final bool busy;

  const _ToolTile({
    required this.c,
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      onTap: busy ? null : onTap,
      padding: const EdgeInsets.symmetric(
        vertical: UgamSpacing.md,
        horizontal: UgamSpacing.sm,
      ),
      child: Column(
        children: [
          // Neutral glyph. Three of these sit side by side and ALL of them were
          // copper, so the accent was marking "this is a tool tile" — which is
          // no meaning at all. The label below is the identifier and keeps full
          // ink; the glyph supports it.
          SizedBox(
            width: 22,
            height: 22,
            child: busy
                ? Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(c.ink2),
                      ),
                    ),
                  )
                : Icon(icon, size: 22, color: c.ink2),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: UgamText.caption.copyWith(color: c.ink),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ─── NEXT ACTION ──────────────────────────────────────────────────────

class _NextActionCard extends StatelessWidget {
  final Tour tour;
  final _NextAction action;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;

  const _NextActionCard({
    required this.tour,
    required this.action,
    required this.c,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    final tone = action.tone;
    final fg = _toneColor(tone, c);
    // Tappable: fires the SAME action as the bottom sticky CTA (reuses
    // _runAction) so the card and the sticky button stay in lock-step.
    return UgamCard.plain(
      tone: _cardToneFor(tone),
      onTap: () => _runAction(context, action, tour, onSwitchTab),
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: UgamScale.px(context, 44),
                height: UgamScale.px(context, 44),
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                alignment: Alignment.center,
                child: Icon(action.icon,
                    size: UgamScale.px(context, 20), color: fg),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('tour_detail.next_action'),
                      style: UgamText.micro.copyWith(color: fg),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      action.title,
                      style: UgamText.titleS.copyWith(color: c.ink),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              Icon(Icons.arrow_forward_rounded, size: 18, color: fg),
            ],
          ),
          if (action.subtitle != null) ...[
            const SizedBox(height: UgamSpacing.tight),
            Text(
              action.subtitle!,
              style: UgamText.caption.copyWith(color: c.ink2),
            ),
          ],
          if (action.secondaryKind != null &&
              action.secondaryCtaLabel != null) ...[
            // The seam shrinks because the link now carries its own 44pt box —
            // net card height is close to unchanged.
            const SizedBox(height: UgamSpacing.xs),
            UgamTappable(
              onTap: () =>
                  _runKind(context, action.secondaryKind!, tour, onSwitchTab),
              semanticLabel: action.secondaryCtaLabel,
              // Without a real 44pt target a near-miss fell through to the
              // card's own onTap and fired the PRIMARY action instead — a
              // different screen than the label the user aimed at.
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: UgamScale.tap(context, 44),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline_rounded,
                        size: 16, color: fg),
                    const SizedBox(width: 6),
                    Text(
                      action.secondaryCtaLabel!,
                      style: UgamText.bodyStrong
                          .copyWith(color: fg, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

UgamCardTone _cardToneFor(UgamStatusTone t) => switch (t) {
      UgamStatusTone.accent => UgamCardTone.accent,
      UgamStatusTone.good => UgamCardTone.good,
      UgamStatusTone.warm => UgamCardTone.warm,
      UgamStatusTone.neutral => UgamCardTone.none,
    };

/// Shared broadcast/share action used by BOTH the Overview [_BroadcastCard] and
/// the empty Passengers-tab CTA — so the WhatsApp send + copy message-building
/// lives in exactly ONE place (no duplication of the snackbar/`mounted` logic).
///
/// [send] opens WhatsApp's own broadcast/group picker with the announcement
/// pre-filled (and also copies it); [copy] just drops the message on the
/// clipboard. Callers pass `setSending`/`isMounted` so this can drive their
/// own loading flag and respect their lifecycle.
class _TourBroadcast {
  const _TourBroadcast._();

  static Future<void> send(
    Tour tour, {
    required bool isSending,
    required void Function(bool) setSending,
    required bool Function() isMounted,
  }) async {
    if (isSending) return;

    setSending(true);
    try {
      // Free broadcast: copy the message + open WhatsApp's own broadcast/group
      // picker with it pre-filled. No Cloud API, no server, no Meta approval —
      // the agent taps their saved Broadcast List or group to actually send.
      final opened = await WhatsAppService().broadcastTour(tour: tour);
      if (!isMounted()) return;
      if (opened) {
        AppSnackBar.success(tr('tour_detail.snack_broadcast_opened'));
      } else {
        AppSnackBar.warning(
          tr('tour_detail.snack_broadcast_copied_only'),
          title: tr('tour_detail.whatsapp_unavailable_title'),
        );
      }
    } catch (e) {
      if (isMounted()) {
        AppSnackBar.error(
          tr('tour_detail.snack_broadcast_error', namedArgs: {'error': '$e'}),
          title: tr('tour_detail.send_failed_title'),
        );
      }
    } finally {
      if (isMounted()) setSending(false);
    }
  }

  static Future<void> copy(Tour tour) async {
    HapticFeedback.lightImpact();
    await WhatsAppService().copyAnnouncementToClipboard(tour: tour);
    AppSnackBar.success(tr('tour_detail.snack_broadcast_copied'));
  }
}

/// The tour's broadcast poster, rendered as ordinary Overview content.
///
/// Only ever built when [Tour.broadcastImageUrl] is non-empty. When the photo
/// cannot be shown it renders NOTHING: the old fallback painted a ~170pt
/// decorative route monogram ("S→ભ") over a bus silhouette — a full card of
/// height that said nothing the header doesn't. While the photo loads, the
/// slot holds a quiet plain card so the poster doesn't shove the list down on
/// arrival; if the load fails the slot collapses.
class _TourCoverCard extends StatefulWidget {
  final Tour tour;

  const _TourCoverCard({required this.tour});

  /// Physical pixels wide the poster is actually painted at, capped so a
  /// high-DPI phone can't ask for more than the stored image has (1600).
  /// Returning null would mean "decode at full size", which is the thing this
  /// exists to avoid.
  static int _decodeWidth(BuildContext context) {
    final mq = MediaQuery.of(context);
    final physical = (mq.size.width * mq.devicePixelRatio).round();
    if (physical <= 0) return 800; // degenerate metrics — pick a sane default
    return physical > 1600 ? 1600 : physical;
  }

  @override
  State<_TourCoverCard> createState() => _TourCoverCardState();
}

class _TourCoverCardState extends State<_TourCoverCard> {
  bool _failed = false;

  @override
  void didUpdateWidget(covariant _TourCoverCard old) {
    super.didUpdateWidget(old);
    if (old.tour.broadcastImageUrl != widget.tour.broadcastImageUrl) {
      _failed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    // A failed photo collapses to zero height (the Image stays mounted, so a
    // later successful retry/URL change can still paint without a remount).
    return Padding(
      padding: EdgeInsets.only(bottom: _failed ? 0 : UgamSpacing.md),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(UgamRadius.photo),
        child: SizedBox(
          width: double.infinity,
          // Decorative, so it tracks the responsive factor rather than the
          // text scale — a poster does not need to grow with the font setting.
          height: _failed ? 0 : UgamScale.px(context, 168),
          child: Image.network(
            widget.tour.broadcastImageUrl!,
            fit: BoxFit.cover,
            // Decode at the size we actually PAINT, not the size uploaded. The
            // picker stores at maxWidth 1600 (create_tour_screen), so without
            // this the poster decodes to a 1600x1067 ARGB bitmap — ~6.8 MB of
            // RAM for a 168pt strip, on phones that have little to spare.
            cacheWidth: _TourCoverCard._decodeWidth(context),
            // Loading: a plain card, no monogram. (Bucket history: the
            // tour-broadcasts bucket was private until migration 051, so this
            // fallback used to be what ALWAYS rendered.)
            loadingBuilder: (ctx, child, progress) =>
                progress == null ? child : ColoredBox(color: c.card),
            errorBuilder: (_, _, _) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && !_failed) setState(() => _failed = true);
              });
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }
}

/// A single broadcast card: campaign icon + title + hint, a PRIMARY
/// "Send broadcast on WhatsApp" CTA (opens WhatsApp's own broadcast/group
/// picker with the message pre-filled), plus a small secondary copy icon that
/// drops the announcement on the clipboard. Replaces the previous two stacked
/// elements (copy-card + send-CTA).
class _BroadcastCard extends StatefulWidget {
  final Tour tour;
  final UgamColorSet c;
  const _BroadcastCard({required this.tour, required this.c});

  @override
  State<_BroadcastCard> createState() => _BroadcastCardState();
}

class _BroadcastCardState extends State<_BroadcastCard> {
  bool _sending = false;

  Future<void> _send() => _TourBroadcast.send(
        widget.tour,
        isSending: _sending,
        setSending: (v) => setState(() => _sending = v),
        isMounted: () => mounted,
      );

  Future<void> _copy() => _TourBroadcast.copy(widget.tour);

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: UgamScale.px(context, 44),
                height: UgamScale.px(context, 44),
                decoration: BoxDecoration(
                  color: c.goodFill,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.campaign_rounded,
                    size: UgamScale.px(context, 22), color: c.good),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('tour_detail.broadcast_this_tour'),
                      style:
                          UgamText.titleS.copyWith(color: c.ink, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tr('tour_detail.broadcast_copy_hint'),
                      style: UgamText.caption.copyWith(color: c.ink2),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.md),
          Row(
            children: [
              // Demoted from a full UgamCTA to TONAL — one focal control per
              // surface, and on the Overview tab that is the Next-Action card.
              // (`tonal` used to be amber-INKED too; that was retired in
              // `ugam_button.dart` — the wash stays amber, the lettering is
              // now `ink`. Nothing to do here.)
              Expanded(
                child: UgamButton(
                  label: _sending
                      ? tr('tour_detail.sending_broadcast')
                      : tr('tour_detail.send_broadcast_whatsapp'),
                  icon: Icons.send_rounded,
                  kind: UgamButtonKind.tonal,
                  loading: _sending,
                  expand: true,
                  onPressed: _send,
                ),
              ),
              const SizedBox(width: UgamSpacing.sm),
              UgamIconButton(
                icon: Icons.copy_rounded,
                onTap: _copy,
                size: 50,
                iconSize: 18,
                semanticLabel: tr('tour_detail.copy_broadcast_message'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
