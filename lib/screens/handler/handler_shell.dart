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

  // ── Live location ─────────────────────────────────────────

  // The four platform calls, behind [TrackingProbes] so the wiring above them
  // is testable. Production passes no probes and these tear off the Geolocator
  // statics directly.
  Future<bool> _serviceEnabled() =>
      (widget.trackingProbes?.serviceEnabled ??
          Geolocator.isLocationServiceEnabled)();

  Future<LocationPermission> _checkPermission() =>
      (widget.trackingProbes?.checkPermission ?? Geolocator.checkPermission)();

  Future<LocationPermission> _requestPermission() =>
      (widget.trackingProbes?.requestPermission ??
          Geolocator.requestPermission)();

  Future<bool> _rationale() {
    final probes = widget.trackingProbes;
    if (probes != null) return probes.rationale();
    return showLocationRationale(context);
  }

  /// Auto-start, per the tracking design: the handler never taps a Start
  /// button, because consent lives at the permission step. The gate is simply
  /// "manifest loaded and a bus selected" — `handler_tour_manifest` is itself
  /// lock-gated, so a handler on a pre-lock tour never reaches here.
  ///
  /// Runs after every successful manifest load and does its own bookkeeping,
  /// because the two questions are genuinely different: "is one already in
  /// flight?" ([_trackingInFlight]) versus "is there any point ever asking
  /// again?" ([_trackingBootstrapped]). Only three outcomes answer the second
  /// one — tracking started, the rationale was declined, or the OS prompt was
  /// answered no. Everything else is transient and must leave the door open.
  Future<void> _bootstrapTracking() async {
    if (_trackingBootstrapped || _trackingInFlight) return;
    if (!Get.isRegistered<LocationTrackerService>()) return;
    final busId = c.selectedBusId.value;
    // Transient, NOT terminal: the manifest worker fires before `selectedBusId`
    // is assigned, so the very first trigger of every cold start lands here.
    if (busId == null || c.manifest.value == null) return;

    final tracker = Get.find<LocationTrackerService>();
    // A passenger (or this same phone, from the home screen) is already
    // reporting for this bus. Don't ask again, and don't open a second stream.
    if (tracker.isSharing && tracker.attachedBusId == busId) {
      _trackingBootstrapped = true;
      return;
    }

    _trackingInFlight = true;
    try {
      tracker.status.value = TrackingStatus.awaitingPermission;

      // The OS is the truth, read EVERY time — never the launch gate's cached
      // answer. Trusting that cache is what kept buses dark: a phone whose GPS
      // switch was off at app launch (very common on Android) was latched
      // "location off" for the whole run, and turning GPS on — or granting
      // permission in system settings — changed nothing until the app was
      // killed. Reading the state is free and never shows a prompt.
      var serviceEnabled = await _serviceEnabled();
      var permission = await _checkPermission();
      var state = resolveTrackingStatus(
        serviceEnabled: serviceEnabled,
        permission: permission,
      );

      // The launch gate already ASKED this run and was told no. Don't ask a
      // second time; the strip's Allow button clears the gate first. This only
      // suppresses the PROMPT — a permission granted since still starts below.
      if (state == TrackingStatus.denied &&
          launchGateDeclined(
            gateDone: CrowdLocationShare.permissionGateDone,
            launch: CrowdLocationShare.launchStatus,
          )) {
        tracker.status.value = TrackingStatus.denied;
        _trackingBootstrapped = true;
        return;
      }

      // First ask ever: disclose BEFORE the OS prompt (Play policy), once only.
      if (state == TrackingStatus.denied) {
        final prefs = await SharedPreferences.getInstance();
        final seen = prefs.getBool(_rationaleSeenKey) ?? false;
        if (!seen) {
          if (!mounted) return;
          final go = await _rationale();
          await prefs.setBool(_rationaleSeenKey, true);
          if (!go) {
            // TERMINAL — an explicit "not now". Retrying this on the next
            // manifest load would re-open the sheet after every write and every
            // app resume: a loop the handler cannot get out of. Coming back in
            // stays a deliberate tap, on the strip or the Trip tab's card.
            _trackingBootstrapped = true;
            tracker.status.value = TrackingStatus.denied;
            return;
          }
        }
        permission = await _requestPermission();
        // Android needs a SECOND ask to move whileInUse -> always. Declining
        // leaves foreground-only tracking, which the card states plainly.
        if (permission == LocationPermission.whileInUse && Platform.isAndroid) {
          permission = await _requestPermission();
        }
        serviceEnabled = await _serviceEnabled();
        state = resolveTrackingStatus(
          serviceEnabled: serviceEnabled,
          permission: permission,
        );
      }

      switch (state) {
        case TrackingStatus.live || TrackingStatus.foregroundOnly:
          await tracker.start(
            requestId: widget.requestId,
            busId: busId,
            leg: c.legForBoarding.storageKey,
          );
          // start() optimistically sets `live`; correct it when the handler
          // only granted while-in-use.
          tracker.status.value = state;
          tracker.startStream();
          // TERMINAL — it is actually running. This is the one latch that was
          // ever meant to happen automatically.
          _trackingBootstrapped = true;
        case TrackingStatus.denied || TrackingStatus.deniedForever:
          // TERMINAL — the OS prompt was answered no. Same reasoning as the
          // declined rationale: never re-prompt on a reconcile.
          tracker.status.value = state;
          _trackingBootstrapped = true;
        default:
          // serviceDisabled, or anything we did not prompt for. Nobody was
          // asked anything, so retrying on the next manifest load costs the
          // handler nothing — and picks sharing up by itself the moment they
          // flip the system location switch back on.
          tracker.status.value = state;
      }
    } catch (e, st) {
      // A throw out of a platform probe is precisely the transient bail the old
      // code latched on. Leave the flag clear so the next load retries, and
      // clear the status so the card is not stranded on a spinner that will
      // never resolve.
      tracker.status.value = TrackingStatus.idle;
      ErrorReporter.report(kind: 'tracking_bootstrap', error: e, stack: st);
    } finally {
      _trackingInFlight = false;
    }
  }

  /// The single recovery action behind both the Trip tab's card and the shell
  /// strip. This is the ONLY path that re-arms a terminal latch, which is what
  /// keeps an explicit decline from turning into a permission-prompt loop.
  Future<void> _onTrackingFix() async {
    if (!Get.isRegistered<LocationTrackerService>()) return;
    CrowdLocationShare.reopenPrompt();
    final shown = Get.find<LocationTrackerService>().status.value;
    if (shown == TrackingStatus.serviceDisabled ||
        shown == TrackingStatus.deniedForever) {
      // The card may be stale: the handler already fixed it in settings and
      // came back. Look again before sending them to settings a second time —
      // otherwise this button loops between the app and settings forever.
      final now = await _readOsTrackingState();
      if (now == shown) {
        if (shown == TrackingStatus.serviceDisabled) {
          await Geolocator.openLocationSettings();
        } else {
          await Geolocator.openAppSettings();
        }
        return;
      }
    }
    _trackingBootstrapped = false;
    await _bootstrapTracking();
  }

  /// The OS's current answer, without prompting. Null when a probe throws.
  Future<TrackingStatus?> _readOsTrackingState() async {
    try {
      return resolveTrackingStatus(
        serviceEnabled: await _serviceEnabled(),
        permission: await _checkPermission(),
      );
    } catch (_) {
      return null;
    }
  }

  /// App resume: the handler may be coming back from system settings with the
  /// GPS switch on or permission granted. If the OS now allows sharing and
  /// this phone is not sharing, re-arm the bootstrap — it will find the grant
  /// and start without asking anything.
  Future<void> _resumeTrackingIfGranted() async {
    if (_trackingInFlight) return;
    if (!Get.isRegistered<LocationTrackerService>()) return;
    final tracker = Get.find<LocationTrackerService>();
    if (tracker.isSharing) return;
    switch (tracker.status.value) {
      case TrackingStatus.windowClosed || TrackingStatus.forbidden:
        // The SERVER said no; the phone's settings cannot change that.
        return;
      default:
        break;
    }
    final now = await _readOsTrackingState();
    if (now == TrackingStatus.live || now == TrackingStatus.foregroundOnly) {
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
        // Fares still owed come first: a bus can only be squared with the
        // admin once the riders are squared with the handler, and "₹0 to hand
        // over" over a roster that still reads Owing is what made an ended
        // trip look finished.
        final owing = summary.toCollect > Collection.kMoneyEpsilon;
        final toHandOver = tr(
          'handler_phase.detail_outstanding',
          namedArgs: {'amount': Formatters.formatMoneyInr(summary.outstanding)},
        );
        return (
          detail: owing
              ? tr(
                  'handler_phase.detail_to_collect',
                  namedArgs: {
                    'amount': Formatters.formatMoneyInr(summary.toCollect),
                  },
                )
              : toHandOver,
          sub: owing ? toHandOver : null,
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
