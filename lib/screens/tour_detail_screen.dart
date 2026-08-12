import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../components/content_block_view.dart';
import '../design/components/ugam_tappable.dart';
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
import '../widgets/handler_alerts_strip.dart';
import 'add_bus_screen.dart';
import 'add_return_ticket_sheet.dart';
import 'edit_tour_screen.dart';
import 'bus_status_screen.dart';

import 'live_map_screen.dart';
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
        // Builder so everything below reads the metrics of the Scaffold BODY
        // rather than of the route above it. With `extendBody` the body's
        // MediaQuery is where Flutter reports how much of the bottom edge is
        // covered by this screen's own sticky CTA — which is the number the
        // scrolling tab body has to clear.
        body: Builder(builder: (context) {
          // Bottom reserve for the scrolling tab body.
          //
          // The floating dock belongs to the SHELL (every entry point pushes
          // this screen onto the shell's nested navigator), so it never shows
          // up in our own metrics and [UgamSpacing.dockClearance] is what pays
          // for it — measured, the dock is 104–132pt tall across safe-area and
          // text-scale extremes, so 140 clears it.
          //
          // The tabs that DO raise a sticky CTA are the problem the max solves:
          // that bar clears the dock through its own SafeArea and so stands
          // ~208pt tall, while the reserve here was a flat 140 — the last
          // roster row / bus card sat behind it with no way to scroll further.
          final bottomReserve = math.max(
            UgamSpacing.dockClearance,
            MediaQuery.paddingOf(context).bottom + UgamSpacing.lg,
          );
          return Stack(
            children: [
              RefreshIndicator(
                // Chrome, not ownership — the pull spinner is neutral ink2 in
                // every screen, so it never changes hue between tabs.
                color: c.ink2,
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
                    // Problems the handler raised from the bus. Renders nothing
                    // when there is nothing open, which is the normal case — it
                    // must not become permanent furniture on an already dense
                    // screen. Sits directly under the identity header because a
                    // breakdown outranks every tab below it.
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          UgamSpacing.gutter,
                          UgamSpacing.md,
                          UgamSpacing.gutter,
                          0,
                        ),
                        child: HandlerAlertsStrip(tourId: widget.tourId),
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
                      padding: EdgeInsets.fromLTRB(
                        UgamSpacing.gutter,
                        0,
                        UgamSpacing.gutter,
                        bottomReserve,
                      ),
                      sliver: _buildTabBody(tour, c),
                    ),
                  ],
                ),
              ),
              // Status-bar / display-cutout scrim.
              //
              // The scroll view runs full-bleed to the top edge and the app
              // paints a TRANSPARENT status bar app-wide (see app.dart's
              // AnnotatedRegion), so everything that scrolls — the header's back
              // and overflow circles, the title, the vitals, the poster — was
              // drawn straight through the clock, signal and battery. The
              // header pads its own chrome clear of the inset, but that only
              // holds at rest: the moment the page moves, the chrome travels up
              // behind the status bar. The sticky bar below covers the same
              // strip, but only once it has faded in, which leaves every scroll
              // position before the hand-over unprotected.
              //
              // `viewPaddingOf`, not `paddingOf`: this tracks the PHYSICAL
              // inset — notch, punch-hole, Dynamic Island — which is what must
              // never have content in it, and it stays put when a keyboard
              // collapses `padding`. It also rebuilds on that one metric
              // instead of on every MediaQuery change.
              //
              // Opaque `bg`, and deliberately hit-testable: a tap in the status
              // row must not reach a control that is hidden underneath it.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SizedBox(
                  height: MediaQuery.viewPaddingOf(context).top,
                  child: ColoredBox(color: c.bg),
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
          );
        }),
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
    // `viewPaddingOf`: the physical status-bar / cutout inset, which is what
    // chrome has to sit below. `padding` collapses to zero the moment a
    // `viewInset` covers that edge, and it costs a rebuild on every unrelated
    // MediaQuery change; this reads one metric and never lies about the notch.
    final top = MediaQuery.viewPaddingOf(context).top;
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
    // Same reasoning as the sticky bar's inset — see [_CollapsedTourChrome].
    // The scrim painted over this strip by the screen's Stack is what stops
    // the chrome colliding with the clock ONCE THE PAGE MOVES; this keeps it
    // clear at rest.
    final topInset = MediaQuery.viewPaddingOf(context).top;
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
    // Neutral medallion, matching [_TourToolRow]'s un-highlighted rows — this
    // sheet and that list are the same anatomy and used to disagree. A copper
    // square behind "Edit" / "Message" / "Call" is decoration: none of those
    // rows is a thing the user OWNS or has SELECTED, which is the accent's
    // only job. Danger keeps its tint, because destructive IS a state.
    final tint = danger ? c.danger : c.ink;
    final fill = danger ? c.dangerFill : c.card;
    return UgamTappable(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      semanticLabel: label,
      haptic: false,
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
              // Ink, not amber — a fill ratio is a measurement, not something
              // the user picked. Matches the identical bar on the Charts tab.
              color: c.ink2,
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
    // KEEP the accent: "the currently-selected value" is precisely what it is
    // for, and this is the only such control on the screen.
    //
    // DEMOTED from a solid amber slab to the TONAL treatment [UgamSelectorPills]
    // already ships (accentFill + accent ink + a hairline accent border). A
    // solid fill is the app's single focal weight; spending it on a filter chip
    // — and then on a second one in the Activity tab's own row — put two solid
    // amber slabs on a screen whose primary button carries none.
    return Material(
      color: selected ? c.accentFill : c.cardElev,
      borderRadius: BorderRadius.circular(UgamRadius.chip),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(UgamRadius.chip),
        child: Container(
          // The border lives on a Container INSIDE the InkWell, not on the
          // Material: the ripple has to paint over it, and a selected chip must
          // not shift its neighbours by a pixel when the border appears.
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(UgamRadius.chip),
            border: Border.all(
              color: selected
                  ? c.accent.withValues(alpha: 0.32)
                  : Colors.transparent,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(
            text,
            style: UgamText.caption.copyWith(
              color: selected ? c.accent : c.ink2,
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
/// stays NEUTRAL — the sticky "Assign seats" CTA is the tab's one focal
/// control, and it carries `action` ink, not the accent.
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

    // "Still needs a seat" is a STATE — outstanding work on the agent's
    // roster — not "this row is yours", so it takes the warm/pending tone that
    // the re-notify highlight and [UgamButtonKind.warmTonal] already use for
    // exactly this meaning. It pairs with the `good` tick on a seated rider
    // below, so the roster reads green = done / rose = open, and the amber is
    // left to the seat chart, where a berth genuinely belongs to someone.
    return Material(
      color: needsSeat ? c.warmFill : c.card,
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
                  border: Border.all(color: c.warm.withValues(alpha: 0.35)),
                )
              : null,
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: needsSeat ? c.warm.withValues(alpha: 0.18) : c.cardElev,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  _initials(passenger.name),
                  style: UgamText.micro.copyWith(
                    color: needsSeat ? c.warm : c.ink,
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
                                      ? c.warm
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
                // A real per-row control, so it gets press feedback and a 44pt
                // target — it was an ~18pt bare label, and a near-miss fell
                // through to the row's own tap and opened the actions sheet
                // instead. The Center(widthFactor: 1) keeps the PAINTED label
                // its original size while the box grows.
                UgamTappable(
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
                  pressedScale: 0.93,
                  semanticLabel: tr('tour_detail.assign_row'),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: UgamScale.tap(context, 44),
                    ),
                    child: Center(
                      widthFactor: 1,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        child: Text(
                          // `action` ink, not amber: this is the button on the
                          // row, and the app's primary control deliberately
                          // carries no brand hue. It stays legible on the warm
                          // fill and reads as the one thing here to press.
                          // [UgamText.label], not `micro`: this is a
                          // TRANSLATED control label, and micro is Sora 10 with
                          // +1.4 tracking — a no-op caps device, a broken
                          // conjunct and an 8.5pt render in Gujarati.
                          tr('tour_detail.assign_row'),
                          style: UgamText.label.copyWith(color: c.action),
                        ),
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
        // Live map. Only while the trip is actually running: handlers may only
        // push positions on a locked tour (migration 047), so before lock there
        // is nothing to plot and the entry would just disappoint.
        if (tour.status == TourStatus.locked) ...[
          UgamCTA(
            label: tr('tracking.map_open'),
            leadingIcon: Icons.map_outlined,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    LiveMapScreen(tourId: tour.id, buses: tour.buses),
              ),
            ),
          ),
          const SizedBox(height: UgamSpacing.md),
        ],
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
                      // Ink while filling, `good` once full: "how full" is a
                      // measurement, "full" is a state worth a colour. Amber
                      // said neither — and one bar per bus row put four or five
                      // copper strips down a tab whose CTA carries none.
                      color: filled >= bus.totalSeats ? c.good : c.ink2,
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
                            // icon buttons, repeated once per bus; their own
                            // taps win over the row's.
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
                      // full the bus is: green when full, WARM while there are
                      // berths still to sell (seats left is the open work on
                      // this tab), neutral when the bus is untouched. It was
                      // amber for the partly-filled case, which made the
                      // commonest state on the screen the loudest one.
                      UgamReqChip(
                        label: tr('tour_detail.bus_occupancy', namedArgs: {
                          'filled': '$filled',
                          'total': '${bus.totalSeats}',
                        }),
                        variant: bus.totalSeats > 0 && filled >= bus.totalSeats
                            ? UgamChipVariant.good
                            : (filled > 0
                                ? UgamChipVariant.warm
                                : UgamChipVariant.neutral),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: UgamSpacing.sm),
            // The same "open this" affordance is a plain grey chevron on the
            // Passengers tab; repeating a copper circle once per bus row would
            // have spent the accent on "this row is tappable".
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

/// TONE POLICY for the timeline: a log entry is NEUTRAL. Colour is spent only
/// on the two milestones that mean the tour moved forward — all seats assigned
/// and the tour locked — which are `good`. Four of these entries used to be
/// `accent`, so most of the timeline glowed copper and the two entries that
/// actually mattered had nothing left to stand out against. (Amber's job is
/// "this is yours"; a history of things that already happened is nobody's.)
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
        tone: UgamStatusTone.neutral,
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
            tone: UgamStatusTone.neutral,
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
        tone: UgamStatusTone.neutral,
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
        tone: UgamStatusTone.neutral,
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

/// Full tour-actions list — every per-tour workspace in one clean, labeled
/// surface. Restored after the BUG-001 slim removed Seats/Buses/Requests; the
/// agent wanted all shortcuts back, so the fix is presentation (tidy labeled
/// groups) rather than removal. Each row lands straight on its real workspace
/// screen (no forwarding hop), and these are the SAME destinations the tabs /
/// Next-Action card use. The Lock/Send row highlights (and flips Lock→Send)
/// once the tour is ready to lock (all seats assigned + handler set) or is
/// locked, so the next milestone still stands out among neutral rows.
///
/// FLAT BY DESIGN. This used to show three rows plus a "More tools" expander
/// hiding Buses / Groups / Lock — an affordance from when the list rendered
/// INLINE on the Overview tab. Its only caller is now the sheet the Overview's
/// More tile opens, which is itself titled "More tools": the screen read
/// "More tools ▸ More tools" and buried half the tools behind a second tap
/// inside the surface opened to reveal them. Six rows fit; nothing is hidden.
/// Two eyebrows carry the grouping the expander used to imply — ACTIONS is the
/// tour lifecycle (requests → seats → money → lock/send), MANAGE is setup.
class _ActionsGrid extends StatelessWidget {
  final Tour tour;
  final UgamColorSet c;

  const _ActionsGrid({required this.tour, required this.c});

  @override
  Widget build(BuildContext context) {
    final locked = tour.status == TourStatus.locked;
    final completed = tour.status == TourStatus.completed;
    // Riders whose last message no longer matches reality — seats MOVED, or
    // taken back entirely. The predicate here used to be `assignedSeats
    // .isNotEmpty && seatsChangedSinceNotified`: the first half is redundant
    // (the getter already requires seats) and its real effect was to hide the
    // rider whose seat was WITHDRAWN after they were told — the one person who
    // turns up on the day expecting a berth. [Passenger.notifiedSeatsAreStale]
    // is the single "does this rider still need telling?" question.
    final stale =
        tour.passengers.where((p) => locked && p.notifiedSeatsAreStale).toList();
    final needsRenotify = stale.isNotEmpty;
    // A withdrawal cannot be WhatsApp'd (no approved template), so Notify shows
    // the phone number and an "I've told them" acknowledgement instead. The row
    // must not promise a re-send it will not offer.
    final anyWithdrawn = stale.any((p) => p.seatsRemovedSinceNotified);
    final readyToLock = !locked &&
        tour.passengers.isNotEmpty &&
        tour.allSeatsAssigned &&
        tour.handlerId != null;

    void push(Widget screen) => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => screen),
        );

    // Mobile-native: the icon-grid launcher is a vertical list of full-width
    // tool rows (icon left + label + chevron, 56dp), all of them visible.
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
          ? (anyWithdrawn ? Icons.phone_in_talk_rounded : Icons.chat_rounded)
          : locked
              ? Icons.send_rounded
              : Icons.lock_rounded,
      label: needsRenotify
          ? (anyWithdrawn
              ? tr('tour_detail.action_seat_removed_cta')
              : tr('tour_detail.action_renotify_cta'))
          : locked
              ? tr('notify.title')
              : tr('tour_detail.tool_lock'),
      c: c,
      highlight: readyToLock || locked,
      warmHighlight: needsRenotify,
      onTap: () => push(NotifyScreen(tourId: tour.id)),
    );

    const gap = UgamSpacing.tight;

    // Six rows always drawn is taller than the sheet's 92%-of-screen cap on a
    // short phone (or at a large text scale), and the shell's Flexible would
    // clip rather than scroll. Scrolling here keeps every row reachable, so
    // dropping the expander doesn't trade a hidden section for a hidden edge.
    return SingleChildScrollView(
      child: Column(
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
          // The milestone closes the lifecycle group, where it reads as the
          // next step rather than as one more shortcut — and a COMPLETED tour
          // has already passed it. NotifyScreen refuses a finished tour
          // outright ("Tour is completed"), so the row could only dead-end;
          // worse, `locked` is false for a completed tour, so it rendered as a
          // HIGHLIGHTED "Lock" — the next step on a trip that is already over.
          // Hidden, not disabled or relabelled: the other surfaces offering
          // this action already omit it for a completed tour
          // (tours_screen._actionFor returns null, dashboard._needsAttention
          // filters completed out), and Notify has no read-only "who was
          // notified" view a relabel could honestly point at.
          if (!completed) ...[
            const SizedBox(height: gap),
            lockSend,
          ],
          const SizedBox(height: UgamSpacing.lg),
          _SectionEyebrow(label: tr('tour_detail.manage'), c: c),
          const SizedBox(height: UgamSpacing.md),
          buses,
          const SizedBox(height: gap),
          groups,
        ],
      ),
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
    // Ordinary tool rows are NEUTRAL (graphite chip + ink glyph): a shortcut
    // list is navigation, and colouring all six would rank none of them. Only
    // the lifecycle milestone is tinted — `good` once the tour is ready to lock
    // or locked, `warm` for post-lock re-notify urgency. Both are semantic
    // states, so neither is the accent; nothing in this list is ever amber.
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
  // A rider whose seat was taken back AFTER they were told holds a WhatsApp
  // message naming a berth that no longer exists.
  //
  // *** WHY THIS SITS ABOVE "N seats to place" ***
  // Removing the seat also makes that rider's berths unassigned again, so
  // `pendingSeatsToAssign` goes up and the branch below would answer with
  // "1 seat to place" — silently re-seating them is NOT enough, because the
  // number in their hand is wrong either way and only a phone call fixes it.
  // Ranking it here is what makes the stale-notification check further down
  // reachable at all for a withdrawal. Plain seat MOVES keep their old rank:
  // they leave nothing unassigned, so nothing competes with them.
  if (tour.status == TourStatus.locked) {
    final stranded =
        tour.passengers.where((p) => p.seatsRemovedSinceNotified).length;
    if (stranded > 0) {
      return _NextAction(
        kind: _NextActionKind.renotify,
        title: tr('tour_detail.action_seat_removed_title',
            namedArgs: {'n': '$stranded'}),
        subtitle: tr('tour_detail.action_seat_removed_subtitle'),
        // Deliberately NOT "Re-notify": there is no approved WhatsApp template
        // for a withdrawal, so Notify offers their phone number and an "I've
        // told them" acknowledgement rather than a send.
        ctaLabel: tr('tour_detail.action_seat_removed_cta'),
        icon: Icons.phone_in_talk_rounded,
        tone: UgamStatusTone.warm,
      );
    }
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
      // Warm, like every other "there is work outstanding" next action on this
      // screen (add a bus, re-notify). It was the one accent-toned action,
      // which tinted the card, its medallion, its NEXT ACTION eyebrow, its
      // arrow and its secondary link copper — five accent marks for a state.
      tone: UgamStatusTone.warm,
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
  // Asks [Passenger.notifiedSeatsAreStale], the canonical question, rather than
  // the old `assignedSeats.isNotEmpty && seatsChangedSinceNotified` (redundant
  // first half, and it dropped withdrawals). Withdrawals are already answered
  // by the higher-ranked block above, so `changed` here is seat MOVES only and
  // the "moved since the last send" copy stays true.
  if (tour.status == TourStatus.locked) {
    final changed =
        tour.passengers.where((p) => p.notifiedSeatsAreStale).length;
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

/// Lifecycle → tone. THREE bands, and the status LABEL (not the colour) is what
/// names the exact stage:
///
///   * `warm`    — pre-lock. The tour still needs the agent: riders to collect,
///                 a bus to book, seats to place.
///   * `good`    — locked. Set up, confirmed, running.
///   * `neutral` — completed. Archived; nothing to do.
///
/// Planning / bus-booked / assigning were `accent`, which made the amber a
/// STATUS colour — the one role the token's own doc rules out — and meant most
/// tours in the app wore the "this is yours" hue for no reason. They are all
/// the same thing operationally ("not ready yet"), so they share one tone and
/// the label carries the detail.
UgamStatusTone _toneFor(TourStatus s) => switch (s) {
      TourStatus.planning => UgamStatusTone.warm,
      TourStatus.collecting => UgamStatusTone.warm,
      TourStatus.busBooked => UgamStatusTone.warm,
      TourStatus.assigning => UgamStatusTone.warm,
      TourStatus.locked => UgamStatusTone.good,
      TourStatus.completed => UgamStatusTone.neutral,
    };

// The `accent` arms below are now unreachable from this screen — nothing here
// produces [UgamStatusTone.accent] any more. They stay because the switches are
// exhaustive over a shared design-system enum, and because the mapping itself
// is correct: if a genuinely OWNED thing ever lands on this screen, it maps
// here. Do not re-point an ordinary status at it to "use up" the branch.
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
