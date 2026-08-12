import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/auth_controller.dart';
import '../controllers/inbox_controller.dart';
import '../controllers/money_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../routes/app_routes.dart';
import '../utils/formatters.dart';
import '../utils/passenger_display.dart';
import '../widgets/dashboard/attention_section.dart';
import '../widgets/dashboard/dashboard_greeting.dart';
import '../widgets/dashboard/dashboard_models.dart';
import '../widgets/dashboard/loading_shimmer.dart';
import '../widgets/dashboard/quick_actions.dart';
import '../widgets/dashboard/recent_request_row.dart';
import '../widgets/dashboard/trip_hero.dart';
import 'main_shell.dart';
import 'notify_screen.dart';
import 'seating_exceptions_screen.dart';
import 'seats_screen.dart';
import 'tour_detail_screen.dart';
import 'tour_money_board_screen.dart';

/// Admin home — the agent's control center. Surfaces what needs action
/// THIS hour, not just the raw database.
///
/// Order top-to-bottom:
///   1. Greeting + localized date pill + avatar (→ Settings tab)
///   2. Trip hero: a tour picker, then a "both, stacked" card —
///      route · phase / single most-urgent action / money strip /
///      pax · seats-left · open-trip footer.
///   3. Quick actions (Create / Requests / Money / Finance)
///   4. "Needs attention" — tours blocked on agent action (incl. money
///      settlement), one accent CTA on the top item; else "All caught up".
///   5. Recent requests — last 5 new passengers across active tours.
///
/// The widget pieces live in `lib/widgets/dashboard/`; this file keeps the
/// screen scaffold plus the two lifecycle data-helpers ([_needsAttention],
/// [_recentRequests]) — they build navigation + localized callbacks, so they
/// belong to the screen, not a controller.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final authCtrl = Get.find<AuthController>();
    final shell = Get.find<ShellController>();
    final c = UgamColors.of(context);

    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Obx(() {
          if (tourCtrl.isLoading.value && tourCtrl.tours.isEmpty) {
            return DashboardLoadingShimmer(c: c);
          }
          if (tourCtrl.hasError.value && tourCtrl.tours.isEmpty) {
            // Reserve the dock's footprint so the Retry button is optically
            // centred in the space the agent can see, not parked underneath
            // the floating nav.
            return Padding(
              padding: const EdgeInsets.only(bottom: UgamSpacing.dockClearance),
              child: UgamEmpty(
                icon: Icons.cloud_off_rounded,
                title: tr('dashboard.error_title'),
                body: tourCtrl.errorMessage.value,
                cta: UgamCTA(
                  label: tr('app.action.retry'),
                  leadingIcon: Icons.refresh_rounded,
                  onPressed: tourCtrl.refreshTours,
                ),
              ),
            );
          }

          // Fire the AL-3 settlement-snapshot pass once the tour list is
          // known, so non-loaded tours' outstanding handovers get cached
          // (see MoneyController.loadSettlementSnapshots). Post-frame to
          // avoid mutating controller state during build. This Obx only
          // reads tourCtrl state (isLoading/hasError/tours) above, never
          // money.settlementByTour, so the snapshot writes below can't
          // retrigger this same callback — no reactive feedback loop. The
          // controller-side "already cached" guard keeps repeat calls (e.g.
          // when tours mutate for unrelated reasons) a cheap no-op.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Defer settlement snapshots so they never compete with the cold-start
            // roster/layout wave on 2G. Cached entries stay a no-op.
            Future<void>.delayed(const Duration(milliseconds: 1200), () {
              if (!Get.isRegistered<MoneyController>()) return;
              Get.find<MoneyController>()
                  .loadSettlementSnapshots(tourCtrl.tours.map((t) => t.id));
            });
          });

          return RefreshIndicator(
            onRefresh: tourCtrl.refreshTours,
            // CHROME, NOT OWNERSHIP. The accent means exactly one thing —
            // "this is yours" (see [Brand]) — and a pull-to-refresh spinner is
            // not a thing anyone owns. On this screen the same amber was
            // painting the user's own rows *while* the spinner spun, so one hue
            // was doing two jobs in one frame; that is the dilution the ration
            // exists to prevent. ink2 is the app's neutral-chrome ink: 5.95:1
            // on the spinner's puck in Midnight, 5.50:1 in Daylight, both well
            // clear of the 3:1 WCAG floor for a graphical object (the amber it
            // replaces measured 4.46:1 in Daylight).
            //
            // Every RefreshIndicator in lib/ carries this same line. It is a
            // deliberately app-wide, one-pass decision: a spinner that changed
            // hue as the user pulled on a different tab read as a bug.
            color: c.ink2,
            // Slivers, not a ListView, for ONE reason: the trailing
            // SliverFillRemaining. Every live block on this screen sits in the
            // top half, and on a quiet day (no blockers, no new requests) the
            // bottom 300-400 pt was undesigned void. The tail now takes that
            // space deliberately and anchors the one remaining useful door to
            // the bottom edge, in the thumb zone. The children are byte-for-byte
            // the same widgets in the same order.
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    UgamSpacing.gutter,
                    UgamSpacing.lg,
                    UgamSpacing.gutter,
                    0,
                  ),
                  sliver: SliverList.list(children: [
                    Obx(() => DashboardGreeting(
                          name: authCtrl.userName.value,
                          initials: authCtrl.initials,
                          c: c,
                        )),
                    const SizedBox(height: UgamSpacing.md),
                    DashboardTripHero(c: c),
                    const SizedBox(height: UgamSpacing.md),
                    DashboardQuickActions(c: c, shell: shell),
                    // Unread WhatsApp messages nudge — only when there's something
                    // to read; the always-present entry point is the home-header
                    // chat icon. Neutral surface (accent stays rationed to the top
                    // attention CTA); the count rides a TONAL accent pill.
                    Obx(() {
                      final unread = Get.find<InboxController>().totalUnread.value;
                      if (unread <= 0) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: UgamSpacing.md),
                        child: _MessagesCard(count: unread, c: c),
                      );
                    }),
                    const SizedBox(height: UgamSpacing.md),
                    Obx(() {
                      final attention = _needsAttention(context, tourCtrl.tours);
                      if (attention.isEmpty) {
                        // P2: explicit affirmation when there are tours but
                        // nothing needs action — never a silent SizedBox.
                        final activeTours = tourCtrl.tours
                            .where((t) => t.status != TourStatus.completed)
                            .length;
                        if (activeTours == 0) return const SizedBox.shrink();
                        return DashboardAllCaughtUp(count: activeTours, c: c);
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DashboardSectionLabel(
                            label: tr('dashboard.section_attention'),
                            meta: '${attention.length}',
                            c: c,
                          ),
                          const SizedBox(height: UgamSpacing.md),
                          for (var i = 0; i < attention.length; i++) ...[
                            // Accent-rationing: only the single top-priority
                            // (first) attention row gets the accent CTA chip.
                            DashboardAttentionRow(
                              item: attention[i],
                              c: c,
                              isPrimary: i == 0,
                            ),
                            if (i != attention.length - 1)
                              const SizedBox(height: UgamSpacing.tight),
                          ],
                        ],
                      );
                    }),
                    Obx(() {
                      final recent = _recentRequests(tourCtrl.tours);
                      // "No data yet" and "genuinely zero" are different
                      // statements. With no active tour there is nothing that
                      // COULD produce a request, so the section stays away.
                      // With active tours and no requests the section renders
                      // an explicit empty state — a silent gap where a list
                      // should be reads as a load that failed.
                      final hasActive = tourCtrl.tours
                          .any((t) => t.status != TourStatus.completed);
                      if (recent.isEmpty && !hasActive) {
                        return const SizedBox.shrink();
                      }
                      final empty = recent.isEmpty;
                      // Requests tab. Route through the same entry point the
                      // dock uses so there is one way in. NOTE: from the
                      // dashboard (index 0) this is behaviourally identical to
                      // switchTab — onTabTapped only pops the target navigator
                      // when it is ALREADY the current tab, so a Requests
                      // sub-page the agent left open still shows. Resetting it
                      // needs a shell-side method; escalated rather than
                      // hand-rolled here.
                      void openRequests() => shell.onTabTapped(3);
                      return Padding(
                        padding: const EdgeInsets.only(top: UgamSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DashboardSectionLabel(
                              label: tr('dashboard.section_recent'),
                              // Nothing to "see all" of when the list is
                              // empty — the card below is itself the door.
                              action: empty ? null : tr('dashboard.see_all'),
                              onAction: empty ? null : openRequests,
                              c: c,
                            ),
                            const SizedBox(height: UgamSpacing.md),
                            if (empty)
                              _RecentEmptyCard(c: c, onTap: openRequests)
                            else
                              for (var i = 0; i < recent.length; i++) ...[
                                DashboardRecentRow(
                                  entry: recent[i],
                                  onTap: openRequests,
                                ),
                                if (i != recent.length - 1)
                                  const SizedBox(height: UgamSpacing.tight),
                              ],
                          ],
                        ),
                      );
                    }),
                  ]),
                ),
                // The composed tail. `hasScrollBody: false` hands it whatever
                // viewport is left over after the blocks above, and the bottom
                // Align pins its content to the floor of that space — so a
                // quiet dashboard reads as a deliberate composition with an
                // anchored footer, not as a page that just stops. This also
                // carries the whole scrollable's UgamSpacing.dockClearance.
                //
                // The clearance MUST be padding on the CHILD, not a
                // SliverPadding around this sliver: SliverPadding does not
                // subtract its `after` extent from the child's
                // remainingPaintExtent, so the fill would size itself to the
                // full remaining viewport and then push 140 pt of padding
                // BELOW the fold — the tail landed under the dock and a
                // one-card dashboard became scrollable for no reason.
                // Verified by layout probe, not by eye.
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.xl,
                      UgamSpacing.gutter,
                      UgamSpacing.dockClearance,
                    ),
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Obx(
                        () => _DashboardTail(tours: tourCtrl.tours, c: c),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  // ── data helpers ───────────────────────────────────────────────────

  /// Tours that need agent action. Ordered by departure date (soonest first).
  List<AttentionItem> _needsAttention(BuildContext context, List<Tour> tours) {
    final items = <AttentionItem>[];
    final tourCtrl = Get.find<TourController>();
    final money = Get.find<MoneyController>();
    final relevant = tours
        .where((t) => t.status != TourStatus.completed)
        .toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));

    for (final tour in relevant) {
      // Locked tours: only surface post-lock duties (re-notify after seat
      // edits, outstanding handler cash). Pre-lock blockers don't apply.
      if (tour.status == TourStatus.locked) {
        // [Passenger.notifiedSeatsAreStale] — seats moved OR taken back since
        // the send. The old predicate (`assignedSeats.isNotEmpty &&
        // seatsChangedSinceNotified`) was redundant in its first half and
        // silently dropped the rider whose seat was WITHDRAWN after they were
        // told: nothing on this dashboard would ever mention them again.
        final stale =
            tour.passengers.where((p) => p.notifiedSeatsAreStale).toList();
        // A withdrawal has no WhatsApp template — Notify shows the rider's
        // phone and an "I've told them" acknowledgement — so "re-notify"
        // wording would promise a send that surface refuses to offer. When any
        // rider is stranded, the row leads with them and asks for a call.
        final withdrawn =
            stale.where((p) => p.seatsRemovedSinceNotified).length;
        final changed = stale.length;
        if (changed > 0) {
          items.add(AttentionItem(
            tour: tour,
            reason: withdrawn > 0
                ? tr('dashboard.attention_seat_removed',
                    namedArgs: {'n': '$withdrawn'})
                : tr('dashboard.attention_renotify',
                    namedArgs: {'n': '$changed'}),
            ctaLabel: withdrawn > 0
                ? tr('dashboard.cta_call')
                : tr('dashboard.cta_renotify'),
            ctaIcon: withdrawn > 0
                ? Icons.phone_in_talk_rounded
                : Icons.chat_rounded,
            tone: UgamStatusTone.warm,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => NotifyScreen(tourId: tour.id),
              ),
            ),
          ));
          continue;
        }
        final outstanding = money.outstandingHandoverFor(tour.id);
        if (outstanding != null && outstanding > 0.005) {
          final amount = Formatters.formatMoneyInr(outstanding);
          final handler = tour.handler?.displayName;
          items.add(AttentionItem(
            tour: tour,
            reason: handler != null && handler.isNotEmpty
                ? tr('dashboard.settle_from_handler',
                    namedArgs: {'amount': amount, 'handler': handler})
                : tr('dashboard.settle_amount', namedArgs: {'amount': amount}),
            ctaLabel: tr('dashboard.qa_money'),
            ctaIcon: Icons.account_balance_wallet_rounded,
            tone: UgamStatusTone.warm,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => TourMoneyBoardScreen(tourId: tour.id),
              ),
            ),
          ));
        }
        continue;
      }

      // Skip empty planning tours — no requests, no urgency
      if (tour.status == TourStatus.planning && tour.passengers.isEmpty) {
        continue;
      }
      // A customer asked to cancel a CONFIRMED / seat-assigned booking
      // (migration 035) — a discrete decision the organiser owes them. Surface
      // it high, routing to the Requests home where the "Approve cancellation"
      // primary lives and the seat is freed.
      final cancelReqs =
          tour.passengers.where((p) => p.isCancelRequested).length;
      if (cancelReqs > 0) {
        items.add(AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_cancel_requests',
              args: ['$cancelReqs']),
          ctaLabel: tr('dashboard.cta_review'),
          ctaIcon: Icons.event_busy_rounded,
          tone: UgamStatusTone.warm,
          onTap: () => Get.find<ShellController>().onTabTapped(3),
        ));
        continue;
      }
      // Money settlement: a handler still owing cash to the admin is a sharp,
      // money-on-the-line blocker. Reads the SAME TourMoneySummary math the
      // money board uses — the exact live figure when this is the loaded
      // tour, else a cached per-tour snapshot (AL-3) — so tours OTHER than
      // the hero-selected one surface too, not just the loaded one. Null
      // (snapshot not yet loaded) is treated as "unknown", never "settled".
      final outstanding = money.outstandingHandoverFor(tour.id);
      if (outstanding != null && outstanding > 0.005) {
        final amount = Formatters.formatMoneyInr(outstanding);
        final handler = tour.handler?.displayName;
        items.add(AttentionItem(
          tour: tour,
          reason: handler != null && handler.isNotEmpty
              ? tr('dashboard.settle_from_handler',
                  namedArgs: {'amount': amount, 'handler': handler})
              : tr('dashboard.settle_amount', namedArgs: {'amount': amount}),
          ctaLabel: tr('dashboard.qa_money'),
          ctaIcon: Icons.account_balance_wallet_rounded,
          tone: UgamStatusTone.warm,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => TourMoneyBoardScreen(tourId: tour.id),
            ),
          ),
        ));
        continue;
      }
      if (tour.passengers.isNotEmpty && tour.buses.isEmpty) {
        items.add(AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_no_bus',
              namedArgs: {'n': '${tour.passengers.length}'}),
          ctaLabel: tr('dashboard.cta_add_bus'),
          ctaIcon: Icons.directions_bus_rounded,
          tone: UgamStatusTone.warm,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => TourDetailScreen(tourId: tour.id),
            ),
          ),
        ));
        continue;
      }
      // A passenger the engine can't auto-seat (overflow, group won't fit,
      // priority miss, no matching seat type) is a sharper blocker than a raw
      // "N seats unassigned" — surface it first, routing straight to the
      // "needs your decision" list. Count comes from the live, memoized
      // capacityFor (same source as the Requests banner).
      if (tour.buses.isNotEmpty) {
        final decisions = tourCtrl.capacityFor(tour).needsDecision;
        if (decisions > 0) {
          items.add(AttentionItem(
            tour: tour,
            reason: tr('dashboard.attention_seating_decisions',
                namedArgs: {'n': '$decisions'}),
            ctaLabel: tr('dashboard.cta_decide'),
            ctaIcon: Icons.error_outline_rounded,
            tone: UgamStatusTone.warm,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => SeatingExceptionsScreen(tourId: tour.id),
              ),
            ),
          ));
          continue;
        }
      }
      if (tour.buses.isNotEmpty && tour.pendingSeatsToAssign > 0) {
        final remaining = tour.pendingSeatsToAssign;
        items.add(AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_unassigned',
              namedArgs: {'n': '$remaining'}),
          ctaLabel: tr('dashboard.cta_assign'),
          ctaIcon: Icons.grid_view_rounded,
          tone: UgamStatusTone.accent,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => SeatsScreen(
                tourId: tour.id,
                initialMode: SeatsMode.grid,
              ),
            ),
          ),
        ));
        continue;
      }
      if (tour.allSeatsAssigned && tour.handlerId == null) {
        items.add(AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_pick_handler'),
          ctaLabel: tr('dashboard.cta_pick'),
          ctaIcon: Icons.person_pin_rounded,
          tone: UgamStatusTone.good,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => TourDetailScreen(tourId: tour.id),
            ),
          ),
        ));
        continue;
      }
      if (tour.allSeatsAssigned && tour.handlerId != null) {
        items.add(AttentionItem(
          tour: tour,
          reason: tr('dashboard.attention_ready_lock'),
          ctaLabel: tr('dashboard.cta_lock'),
          ctaIcon: Icons.lock_rounded,
          tone: UgamStatusTone.good,
          // Lock & notify lives on the tour-scoped Notify screen — the same
          // destination tour_detail_screen.dart:1989 (_NextActionKind
          // .lockAndNotify) and :2170 (the "Lock" tool row) push for this
          // exact verb. Was switchTab(4), which is the Settings tab
          // (main_shell.dart:98) and dropped the tour context entirely.
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => NotifyScreen(tourId: tour.id),
            ),
          ),
        ));
      }
    }
    return items.take(4).toList();
  }

  /// Last 5 passenger requests across all active tours.
  List<RecentEntry> _recentRequests(List<Tour> tours) {
    final entries = <RecentEntry>[];
    for (final t in tours.where((t) => t.status != TourStatus.completed)) {
      for (final p in t.passengers) {
        entries.add(RecentEntry(tour: t, passenger: p));
      }
    }
    entries.sort((a, b) => b.passenger.createdAt.compareTo(a.passenger.createdAt));
    return entries.take(5).toList();
  }
}

