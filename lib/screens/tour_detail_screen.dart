import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../components/content_block_view.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/passenger.dart';
import '../models/tour.dart';
import '../models/tour_status.dart';
import '../models/trip_type.dart';

import '../services/whatsapp_service.dart';
import '../utils/app_dialogs.dart';
import '../utils/app_nav.dart';
import '../utils/formatters.dart';
import '../utils/app_snackbar.dart';
import '../utils/phone_dialer.dart';
import '../utils/tour_detail_cockpit.dart';
import '../widgets/tour_detail/tour_money_tab.dart';
import '../widgets/tour_detail/tour_overview_cockpit.dart';
import 'add_bus_screen.dart';
import 'add_return_ticket_sheet.dart';
import 'edit_tour_screen.dart';
import 'bus_status_screen.dart';

import 'manage_buses_screen.dart';
import 'notify_screen.dart';
import 'past_tour_seat_history_screen.dart';
import 'requests_screen.dart';
import 'seats_screen.dart';
import 'tour_money_board_screen.dart';
import 'tour_groups_screen.dart';

/// Admin's single-tour workspace.
///
/// Layout — IDENTICAL on every tab, which is the whole point:
///   [Identity header — back / more chrome, title, route, status, vitals,
///    seat badge. Scrolls away.]
///   [Sticky mini bar — back / title / status / more. Fades in once the
///    identity header scrolls off, on EVERY tab, so back is always reachable.]
///   [Tab pills: Overview · Passengers · Buses · Money · Activity]
///   [Body — switches per tab]
///   [Sticky bottom action — contextual per tab]
///
/// HISTORY: the header used to fork three ways — a 200pt broadcast-photo hero
/// on Overview, a compact header on the work tabs (`forceCompact`), and a
/// generated backdrop when the photo failed. Same tour, same screen, three
/// different identities depending on which tab you tapped, plus a ~200pt
/// vertical jump on every tab switch and no reachable back button once a
/// roster scrolled. The photo is CONTENT, not chrome, so it now lives in the
/// Overview body as [_TourCoverCard] and the header never changes.
///
/// Business logic is unchanged from the previous incarnation:
/// `TourController.getTour`, `ManageBusesScreen`, `TourSeatAssignmentScreen`,
/// `EditTourScreen`, `AddBusScreen` are all reused as before.
class TourDetailScreen extends StatefulWidget {
  final String tourId;
  const TourDetailScreen({super.key, required this.tourId});

  @override
  State<TourDetailScreen> createState() => _TourDetailScreenState();
}

class _TourDetailScreenState extends State<TourDetailScreen> {
  int _tabIndex = 0;

  /// One scroll view serves all five tabs, so we own its controller: it drives
  /// the sticky mini bar and lets a tab switch return to the top.
  final ScrollController _scroll = ScrollController();

  /// Whether the in-place tab strip has reached the top edge. A
  /// [ValueNotifier] rather than `setState` on purpose — the previous version
  /// rebuilt the ENTIRE screen (Obx, roster, every card) on the scroll frame
  /// that crossed the threshold. Only the sticky bar listens now.
  final ValueNotifier<bool> _collapsed = ValueNotifier<bool>(false);

  /// Mark the in-place tab strip and the sticky bar so [_onScroll] can ask
  /// where they actually are. A measured handover rather than a magic scroll
  /// offset: the header's height depends on the title's line count, the locale
  /// and the text scale, so any constant would hand over too early on one
  /// device and too late on another — and an early handover shows the tabs
  /// twice.
  final GlobalKey _tabStripKey = GlobalKey();
  final GlobalKey _stickyBarKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // Cold start fetches rosters for RUNNING tours only — that scoping is what
    // makes launch viable on 2G. An ARCHIVED tour therefore arrives without
    // its passengers/buses, so pull them now that the user has actually asked
    // for this one. No-op for tours already hydrated, so the common path
    // (opening a live tour) costs nothing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Roster + seat layouts (layouts are deferred on cold start for 2G).
      Get.find<TourController>().ensureTourReadyForSeating(widget.tourId);
    });
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _collapsed.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted || !_scroll.hasClients) return;
    final strip = _tabStripKey.currentContext?.findRenderObject() as RenderBox?;
    final bar = _stickyBarKey.currentContext?.findRenderObject() as RenderBox?;
    // Scroll deep enough into a long roster and the viewport disposes the
    // in-place strip outright — there is nothing left to measure. Holding the
    // last value is the right answer there: it can only ever have been
    // "collapsed", since the strip cannot vanish while it is on screen.
    if (strip == null || !strip.hasSize) return;
    if (bar == null || !bar.hasSize) return;
    // Hand over the instant the in-place strip finishes passing behind the
    // sticky bar. The sticky copy sits at that bar's bottom edge, so it lands
    // exactly where the in-place one left — no jump, and never both at once.
    final stripBottom = strip.localToGlobal(Offset.zero).dy + strip.size.height;
    _collapsed.value = stripBottom <= bar.size.height;
  }

  /// Switch tabs and rewind to the top.
  ///
  /// All five tabs share ONE scroll view, so without the rewind the offset
  /// from a 52-rider roster carries into a three-card Overview and strands the
  /// user in the middle of it — or past its end.
  void _selectTab(int i) {
    if (i == _tabIndex) return;
    setState(() => _tabIndex = i);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _collapsed.value = false;
  }

  @override
  Widget build(BuildContext context) {
    final tourCtrl = Get.find<TourController>();
    final c = UgamColors.of(context);

    return Obx(() {
      final tour = tourCtrl.getTour(widget.tourId);
      if (tour == null) {
        return UgamScaffold(
          body: SafeArea(
            child: UgamEmpty(
              icon: Icons.search_off_rounded,
              title: tr('tour_detail.not_found_title'),
              body: tr('tour_detail.not_found_body'),
              cta: UgamCTA(
                label: tr('app.action.back'),
                leadingIcon: Icons.arrow_back_rounded,
                onPressed: () => AppNav.pop(context),
              ),
            ),
          ),
        );
      }

      // Shared by the in-place strip and its sticky copy, so the two can never
      // drift apart.
      final tabCounts = <int?>[
        null,
        tour.passengerCount == 0 ? null : tour.passengerCount,
        tour.buses.isEmpty ? null : tour.buses.length,
        null,
        null,
      ];
      return UgamScaffold(
        extendBody: true,
        body: Stack(
          children: [
            RefreshIndicator(
              color: c.accent,
              onRefresh: tourCtrl.refreshTours,
              child: CustomScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: [
                  SliverToBoxAdapter(
                    child: _TourIdentityHeader(
                      tour: tour,
                      onBack: () => AppNav.pop(context),
                      onEdit: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) =>
                              EditTourScreen(tourId: widget.tourId),
                        ),
                      ),
                      onDelete: () => _confirmDelete(context, tourCtrl, tour),
                    ),
                  ),
                  // Operator-facing slot, below the identity header.
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UgamSpacing.gutter,
                        UgamSpacing.md,
                        UgamSpacing.gutter,
                        0,
                      ),
                      child: const ContentSlot(
                        ContentSlots.adminTourDetailTop,
                        role: 'admin',
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      key: _tabStripKey,
                      // Constant gap. It used to widen to `huge` on the one
                      // tab that drew the photo hero, which is half of why
                      // switching tabs shifted the whole page.
                      padding: const EdgeInsets.fromLTRB(
                        UgamSpacing.gutter,
                        UgamSpacing.md,
                        UgamSpacing.gutter,
                        UgamSpacing.sm,
                      ),
                      child: _TabBar(
                        index: _tabIndex,
                        counts: tabCounts,
                        onChanged: _selectTab,
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      0,
                      UgamSpacing.gutter,
                      UgamSpacing.dockClearance,
                    ),
                    sliver: _buildTabBody(tour, c),
                  ),
                ],
              ),
            ),
            // Sticky bar — on EVERY tab, for every tour. Previously it existed
            // only on Overview and only when the tour had a broadcast photo,
            // so scrolling a 52-rider roster left no way back and no way to
            // change tab short of scrolling all the way up again.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: ValueListenableBuilder<bool>(
                valueListenable: _collapsed,
                builder: (context, collapsed, child) => IgnorePointer(
                  ignoring: !collapsed,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: collapsed ? 1 : 0,
                    child: child,
                  ),
                ),
                child: _CollapsedTourChrome(
                  key: _stickyBarKey,
                  tour: tour,
                  c: c,
                  tabs: _TabBar(
                    index: _tabIndex,
                    counts: tabCounts,
                    onChanged: _selectTab,
                  ),
                  onBack: () => AppNav.pop(context),
                  onMore: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) =>
                            EditTourScreen(tourId: widget.tourId),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
        bottomNavigationBar: _StickyAction(
          tour: tour,
          tab: _tabIndex,
          c: c,
          onSwitchTab: _selectTab,
        ),
      );
    });
  }

  Future<void> _confirmDelete(BuildContext context, TourController tourCtrl, Tour tour) async {
    final ok = await AppDialogs.confirm(
      title: tr('tour_detail.delete_confirm_title'),
      message: tr('tour_detail.delete_confirm_body',
          namedArgs: {'title': tour.title}),
      confirmText: tr('tour_detail.delete_tour'),
      isDestructive: true,
    );
    if (!ok) return;
    try {
      await tourCtrl.deleteTour(tour.id);
      if (!context.mounted) return;
      AppNav.pop(context);
      AppSnackBar.success(tr('tour_detail.snack_tour_deleted'));
    } catch (_) {
      // deleteTour already surfaces its own error snackbar.
    }
  }

  Widget _buildTabBody(Tour tour, UgamColorSet c) {
    switch (_tabIndex) {
      case 1:
        return _PassengersTab(tour: tour, c: c);
      case 2:
        return _BusesTab(tour: tour, c: c);
      case 3:
        return TourMoneyTab(tour: tour, c: c);
      case 4:
        return _ActivityTab(tour: tour, c: c);
      case 0:
      default:
        return _OverviewTab(
          tour: tour,
          c: c,
          onSwitchTab: _selectTab,
        );
    }
  }
}


