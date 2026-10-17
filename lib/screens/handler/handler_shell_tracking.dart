part of 'handler_shell.dart';

// The live-location bootstrap of [HandlerShell].
extension _HandlerShellTracking on _HandlerShellState {
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
        final seen =
            prefs.getBool(_HandlerShellState._rationaleSeenKey) ?? false;
        if (!seen) {
          if (!mounted) return;
          final go = await _rationale();
          await prefs.setBool(_HandlerShellState._rationaleSeenKey, true);
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
}
