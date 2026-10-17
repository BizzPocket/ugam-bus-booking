part of '../customer_my_requests_screen.dart';

/// Single action strip for a request card: the ONE most relevant CTA inline
/// plus a ⋮ overflow that holds every other action. Replaces the old stack of
/// full-width Edit / Handler-chart / Cancel sections so no card ever shows more
/// than two strips.
///
/// Everything here is CARD-scoped — it acts on this one booking. "Add another
/// request" used to sit at the head of this list and was rendered as the solid
/// accent CTA, which put a page-level action inside a list item and repeated a
/// solid accent button once per row; it now lives on the page, at the bottom.
///
/// Primary CTA priority: Edit → View chart → ask-to-cancel / call. A
/// destructive self-cancel is only ever promoted inline when it is the sole
/// action left, and then it renders danger-tonal rather than affirmative. The
/// non-actionable "cancellation requested — awaiting organiser" state is
/// surfaced as a footer chip, so no cancel action is offered once one has been
/// raised.
class _ActionBar extends StatelessWidget {
  final CustomerRequestEntry entry;
  final UgamColorSet c;
  final bool isHandler;
  final VoidCallback onViewSeat;
  final VoidCallback onEdit;
  final VoidCallback onViewChart;
  final VoidCallback onCancel;
  final VoidCallback onRequestCancel;
  final VoidCallback onContact;

  const _ActionBar({
    required this.entry,
    required this.c,
    required this.isHandler,
    required this.onViewSeat,
    required this.onEdit,
    required this.onViewChart,
    required this.onCancel,
    required this.onRequestCancel,
    required this.onContact,
  });

  List<_RowAction> _actions() {
    final actions = <_RowAction>[];
    // Locked and seated: the one thing a confirmed rider comes here for.
    if (entry.seatsVisible) {
      actions.add(
        _RowAction(
          icon: Icons.event_seat_rounded,
          label: tr('customer_my_requests.view_my_seat'),
          onTap: onViewSeat,
        ),
      );
    }
    if (entry.canEdit) {
      actions.add(
        _RowAction(
          icon: Icons.edit_rounded,
          label: tr('customer_my_requests.edit_request_btn'),
          onTap: onEdit,
        ),
      );
    }
    if (isHandler) {
      actions.add(
        _RowAction(
          icon: Icons.grid_view_rounded,
          label: tr('customer_my_requests.view_full_chart'),
          onTap: onViewChart,
        ),
      );
    }
    // Cancel family — only when not already cancelled and no request pending
    // (the requested state shows as a footer chip instead).
    if (!entry.isCancelled && !entry.cancellationRequested) {
      if (entry.canCancel) {
        actions.add(
          _RowAction(
            icon: Icons.close_rounded,
            label: tr('customer_my_requests.cancel_action'),
            onTap: onCancel,
            destructive: true,
          ),
        );
      } else if (entry.canRequestCancel) {
        actions.add(
          _RowAction(
            icon: Icons.event_seat_outlined,
            label: tr('customer_my_requests.request_cancel_action'),
            onTap: onRequestCancel,
            quiet: true,
          ),
        );
      } else {
        actions.add(
          _RowAction(
            icon: Icons.call_rounded,
            label: tr('customer_my_requests.contact_to_cancel'),
            onTap: onContact,
            quiet: true,
          ),
        );
      }
    }
    return actions;
  }

