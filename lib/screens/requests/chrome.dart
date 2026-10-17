part of '../requests_screen.dart';

/// The screen's single bottom slab, extended or retracted.
///
/// The Requests tab floats its own action bar (Seats CTA / bulk-action bar)
/// over a shell that already floats the dock nav at the same edge, which is
/// what made the bottom of this screen read as two bars fighting each other.
/// The bar is positioned ABOVE the dock (see `_kBarLift`) and slides down
/// behind it whenever the agent scrolls into the list, so only one piece of
/// chrome is on the edge at any moment. Hidden means genuinely inert — the
/// retracted bar takes no taps in the dock's strip.
class _RetractingBar extends StatelessWidget {
  final bool shown;
  final Widget child;

  const _RetractingBar({required this.shown, required this.child});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedSlide(
        duration: UgamMotion.dock,
        curve: UgamMotion.easeOut,
        // A full self-height slide parks it entirely under the dock capsule,
        // which paints above the body and hides the last few pixels.
        offset: shown ? Offset.zero : const Offset(0, 1),
        child: AnimatedOpacity(
          duration: UgamMotion.dock,
          curve: UgamMotion.easeOut,
          opacity: shown ? 1 : 0,
          child: child,
        ),
      ),
    );
  }
}

// ─── Top bar ──────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final UgamColorSet c;
  final bool showBack;
  final VoidCallback onBack;
  final bool searchActive;
  final VoidCallback onToggleSearch;
  final VoidCallback? onAdd;
  final VoidCallback? onGroups;
  final bool selectionMode;
  final int selectedCount;
  final VoidCallback onExitSelection;

  const _TopBar({
    required this.c,
    this.showBack = false,
    required this.onBack,
    required this.searchActive,
    required this.onToggleSearch,
    required this.onAdd,
    required this.onGroups,
    required this.selectionMode,
    required this.selectedCount,
    required this.onExitSelection,
  });

  @override
  Widget build(BuildContext context) {
    // Selection mode: the shared app bar with a close-X "back" and the
    // selected-count as the title. Keeps the chrome identical to the rest of
    // the app instead of a hand-rolled row.
    if (selectionMode) {
      return UgamAppBar(
        title: tr('requests.selected_count', namedArgs: {'n': '$selectedCount'}),
        showBack: true,
        onBack: onExitSelection,
      );
    }

    // Normal mode. Add is now a NEUTRAL chrome action (champagne is rationed to
    // the sticky Seats CTA + bulk-Confirm); a null onTap renders it properly
    // disabled via UgamIconButton's muted token, not an accent-at-40% hack.
    return UgamAppBar(
      title: tr('requests.title'),
      // Pushed/scoped mode shows the back affordance; the shell tab hides it.
      showBack: showBack,
      onBack: onBack,
      actions: [
        UgamAppBarAction(
          icon: searchActive ? Icons.close_rounded : Icons.search_rounded,
          onTap: onToggleSearch,
          active: searchActive,
        ),
        UgamIconButton(
          icon: Icons.groups_rounded,
          onTap: onGroups,
          semanticLabel: tr('tour_detail.tool_groups'),
        ),
        UgamIconButton(
          icon: Icons.person_add_alt_rounded,
          onTap: onAdd,
          semanticLabel: tr('requests.sheet.title'),
        ),
      ],
    );
  }
}

// ─── Assignment CTA ───────────────────────────────────────────────────

/// The "add a bus" way out, and ONLY that.
///
/// This used to also be a full-width "Seats" shortcut into the seating
/// workspace whenever the tour had a bus — i.e. essentially always. Removed:
/// the dock's own CHARTS tab already reaches seating, so the slab was a second
/// route to a place that was never more than one tap away, and it paid for that
/// redundancy with the loudest control on the screen — permanently parked over
/// the request list, and over the empty state's body text.
///
/// A tour with NO bus is different: nothing on this screen can be acted on
/// until one exists, so that case keeps its CTA rather than leaving the agent
/// on a dead end. Which also means the bottom bar is now the exception on this
/// screen, not the rule — see `_hasBottomBar`, which the list padding reads so
/// it stops reserving 144pt for a bar that is not there.
class _AssignmentCTA extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _AssignmentCTA({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    if (tour.buses.isNotEmpty) return const SizedBox.shrink();
    return UgamStickyCTA(
      child: UgamCTA(
        label: tr('requests.cta_add_bus'),
        leadingIcon: Icons.add_rounded,
        onPressed: () {
          HapticFeedback.lightImpact();
          Get.to(() => AddBusScreen(tourId: tour.id));
        },
      ),
    );
  }
}

