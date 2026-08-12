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
import '../../models/handler_phase.dart';
import '../../services/location_tracker_service.dart';
import '../../utils/app_snackbar.dart';
import '../../utils/formatters.dart';
import '../../utils/seat_occupants.dart';
import '../../widgets/handler/handler_phase_banner.dart';
import '../../widgets/handler/handler_skeleton.dart';
import '../../widgets/location_rationale_sheet.dart';
import '../fullscreen_chart_screen.dart';
import 'handler_board_tab.dart';
import 'handler_chart_tab.dart';
import 'handler_money_tab.dart';
import 'handler_trip_tab.dart';

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

  /// TEST SEAM — see [HandlerController.manifestReader].
  @visibleForTesting
  final HandlerManifestReader? manifestReader;

  const HandlerShell({super.key, required this.requestId, this.manifestReader});

  @override
  State<HandlerShell> createState() => _HandlerShellState();
}

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

  bool _trackingBootstrapped = false;
  static const String _rationaleSeenKey = 'tracking.rationale_seen';

  /// The bus-selection listener, kept so dispose can tear it down — an
  /// undisposed GetX worker outlives the widget and fires against a dead state.
  Worker? _busWorker;

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
      ),
      tag: _tag,
    );
    c.onRefreshFailed = () {
      if (mounted) AppSnackBar.error(tr('handler_chart.error_refresh'));
    };
    // Start tracking once the manifest lands and a bus is known.
    _busWorker = ever<String?>(
      c.selectedBusId,
      (_) => unawaited(_bootstrapTracking()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _busWorker?.dispose();
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
  }

  // ── Live location ─────────────────────────────────────────

  /// Auto-start, per the tracking design: the handler never taps a Start
  /// button, because consent lives at the permission step. The gate is simply
  /// "manifest loaded and a bus selected" — `handler_tour_manifest` is itself
  /// lock-gated, so a handler on a pre-lock tour never reaches here.
  Future<void> _bootstrapTracking() async {
    if (_trackingBootstrapped) return;
    if (!Get.isRegistered<LocationTrackerService>()) return;
    final busId = c.selectedBusId.value;
    if (busId == null || c.manifest.value == null) return;
    _trackingBootstrapped = true;

    final tracker = Get.find<LocationTrackerService>();
    tracker.status.value = TrackingStatus.awaitingPermission;

    var serviceEnabled = await Geolocator.isLocationServiceEnabled();
    var permission = await Geolocator.checkPermission();
    var state = resolveTrackingStatus(
      serviceEnabled: serviceEnabled,
      permission: permission,
    );

    // First ask ever: disclose BEFORE the OS prompt (Play policy), once only.
    if (state == TrackingStatus.denied) {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getBool(_rationaleSeenKey) ?? false;
      if (!seen) {
        if (!mounted) return;
        final go = await showLocationRationale(context);
        await prefs.setBool(_rationaleSeenKey, true);
        if (!go) {
          tracker.status.value = TrackingStatus.denied;
          return;
        }
      }
      permission = await Geolocator.requestPermission();
      // Android needs a SECOND ask to move whileInUse -> always. Declining
      // leaves foreground-only tracking, which the card states plainly.
      if (permission == LocationPermission.whileInUse && Platform.isAndroid) {
        permission = await Geolocator.requestPermission();
      }
      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      state = resolveTrackingStatus(
        serviceEnabled: serviceEnabled,
        permission: permission,
      );
    }

    if (state == TrackingStatus.live ||
        state == TrackingStatus.foregroundOnly) {
      await tracker.start(
        requestId: widget.requestId,
        busId: busId,
        leg: c.legForBoarding.storageKey,
      );
      // start() optimistically sets `live`; correct it when the handler only
      // granted while-in-use.
      tracker.status.value = state;
      tracker.startStream();
    } else {
      tracker.status.value = state;
    }
  }

  Future<void> _onTrackingFix() async {
    if (!Get.isRegistered<LocationTrackerService>()) return;
    switch (Get.find<LocationTrackerService>().status.value) {
      case TrackingStatus.serviceDisabled:
        await Geolocator.openLocationSettings();
      case TrackingStatus.deniedForever:
        await Geolocator.openAppSettings();
      default:
        _trackingBootstrapped = false;
        await _bootstrapTracking();
    }
  }

  Future<void> _stopTracking() async {
    if (!Get.isRegistered<LocationTrackerService>()) return;
    await Get.find<LocationTrackerService>().stop();
  }

  // ── Milestones ────────────────────────────────────────────

  Future<void> _stamp(Bus bus, HandlerMilestone m) async {
    // Every milestone is hard to walk back, so none of them fires straight off
    // the tap.
    final ok = await UgamDialog.confirm(
      context,
      title: m.label,
      message: m.confirmBody,
      cancelLabel: tr('app.action.cancel'),
      confirmLabel: m.label,
      confirmIcon: Icons.check_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _stamping = true);
    try {
      await c.stampMilestone(bus, m);
      if (!mounted) return;
      AppSnackBar.success(tr('handler_phase.milestone_ok'));
      // Follow the trip: arriving moves the handler onto the return boarding
      // list, ending it moves them to the cash. The whole point of the phase is
      // that the app leads.
      final next = c.phaseForBus(bus);
      setState(() {
        _tab = next.isBoarding
            ? _Tab.board
            : (next == HandlerPhase.settling ? _Tab.money : _tab);
      });
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('handler_phase.milestone_failed'));
    } finally {
      if (mounted) setState(() => _stamping = false);
    }
  }

  void _openFullscreenChart(Bus bus) {
    final layout = bus.layout;
    if (layout == null || layout.totalCells == 0) return;
    FullscreenChartScreen.open(
      context,
      layout: layout,
      occupantsBySeat: occupantListForBus(
        c.manifest.value?.passengers ?? const [],
        bus.id,
      ),
      title: bus.name,
      driverLabel: tr('handler_chart.driver'),
      bandColorFor: (cell) {
        final idx = bus.bandIndexForRow(cell.row);
        return idx == null ? null : priceBandWash(idx);
      },
    );
  }

  // ── Banner copy ───────────────────────────────────────────

  /// The one number that matters in this phase.
  ({String detail, String? sub}) _bannerCopy(Bus bus, HandlerPhase phase) {
    final summary = c.summaryFor(bus);
    switch (phase) {
      case HandlerPhase.boardingGo:
      case HandlerPhase.boardingRet:
        final p = c.boardingFor(bus, c.legForBoarding);
        final stop = p.current;
        return (
          detail: tr(
            'handler_phase.detail_boarding',
            namedArgs: {'boarded': '${p.boarded}', 'total': '${p.total}'},
          ),
          sub: stop == null
              ? tr('handler_phase.detail_all_aboard')
              : tr(
                  'handler_phase.detail_at_stop',
                  namedArgs: {
                    'stop': stop.isUnassigned
                        ? tr('handler_chart.pickup_none')
                        : stop.locationName!,
                  },
                ),
        );
      case HandlerPhase.enRouteGo:
      case HandlerPhase.enRouteRet:
        return (
          detail: summary.toCollect > 0
              ? tr(
                  'handler_phase.detail_to_collect',
                  namedArgs: {
                    'amount': Formatters.formatMoneyInr(summary.toCollect),
                  },
                )
              : tr('handler_phase.detail_all_collected'),
          sub: tr(
            'handler_phase.detail_in_hand',
            namedArgs: {'amount': Formatters.formatMoneyInr(summary.inHand)},
          ),
        );
      case HandlerPhase.settling:
        return (
          detail: tr(
            'handler_phase.detail_outstanding',
            namedArgs: {
              'amount': Formatters.formatMoneyInr(summary.outstanding),
            },
          ),
          sub: null,
        );
      case HandlerPhase.closed:
        return (detail: tr('handler_phase.detail_closed'), sub: null);
    }
  }

  /// Which tab the banner opens — the one its number lives on.
  _Tab _tabForPhase(HandlerPhase phase) {
    if (phase.isBoarding) return _Tab.board;
    return _Tab.money;
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
            detail: copy.detail,
            sublabel: copy.sub,
            milestone: milestone,
            outstanding: summary.outstanding,
            onMilestone: (_stamping || milestone == null)
                ? null
                : () => _stamp(bus, milestone),
            onOpen: () => setState(() => _tab = _tabForPhase(phase)),
            onSettle: phase == HandlerPhase.settling
                ? () => setState(() {
                    _tab = _Tab.money;
                    _openSettleOnMoney = true;
                  })
                : null,
          ),
        ),
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
    return UgamDockNav(
      currentIndex: _Tab.values.indexOf(_tab),
      onTap: (i) => setState(() => _tab = _Tab.values[i]),
      items: [
        UgamDockItem(
          icon: Icons.how_to_reg_rounded,
          label: tr('handler_tabs.board'),
          tooltip: tr('handler_tabs.board'),
          // Riders still to board — the number the handler is working down.
          badgeCount: (boarding?.pending ?? 0) > 0 ? boarding!.pending : null,
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
