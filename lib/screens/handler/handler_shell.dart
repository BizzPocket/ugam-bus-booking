import 'dart:async';
import 'dart:io' show Platform;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../controllers/handler_controller.dart';
import '../../design/price_band_color.dart';
import '../../design/ugam.dart';
import '../../models/bus_details.dart';
import '../../models/collection.dart';
import '../../models/handler_manifest.dart';
import '../../models/handler_phase.dart';
import '../../models/tour_status.dart';
import '../../services/crowd_location_share.dart';
import '../../services/error_reporter.dart';
import '../../services/location_tracker_service.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/formatters.dart';
import '../../utils/seat_occupants.dart';
import '../../widgets/handler/handler_phase_banner.dart';
import '../../widgets/handler/handler_skeleton.dart';
import '../../widgets/handler/handler_tracking_strip.dart';
import '../../widgets/location_rationale_sheet.dart';
import '../fullscreen_chart_screen.dart';
import 'handler_board_tab.dart';
import 'handler_chart_tab.dart';
import 'handler_money_tab.dart';
import 'handler_trip_tab.dart';

part 'handler_shell_tracking.dart';
part 'handler_shell_phase.dart';

/// The handler's app.
///
/// It replaces `HandlerBusChartScreen`, which was a single 4,186-line screen
/// holding every handler feature in one scroll: two tabs that swapped only the
/// bottom third, the money hero and settlement card permanently in the way of
/// the boarding list, and the expense and income ledgers reachable only by
/// scrolling past the seat chart. Everything was present and nothing was
/// organised.
///
/// What the shell owns is deliberately small: the bus selector, the phase
/// banner, the dock, and the lifecycle concerns a tab cannot hold (app-resume
/// reconciles, the location-permission flow). All state lives in
/// [HandlerController], so the four tabs read one source and every write is
/// visible everywhere at once.
class HandlerShell extends StatefulWidget {
  final String requestId;

  /// The tour's lifecycle status as the opening screen knew it (`locked`,
  /// `completed`, …), or null when the caller has no such fact. Only
  /// `completed` changes anything: it ends the trip for the phase resolver —
  /// see [HandlerController.tourCompleted].
  final String? tourStatus;

  /// TEST SEAM — see [HandlerController.manifestReader].
  @visibleForTesting
  final HandlerManifestReader? manifestReader;

  /// TEST SEAM — see [TrackingProbes].
  @visibleForTesting
  final TrackingProbes? trackingProbes;

  const HandlerShell({
    super.key,
    required this.requestId,
    this.tourStatus,
    this.manifestReader,
    this.trackingProbes,
  });

  @override
  State<HandlerShell> createState() => _HandlerShellState();
}

/// TEST SEAM for the platform half of the tracking bootstrap.
///
/// Geolocator answers over a plugin channel that does not exist under
/// `flutter test`, and the rationale sheet needs a live navigator — so the
/// bootstrap's WIRING (which trigger runs it, and when it may be latched off
/// for good) had no coverage at all, which is exactly where it regressed. With
/// the four platform calls behind this, the wiring is testable without a device
/// and without ever opening a GPS stream. Production leaves it null and the
/// shell talks to [Geolocator] and [showLocationRationale] directly.
@visibleForTesting
class TrackingProbes {
  final Future<bool> Function() serviceEnabled;
  final Future<LocationPermission> Function() checkPermission;
  final Future<LocationPermission> Function() requestPermission;

  /// True when the handler chose to continue on to the OS prompt.
  final Future<bool> Function() rationale;

  const TrackingProbes({
    required this.serviceEnabled,
    required this.checkPermission,
    required this.requestPermission,
    required this.rationale,
  });
}

/// Whether the phase banner offers "Hand over cash".
///
/// Only in [HandlerPhase.settling], only with cash actually in hand, and only
/// once every fare is in: a bus is squared with the admin after its riders are
/// squared with the handler. Offering "Hand over ₹26,800" while ₹24,500 is
/// still owed invited a handover the next collection would immediately make
/// short.
@visibleForTesting
bool settleOffered({
  required HandlerPhase phase,
  required double toCollect,
  required double outstanding,
}) =>
    phase == HandlerPhase.settling &&
    outstanding > Collection.kMoneyEpsilon &&
    toCollect <= Collection.kMoneyEpsilon;

