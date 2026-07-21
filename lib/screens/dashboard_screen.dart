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
import '../utils/formatters.dart';
import '../utils/passenger_display.dart';
import '../widgets/dashboard/attention_section.dart';
import '../widgets/dashboard/dashboard_greeting.dart';
import '../widgets/dashboard/dashboard_models.dart';
import '../widgets/dashboard/loading_shimmer.dart';
import '../widgets/dashboard/quick_actions.dart';
import '../widgets/dashboard/recent_request_row.dart';
import '../widgets/dashboard/trip_hero.dart';
import 'inbox_screen.dart';
import 'main_shell.dart';
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
///   3. Quick actions (Create / Requests / Money / Charts)
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
            return UgamEmpty(
              icon: Icons.cloud_off_rounded,
              title: tr('dashboard.section_overview'),
              body: tourCtrl.errorMessage.value,
              cta: UgamCTA(
                label: tr('app.action.retry'),
                leadingIcon: Icons.refresh_rounded,
                onPressed: tourCtrl.refreshTours,
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
            Get.find<MoneyController>()
                .loadSettlementSnapshots(tourCtrl.tours.map((t) => t.id));
          });

          return RefreshIndicator(
            onRefresh: tourCtrl.refreshTours,
            color: c.accent,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: const EdgeInsets.fromLTRB(
                UgamSpacing.gutter,
                UgamSpacing.lg,
                UgamSpacing.gutter,
                140,
              ),
              children: [
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
                // attention CTA); the count rides an accent pill.
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
                          const SizedBox(height: UgamSpacing.sm + 2),
                      ],
                    ],
                  );
                }),
                Obx(() {
                  final recent = _recentRequests(tourCtrl.tours);
                  if (recent.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: UgamSpacing.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        DashboardSectionLabel(
                          label: tr('dashboard.section_recent'),
                          action: tr('dashboard.see_all'),
                          onAction: () => shell.switchTab(3), // Requests tab
                          c: c,
                        ),
                        const SizedBox(height: UgamSpacing.md),
                        for (var i = 0; i < recent.length; i++) ...[
                          DashboardRecentRow(
                            entry: recent[i],
                            onTap: () => shell.switchTab(3), // Requests tab
                          ),
                          if (i != recent.length - 1)
                            const SizedBox(height: UgamSpacing.sm + 2),
                        ],
                      ],
                    ),
                  );
                }),
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
        .where((t) =>
            t.status != TourStatus.completed &&
            t.status != TourStatus.locked)
        .toList()
      ..sort((a, b) => a.departureDate.compareTo(b.departureDate));

    for (final tour in relevant) {
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
          onTap: () => Get.find<ShellController>().switchTab(3),
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
          onTap: () {
            Get.find<ShellController>().switchTab(4);
          },
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

/// Dashboard nudge card for unread WhatsApp customer messages. Neutral surface
/// (accent-rationing law — the accent CTA belongs to the top attention row);
/// the unread count rides a small accent pill. Opens the full [InboxScreen].
class _MessagesCard extends StatelessWidget {
  final int count;
  final UgamColorSet c;

  const _MessagesCard({required this.count, required this.c});

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      onTap: () => Get.to(() => const InboxScreen()),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: c.accentFill,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.forum_rounded, size: 20, color: c.accent),
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
                Text(
                  tr('inbox.card_unread', namedArgs: {'count': '$count'}),
                  style: UgamText.micro.copyWith(color: c.ink3),
                ),
              ],
            ),
          ),
          Container(
            constraints: const BoxConstraints(minWidth: 22),
            height: 22,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.accent,
              borderRadius: BorderRadius.circular(UgamRadius.chip),
            ),
            child: Text(
              count > 99 ? '99+' : '$count',
              style: UgamText.tabular(
                UgamText.micro.copyWith(
                  color: c.onAccent,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            ),
          ),
          const SizedBox(width: UgamSpacing.xs),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.ink3),
        ],
      ),
    );
  }
}