// ─── Bulk action bar ──────────────────────────────────────────────────

class _BulkActionBar extends StatelessWidget {
  final UgamColorSet c;
  final int count;
  final bool isWaitlistTab;

  /// Whether the Confirm slot is offered (false on the Assigned tab, where the
  /// selection is already past the confirm stage).
  final bool canConfirm;
  /// Whether the Decline slot is offered.
  /// Decline/cancel is only allowed while the booking is not confirmed.
  final bool canDecline;
  final VoidCallback onWaitlist;
  final VoidCallback onPromote;
  final VoidCallback onConfirm;
  final VoidCallback onSendWA;
  final VoidCallback onDecline;
  final VoidCallback onCancel;

  const _BulkActionBar({
    required this.c,
    required this.count,
    required this.isWaitlistTab,
    required this.canConfirm,
    required this.canDecline,
    required this.onWaitlist,
    required this.onPromote,
    required this.onConfirm,
    required this.onSendWA,
    required this.onDecline,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = count > 0;
    // The bar occupies the exact pixel slot the sticky Seats CTA vacates, so it
    // reuses the SAME scrim ([UgamStickyCTA]) rather than a hand-rolled
    // gradient — the two differed by 4px of top padding and 10% of fade stop,
    // so long-pressing a row made the bottom scrim visibly jump and darken
    // instead of the bar simply swapping in place.
    return UgamStickyCTA(
      child: Container(
        padding: const EdgeInsets.all(UgamSpacing.sm),
        decoration: BoxDecoration(
          color: c.card,
          borderRadius: BorderRadius.circular(UgamRadius.chip),
        ),
        // Cancel lives in the top bar (the close-X shown in selection mode),
        // so the bar focuses on the real moves. The first slot flips between
        // Promote (waitlist tab) and Waitlist (everywhere else). Confirm is
        // the accent primary when offered; it drops to a plain Send-WA primary
        // on the Assigned tab where confirming is moot.
        child: Row(
          children: [
            Expanded(
              child: isWaitlistTab
                  ? UgamButton(
                      icon: Icons.arrow_back_rounded,
                      label: tr('requests.bulk.promote'),
                      kind: UgamButtonKind.ghost,
                      expand: true,
                      onPressed: enabled ? onPromote : null,
                    )
                  : UgamButton(
                      icon: Icons.hourglass_top_rounded,
                      label: tr('requests.bulk.waitlist'),
                      kind: UgamButtonKind.ghost,
                      expand: true,
                      onPressed: enabled ? onWaitlist : null,
                    ),
            ),
            if (canConfirm)
              Expanded(
                child: UgamButton(
                  icon: Icons.verified_rounded,
                  label: tr('requests.bulk.accept'),
                  // The ONE accent in the bulk bar (per accent-rationing).
                  kind: UgamButtonKind.primary,
                  expand: true,
                  onPressed: enabled ? onConfirm : null,
                ),
              ),
            Expanded(
              child: UgamButton(
                icon: Icons.chat_rounded,
                label: tr('requests.bulk.send_wa'),
                // Accent primary only when Confirm isn't taking that slot
                // (Assigned tab); otherwise a quiet ghost.
                kind: canConfirm
                    ? UgamButtonKind.ghost
                    : UgamButtonKind.primary,
                expand: true,
                onPressed: enabled ? onSendWA : null,
              ),
            ),
            Expanded(
              child: UgamButton(
                icon: Icons.close_rounded,
                label: tr('requests.bulk.decline'),
                kind: UgamButtonKind.dangerTonal,
                expand: true,
                onPressed: enabled && canDecline ? onDecline : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
