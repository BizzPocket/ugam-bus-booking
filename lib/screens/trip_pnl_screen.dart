import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/tour_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/money_summary.dart';
import '../models/pnl_confidence.dart';
import '../models/tour.dart';
import '../utils/app_nav.dart';
import '../utils/formatters.dart';
import '../widgets/money_loading_skeleton.dart';
import 'add_bus_screen.dart';
import 'bus_money_screen.dart';

part 'trip_pnl/trip_pnl_cards.dart';

/// Per-trip Profit & Loss — the breakdown the agent lands on when they open a
/// trip's money and want "did this trip make money, and where".
///
/// Shows, for ONE tour:
///   * a trip total with BOTH nets — *billed* (true profit: fares owed −
///     rent − expenses) and *collected* (cash so far − rent − expenses);
///   * a per-HANDLER breakdown (a handler runs whole buses, so their P&L is
///     the sum of their buses');
///   * a per-BUS breakdown.
///
/// Read-only: every figure comes from [MoneyController]'s pure aggregation
/// helpers. Bus rent (`Bus.busPrice`) is already folded into each bus's
/// expenses, so it never has to be added here.
class TripPnlScreen extends StatefulWidget {
  final String tourId;
  const TripPnlScreen({super.key, required this.tourId});

  @override
  State<TripPnlScreen> createState() => _TripPnlScreenState();
}

class _TripPnlScreenState extends State<TripPnlScreen> {
  MoneyController get _money => Get.find<MoneyController>();
  TourController get _tours => Get.find<TourController>();