/// Explicit "no requests yet" state for the Recent requests section. Replaces
/// a silent `SizedBox.shrink()`: on a live tour with no bookings, a section
/// that simply is not there is indistinguishable from a section that failed to
/// load. The whole card is the primary action (→ the Requests tab), so it also
/// clears the 44 pt minimum by a wide margin.
class _RecentEmptyCard extends StatelessWidget {
  final UgamColorSet c;
  final VoidCallback onTap;

  const _RecentEmptyCard({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Decorative medallion inside an already-tappable card -> px, never tap.
    final tile = UgamScale.px(context, 40);
    return UgamCard.plain(
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: tile,
            height: tile,
            decoration: BoxDecoration(
              color: c.cardElev,
              borderRadius: BorderRadius.circular(UgamRadius.input),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.inbox_rounded,
              size: UgamScale.px(context, 20),
              color: c.ink3,
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('dashboard.recent_empty_title'),
                  style: UgamText.titleS.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                // Two lines: the Gujarati copy runs past one line at 375.
                Text(
                  tr('dashboard.recent_empty_body'),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.sm),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
        ],
      ),
    );
  }
}

/// Bottom-anchored closing block for the dashboard.
///
/// Everything live on this screen sits in the top half. When the agent has no
/// active tour left — a brand-new account, or a season that has finished — the
/// blocks above collapse and the rest of the page was blank. This takes that
/// space on purpose and puts the one door that is still useful (the archive of
/// finished tours) on the floor of the viewport, where the thumb already is.
/// It renders nothing while there IS active work: a quiet dashboard should not
/// grow footer furniture the moment it is busy.
class _DashboardTail extends StatelessWidget {
  final List<Tour> tours;
  final UgamColorSet c;