/// Sticky bar shown once the identity header has scrolled away — on every tab,
/// for every tour. Carries the tab strip too, so a 52-rider roster never traps
/// the user: back and all five tabs stay one tap away at any scroll depth.
///
/// Deliberately carries no photo thumbnail: the bar is chrome, and chrome that
/// changes shape per tour is what this screen was being fixed for.
class _CollapsedTourChrome extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  /// The same [_TabBar] the page renders in place. It appears here exactly as
  /// the in-place strip reaches the top edge, so the two never show at once.
  final Widget tabs;
  final VoidCallback onBack;
  final VoidCallback onMore;

  const _CollapsedTourChrome({
    super.key,
    required this.tour,
    required this.c,
    required this.tabs,
    required this.onBack,
    required this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Material(
      color: c.bg.withValues(alpha: 0.96),
      elevation: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          top + UgamSpacing.sm,
          UgamSpacing.gutter,
          UgamSpacing.sm,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                UgamIconButton(
                  icon: Icons.arrow_back_rounded,
                  onTap: onBack,
                  semanticLabel: tr('app.action.back'),
                ),
                const SizedBox(width: UgamSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        tour.title,
                        style: UgamText.titleS.copyWith(color: c.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      UgamStatusDot(
                        label: tour.status.displayName,
                        tone: _toneFor(tour.status),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: UgamSpacing.sm),
                UgamIconButton(
                  icon: Icons.more_vert_rounded,
                  onTap: onMore,
                  semanticLabel: tr('tour_detail.actions_title'),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.sm),
            tabs,
          ],
        ),
      ),
    );
  }
}

// ─── IDENTITY HEADER ──────────────────────────────────────────────────

/// The one and only tour header. Chrome row, title, route, status, live
/// vitals, seat badge — identical on all five tabs, so the screen keeps the
/// same identity wherever the user is working.
class _TourIdentityHeader extends StatelessWidget {
  final Tour tour;
  final VoidCallback onBack;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _TourIdentityHeader({
    required this.tour,
    required this.onBack,
    required this.onEdit,
    required this.onDelete,
  });

  /// Bottom sheet of tour-level actions (edit / delete), opened from the single
  /// overflow chrome circle so the header stays uncluttered.
  void _showActions(BuildContext context) {
    final c = UgamColors.of(context);
    UgamSheet.show<void>(
      context,
      title: tr('tour_detail.actions_title'),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HeroActionRow(
            icon: Icons.edit_rounded,
            label: tr('tour_detail.edit_tour'),
            c: c,
            onTap: () {
              // Close the actions sheet on the correct navigator (it may sit on
              // a nested tab navigator — see BUG-002), then run edit.
              AppNav.pop(ctx);
              onEdit();
            },
          ),
          const SizedBox(height: UgamSpacing.sm),
          _HeroActionRow(
            icon: Icons.delete_outline_rounded,
            label: tr('tour_detail.delete_tour'),
            c: c,
            danger: true,
            onTap: () {
              // Same nested-navigator-safe close before the delete confirm.
              AppNav.pop(ctx);
              onDelete();
            },
          ),
        ],
      ),
    );
  }

  /// No illustration — just chrome + tour identity, so the tabbed body
  /// reclaims the ~200px the old backdrop spent on a photo or a generated
  /// glyph. Status shows once (the status dot in the identity block), so no
  /// extra chip in the chrome row.
  Widget _buildHeader(BuildContext context) {
    final c = UgamColors.of(context);
    final topInset = MediaQuery.of(context).padding.top;
    final statusTone = _toneFor(tour.status);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        UgamSpacing.gutter,
        topInset + UgamSpacing.sm,
        UgamSpacing.gutter,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              UgamIconButton(
                icon: Icons.arrow_back_rounded,
                onTap: onBack,
                semanticLabel: tr('app.action.back'),
              ),
              const Spacer(),
              UgamIconButton(
                icon: Icons.more_vert_rounded,
                onTap: () => _showActions(context),
                semanticLabel: tr('tour_detail.actions_title'),
              ),
            ],
          ),
          const SizedBox(height: UgamSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tour.title,
                      style: UgamText.titleL.copyWith(color: c.ink),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.south_east_rounded, size: 13, color: c.ink2),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${tour.fromCity} → ${tour.toCity}',
                            style: UgamText.caption.copyWith(color: c.ink2),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: UgamSpacing.sm),
                        Text('·',
                            style: UgamText.caption.copyWith(color: c.ink3)),
                        const SizedBox(width: UgamSpacing.sm),
                        Text(
                          _durationLabel(context, tour),
                          style: UgamText.tabular(
                            UgamText.caption.copyWith(color: c.ink2),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: UgamSpacing.sm),
                    UgamStatusDot(
                      label: tour.status.description,
                      tone: statusTone,
                    ),
                    // Live "how's this tour doing" vitals — seats filled +
                    // rider count — so the agent reads progress at a glance
                    // without drilling into Seats/Passengers.
                    _HeroVitals(tour: tour, c: c),
                  ],
                ),
              ),
              const SizedBox(width: UgamSpacing.md),
              TourHeroChipBadge(tour: tour, c: c),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _buildHeader(context);

  String _durationLabel(BuildContext context, Tour t) {
    final r = t.returnDate;
    final locale = context.locale.toString();
    if (r == null) {
      return Formatters.formatDateShort(t.departureDate, locale: locale);
    }
    final days = r.difference(t.departureDate).inDays + 1;
    return days == 1
        ? tr('tour_detail.duration_day_one')
        : tr('tour_detail.duration_day_other', namedArgs: {'n': '$days'});
  }
}

