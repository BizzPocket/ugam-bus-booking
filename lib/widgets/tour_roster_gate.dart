import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/tour_controller.dart';
import '../design/ugam.dart';

/// Shows [empty] only once [tourId]'s roster is genuinely known.
///
/// Drop-in for the "no buses / no riders" branch of a tour screen. Until the
/// on-demand hydrate answers it shows [loading]; if the hydrate failed it shows
/// the shared retry state. Without it an archived tour opened on 2G read as an
/// empty tour — "No buses · Add bus" — both while the roster was still on its
/// way and after the read had failed, which is how a tour gets a duplicate bus.
///
/// Its own `Obx`, so the parent's reactive scope is untouched: it rebuilds on
/// the hydrate landing (`tours`) and on it failing (the failure set).
class TourRosterGate extends StatelessWidget {
  final String tourId;
  final Widget loading;
  final Widget empty;

  const TourRosterGate({
    super.key,
    required this.tourId,
    required this.loading,
    required this.empty,
  });

  @override
  Widget build(BuildContext context) {
    final ctrl = Get.find<TourController>();
    return Obx(() {
      return switch (ctrl.rosterStateOf(tourId)) {
        TourRosterState.ready => empty,
        TourRosterState.loading => loading,
        TourRosterState.failed => UgamEmpty.error(
            onRetry: () => ctrl.retryTourHydration(tourId),
          ),
      };
    });
  }
}

/// Runs [TourController.ensureTourReadyForSeating] once per mount, after the
/// first frame — never from `build`.
///
/// For screens that are `StatelessWidget`s (so have no `initState`) and used
/// to fire the hydrate from `build`. That re-fired on EVERY rebuild, and once a
/// read had failed — so the tour was not marked hydrated — every rebuild sent
/// a fresh roster request down the same 2G radio. Here a failure stays failed
/// until the agent taps Retry (or the screen is opened again).
class EnsureTourReady extends StatefulWidget {
  final String tourId;
  final Widget child;

  const EnsureTourReady({super.key, required this.tourId, required this.child});

  @override
  State<EnsureTourReady> createState() => _EnsureTourReadyState();
}

class _EnsureTourReadyState extends State<EnsureTourReady> {
  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(EnsureTourReady oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tourId != widget.tourId) _schedule();
  }

  void _schedule() {
    final tourId = widget.tourId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !Get.isRegistered<TourController>()) return;
      Get.find<TourController>()
          .ensureTourReadyForSeating(tourId)
          .catchError((Object e, StackTrace st) {
        // Surfaced by [TourRosterGate] through the controller's failure set.
        dev.log('hydrate failed for $tourId: $e\n$st', name: 'EnsureTourReady');
      });
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
