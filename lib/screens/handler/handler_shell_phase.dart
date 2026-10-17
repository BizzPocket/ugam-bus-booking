part of 'handler_shell.dart';

// Milestone stamps, the fullscreen chart and the phase banner's copy.
extension _HandlerShellPhase on _HandlerShellState {
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
    _update(() => _stamping = true);
    try {
      await c.stampMilestone(bus, m);
      if (!mounted) return;
      AppSnackBar.success(tr('handler_phase.milestone_ok'));
      // Follow the trip: arriving moves the handler onto the return boarding
      // list, ending it moves them to the cash. The whole point of the phase is
      // that the app leads.
      final next = c.phaseForBus(bus);
      _update(() {
        _tab = next.isBoarding
            ? _Tab.board
            : (next == HandlerPhase.settling ? _Tab.money : _tab);
      });
    } catch (_) {
      if (mounted) AppSnackBar.error(tr('handler_phase.milestone_failed'));
    } finally {
      if (mounted) _update(() => _stamping = false);
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
  _Tab _tabForPhase(HandlerPhase phase) =>
      phase.isBoarding ? _Tab.board : _Tab.money;
}