  /// True only when the money load failed AND nothing is already held — so a
  /// transient read failure shows a retry instead of an all-zero P&L. Reads the
  /// money obs inside the calling [Obx] to stay reactive across a retry.
  bool get _showLoadError =>
      _money.loadFailed.value &&
      _money.collections.isEmpty &&
      _money.expenses.isEmpty &&
      _money.handovers.isEmpty &&
      _money.incomes.isEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _money.loadForTour(widget.tourId);
    });
  }

  String _handlerName(Tour tour, String? id) {
    if (id == null) return tr('trip_pnl.no_handler');
    final p = tour.passengers.firstWhereOrNull((x) => x.id == id);
    final n = p?.name.trim() ?? '';
    return n.isEmpty ? tr('trip_pnl.no_handler') : n;
  }

  String _busCount(int n) => n == 1
      ? tr('trip_pnl.bus_one')
      : tr('trip_pnl.bus_many', namedArgs: {'n': '$n'});

  String _busPnlSubtitle(Bus? bus, BusMoneySummary s) {
    if (bus == null || bus.busPrice <= 0) {
      return tr('trip_pnl.rent_not_set');
    }
    final rent = tr(
      'trip_pnl.rent',
      namedArgs: {'n': Formatters.formatMoneyInr(bus.busPrice)},
    );
    if (s.busMalikPayable <= 0.005) return rent;
    final malik = tr(
      'trip_pnl.malik_remaining',
      namedArgs: {'n': Formatters.formatMoneyInr(s.busMalikPayable)},
    );
    return '$rent · $malik';
  }

  /// Drill from "this bus lost money" into that bus's ledger — the same
  /// destination, entry style and transition the board one screen back uses
  /// (tour_money_board_screen.dart:61-66).
  void _openBus(Tour tour, Bus bus) {
    Get.to(
      () => BusMoneyScreen(tour: tour, bus: bus),
      transition: Transition.cupertino,
    );
  }

  /// One per-BUS P&L card, drilling into that bus's ledger.
  Widget _busCard(Tour tour, Bus? bus, BusMoneySummary s, UgamColorSet c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UgamSpacing.md),
      child: _PnlCard(
        // Null only if the summary outlives its bus; the
        // card then stays inert rather than pushing a
        // screen with no bus to render.
        onTap: bus == null ? null : () => _openBus(tour, bus),
        title: bus?.name ?? '',
        // "Rent ₹0" is the exact ambiguity that lets a
        // missing cost pass for a free bus, so an unentered
        // rent says so in words instead of printing a zero.
        subtitle: _busPnlSubtitle(bus, s),
        revenueBilled: s.revenueBilled,
        collected: s.collected,
        costs: s.expensesTotal,
        income: s.income,
        detachedCash: s.detachedCash,
        detachedCashKey: 'trip_pnl.detached_cash_bus',
        netBilled: s.netBilled,
        netCollected: s.netCollected,
        c: c,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Obx(() {
              final title = _tours.getTour(widget.tourId)?.title ?? '';
              return UgamAppBar(
                eyebrow: tr('trip_pnl.eyebrow'),
                title: title.isEmpty ? tr('trip_pnl.title') : title,
                subtitle: tr('trip_pnl.title'),
              );
            }),
            Expanded(
              child: Obx(() {
                final tour = _tours.getTour(widget.tourId);
                if (tour == null) {
                  return UgamEmpty(
                    icon: Icons.search_off_rounded,
                    title: tr('tour_money_board.tour_not_found'),
                    // A dead end otherwise: the P&L of a tour that no longer
                    // exists offered nothing but the OS back gesture.
                    cta: UgamCTA(
                      label: tr('app.action.back'),
                      leadingIcon: Icons.arrow_back_rounded,
                      onPressed: () => AppNav.pop(context),
                    ),
                  );
                }
                if (_money.isLoading.value && !_money.loadedOnce.value) {
                  return const MoneyLoadingSkeleton();
                }

                final buses = tour.buses;
                if (buses.isEmpty) {
                  // "No buses YET" — a setup gap, not a zero P&L, so it gets
                  // the action that closes it rather than leaving the agent to
                  // back out twice to find the bus wizard. (A tour that HAS
                  // buses and simply hasn't earned anything falls through to
                  // the real breakdown below, which prints honest zeroes.)
                  return UgamEmpty(
                    icon: Icons.directions_bus_outlined,
                    title: tr('tour_money_board.no_buses'),
                    cta: UgamCTA(
                      label: tr('add_bus.title'),
                      leadingIcon: Icons.add_rounded,
                      onPressed: () => Get.to(
                        () => AddBusScreen(tourId: tour.id),
                        transition: Transition.cupertino,
                      ),
                    ),
                  );
                }

                // A failed money load leaves the obs lists empty; show the
                // shared retry instead of an all-zero (false break-even) P&L.
                if (_showLoadError) {
                  return UgamEmpty.error(
                    onRetry: () => _money.loadForTour(widget.tourId),
                  );
                }

                // Touch the obs lists so Obx re-runs on any money change.
                final total = _money.tourSummary();
                final handlers = _money.handlerSummaries();
                final busSummaries = _money.summariesForBuses(
                  buses.map((b) => b.id),
                );
                final busById = {for (final b in buses) b.id: b};

                return RefreshIndicator(
                  // Chrome, not ownership — the pull spinner is neutral ink2
                  // in every screen, so it never changes hue between tabs.
                  // (Unset used to mean `colorScheme.primary`, i.e. the accent;
                  // there is no theme hook for a refresh spinner.)
                  color: c.ink2,
                  onRefresh: () => _money.refreshForTour(widget.tourId),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      UgamSpacing.gutter,
                      UgamSpacing.sm,
                      UgamSpacing.gutter,
                      UgamSpacing.xxl,
                    ),
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    children: [
                      _TripTotalCard(
                        total: total,
                        confidence: PnlConfidence.of(total, tour.status),
                        c: c,
                      ),
                      const SizedBox(height: UgamSpacing.xl),
                      if (handlers.isNotEmpty) ...[
                        UgamSectionLabel(tr('trip_pnl.by_handler')),
                        const SizedBox(height: UgamSpacing.md),
                        for (final h in handlers)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: UgamSpacing.md,
                            ),
                            child: _PnlCard(
                              title: _handlerName(tour, h.handlerPassengerId),
                              subtitle: _busCount(h.busIds.length),
                              revenueBilled: h.revenueBilled,
                              collected: h.collected,
                              costs: h.expensesTotal,
                              income: h.income,
                              detachedCash: h.detachedCash,
                              detachedCashKey: 'trip_pnl.detached_cash_handler',
                              netBilled: h.netBilled,
                              netCollected: h.netCollected,
                              c: c,
                            ),
                          ),
                        const SizedBox(height: UgamSpacing.lg),
                      ],
                      UgamSectionLabel(tr('trip_pnl.by_bus')),
                      const SizedBox(height: UgamSpacing.md),
                      for (final s in busSummaries)
                        _busCard(tour, busById[s.busId], s, c),
                    ],
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}
