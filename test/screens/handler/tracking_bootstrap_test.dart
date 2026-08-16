import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:occubusbooking/controllers/handler_controller.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/handler_manifest.dart';
import 'package:occubusbooking/screens/handler/handler_shell.dart';
import 'package:occubusbooking/services/location_tracker_service.dart';
import 'package:occubusbooking/widgets/handler/handler_tracking_strip.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The handler's live-location BOOTSTRAP WIRING — which trigger runs it, when it
/// is allowed to give up for good, and what the handler is told when it fails.
///
/// This had zero coverage, which is why it regressed silently when the 4,186-
/// line `HandlerBusChartScreen` was split into the shell and four tabs: the old
/// screen re-ran the bootstrap after every successful manifest load, the new one
/// hung it off a single `ever(selectedBusId)` worker that fires at most once per
/// screen-open, and the flag that suppresses a repeat was set BEFORE the
/// permission flow rather than after it. Between them, a handler who dismissed
/// one sheet — or whose first attempt bailed for any transient reason at all —
/// spent the entire trip not reporting, with nothing on screen to say so.
///
/// Geolocator answers over a plugin channel that does not exist here, so the
/// device is scripted through [HandlerShell.trackingProbes]. Every case below
/// deliberately ends in a state that does NOT open a GPS stream: a granted
/// permission would leave `Geolocator.getPositionStream` and the tracker's
/// 2-minute flush timer running past the end of the test.
///
/// EasyLocalization is not initialised, so `tr(key)` returns the raw key and the
/// assertions are written against keys rather than English copy.
void main() {
  late LocationTrackerService tracker;

  setUp(() {
    // The rationale sheet's seen-once flag lives in prefs; without a mock store
    // `SharedPreferences.getInstance()` throws and the bootstrap never resolves.
    SharedPreferences.setMockInitialValues({});
    tracker = Get.put(LocationTrackerService());
  });

  tearDown(Get.reset);

  HandlerManifest oneBus() =>
      HandlerManifest(buses: [Bus(id: 'bus-1', tourId: 'tour-1', name: 'Bus 1')]);

  Widget app(_Device device, {HandlerManifestReader? reader}) => GetMaterialApp(
    theme: ThemeData(brightness: Brightness.dark),
    home: HandlerShell(
      requestId: 'req-1',
      manifestReader: reader ?? (_) async => oneBus(),
      trackingProbes: device.probes,
    ),
  );

  /// The tab body's vertical scroller — the pull-to-refresh target, and the
  /// cheapest way for a test to reproduce "another manifest load landed".
  final refreshable = find.descendant(
    of: find.byType(RefreshIndicator),
    matching: find.byWidgetPredicate(
      (w) => w is ListView && w.scrollDirection == Axis.vertical,
    ),
  );

  Future<void> reload(WidgetTester tester) async {
    await tester.fling(refreshable, const Offset(0, 320), 1000);
    await tester.pumpAndSettle();
  }

  // ─── Defect 1: the bootstrap runs after EVERY load ───────────────────

  testWidgets('a bail-out is retried on the next manifest load of the SAME bus', (
    tester,
  ) async {
    // The system location switch is off — a real and extremely common state on
    // a handler's phone, and one that the client can do nothing about except
    // look again later.
    final device = _Device(
      serviceEnabled: false,
      permission: LocationPermission.denied,
      acceptRationale: false,
    );
    await tester.pumpWidget(app(device));
    await tester.pumpAndSettle();

    expect(device.serviceChecks, 1);
    expect(tracker.status.value, TrackingStatus.serviceDisabled);
    // Nobody was prompted, so nothing was declined.
    expect(device.rationales, 0);

    // The handler walks into settings and turns location on. Nothing about the
    // SCREEN changes — same tour, same bus, same everything — which is exactly
    // the case a worker on `selectedBusId` can never see: GetX's Rx setter
    // swallows a write that does not change the value, so it never emits again.
    device.serviceEnabled = true;
    await reload(tester);

    expect(
      device.serviceChecks,
      2,
      reason: 'the second manifest load must re-run the bootstrap',
    );
    expect(device.rationales, 1);
    expect(tracker.status.value, TrackingStatus.denied);
  });

  // ─── Defect 2: the latch is only spent on a terminal outcome ─────────

  testWidgets('a declined rationale is never re-prompted on a later load', (
    tester,
  ) async {
    final device = _Device(
      permission: LocationPermission.denied,
      acceptRationale: false,
    );
    await tester.pumpWidget(app(device));
    await tester.pumpAndSettle();

    expect(device.rationales, 1);
    expect(tracker.status.value, TrackingStatus.denied);

    // Reconciles fire after every write and every app resume. Re-asking on each
    // of them would be a sheet the handler cannot get out of — the failure mode
    // the retry above must not create.
    await reload(tester);
    await reload(tester);

    expect(device.rationales, 1, reason: 'an explicit "no" is terminal');
    expect(device.prompts, 0);
    expect(device.serviceChecks, 1, reason: 'the latch short-circuits early');
  });

  testWidgets('a denied OS prompt is terminal, and does not re-prompt', (
    tester,
  ) async {
    final device = _Device(
      permission: LocationPermission.denied,
      // The handler reads the disclosure and continues, then taps Deny on the
      // OS prompt itself.
      acceptRationale: true,
      granted: LocationPermission.denied,
    );
    await tester.pumpWidget(app(device));
    await tester.pumpAndSettle();

    expect(device.prompts, 1);
    expect(tracker.status.value, TrackingStatus.denied);

    await reload(tester);

    expect(device.prompts, 1, reason: 'the OS prompt is asked once, not on a loop');
  });

  // ─── Defect 3: a refusal is visible from every tab ───────────────────

  testWidgets('a refusal surfaces on the Board tab, not only on Trip', (
    tester,
  ) async {
    final device = _Device(
      permission: LocationPermission.denied,
      acceptRationale: false,
    );
    await tester.pumpWidget(app(device));
    await tester.pumpAndSettle();

    // The shell opens on the Board. The full TrackingStatusCard lives on Trip —
    // the FOURTH tab — so before this strip existed there was nothing at all
    // here to say the bus had stopped reporting.
    expect(find.byType(HandlerTrackingStrip), findsOneWidget);
    expect(find.text('tracking.card_denied_title'), findsOneWidget);
    expect(find.text('tracking.card_denied_cta'), findsOneWidget);
  });

  testWidgets('tapping the strip re-arms the bootstrap and re-asks', (
    tester,
  ) async {
    final device = _Device(
      permission: LocationPermission.denied,
      acceptRationale: false,
    );
    await tester.pumpWidget(app(device));
    await tester.pumpAndSettle();
    expect(device.prompts, 0);

    // The one deliberate way back in after a decline. The rationale has been
    // seen once and is not shown again; the OS prompt is, and this handler taps
    // "Don't allow" hard enough that Android stops offering.
    device.granted = LocationPermission.deniedForever;
    await tester.tap(find.byType(HandlerTrackingStrip));
    await tester.pumpAndSettle();

    expect(device.prompts, 1);
    expect(device.rationales, 1, reason: 'the disclosure is shown once ever');
    expect(tracker.status.value, TrackingStatus.deniedForever);
    // The strip follows the new state: settings, not another permission ask.
    expect(find.text('tracking.card_settings_cta'), findsOneWidget);
  });

  testWidgets('a shell with no tracker registered renders no strip', (
    tester,
  ) async {
    // The service is app-wide and lazily registered; a build without it (and
    // every other widget test in the suite) must not blow up here. `force`
    // because GetX refuses to delete a GetxService without it.
    Get.delete<LocationTrackerService>(force: true);
    await tester.pumpWidget(app(_Device()));
    await tester.pumpAndSettle();

    expect(find.byType(HandlerTrackingStrip), findsNothing);
  });
}

/// A scripted stand-in for the handler's phone.
///
/// Counts every call, because the regressions here are about HOW MANY TIMES the
/// bootstrap ran, not about what it computed: once when it should have been
/// twice (the load trigger), and twice when it should have been once (the
/// permission prompt).
class _Device {
  _Device({
    this.serviceEnabled = true,
    this.permission = LocationPermission.always,
    this.granted,
    this.acceptRationale = true,
  });

  bool serviceEnabled;
  LocationPermission permission;

  /// What the OS prompt answers. Null leaves [permission] as it was.
  LocationPermission? granted;
  bool acceptRationale;

  int serviceChecks = 0;
  int prompts = 0;
  int rationales = 0;

  TrackingProbes get probes => TrackingProbes(
    serviceEnabled: () async {
      serviceChecks++;
      return serviceEnabled;
    },
    checkPermission: () async => permission,
    requestPermission: () async {
      prompts++;
      return permission = granted ?? permission;
    },
    rationale: () async {
      rationales++;
      return acceptRationale;
    },
  );
}
