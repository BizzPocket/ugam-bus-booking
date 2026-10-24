import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../config/ui_flags.dart';
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
import '../utils/app_nav.dart';
import '../utils/formatters.dart';
import '../utils/app_snackbar.dart';
import '../utils/in_flight.dart';
import '../utils/phone_dialer.dart';
import '../utils/search_debounce.dart';
import '../utils/tour_detail_cockpit.dart';
import '../widgets/tour_detail/tour_money_tab.dart';
import '../widgets/tour_detail/tour_overview_cockpit.dart';
import '../widgets/handler_alerts_strip.dart';
import '../widgets/tour_roster_gate.dart';
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

part 'tour_detail/identity_header.dart';
part 'tour_detail/overview_tab.dart';
part 'tour_detail/passengers_tab.dart';
part 'tour_detail/buses_tab.dart';
part 'tour_detail/activity_tab.dart';
part 'tour_detail/next_action.dart';
part 'tour_detail/shared.dart';

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
      // A failure is surfaced by the tabs' [TourRosterGate] retry state.
      Get.find<TourController>()
          .ensureTourReadyForSeating(widget.tourId)
          .catchError((Object _) {});
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
                        onEdit: () => _openEdit(context),
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
                    onMore: () => _openEdit(context),
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

  void _openEdit(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => EditTourScreen(tourId: widget.tourId),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, TourController tourCtrl, Tour tour) async {
    final ok = await UgamDialog.confirm(
      context,
      title: tr('tour_detail.delete_confirm_title'),
      message: tr('tour_detail.delete_confirm_body',
          namedArgs: {'title': tour.title}),
      confirmLabel: tr('tour_detail.delete_tour'),
      destructive: true,
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

  Widget _buildTabBody(Tour tour, UgamColorSet c) => switch (_tabIndex) {
        1 => _PassengersTab(tour: tour, c: c),
        2 => _BusesTab(tour: tour, c: c),
        3 => TourMoneyTab(tour: tour, c: c),
        4 => _ActivityTab(tour: tour, c: c),
        _ => _OverviewTab(tour: tour, c: c, onSwitchTab: _selectTab),
      };
}