  const _DashboardTail({required this.tours, required this.c});

  @override
  Widget build(BuildContext context) {
    final hasActive = tours.any((t) => t.status != TourStatus.completed);
    final completed =
        tours.where((t) => t.status == TourStatus.completed).length;
    if (hasActive || completed == 0) return const SizedBox.shrink();

    return UgamButton(
      label: tr('dashboard.completed_tours', namedArgs: {'n': '$completed'}),
      icon: Icons.history_rounded,
      kind: UgamButtonKind.ghost,
      expand: true,
      onPressed: () => Get.find<ShellController>().onTabTapped(1), // Tours tab
    );
  }
}

/// Dashboard nudge card for unread WhatsApp customer messages. Neutral surface
/// (accent-rationing law — the accent CTA belongs to the top attention row);
/// the unread count rides a small TONAL accent pill — `accentFill` + `accent`
/// ink, never a solid copper blob. Opens the inbox by named route.
class _MessagesCard extends StatelessWidget {
  final int count;
  final UgamColorSet c;

  const _MessagesCard({required this.count, required this.c});

  @override
  Widget build(BuildContext context) {
    // Decorative chrome inside an already-tappable card (the whole card is the
    // target), so [UgamScale.px], never [tap] — nothing here is its own target.
    final tile = UgamScale.px(context, 40);
    final glyph = UgamScale.px(context, 20);
    return UgamCard.plain(
      // Named route, not an anonymous `Get.to(() => const InboxScreen())`:
      // push_service.dart:245 guards inbox re-entry with
      // `Get.currentRoute != AppRoutes.inbox`, and an anonymous route never
      // reports '/inbox', so a WhatsApp push arriving while the inbox was
      // open from here stacked a second identical inbox.
      onTap: () => Get.toNamed(AppRoutes.inbox),
      tone: UgamCardTone.warm,
      child: Row(
        children: [
          Container(
            width: tile,
            height: tile,
            decoration: BoxDecoration(
              color: c.warmFill,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
              border: Border.all(color: c.warm.withValues(alpha: 0.35)),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.forum_rounded, size: glyph, color: c.warm),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  tr('inbox.title'),
                  style: UgamText.bodyStrong.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                // `caption`, not `micro`: micro is the uppercase eyebrow step
                // (10 pt, 1.4 tracking) and this is a subtitle sentence. In
                // Gujarati ("3 વાંચ્યા વગર") the eyebrow tracking pulled the
                // conjuncts apart and the line read as spaced-out fragments.
                Text(
                  tr('inbox.card_unread', namedArgs: {'count': '$count'}),
                  style: UgamText.caption.copyWith(color: c.ink2),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          Container(
            constraints: BoxConstraints(minWidth: UgamScale.px(context, 26)),
            height: UgamScale.px(context, 26),
            padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.sm),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // Warm count matches the card tone — keeps champagne reserved for
              // the top attention CTA on this screen.
              color: c.warm,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
            ),
            // `onAction` rather than a hardcoded `Colors.white`: the warm fill
            // is a DARK rose in Daylight (white ink, 5.4:1) but a LIGHT pink in
            // Midnight, where white-on-pink measured ~1.4:1 — the count was
            // effectively invisible in the app's primary theme. `onAction` is
            // the token that already resolves to "ink that survives a
            // maximum-contrast fill" and flips correctly in both themes.
            // Numerals also drop to `caption`: micro's eyebrow tracking was
            // spacing out a two-digit badge.
            child: Text(
              count > 99 ? '99+' : '$count',
              style: UgamText.tabular(
                UgamText.caption.copyWith(
                  color: c.onAction,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.xs),
          Icon(Icons.chevron_right_rounded, size: glyph, color: c.ink3),
        ],
      ),
    );
  }
}