/// A full-width tappable row inside the hero actions sheet (icon square +
/// label). `danger` tints it with the destructive colour for Delete.
class _HeroActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final UgamColorSet c;
  final VoidCallback onTap;
  final bool danger;

  const _HeroActionRow({
    required this.icon,
    required this.label,
    required this.c,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? c.danger : c.ink;
    final tint = danger ? c.danger : c.accent;
    final fill = danger
        ? c.danger.withValues(alpha: 0.12)
        : c.accentFill;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Container(
        // One anatomy = one height: this matches _TourToolRow's fixed 56 so the
        // sheet's rows don't read airier than the Overview tool rows behind it.
        height: UgamScale.tap(context, 56),
        padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
        decoration: BoxDecoration(
          color: c.cardElev,
          borderRadius: BorderRadius.circular(UgamRadius.row),
        ),
        child: Row(
          children: [
            Container(
              width: UgamScale.px(context, 40),
              height: UgamScale.px(context, 40),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(UgamRadius.input),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: UgamScale.px(context, 19), color: tint),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Text(
                label,
                style: UgamText.titleS.copyWith(color: fg, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── TAB BAR ──────────────────────────────────────────────────────────

class _TabBar extends StatelessWidget {
  final int index;
  final List<int?> counts;
  final ValueChanged<int> onChanged;

  const _TabBar({
    required this.index,
    required this.counts,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final labels = [
      tr('tour_detail.tab_overview'),
      tr('tour_detail.tab_passengers'),
      tr('tour_detail.tab_buses'),
      tr('tour_detail.tab_money'),
      tr('tour_detail.tab_activity'),
    ];
    return UgamTabPills(
      currentIndex: index,
      onChanged: onChanged,
      items: List.generate(labels.length, (i) {
        return UgamTabItem(label: labels[i], count: counts[i]);
      }),
    );
  }
}

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

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _NextActionCard(
          tour: tour,
          action: action,
          c: c,
          onSwitchTab: onSwitchTab,
        ),
        const SizedBox(height: UgamSpacing.lg),
        TourOverviewVitals(tour: tour, c: c, onSwitchTab: onSwitchTab),
        const SizedBox(height: UgamSpacing.lg),
        _OverviewToolsRow(tour: tour, c: c, onSwitchTab: onSwitchTab),
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
        const SizedBox(height: UgamSpacing.md),
        // The broadcast poster. It used to be the screen's HEADER on this tab
        // only — which is what made the same tour look like two different
        // screens. It sits with the broadcast card because that is what it is
        // for, and below the working cards because the agent's next action
        // outranks decoration.
        if ((tour.broadcastImageUrl ?? '').trim().isNotEmpty) ...[
          _TourCoverCard(tour: tour),
          const SizedBox(height: UgamSpacing.md),
        ],
        _BroadcastCard(tour: tour, c: c),
      ]),
    );
  }

}

/// Compact tools row: Money · Broadcast · More (expander with secondary tools).
class _OverviewToolsRow extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;

  const _OverviewToolsRow({
    required this.tour,
    required this.c,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
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
                onTap: () => onSwitchTab(3),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _ToolTile(
                c: c,
                icon: Icons.campaign_rounded,
                label: tr('tour_detail.tool_broadcast'),
                onTap: () => _TourBroadcast.copy(tour),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: _ToolTile(
                c: c,
                icon: Icons.apps_rounded,
                label: tr('tour_detail.tool_more'),
                onTap: () {
                  // Scroll affordance: expand more tools via existing grid sheet.
                  UgamSheet.show<void>(
                    context,
                    title: tr('tour_detail.more_tools'),
                    builder: (_) => _ActionsGrid(tour: tour, c: c),
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

  const _ToolTile({
    required this.c,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        vertical: UgamSpacing.md,
        horizontal: UgamSpacing.sm,
      ),
      child: Column(
        children: [
          Icon(icon, size: 22, color: c.accent),
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
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  _runKind(context, action.secondaryKind!, tour, onSwitchTab),
              // Without a real 44pt target a near-miss fell through to the
              // card's own onTap and fired the PRIMARY action instead — a
              // different screen than the label the user aimed at.
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
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
/// Only ever built when [Tour.broadcastImageUrl] is non-empty, so there is no
/// "no photo" variant to diverge — an absent poster simply means this card
/// isn't in the list. The header above is the same either way.
class _TourCoverCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(UgamRadius.photo),
      child: SizedBox(
        width: double.infinity,
        // Decorative, so it tracks the responsive factor rather than the text
        // scale — a poster does not need to grow with the font setting.
        height: UgamScale.px(context, 168),
        child: Image.network(
          tour.broadcastImageUrl!,
          fit: BoxFit.cover,
          // Decode at the size we actually PAINT, not the size uploaded. The
          // picker stores at maxWidth 1600 (create_tour_screen), so without
          // this the poster decodes to a 1600x1067 ARGB bitmap — ~6.8 MB of
          // RAM for a 168pt strip, on phones that have little to spare.
          cacheWidth: _decodeWidth(context),
          // While loading or if the photo fails, fall back to the graphite
          // backdrop so the card never flashes raw/broken.
          //
          // HISTORY: this fallback used to be what ALWAYS rendered. The stored
          // URL is a getPublicUrl() link, but the tour-broadcasts bucket was
          // private live, so every uncredentialed fetch 400'd and the miss
          // looked like a design choice rather than a failure. Fixed by
          // migration 051, verified 2026-08-01: GET
          // /object/public/tour-broadcasts/<file> with no credentials now
          // returns 200 image/jpeg. Keep the fallback anyway — it still covers
          // a slow network and a genuinely missing object.
          loadingBuilder: (ctx, child, progress) => progress == null
              ? child
              : UgamBusBackdrop(seed: tour.id, label: _routeInitialsOf(tour)),
          errorBuilder: (_, _, _) =>
              UgamBusBackdrop(seed: tour.id, label: _routeInitialsOf(tour)),
        ),
      ),
    );
  }
}

/// Short route monogram for the poster fallback backdrop, e.g. `"S→M"` from the
/// from/to city initials. Returns null when either city is blank so the
/// backdrop falls back to the bare bus glyph.
String? _routeInitialsOf(Tour t) {
  String first(String s) {
    final v = s.trim();
    return v.isEmpty ? '' : v[0].toUpperCase();
  }

  final from = first(t.fromCity);
  final to = first(t.toCity);
  if (from.isEmpty || to.isEmpty) return null;
  return '$from→$to';
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
              // Demoted from solid-gold UgamCTA to TONAL — the bottom sticky CTA
              // is the one rationed champagne focal point per screen.
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

// ─── PASSENGERS TAB ───────────────────────────────────────────────────

class _PassengersTab extends StatefulWidget {
  final Tour tour;
  final UgamColorSet c;

  const _PassengersTab({required this.tour, required this.c});

  @override
  State<_PassengersTab> createState() => _PassengersTabState();
}

class _PassengersTabState extends State<_PassengersTab> {
  TravelerFilter _filter = TravelerFilter.all;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final tour = widget.tour;
    final c = widget.c;
    final all = tour.passengers;

    if (all.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.lg),
          child: _PassengersEmptyState(tour: tour),
        ),
      );
    }

    final needsSeatCount = all.where(passengerNeedsSeat).length;
    final seatedCount = all.length - needsSeatCount;
    var filtered = filterTravelers(
      all,
      filter: _filter,
      query: _query,
    );
    // Needs-seat first so the agent sees work before the completed roster.
    if (_filter == TravelerFilter.all && _query.trim().isEmpty) {
      filtered = [
        ...filtered.where(passengerNeedsSeat),
        ...filtered.where((p) => !passengerNeedsSeat(p)),
      ];
    }

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _RosterHeader(
          count: all.length,
          c: c,
          onAdd: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => RequestsScreen(initialTourId: tour.id),
            ),
          ),
        ),
        if (needsSeatCount > 0) ...[
          const SizedBox(height: UgamSpacing.sm),
          _TravelersProgressStrip(
            c: c,
            seated: seatedCount,
            open: needsSeatCount,
            total: all.length,
          ),
        ],
        const SizedBox(height: UgamSpacing.sm),
        UgamSearchField(
          hint: tr('tour_detail.search_travelers_hint'),
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: UgamSpacing.sm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _FilterChip(
                label: tr('tour_detail.filter_all'),
                count: all.length,
                selected: _filter == TravelerFilter.all,
                c: c,
                onTap: () => setState(() => _filter = TravelerFilter.all),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.filter_needs_seat'),
                count: needsSeatCount,
                selected: _filter == TravelerFilter.needsSeat,
                c: c,
                onTap: () =>
                    setState(() => _filter = TravelerFilter.needsSeat),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.filter_sl'),
                selected: _filter == TravelerFilter.single,
                c: c,
                onTap: () => setState(() => _filter = TravelerFilter.single),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.filter_dl'),
                selected: _filter == TravelerFilter.double_,
                c: c,
                onTap: () => setState(() => _filter = TravelerFilter.double_),
              ),
            ],
          ),
        ),
        const SizedBox(height: UgamSpacing.md),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: UgamSpacing.xl),
            child: UgamEmpty(
              icon: Icons.search_off_rounded,
              title: tr('tour_detail.no_matches_title'),
              body: tr('tour_detail.no_matches_body'),
            ),
          )
        else
          for (var i = 0; i < filtered.length; i++) ...[
            _PassengerRow(passenger: filtered[i], tour: tour, c: c),
            if (i != filtered.length - 1)
              const SizedBox(height: 6),
          ],
      ]),
    );
  }
}

class _TravelersProgressStrip extends StatelessWidget {
  final UgamColorSet c;
  final int seated;
  final int open;
  final int total;