  Future<void> _openOverflow(
    BuildContext context,
    List<_RowAction> actions,
  ) async {
    HapticFeedback.selectionClick();
    await UgamSheet.show<void>(
      context,
      title: tr('customer_my_requests.actions_title'),
      builder: (sheetCtx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final a in actions)
            _OverflowMenuRow(
              action: a,
              c: c,
              onTap: () {
                Navigator.of(sheetCtx).maybePop();
                a.onTap();
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final actions = _actions();
    // A cancelled ticket the customer neither owns as handler nor can edit has
    // nothing left to act on — the strip collapses rather than showing a lone
    // ⋮ over an empty row.
    if (actions.isEmpty) return const SizedBox.shrink();

    // Never lead with the destructive self-cancel (or a quiet exit) unless it
    // is all there is.
    final firstReal = actions.indexWhere((a) => !a.destructive && !a.quiet);
    final firstSafe = actions.indexWhere((a) => !a.destructive);
    final primaryIndex = firstReal >= 0
        ? firstReal
        : (firstSafe >= 0 ? firstSafe : 0);
    final primary = actions[primaryIndex];
    final overflow = [
      for (var i = 0; i < actions.length; i++)
        if (i != primaryIndex) actions[i],
    ];

    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.tight),
      child: Row(
        children: [
          Expanded(
            child: UgamButton(
              label: primary.label,
              icon: primary.icon,
              // Tonal, never solid: the page owns the one solid control. A
              // destructive sole action stays danger-tinted.
              kind: primary.destructive
                  ? UgamButtonKind.dangerTonal
                  : primary.quiet
                  ? UgamButtonKind.ghost
                  : UgamButtonKind.tonal,
              expand: true,
              onPressed: primary.onTap,
            ),
          ),
          if (overflow.isNotEmpty) ...[
            const SizedBox(width: UgamSpacing.sm),
            UgamTappable(
              onTap: () => _openOverflow(context, overflow),
              semanticLabel: tr('customer_my_requests.actions_title'),
              child: Container(
                // Matches UgamButton's box on both axes, so the strip is one
                // height and the ⋮ finally clears 44pt (it was 44×38).
                width: UgamScale.tap(context, 50),
                height: UgamScale.tap(context, 50),
                decoration: BoxDecoration(
                  color: c.card,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                  border: Border.all(color: c.border),
                ),
                alignment: Alignment.center,
                child: Icon(Icons.more_vert_rounded, size: 18, color: c.ink2),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One tappable row inside the ⋮ overflow sheet. Neutral, so it never competes
/// with the card's inline action; destructive actions tint danger.
class _OverflowMenuRow extends StatelessWidget {
  final _RowAction action;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _OverflowMenuRow({
    required this.action,
    required this.c,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tint = action.destructive ? c.danger : c.ink;
    return UgamTappable(
      onTap: onTap,
      semanticLabel: action.label,
      child: Container(
        margin: const EdgeInsets.only(bottom: UgamSpacing.sm),
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 50)),
        padding: const EdgeInsets.symmetric(
          horizontal: UgamSpacing.md,
          vertical: UgamSpacing.md,
        ),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          children: [
            Icon(action.icon, size: 18, color: tint),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                action.label,
                style: UgamText.bodyStrong.copyWith(color: tint),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One trip in the "which trip?" sheet the page CTA opens when the journal
/// holds live requests on MORE than one tour. This is the disambiguation the
/// card-nested button used to dodge by silently answering with its own row.
class _TourPickRow extends StatelessWidget {
  final CustomerRequestEntry entry;
  final VoidCallback onTap;

  const _TourPickRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamTappable(
      onTap: onTap,
      semanticLabel: entry.tourTitle,
      child: Container(
        margin: const EdgeInsets.only(bottom: UgamSpacing.sm),
        constraints: BoxConstraints(minHeight: UgamScale.tap(context, 50)),
        padding: const EdgeInsets.all(UgamSpacing.sm),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.input),
        ),
        child: Row(
          children: [
            _DateBlock(date: entry.tourDepartureDate, c: c),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    entry.tourTitle,
                    style: UgamText.titleS.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${entry.tourFromCity} → ${entry.tourToCity}',
                    style: UgamText.caption.copyWith(color: c.ink2),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
          ],
        ),
      ),
    );
  }
}

/// Tail content for a short list.
///
/// A customer with one booking used to see a single card at the top of the page
/// and nothing else — roughly two thirds of the screen was blank. The honest
/// fix is not padding but content, and the content a customer sitting on a
/// pending request actually wants is the sequence they are waiting on: who has
/// it now, what they do, and when the seat number appears. It withdraws once
/// the list is long enough to compose itself.
class _NextSteps extends StatelessWidget {
  const _NextSteps();

  static const _steps = <(IconData, String)>[
    (Icons.outbound_rounded, 'customer_my_requests.next_steps_1'),
    (Icons.verified_outlined, 'customer_my_requests.next_steps_2'),
    (Icons.event_seat_outlined, 'customer_my_requests.next_steps_3'),
  ];

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamCard.plain(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          UgamSectionLabel(tr('customer_my_requests.next_steps_title')),
          const SizedBox(height: UgamSpacing.md),
          for (var i = 0; i < _steps.length; i++) ...[
            if (i > 0) const SizedBox(height: UgamSpacing.tight),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(_steps[i].$1, size: 16, color: c.ink3),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Text(
                    tr(_steps[i].$2),
                    style: UgamText.caption.copyWith(color: c.ink2),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _LoadingShimmer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(UgamSpacing.gutter),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        UgamSkeleton(height: 110, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 110, radius: UgamRadius.card),
        SizedBox(height: UgamSpacing.md),
        UgamSkeleton(height: 110, radius: UgamRadius.card),
      ],
    );
  }
}

// ─── REFRESH ACTION (UgamAppBar trailing slot) ────────────────────────

/// Trailing refresh affordance for the shared [UgamAppBar]. Matches the
/// [UgamAppBarAction] circle styling, but swaps the glyph for a spinner while
/// a refresh is in flight (so the customer sees the pull is working).
class _RefreshAction extends StatelessWidget {
  final UgamColorSet c;
  final bool refreshing;
  final VoidCallback? onRefresh;

  const _RefreshAction({
    required this.c,
    required this.refreshing,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (!refreshing) {
      return UgamAppBarAction(
        icon: Icons.refresh_rounded,
        onTap: onRefresh ?? () {},
      );
    }
    // Same box UgamIconButton resolves, so the slot does not resize (and the
    // title beside it does not reflow) the moment a refresh starts.
    final box = UgamScale.tap(context, 44);
    return Container(
      width: box,
      height: box,
      decoration: BoxDecoration(color: c.cardElev, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: c.ink2),
      ),
    );
  }
}