/// The four things a handler does. Order is the order of the trip.
enum _Tab { board, money, chart, trip }

class _HandlerShellState extends State<HandlerShell>
    with WidgetsBindingObserver {
  late final HandlerController c;

  /// GetX tag, so two handler shells (a handler who runs two tours and opens
  /// both) never share one controller.
  late final String _tag;

  _Tab _tab = _Tab.board;

  /// Passed to the Money tab to open the handover sheet on arrival, then
  /// cleared so a later visit doesn't reopen it.
  bool _openSettleOnMoney = false;

  /// True while a milestone stamp is in the air — disables the CTA.
  bool _stamping = false;

  /// The TERMINAL latch: set only once tracking is genuinely running, or the
  /// handler has genuinely said no. It used to be set on the first line of
  /// [_bootstrapTracking], where it doubled as the reentrancy guard — which
  /// meant a handler who dismissed the rationale sheet once, or whose first
  /// attempt bailed for any transient reason at all, got no automatic retry for
  /// the entire life of the screen and their bus silently never reported.
  bool _trackingBootstrapped = false;

  /// The reentrancy guard the latch used to double as. Two workers fire within
  /// one manifest load, so without this the second would stack a second
  /// rationale sheet (and a second OS prompt) on top of the first.
  bool _trackingInFlight = false;

  static const String _rationaleSeenKey = 'tracking.rationale_seen';

  /// The bootstrap triggers, kept so dispose can tear them down — an undisposed
  /// GetX worker outlives the widget and fires against a dead state.
  Worker? _busWorker;
  Worker? _manifestWorker;

  /// `setState` for the part-file extensions (it is protected on [State]).
  void _update(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    // The handler works a moving bus for hours with the agent editing the same
    // tour behind them, so the surface has to keep re-reading: on resume, on
    // pull-to-refresh, and after every write.
    WidgetsBinding.instance.addObserver(this);
    _tag = 'handler-${widget.requestId}';
    c = Get.put(
      HandlerController(
        requestId: widget.requestId,
        manifestReader: widget.manifestReader,
        tourCompleted:
            widget.tourStatus?.trim().toLowerCase() ==
            TourStatus.completed.name,
      ),
      tag: _tag,
    );
    c.onRefreshFailed = () {
      if (mounted) AppSnackBar.error(tr('handler_chart.error_refresh'));
    };
    // Retry the tracking bootstrap after EVERY successful manifest load, which
    // is what the screen this replaced did (`unawaited(_bootstrapTracking())`
    // at the tail of its own load). It takes two triggers, because neither is
    // sufficient alone:
    //
    //   * `manifest` is assigned BEFORE `selectedBusId` on every load
    //     (handler_controller.dart:389 vs :408), so on a cold start it fires
    //     while the bus is still null and the attempt legitimately bails;
    //   * `selectedBusId` therefore catches that cold start — but GetX's Rx
    //     setter swallows a write that does not change the value, so on every
    //     later load of the SAME bus it never emits at all. Wiring the bootstrap
    //     to it alone is what reduced "after every load" to "at most once per
    //     screen-open, and only if the bus changed".
    //
    // Both are cheap no-ops once tracking is genuinely up: the bootstrap
    // latches itself the moment its outcome is terminal.
    _busWorker = ever<String?>(
      c.selectedBusId,
      (_) => unawaited(_bootstrapTracking()),
    );
    _manifestWorker = ever<HandlerManifest?>(
      c.manifest,
      (_) => unawaited(_bootstrapTracking()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _busWorker?.dispose();
    _manifestWorker?.dispose();
    // Deliberately does NOT stop tracking: sharing is scoped to the TRIP, not
    // to this screen. A handler who backs out to check something, or pockets
    // the phone, must keep reporting.
    Get.delete<HandlerController>(tag: _tag);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Only `resumed` matters: the handler pockets the phone between pickups and
    // comes back minutes later to an agent-edited tour. Reconcile SILENTLY —
    // being met with a skeleton on return would read as a crash.
    if (state != AppLifecycleState.resumed) return;
    c.reconcile();
    unawaited(_resumeTrackingIfGranted());
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final bus = c.selectedBus;
      final canExpand =
          _tab == _Tab.chart &&
          bus != null &&
          (bus.layout?.totalCells ?? 0) > 0;

      return UgamScaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              UgamAppBar(
                title: tr('handler_chart.bus_chart'),
                actions: [
                  if (canExpand)
                    UgamAppBarAction(
                      icon: Icons.open_in_full_rounded,
                      onTap: () => _openFullscreenChart(bus),
                      tooltip: tr('handler_chart.expand_chart'),
                    ),
                ],
              ),
              Expanded(child: _body(bus)),
            ],
          ),
        ),
        bottomNavigationBar: bus == null ? null : _dock(),
      );
    });
  }

  Widget _body(Bus? bus) {
    if (c.loading.value) return const HandlerLoadingSkeleton();

    if (c.error.value != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UgamSpacing.lg),
          // UgamEmpty.error, not a bare UgamEmpty: this card used to be a dead
          // end — a handler whose first fetch failed on a patchy highway had no
          // way back other than force-quitting.
          child: UgamEmpty.error(
            title: tr('handler_chart.error_load_title'),
            message: tr('handler_chart.error_load'),
            onRetry: () => c.load(),
          ),
        ),
      );
    }

    if (bus == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UgamSpacing.lg),
          child: UgamEmpty(
            icon: Icons.event_seat_outlined,
            title: tr('handler_chart.no_bus_chart_title'),
            body: tr('handler_chart.no_bus_chart_body'),
          ),
        ),
      );
    }

    final phase = c.phaseForBus(bus);
    final copy = _bannerCopy(bus, phase);
    final milestone = milestoneFor(phase);
    final summary = c.summaryFor(bus);
    final phaseTab = _tabForPhase(phase);
    final onPhaseTab = _tab == phaseTab;
    // The full banner lives on its phase's own tab. The Money tab's hero
    // already carries every figure the banner would print (in hand, still to
    // collect), so there it shrinks to the phase name + its action; on the
    // Board tab the tally owns the boarded count, so the banner leads with
    // the stop instead. Every other tab gets the one-line strip.
    final compact = !onPhaseTab || phaseTab == _Tab.money;
    final String detail;
    final String? sub;
    if (onPhaseTab && phaseTab == _Tab.money) {
      detail = '';
      sub = null;
    } else if (onPhaseTab && phase.isBoarding) {
      detail = copy.sub ?? copy.detail;
      sub = null;
    } else {
      detail = copy.detail;
      sub = copy.sub;
    }
    final boardingPending = phase.isBoarding
        ? c.boardingFor(bus, c.legForBoarding).pending
        : 0;

    return Column(
      children: [
        if (c.isMultiBus)
          Padding(
            padding: const EdgeInsets.only(bottom: UgamSpacing.sm),
            child: UgamSelectorPills(
              items: [for (final b in c.buses) UgamSelectorItem(label: b.name)],
              currentIndex: c.buses.indexWhere((b) => b.id == bus.id),
              onChanged: (i) => c.selectBus(c.buses[i].id),
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: UgamSpacing.gutter),
          child: HandlerPhaseBanner(
            phase: phase,
            detail: detail,
            sublabel: sub,
            milestone: milestone,
            outstanding: summary.outstanding,
            compact: compact,
            showAction: onPhaseTab,
            // "We've left" stays tappable while riders are missing (someone
            // always no-shows) but only turns solid once everyone is aboard.
            milestoneReady: boardingPending == 0,
            onMilestone: (_stamping || milestone == null)
                ? null
                : () => _stamp(bus, milestone),
            onOpen: () => setState(() => _tab = phaseTab),
            onSettle: settleOffered(
                  phase: phase,
                  toCollect: summary.toCollect,
                  outstanding: summary.outstanding,
                )
                ? () => setState(() {
                    _tab = _Tab.money;
                    _openSettleOnMoney = true;
                  })
                : null,
          ),
        ),
        _trackingStrip(),
        Expanded(
          // Pull-to-refresh over whichever tab is showing, with
          // AlwaysScrollableScrollPhysics on each so the gesture still works on
          // a short bus whose content doesn't fill the viewport.
          child: RefreshIndicator(
            // Chrome, not ownership — the pull spinner is neutral ink2 in
            // every screen, so it never changes hue between tabs. (Unset used
            // to mean `colorScheme.primary`, i.e. the accent; there is no
            // theme hook for a refresh spinner.) `c` here is the handler
            // controller, so the colour set is read off the context.
            color: UgamColors.of(context).ink2,
            onRefresh: () => c.load(kind: HandlerLoadKind.pull),
            child: _tabBody(bus),
          ),
        ),
      ],
    );
  }

  /// The tracking signal that follows the handler across all four tabs — see
  /// [HandlerTrackingStrip] for why the Trip tab's card was not enough.
  ///
  /// Rendered nowhere at all under `flutter test` unless the service has been
  /// registered, and nowhere on the Trip tab either: the full card is already
  /// standing there, and two warnings about one thing in one viewport is the
  /// duplication this shell exists to remove.
  Widget _trackingStrip() {
    if (_tab == _Tab.trip) return const SizedBox.shrink();
    if (!Get.isRegistered<LocationTrackerService>()) {
      return const SizedBox.shrink();
    }
    // Its own Obx: the status changes on the tracker's schedule (a refused push
    // lands minutes into a trip), not on the shell's, and this keeps that
    // repaint off the seat chart.
    return Obx(
      () => HandlerTrackingStrip(
        status: Get.find<LocationTrackerService>().status.value,
        onFix: () => unawaited(_onTrackingFix()),
      ),
    );
  }

  Widget _tabBody(Bus bus) {
    switch (_tab) {
      case _Tab.board:
        return HandlerBoardTab(controller: c, bus: bus);
      case _Tab.money:
        final auto = _openSettleOnMoney;
        // One-shot: cleared as soon as it is handed over, so returning to the
        // tab later doesn't reopen the sheet.
        _openSettleOnMoney = false;
        return HandlerMoneyTab(
          controller: c,
          bus: bus,
          autoOpenSettle: auto,
          key: ValueKey('money-${bus.id}-$auto'),
        );
      case _Tab.chart:
        return HandlerChartTab(controller: c, bus: bus);
      case _Tab.trip:
        return HandlerTripTab(
          controller: c,
          bus: bus,
          onTrackingFix: () => unawaited(_onTrackingFix()),
          onTrackingStop: () => unawaited(_stopTracking()),
        );
    }
  }

  Widget _dock() {
    final bus = c.selectedBus;
    final boarding = bus == null ? null : c.boardingFor(bus, c.legForBoarding);
    final boardingPhase = bus != null && c.phaseForBus(bus).isBoarding;
    return UgamDockNav(
      currentIndex: _Tab.values.indexOf(_tab),
      onTap: (i) => setState(() => _tab = _Tab.values[i]),
      items: [
        UgamDockItem(
          icon: Icons.how_to_reg_rounded,
          label: tr('handler_tabs.board'),
          tooltip: tr('handler_tabs.board'),
          // Riders still to board — the number the handler is working down.
          // Only while this leg is actually boarding (a "17" left on the dock
          // after the trip is over read as 17 people stranded), and not on the
          // Board tab itself, whose tally already shows it.
          badgeCount:
              boardingPhase && _tab != _Tab.board && (boarding?.pending ?? 0) > 0
              ? boarding!.pending
              : null,
        ),
        UgamDockItem(
          icon: Icons.account_balance_wallet_rounded,
          label: tr('handler_tabs.money'),
          tooltip: tr('handler_tabs.money'),
        ),
        UgamDockItem(
          icon: Icons.grid_view_rounded,
          label: tr('handler_tabs.chart'),
          tooltip: tr('handler_tabs.chart'),
        ),
        UgamDockItem(
          icon: Icons.directions_bus_filled_rounded,
          label: tr('handler_tabs.trip'),
          tooltip: tr('handler_tabs.trip'),
          badgeCount: c.openReportCount > 0 ? c.openReportCount : null,
        ),
      ],
    );
  }
}