  const _TravelersProgressStrip({
    required this.c,
    required this.seated,
    required this.open,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final progress = total == 0 ? 0.0 : seated / total;
    return Row(
      children: [
        Expanded(
          child: Text(
            tr('tour_detail.travelers_progress', namedArgs: {
              'seated': '$seated',
              'open': '$open',
            }),
            style: UgamText.caption.copyWith(color: c.ink2),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        SizedBox(
          width: 72,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 4,
              backgroundColor: c.cardElev,
              color: c.accent,
            ),
          ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final UgamColorSet c;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.selected,
    required this.c,
    required this.onTap,
    this.count,
  });

  @override
  Widget build(BuildContext context) {
    final text = count == null ? label : '$label $count';
    return Material(
      color: selected ? c.accent : c.cardElev,
      borderRadius: BorderRadius.circular(UgamRadius.chip),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            text,
            style: UgamText.caption.copyWith(
              color: selected ? c.onAccent : c.ink2,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Empty Passengers tab. ONE primary action — "Share on WhatsApp to collect
/// riders" — wired to the SAME broadcast send the Overview Broadcast card uses
/// (via shared [_TourBroadcast.send], no duplicated message-building). "Copy
/// broadcast message" and the manual "Add riders" path are demoted to
/// full-width neutral buttons (>=48dp tap targets) below the empty state.
class _PassengersEmptyState extends StatefulWidget {
  final Tour tour;

  const _PassengersEmptyState({required this.tour});

  @override
  State<_PassengersEmptyState> createState() => _PassengersEmptyStateState();
}

class _PassengersEmptyStateState extends State<_PassengersEmptyState> {
  bool _sending = false;

  Future<void> _share() => _TourBroadcast.send(
        widget.tour,
        isSending: _sending,
        setSending: (v) => setState(() => _sending = v),
        isMounted: () => mounted,
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        UgamEmpty(
          icon: Icons.people_outline_rounded,
          title: tr('tour_detail.no_passengers_title'),
          body: tr('tour_detail.no_passengers_body'),
          // PRIMARY: share the tour on WhatsApp to collect riders.
          cta: UgamCTA(
            label: _sending
                ? tr('tour_detail.sending_broadcast')
                : tr('tour_detail.share_to_collect_riders'),
            leadingIcon: Icons.send_rounded,
            loading: _sending,
            onPressed: _share,
          ),
        ),
        const SizedBox(height: UgamSpacing.lg),
        // Secondary, demoted: copy the same message to the clipboard. Promoted
        // from a sub-44dp inline text link to a full-width neutral button so it
        // hits the 48dp+ tap-target rule.
        UgamButton(
          label: tr('tour_detail.copy_broadcast_message'),
          icon: Icons.copy_rounded,
          kind: UgamButtonKind.neutral,
          expand: true,
          onPressed: () => _TourBroadcast.copy(widget.tour),
        ),
        const SizedBox(height: UgamSpacing.sm),
        // Quiet manual path: add a rider on behalf of a customer (with the
        // phone-contacts picker) even before anyone has booked.
        UgamButton(
          label: tr('tour_detail.add_riders'),
          icon: Icons.person_add_alt_1_rounded,
          kind: UgamButtonKind.neutral,
          expand: true,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => RequestsScreen(initialTourId: widget.tour.id),
            ),
          ),
        ),
      ],
    );
  }
}

/// Slim header for the populated Passengers tab: a "Riders" label + live count
/// on the left and a compact "+ Add" pill on the right that opens the per-tour
/// requests manager. Replaces the old full-width _ManageRequestsButton card so
/// the roster itself leads the tab rather than a navigation button. The pill
/// stays NEUTRAL (not champagne) — the single rationed accent on this tab is
/// the sticky "Assign seats" CTA.
class _RosterHeader extends StatelessWidget {
  final int count;
  final UgamColorSet c;
  final VoidCallback onAdd;

  const _RosterHeader({
    required this.count,
    required this.c,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          tr('tour_detail.roster_header'),
          style: UgamText.titleS.copyWith(color: c.ink),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: UgamSpacing.badgeH,
            vertical: UgamSpacing.badgeV,
          ),
          decoration: BoxDecoration(
            color: c.cardElev,
            borderRadius: BorderRadius.circular(UgamRadius.chip),
          ),
          child: Text(
            '$count',
            style: UgamText.tabular(
              UgamText.caption.copyWith(
                color: c.ink2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        const Spacer(),
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              onAdd();
            },
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            // The only "add a rider" entry on a populated roster was a ~33pt
            // pill. The Center is load-bearing: without it the minHeight
            // propagates into the Container and inflates the painted pill.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Center(
                widthFactor: 1,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UgamSpacing.md,
                    vertical: UgamSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: c.cardElev,
                    borderRadius: BorderRadius.circular(UgamRadius.chip),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_add_alt_1_rounded,
                          size: 16, color: c.ink),
                      const SizedBox(width: 6),
                      Text(
                        tr('tour_detail.add'),
                        style: UgamText.bodyStrong
                            .copyWith(color: c.ink, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Quick-action sheet for a single rider, opened by tapping their roster row.
/// Three first-class actions for a WhatsApp-run tour desk: message the rider
/// (request-received / seat-confirmed ack), call them, or jump to edit their
/// request. Reuses [_HeroActionRow] for the row styling and the shared
/// [WhatsAppService.sendAck] / [PhoneDialer] paths used elsewhere in the app.
void _showPassengerActions(
  BuildContext context,
  Passenger passenger,
  Tour tour,
  UgamColorSet c,
) {
  UgamSheet.show<void>(
    context,
    title: passenger.name,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _HeroActionRow(
          icon: Icons.chat_rounded,
          label: tr('tour_detail.msg_whatsapp'),
          c: c,
          onTap: () {
            // Pop on the sheet's own (root) navigator first, then fire the
            // ack send — mirrors the hero actions sheet's close-then-act order.
            AppNav.pop(ctx);
            _messageRiderOnWhatsApp(passenger, tour);
          },
        ),
        const SizedBox(height: UgamSpacing.sm),
        _HeroActionRow(
          icon: Icons.call_rounded,
          label: tr('tour_detail.call'),
          c: c,
          onTap: () {
            AppNav.pop(ctx);
            PhoneDialer.call(passenger.phone);
          },
        ),
        const SizedBox(height: UgamSpacing.sm),
        _HeroActionRow(
          icon: Icons.edit_note_rounded,
          label: tr('tour_detail.edit_request'),
          c: c,
          onTap: () {
            AppNav.pop(ctx);
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => RequestsScreen(initialTourId: tour.id),
              ),
            );
          },
        ),
      ],
    ),
  );
}

/// Opens WhatsApp addressed to [passenger] with the contextual ack pre-filled
/// (request-received before seats, seat-confirmed once assigned). Surfaces a
/// warning toast only if WhatsApp can't be opened.
Future<void> _messageRiderOnWhatsApp(Passenger passenger, Tour tour) async {
  final ok = await WhatsAppService().sendAck(passenger: passenger, tour: tour);
  if (!ok) AppSnackBar.warning(tr('tour_detail.whatsapp_open_failed'));
}

/// Opens a blank WhatsApp chat to the bus driver (same path used by the bus &
/// handler screens). Warning toast only on failure.
Future<void> _contactDriverOnWhatsApp(Bus bus) async {
  final ok =
      await WhatsAppService().openChat(phone: bus.driverPhone, message: '');
  if (!ok) AppSnackBar.warning(tr('tour_detail.whatsapp_open_failed'));
}

class _PassengerRow extends StatelessWidget {
  final Passenger passenger;
  final Tour tour;
  final UgamColorSet c;

  const _PassengerRow({
    required this.passenger,
    required this.tour,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final needsSeat = passengerNeedsSeat(passenger);
    final seated = passenger.isFullyAssigned;

    return Material(
      color: needsSeat ? c.accentFill : c.card,
      borderRadius: BorderRadius.circular(UgamRadius.row),
      child: InkWell(
        onTap: () => _showPassengerActions(context, passenger, tour, c),
        borderRadius: BorderRadius.circular(UgamRadius.row),
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: needsSeat
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(UgamRadius.row),
                  border: Border.all(color: c.accent.withValues(alpha: 0.35)),
                )
              : null,
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: needsSeat ? c.accent.withValues(alpha: 0.18) : c.cardElev,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  _initials(passenger.name),
                  style: UgamText.micro.copyWith(
                    color: needsSeat ? c.accent : c.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      passenger.name,
                      style: UgamText.bodyStrong
                          .copyWith(color: c.ink, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _seatMeta(passenger, tour),
                            style: UgamText.caption.copyWith(
                              color: c.ink2,
                              fontSize: 11,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          seated
                              ? '✓ ${passenger.totalSeatsAssigned}/${passenger.seatBerths}'
                              : passenger.progressLabel,
                          style: UgamText.tabular(
                            UgamText.micro.copyWith(
                              color: seated
                                  ? c.good
                                  : needsSeat
                                      ? c.accent
                                      : c.ink3,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _ago(passenger.createdAt),
                style: UgamText.tabular(
                  UgamText.micro.copyWith(color: c.ink3),
                ),
              ),
              if (needsSeat) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SeatsScreen(
                          tourId: tour.id,
                          initialMode: SeatsMode.summary,
                        ),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    child: Text(
                      tr('tour_detail.assign_row'),
                      style: UgamText.micro.copyWith(
                        color: c.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ] else
                Icon(Icons.chevron_right_rounded, size: 16, color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }

  String _seatMeta(Passenger p, Tour tour) {
    final req = p.requestSummary;
    if (p.assignedSeats.isEmpty) {
      return '$req · ${tr('tour_detail.seat_meta_none')}';
    }
    final seatIds = p.assignedSeats.map((a) => a.seatId).join(', ');
    final busId = p.assignedSeats.first.busId;
    final bus = tour.buses.where((b) => b.id == busId).firstOrNull;
    final busLabel = bus?.displayLabel;
    if (busLabel != null && busLabel.isNotEmpty) {
      return '$req · $busLabel · $seatIds';
    }
    return '$req · ${tr('tour_detail.seat_meta_placed', namedArgs: {'seats': seatIds})}';
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inDays > 0) return '${d.inDays}d';
    if (d.inHours > 0) return '${d.inHours}h';
    if (d.inMinutes > 0) return '${d.inMinutes}m';
    return tr('tour_detail.ago_now');
  }
}

// ─── BUSES TAB ────────────────────────────────────────────────────────

class _BusesTab extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _BusesTab({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    if (tour.buses.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: UgamSpacing.lg),
          child: UgamEmpty(
            icon: Icons.directions_bus_outlined,
            title: tr('tour_detail.no_buses_title'),
            body: tr('tour_detail.no_buses_body'),
            cta: UgamCTA(
              label: tr('tour_detail.add_bus'),
              leadingIcon: Icons.add_rounded,
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => AddBusScreen(tourId: tour.id),
                ),
              ),
            ),
          ),
        ),
      );
    }

    // ONE add-bus affordance per screen: the sticky bottom CTA owns "Add
    // another bus" (see _StickyAction case 2). The previously-duplicated inline
    // _AddBusTile is intentionally omitted here so the entry isn't doubled.
    final occupied = tour.occupiedBerths;
    final capacity = tour.totalBusSeats;
    final fillPct = capacity == 0 ? 0 : ((occupied * 100) / capacity).round();
    final driversSet = tour.buses.where((b) => b.driverName.trim().isNotEmpty).length;

    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        Row(
          children: [
            Expanded(
              child: UgamCard.plain(
                padding: const EdgeInsets.all(UgamSpacing.md),
                child: Column(
                  children: [
                    Text(
                      tr('tour_detail.fleet_filled_pct', namedArgs: {'n': '$fillPct'}),
                      style: UgamText.tabular(UgamText.titleM.copyWith(color: c.ink)),
                    ),
                    Text(tr('tour_detail.fleet_filled_label'),
                        style: UgamText.micro.copyWith(color: c.ink3)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            Expanded(
              child: UgamCard.plain(
                padding: const EdgeInsets.all(UgamSpacing.md),
                child: Column(
                  children: [
                    Text(
                      tr('tour_detail.fleet_drivers', namedArgs: {
                        'set': '$driversSet',
                        'total': '${tour.buses.length}',
                      }),
                      style: UgamText.tabular(
                        UgamText.titleM.copyWith(
                          color: driversSet == tour.buses.length ? c.ink : c.danger,
                        ),
                      ),
                    ),
                    Text(tr('tour_detail.fleet_drivers_label'),
                        style: UgamText.micro.copyWith(color: c.ink3)),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: UgamSpacing.md),
        for (var i = 0; i < tour.buses.length; i++) ...[
          _BusListItem(
            bus: tour.buses[i],
            tourId: tour.id,
            // Leg-aware berths occupied on this bus (max of the busier leg) —
            // single-sourced from the same helper the capacity engine uses.
            filled: tour.occupiedBerthsFor(tour.buses[i].id),
            c: c,
          ),
          if (i != tour.buses.length - 1)
            const SizedBox(height: UgamSpacing.md),
        ],
      ]),
    );
  }
}

class _BusListItem extends StatelessWidget {
  final Bus bus;

  /// The enclosing tour's id. `Bus.tourId` is nullable and not always populated,
  /// so it cannot be trusted as the sole source — BusStatusScreen applies the
  /// same fallback at bus_status_screen.dart:257.
  final String tourId;
  final int filled;
  final UgamColorSet c;
  const _BusListItem({
    required this.bus,
    required this.tourId,
    required this.filled,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return UgamCard.plain(
      elev: true,
      padding: const EdgeInsets.all(UgamSpacing.md),
      // Tapping a bus opens its seat chart directly — the most common action.
      // Bus management (edit/delete/handler/add) stays reachable via the tour
      // actions + the per-bus "more" menu inside ManageBuses, so we skip the
      // ManageBuses hop that previously forced a second tap to reach the chart.
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => BusStatusScreen(
              tourId: bus.tourId?.isNotEmpty == true ? bus.tourId! : tourId,
              busId: bus.id,
            ),
          ),
        );
      },
      child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(UgamRadius.photo),
              child: SizedBox(
                width: 64,
                height: 64,
                child: UgamBusBackdrop(seed: '${bus.id}-bus'),
              ),
            ),
            const SizedBox(width: UgamSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    bus.displayLabel,
                    style: UgamText.titleS.copyWith(color: c.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    bus.driverName.isNotEmpty
                        ? bus.driverName
                        : tr('tour_detail.driver_not_set'),
                    style: UgamText.caption.copyWith(
                      color: bus.driverName.isNotEmpty ? c.ink2 : c.ink3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: bus.totalSeats == 0
                          ? 0
                          : (filled / bus.totalSeats).clamp(0.0, 1.0),
                      minHeight: 5,
                      backgroundColor: c.cardElev,
                      color: filled >= bus.totalSeats ? c.good : c.accent,
                    ),
                  ),
                  if (bus.driverPhone.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      // Tap barrier, NOT a resize: the two call buttons must
                      // stay 32 or the driver phone number ellipsizes on a
                      // 360/375pt device (PLAN §5 item 6). This absorbs a near
                      // miss so it no longer falls through to the card's own
                      // onTap and navigates into the seat chart.
                      child: GestureDetector(
                        onTap: () {},
                        behavior: HitTestBehavior.opaque,
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                bus.driverPhone,
                                style: UgamText.tabular(
                                  UgamText.caption.copyWith(color: c.ink3),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: UgamSpacing.sm),
                            // Reach the driver without leaving the tour — same
                            // symmetry as the rider row-tap actions. Neutral
                            // icon buttons keep the gold reserved for the
                            // sticky CTA; their own taps win over the row's.
                            UgamIconButton(
                              icon: Icons.chat_rounded,
                              onTap: () => _contactDriverOnWhatsApp(bus),
                              size: 32,
                              iconSize: 16,
                              semanticLabel: tr('tour_detail.msg_whatsapp'),
                            ),
                            const SizedBox(width: 6),
                            UgamIconButton(
                              icon: Icons.call_rounded,
                              onTap: () => PhoneDialer.call(bus.driverPhone),
                              size: 32,
                              iconSize: 16,
                              semanticLabel: tr('tour_detail.call'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: UgamSpacing.sm),
                  Row(
                    children: [
                      if (bus.isAC) ...[
                        UgamReqChip(label: tr('tour_detail.chip_ac')),
                        const SizedBox(width: 5),
                      ],
                      // Occupancy at a glance — "12/40 filled" — tinted by how
                      // full the bus is (green when full, accent when partly,
                      // neutral when empty). Carries the total seat count too,
                      // so it replaces the old plain "{n} SEATS" chip.
                      UgamReqChip(
                        label: tr('tour_detail.bus_occupancy', namedArgs: {
                          'filled': '$filled',
                          'total': '${bus.totalSeats}',
                        }),
                        variant: bus.totalSeats > 0 && filled >= bus.totalSeats
                            ? UgamChipVariant.good
                            : (filled > 0
                                ? UgamChipVariant.accent
                                : UgamChipVariant.neutral),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            // Accent-rationing: the same "open this" affordance is a plain grey
            // chevron on the Passengers tab, and every bus row repeating a
            // copper circle stacked a third copper under the sticky CTA.
            Icon(Icons.chevron_right_rounded, size: 18, color: c.ink3),
          ],
        ),
      );
  }
}

// ─── ACTIVITY TAB ─────────────────────────────────────────────────────

class _ActivityTab extends StatefulWidget {
  final Tour tour;
  final UgamColorSet c;

  const _ActivityTab({required this.tour, required this.c});

  @override
  State<_ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends State<_ActivityTab> {
  ActivityEventCategory? _filter; // null = all

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final events = _buildTourTimelineEvents(widget.tour);
    final visible = _filter == null
        ? events
        : events.where((e) => e.category == _filter).toList();
    return SliverList(
      delegate: SliverChildListDelegate.fixed([
        _SectionEyebrow(label: tr('tour_detail.timeline'), c: c),
        const SizedBox(height: UgamSpacing.sm),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _FilterChip(
                label: tr('tour_detail.activity_filter_all'),
                selected: _filter == null,
                c: c,
                onTap: () => setState(() => _filter = null),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.activity_filter_seats'),
                selected: _filter == ActivityEventCategory.seats,
                c: c,
                onTap: () => setState(() => _filter = ActivityEventCategory.seats),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.activity_filter_buses'),
                selected: _filter == ActivityEventCategory.buses,
                c: c,
                onTap: () => setState(() => _filter = ActivityEventCategory.buses),
              ),
              const SizedBox(width: 6),
              _FilterChip(
                label: tr('tour_detail.activity_filter_money'),
                selected: _filter == ActivityEventCategory.money,
                c: c,
                onTap: () => setState(() => _filter = ActivityEventCategory.money),
              ),
            ],
          ),
        ),
        const SizedBox(height: UgamSpacing.md),
        for (var i = 0; i < visible.length; i++)
          _TimelineRow(
            event: visible[i],
            isFirst: i == 0,
            isLast: i == visible.length - 1,
            c: c,
          ),
      ]),
    );
  }
}

List<_TimelineEvent> _buildTourTimelineEvents(Tour t) {
    final events = <_TimelineEvent>[];

    events.add(_TimelineEvent(
      icon: Icons.add_circle_rounded,
      title: tr('tour_detail.event_tour_created'),
      time: t.createdAt,
      tone: UgamStatusTone.neutral,
      category: ActivityEventCategory.system,
    ));

    if (t.passengers.isNotEmpty) {
      final earliest = t.passengers
          .map((p) => p.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      final first = t.passengers.firstWhere(
        (p) => p.createdAt == earliest,
        orElse: () => t.passengers.first,
      );
      events.add(_TimelineEvent(
        icon: Icons.person_add_alt_1_rounded,
        title: tr('tour_detail.event_first_request',
            namedArgs: {'name': first.name}),
        time: earliest,
        tone: UgamStatusTone.accent,
      category: ActivityEventCategory.requests,
    ));

      if (t.passengers.length > 1) {
        final latestReq = t.passengers
            .map((p) => p.createdAt)
            .reduce((a, b) => a.isAfter(b) ? a : b);
        if (latestReq != earliest) {
          events.add(_TimelineEvent(
            icon: Icons.groups_rounded,
            title: tr('tour_detail.event_requests_total',
                namedArgs: {'n': '${t.passengers.length}'}),
            time: latestReq,
            tone: UgamStatusTone.accent,
      category: ActivityEventCategory.requests,
    ));
        }
      }
    }

    if (t.buses.isNotEmpty) {
      final earliestBus = t.buses
          .map((b) => b.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      events.add(_TimelineEvent(
        icon: Icons.directions_bus_rounded,
        title: t.buses.length == 1
            ? tr('tour_detail.event_bus_added')
            : tr('tour_detail.event_buses_added',
                namedArgs: {'n': '${t.buses.length}'}),
        time: earliestBus,
        tone: UgamStatusTone.accent,
      category: ActivityEventCategory.buses,
    ));
    }

    if (t.totalSeatsAssigned > 0) {
      events.add(_TimelineEvent(
        icon: Icons.event_seat_rounded,
        title: t.totalSeatsAssigned == 1
            ? tr('tour_detail.event_seats_assigned_one')
            : tr('tour_detail.event_seats_assigned_other',
                namedArgs: {'n': '${t.totalSeatsAssigned}'}),
        time: t.updatedAt,
        tone: UgamStatusTone.accent,
      category: ActivityEventCategory.seats,
    ));
    }

    if (t.allSeatsAssigned) {
      events.add(_TimelineEvent(
        icon: Icons.check_circle_rounded,
        title: tr('tour_detail.event_all_seats_assigned'),
        time: t.updatedAt,
        tone: UgamStatusTone.good,
      category: ActivityEventCategory.seats,
    ));
    }

    if (t.status == TourStatus.locked || t.status == TourStatus.completed) {
      events.add(_TimelineEvent(
        icon: Icons.lock_rounded,
        title: tr('tour_detail.event_tour_locked'),
        time: t.updatedAt,
        tone: UgamStatusTone.good,
      category: ActivityEventCategory.system,
    ));
    }

    if (t.status == TourStatus.completed) {
      events.add(_TimelineEvent(
        icon: Icons.flag_rounded,
        title: tr('tour_detail.event_trip_completed'),
        time: t.updatedAt,
        tone: UgamStatusTone.neutral,
      category: ActivityEventCategory.system,
    ));
    }

    events.sort((a, b) => a.time.compareTo(b.time));
    return events;
}

class _TimelineEvent {
  final IconData icon;
  final String title;
  final DateTime time;
  final UgamStatusTone tone;
  final ActivityEventCategory category;
  const _TimelineEvent({
    required this.icon,
    required this.title,
    required this.time,
    required this.tone,
    this.category = ActivityEventCategory.system,
  });
}

class _TimelineRow extends StatelessWidget {
  final _TimelineEvent event;
  final bool isFirst;
  final bool isLast;
  final UgamColorSet c;

  const _TimelineRow({
    required this.event,
    required this.isFirst,
    required this.isLast,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final tone = _toneColor(event.tone, c);
    final fill = _toneFill(event.tone, c);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            // Decorative rail — scales so the nodes don't read heavier than the
            // event text beside them on a small phone.
            width: UgamScale.px(context, 36),
            child: Column(
              children: [
                if (isFirst)
                  const SizedBox(height: 8)
                else
                  Expanded(
                    child: Container(
                      width: 2,
                      color: c.border,
                    ),
                  ),
                Container(
                  width: UgamScale.px(context, 28),
                  height: UgamScale.px(context, 28),
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                    // 1.5 stays a hairline — hairlines don't scale.
                    border: Border.all(color: tone, width: 1.5),
                  ),
                  alignment: Alignment.center,
                  child: Icon(event.icon,
                      size: UgamScale.px(context, 13), color: tone),
                ),
                if (isLast)
                  const SizedBox(height: 8)
                else
                  Expanded(
                    child: Container(
                      width: 2,
                      color: c.border,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: UgamSpacing.md),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: UgamSpacing.sm),
              child: UgamCard.plain(
                elev: true,
                radius: UgamRadius.input,
                padding: const EdgeInsets.all(UgamSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      event.title,
                      style: UgamText.bodyStrong
                          .copyWith(color: c.ink, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _agoLine(context, event.time),
                      style: UgamText.tabular(
                        UgamText.caption.copyWith(color: c.ink3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _agoLine(BuildContext context, DateTime t) {
    final d = DateTime.now().difference(t);
    // Every other branch of this method is tr()'d; without the locale the
    // >6-day branch rendered an English "Jul 14 · 3:05 PM" sandwiched between
    // localized rows in the same timeline.
    if (d.inDays > 6) {
      return DateFormat('MMM d · h:mm a', context.locale.toString()).format(t);
    }
    if (d.inDays > 0) {
      return d.inDays == 1
          ? tr('tour_detail.ago_day_one')
          : tr('tour_detail.ago_day_other', namedArgs: {'n': '${d.inDays}'});
    }
    if (d.inHours > 0) {
      return tr('tour_detail.ago_hours', namedArgs: {'n': '${d.inHours}'});
    }
    if (d.inMinutes > 0) {
      return tr('tour_detail.ago_minutes', namedArgs: {'n': '${d.inMinutes}'});
    }
    return tr('tour_detail.ago_just_now');
  }
}

// ─── STICKY ACTION BAR ────────────────────────────────────────────────

class _StickyAction extends StatelessWidget {
  final Tour tour;
  final int tab;
  final UgamColorSet c;
  final ValueChanged<int> onSwitchTab;

  const _StickyAction({
    required this.tour,
    required this.tab,
    required this.c,
    required this.onSwitchTab,
  });

  @override
  Widget build(BuildContext context) {
    if (tab == 4) {
      // Activity tab → no sticky action (back button is enough).
      return const SizedBox.shrink();
    }

    final cta = _buildCta(context);
    if (cta == null) return const SizedBox.shrink();

    return UgamStickyCTA(child: cta);
  }

  Widget? _buildCta(BuildContext context) {
    switch (tab) {
      case 1:
        {
          // Hide the sticky "Seats" button until seating is actually
          // actionable: there must be at least one bus AND at least one
          // passenger. Otherwise it's a dead-end tap (BUG-001) — the empty
          // state owns the share CTA.
          if (tour.buses.isEmpty || tour.passengers.isEmpty) return null;
          // While seats are still pending, action-word the CTA ("Assign seats"
          // + "N left") so the next step is explicit; once everything is placed
          // it settles to the neutral "Seats x/y" status label. Same
          // destination either way: the SeatsScreen SUMMARY.
          final pending = tour.pendingSeatsToAssign;
          final assigning = pending > 0;
          return UgamCTA(
            label:
                assigning ? tr('tour_detail.assign_seats') : tr('seats.title'),
            leadingIcon: Icons.event_seat_rounded,
            trailingValue: assigning
                ? tr('tour_detail.seats_left', namedArgs: {'n': '$pending'})
                : (tour.totalBusSeats > 0
                    ? '${tour.totalSeatsAssigned}/${tour.totalBusSeats}'
                    : null),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => SeatsScreen(
                  tourId: tour.id,
                  initialMode: SeatsMode.summary,
                ),
              ),
            ),
          );
        }
      case 2:
        // When empty, the body's UgamEmpty already owns the "Add bus" CTA
        // (next to its explanatory text) — don't duplicate it here. The sticky
        // bar only owns the "Add another bus" affordance once buses exist.
        if (tour.buses.isEmpty) return null;
        return UgamCTA(
          label: tr('tour_detail.add_another_bus'),
          leadingIcon: Icons.add_rounded,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => AddBusScreen(tourId: tour.id),
            ),
          ),
        );
      case 0:
      default:
        // Overview (1st) tab: NO sticky CTA. The Next-Action card in the tab
        // body is itself tappable and fires the exact same _runAction (and also
        // exposes the secondary action + the compact More-tools row above), so a
        // bottom CTA here only duplicates what the tab already covers. Every
        // action it could offer is already reachable from the tab body.
        return null;
    }
  }
}

void _runAction(
  BuildContext context,
  _NextAction action,
  Tour tour,
  ValueChanged<int> onSwitchTab,
) =>
    _runKind(context, action.kind, tour, onSwitchTab);

void _runKind(
  BuildContext context,
  _NextActionKind kind,
  Tour tour,
  ValueChanged<int> onSwitchTab,
) {
  switch (kind) {
    case _NextActionKind.addBus:
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ManageBusesScreen(tourId: tour.id),
        ),
      );
      break;
    case _NextActionKind.assignSeats:
      // "Seats" entry -> SeatsScreen SUMMARY (tourOverview), never the bare grid.
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SeatsScreen(
            tourId: tour.id,
            initialMode: SeatsMode.summary,
          ),
        ),
      );
      break;
    case _NextActionKind.pickHandler:
      // Handler picking lives in ManageBusesScreen (per-bus handler picker),
      // not the seat screen — route the agent there.
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ManageBusesScreen(tourId: tour.id),
        ),
      );
      break;
    case _NextActionKind.lockAndNotify:
    case _NextActionKind.renotify:
      // Push the tour-scoped Notify screen for THIS tour.
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => NotifyScreen(tourId: tour.id),
        ),
      );
      break;
    case _NextActionKind.completeGoLeg:
      () async {
        final ctrl = Get.find<TourController>();
        final n = ctrl.outboundOnlyActiveCount(tour.id);
        final ok = await AppDialogs.confirm(
          title: tr('tour_detail.complete_go_confirm_title'),
          message: tr('tour_detail.complete_go_confirm_body',
              namedArgs: {'count': '$n'}),
          confirmText: tr('tour_detail.complete_go_cta'),
        );
        if (ok) {
          final cleared = await ctrl.completeOutboundLeg(tour.id);
          AppSnackBar.success(tr('tour_detail.complete_go_done',
              namedArgs: {'count': '$cleared'}));
        }
      }();
      break;
    case _NextActionKind.markCompleted:
      () async {
        final ok = await AppDialogs.confirm(
          title: tr('tour_detail.complete_confirm_title'),
          message: tr('tour_detail.complete_confirm_body',
              namedArgs: {'title': tour.title}),
          confirmText: tr('tour_detail.mark_completed'),
        );
        if (ok) {
          await Get.find<TourController>().completeTour(tour.id);
        }
      }();
      break;
    case _NextActionKind.addReturnTicket:
      // Return phase: book a new return-only ticket past the lock gate. Uses the
      // overlay context since this dispatcher is a top-level function.
      final ctx = Get.context;
      if (ctx != null) AddReturnTicketSheet.show(ctx, tour);
      break;
    case _NextActionKind.allSet:
      onSwitchTab(3); // jump to activity
      break;
  }
}

// ─── HELPERS / SHARED MODELS ──────────────────────────────────────────

class _SectionEyebrow extends StatelessWidget {
  final String label;
  final UgamColorSet c;
  const _SectionEyebrow({required this.label, required this.c});

  @override
  Widget build(BuildContext context) {
    return Text(label, style: UgamText.micro.copyWith(color: c.ink3));
  }
}

/// Compact live-vitals strip for the hero: "X/Y seats · N riders" from
/// tour-only data (no money controller). Seats use the leg-aware
/// [Tour.occupiedBerths]; riders use [Tour.passengerCount]. Renders nothing
/// until the tour actually has buses or riders, so a brand-new tour's hero
/// stays clean.
class _HeroVitals extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;
  const _HeroVitals({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    if (tour.totalBusSeats > 0) {
      parts.add(tr('tour_detail.vitals_seats', namedArgs: {
        'filled': '${tour.occupiedBerths}',
        'total': '${tour.totalBusSeats}',
      }));
    }
    if (tour.passengerCount > 0) {
      parts.add(tour.passengerCount == 1
          ? tr('tour_detail.vitals_riders_one')
          : tr('tour_detail.vitals_riders_other',
              namedArgs: {'n': '${tour.passengerCount}'}));
    }
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.sm),
      child: Row(
        children: [
          Icon(Icons.event_seat_rounded, size: 13, color: c.ink3),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              parts.join('   ·   '),
              style: UgamText.tabular(
                UgamText.caption.copyWith(color: c.ink2),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Full tour-actions grid — every per-tour workspace in one clean, labeled
/// surface. Restored after the BUG-001 slim removed Seats/Buses/Requests; the
/// agent wanted all shortcuts back, so the fix is presentation (a tidy 3×2
/// grid) rather than removal. Order follows the tour lifecycle: Requests →
/// Buses → Seats → Money → Groups → Lock/Send. Each tile lands straight on its
/// real workspace screen (no forwarding hop), and these are the SAME
/// destinations the tabs / Next-Action card use. The Lock/Send tile highlights
/// (and flips Lock→Send) once the tour is ready to lock (all seats assigned +
/// handler set) or is locked, so the next milestone still stands out within the
/// otherwise-neutral grid.
class _ActionsGrid extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _ActionsGrid({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final locked = tour.status == TourStatus.locked;
    final needsRenotify = locked &&
        tour.passengers.any((p) =>
            p.assignedSeats.isNotEmpty && p.seatsChangedSinceNotified);
    final readyToLock = !locked &&
        tour.passengers.isNotEmpty &&
        tour.allSeatsAssigned &&
        tour.handlerId != null;

    void push(Widget screen) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => screen),
        );

    // Mobile-native: the icon-grid launcher is now a vertical list of
    // full-width tool rows (icon left + label + chevron, 56dp). The three
    // primary destinations (Requests / Seats / Money) show by default; the
    // rest live behind a "More tools" expander so the Overview stays calm.
    final requests = _TourToolRow(
      icon: Icons.how_to_reg_rounded,
      label: tr('tour_detail.tool_requests'),
      c: c,
      onTap: () => push(RequestsScreen(initialTourId: tour.id)),
    );
    final seats = _TourToolRow(
      icon: Icons.event_seat_rounded,
      label: tr('tour_detail.tool_seats'),
      c: c,
      // A completed tour's live GO chart has been recycled, so its Seats row
      // opens the frozen read-only seat HISTORY instead of the live editor.
      onTap: () => push(
        tour.status == TourStatus.completed
            ? PastTourSeatHistoryScreen(tourId: tour.id)
            : SeatsScreen(tourId: tour.id, initialMode: SeatsMode.summary),
      ),
    );
    final money = _TourToolRow(
      icon: Icons.account_balance_wallet_rounded,
      label: tr('tour_detail.tool_money'),
      c: c,
      onTap: () => push(TourMoneyBoardScreen(tourId: tour.id)),
    );

    final buses = _TourToolRow(
      icon: Icons.directions_bus_rounded,
      label: tr('tour_detail.tool_buses'),
      c: c,
      onTap: () => push(ManageBusesScreen(tourId: tour.id)),
    );
    final groups = _TourToolRow(
      icon: Icons.groups_rounded,
      label: tr('tour_detail.tool_groups'),
      c: c,
      onTap: () => push(TourGroupsScreen(tourId: tour.id)),
    );
    final lockSend = _TourToolRow(
      icon: needsRenotify
          ? Icons.chat_rounded
          : locked
              ? Icons.send_rounded
              : Icons.lock_rounded,
      label: needsRenotify
          ? tr('tour_detail.action_renotify_cta')
          : locked
              ? tr('notify.title')
              : tr('tour_detail.tool_lock'),
      c: c,
      highlight: readyToLock || locked,
      warmHighlight: needsRenotify,
      onTap: () => push(NotifyScreen(tourId: tour.id)),
    );

    const gap = UgamSpacing.tight;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionEyebrow(label: tr('tour_detail.actions_section'), c: c),
        const SizedBox(height: UgamSpacing.md),
        requests,
        const SizedBox(height: gap),
        seats,
        const SizedBox(height: gap),
        money,
        const SizedBox(height: gap),
        // Secondary tools hidden behind a tap. Lock/Send stays here too but, if
        // it's the next milestone (ready-to-lock / locked), the expander opens
        // by default so it isn't buried.
        UgamExpander(
          title: tr('tour_detail.more_tools'),
          icon: Icons.apps_rounded,
          initiallyExpanded: readyToLock || needsRenotify || locked,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              buses,
              const SizedBox(height: gap),
              groups,
              const SizedBox(height: gap),
              lockSend,
            ],
          ),
        ),
      ],
    );
  }
}

/// A full-width tool row (56dp): leading icon chip, label, trailing chevron.
/// Replaces the old 3×2 icon grid tile with a thumb-friendly list item.
class _TourToolRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final UgamColorSet c;

  /// Draws the row in the "good" accent — used for Lock/Send when the tour is
  /// ready to lock or already locked, so the next step stands out.
  final bool highlight;

  /// When true with [highlight], uses warm (re-notify) instead of good.
  final bool warmHighlight;

  const _TourToolRow({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.c,
    this.highlight = false,
    this.warmHighlight = false,
  });

  @override
  Widget build(BuildContext context) {
    // Accent-rationing: ordinary tool rows are NEUTRAL (graphite chip + muted
    // ink) so the only champagne signal on the Overview is the single next
    // action card / sticky CTA. The "good" highlight (ready-to-lock / locked)
    // is a distinct semantic green, not the rationed gold, so it stays.
    // Warm is for post-lock re-notify urgency.
    final iconColor = !highlight
        ? c.ink
        : warmHighlight
            ? c.warm
            : c.good;
    final fill = !highlight
        ? c.cardElev
        : warmHighlight
            ? c.warmFill
            : c.goodFill;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        borderRadius: BorderRadius.circular(UgamRadius.row),
        child: Container(
          // Six of these stack on the Overview tab; at a fixed 56 they stayed
          // full size while their labels shrank to 0.85x on a 360pt phone.
          height: UgamScale.tap(context, 56),
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.md),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(UgamRadius.row),
          ),
          child: Row(
            children: [
              Container(
                width: UgamScale.px(context, 40),
                height: UgamScale.px(context, 40),
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(UgamRadius.input),
                ),
                alignment: Alignment.center,
                child: Icon(icon,
                    size: UgamScale.px(context, 19), color: iconColor),
              ),
              const SizedBox(width: UgamSpacing.md),
              Expanded(
                child: Text(
                  label,
                  style: UgamText.titleS.copyWith(color: c.ink, fontSize: 14),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(Icons.chevron_right_rounded,
                  size: UgamScale.px(context, 20), color: c.ink3),
            ],
          ),
        ),
      ),
    );
  }
}

enum _NextActionKind {
  addBus,
  assignSeats,
  pickHandler,
  lockAndNotify,
  renotify,
  completeGoLeg,
  addReturnTicket,
  markCompleted,
  allSet,
}

class _NextAction {
  final _NextActionKind kind;
  final String title;
  final String? subtitle;
  final String ctaLabel;
  final IconData icon;
  final UgamStatusTone tone;

  /// Optional second action shown as a subtle in-card link (e.g. the return
  /// phase offers "Add return ticket" as the primary CTA and "Complete trip"
  /// here as the secondary).
  final _NextActionKind? secondaryKind;
  final String? secondaryCtaLabel;

  const _NextAction({
    required this.kind,
    required this.title,
    this.subtitle,
    required this.ctaLabel,
    required this.icon,
    required this.tone,
    this.secondaryKind,
    this.secondaryCtaLabel,
  });
}

_NextAction _nextActionFor(Tour tour) {
  // A tour with no buses can never get anyone seated, so "add a bus" is always
  // the next step — including a brand-new, passenger-less tour that previously
  // fell through to the terminal "You're all set" card.
  if (tour.buses.isEmpty) {
    return _NextAction(
      kind: _NextActionKind.addBus,
      title: tr('tour_detail.action_add_bus_title'),
      subtitle: tour.passengers.isEmpty
          ? tr('tour_detail.action_add_bus_subtitle_empty')
          : tour.passengers.length == 1
              ? tr('tour_detail.action_add_bus_subtitle_one')
              : tr('tour_detail.action_add_bus_subtitle_other',
                  namedArgs: {'n': '${tour.passengers.length}'}),
      ctaLabel: tr('tour_detail.add_bus'),
      icon: Icons.directions_bus_rounded,
      tone: UgamStatusTone.warm,
    );
  }
  if (tour.buses.isNotEmpty && tour.pendingSeatsToAssign > 0) {
    final remaining = tour.pendingSeatsToAssign;
    // Active-only totals so a finished GO-leg rider neither inflates the
    // fraction nor resurfaces as pending demand (mirrors pendingSeatsToAssign).
    final active = tour.passengers.where((p) => !p.journeyDone);
    final activeAssigned =
        active.fold(0, (s, p) => s + p.totalSeatsAssigned);
    final activeRequested = active.fold(0, (s, p) => s + p.seatBerths);
    return _NextAction(
      kind: _NextActionKind.assignSeats,
      title: remaining == 1
          ? tr('tour_detail.action_assign_title_one')
          : tr('tour_detail.action_assign_title_other',
              namedArgs: {'n': '$remaining'}),
      subtitle: tr('tour_detail.action_assign_subtitle', namedArgs: {
        'assigned': '$activeAssigned',
        'requested': '$activeRequested',
      }),
      ctaLabel: tr('seats.title'),
      icon: Icons.event_seat_rounded,
      tone: UgamStatusTone.accent,
    );
  }
  if (tour.allSeatsAssigned && tour.handlerId == null) {
    return _NextAction(
      kind: _NextActionKind.pickHandler,
      title: tr('tour_detail.action_pick_handler_title'),
      subtitle: tr('tour_detail.action_pick_handler_subtitle'),
      ctaLabel: tr('tour_detail.pick_handler'),
      icon: Icons.person_pin_rounded,
      tone: UgamStatusTone.good,
    );
  }
  if (tour.allSeatsAssigned &&
      tour.handlerId != null &&
      tour.status != TourStatus.locked &&
      tour.status != TourStatus.completed) {
    return _NextAction(
      kind: _NextActionKind.lockAndNotify,
      title: tr('tour_detail.action_lock_title'),
      subtitle: tr('tour_detail.action_lock_subtitle'),
      ctaLabel: tr('tour_detail.action_lock_cta'),
      icon: Icons.lock_rounded,
      tone: UgamStatusTone.good,
    );
  }
  // Post-lock seat edits that haven't been WhatsApp'd yet outrank leg
  // completion — passengers are sitting on wrong-confirmed seats until then.
  if (tour.status == TourStatus.locked) {
    final changed = tour.passengers
        .where((p) =>
            p.assignedSeats.isNotEmpty && p.seatsChangedSinceNotified)
        .length;
    if (changed > 0) {
      return _NextAction(
        kind: _NextActionKind.renotify,
        title: tr('tour_detail.action_renotify_title'),
        subtitle: tr('tour_detail.action_renotify_subtitle',
            namedArgs: {'n': '$changed'}),
        ctaLabel: tr('tour_detail.action_renotify_cta'),
        icon: Icons.chat_rounded,
        tone: UgamStatusTone.warm,
      );
    }
  }
  if (tour.status == TourStatus.locked &&
      tour.passengers.any(
        (p) => p.tripType == TripType.outboundOnly && !p.journeyDone,
      )) {
    return _NextAction(
      kind: _NextActionKind.completeGoLeg,
      title: tr('tour_detail.action_complete_go_title'),
      subtitle: tr('tour_detail.action_complete_go_subtitle'),
      ctaLabel: tr('tour_detail.complete_go_cta'),
      icon: Icons.logout_rounded,
      tone: UgamStatusTone.good,
    );
  }
  if (tour.isReturnPhase) {
    final free =
        Get.find<TourController>().capacityFor(tour).returnSeatsFree;
    return _NextAction(
      kind: _NextActionKind.addReturnTicket,
      title: tr('tour_detail.action_return_leg_title'),
      subtitle: tr('tour_detail.action_return_leg_subtitle',
          namedArgs: {'free': '$free'}),
      ctaLabel: tr('tour_detail.add_return_ticket'),
      icon: Icons.event_seat_rounded,
      tone: UgamStatusTone.good,
      secondaryKind: _NextActionKind.markCompleted,
      secondaryCtaLabel: tr('tour_detail.mark_completed'),
    );
  }
  if (tour.status == TourStatus.locked) {
    return _NextAction(
      kind: _NextActionKind.markCompleted,
      title: tr('tour_detail.action_complete_title'),
      subtitle: tr('tour_detail.action_complete_subtitle'),
      ctaLabel: tr('tour_detail.mark_completed'),
      icon: Icons.check_circle_rounded,
      tone: UgamStatusTone.good,
    );
  }
  return _NextAction(
    kind: _NextActionKind.allSet,
    title: tour.status == TourStatus.completed
        ? tr('tour_detail.action_done_title_completed')
        : tr('tour_detail.action_done_title_ready'),
    subtitle: tour.status == TourStatus.completed
        ? tr('tour_detail.action_done_subtitle_completed')
        : tr('tour_detail.action_done_subtitle_ready'),
    ctaLabel: tr('tour_detail.view_timeline'),
    icon: Icons.check_circle_rounded,
    tone: UgamStatusTone.good,
  );
}

UgamStatusTone _toneFor(TourStatus s) => switch (s) {
      TourStatus.planning => UgamStatusTone.accent,
      TourStatus.collecting => UgamStatusTone.warm,
      TourStatus.busBooked => UgamStatusTone.accent,
      TourStatus.assigning => UgamStatusTone.accent,
      TourStatus.locked => UgamStatusTone.good,
      TourStatus.completed => UgamStatusTone.neutral,
    };

Color _toneColor(UgamStatusTone t, UgamColorSet c) => switch (t) {
      UgamStatusTone.accent => c.accent,
      UgamStatusTone.good => c.good,
      UgamStatusTone.warm => c.warm,
      UgamStatusTone.neutral => c.ink2,
    };

Color _toneFill(UgamStatusTone t, UgamColorSet c) => switch (t) {
      UgamStatusTone.accent => c.accentFill,
      UgamStatusTone.good => c.goodFill,
      UgamStatusTone.warm => c.warmFill,
      UgamStatusTone.neutral => c.cardElev,
    };
