import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../controllers/money_controller.dart';
import '../controllers/pickup_controller.dart';
import '../design/ugam.dart';
import '../models/bus_details.dart';
import '../models/collection.dart';
import '../models/passenger.dart';
import '../models/payment_claim.dart';
import '../models/tour.dart';
import '../models/trip_type.dart';
import '../utils/app_snackbar.dart';
import '../utils/collection_seat_resolver.dart';
import '../utils/formatters.dart';
import '../utils/passenger_display.dart';
import '../utils/seat_money_state.dart';
import '../widgets/board/passenger_sheet.dart' show BoardUndoToast;
import '../widgets/money_loading_skeleton.dart';

part 'collection/collection_actions.dart';
part 'collection/collection_line.dart';
part 'collection/collection_summary.dart';
part 'collection/collection_passenger_row.dart';

/// Per-bus cash collection from passengers. Lists every passenger holding
/// a seat on this bus, shows what they owe vs. what's been received, and
/// lets the handler record received/returned cash via a bottom sheet. All
/// figures derive from [MoneyController]'s `collections` obs list.
class CollectionScreen extends StatefulWidget {
  final Tour tour;
  final Bus bus;

  /// When set, opens on the To collect / To return filter for this rider so a
  /// seat-move money notice can deep-link straight to who needs settling.
  final String? highlightPassengerId;

  const CollectionScreen({
    super.key,
    required this.tour,
    required this.bus,
    this.highlightPassengerId,
  });

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  final MoneyController controller = Get.find<MoneyController>();

  /// 0 = All, 1 = To return, 2 = To collect
  int _filter = 0;

  /// Applies [highlightPassengerId] once after the first non-loading frame.
  bool _highlightApplied = false;

  /// True only when the money load failed AND nothing is already held — so a
  /// transient read failure shows a retry instead of a roster that falsely reads
  /// as "nobody has paid". Reads the money obs inside the calling [Obx] to stay
  /// reactive across a retry.
  bool get _showLoadError =>
      controller.loadFailed.value &&
      controller.collections.isEmpty &&
      controller.expenses.isEmpty &&
      controller.handovers.isEmpty &&
      controller.incomes.isEmpty;

  @override
  void initState() {
    super.initState();
    // Warm the global pickup list once so the per-name code tags can resolve.
    if (Get.isRegistered<PickupController>()) {
      Get.find<PickupController>().ensureLoaded();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.loadForTour(widget.tour.id);
    });
  }

  List<_SeatCollectionLine> get _seatLines {
    final lines = <_SeatCollectionLine>[];
    for (final p in widget.tour.passengers) {
      // Distinct PHYSICAL seats only: a whole double-sofa is two assignment
      // entries on one seat, and amountDueForSeat already charges the full sofa
      // once — so a line per entry would bill it twice.
      //
      // Deduplicated on the BASE id. The app writes both berths under the
      // identical seatId, but the older `#n` berth-suffix form still exists in
      // the data (diagnostics CHECK 10), and on the raw string those read as two
      // seats — two rows for one rider, each at the full sofa price, doubling
      // this bus's shortfall the moment they are part-paid. Every other reader
      // already normalises: `Bus.amountDueFor`, `collectionRowForSeat`, and
      // 062's SQL all strip the suffix first.
      final seatIds = <String>{
        for (final a in p.assignedSeats)
          if (a.busId == widget.bus.id) baseSeatId(a.seatId),
      };
      for (final seatId in seatIds) {
        final due = widget.bus.amountDueForSeat(p, seatId);
        lines.add(
          _SeatCollectionLine(
            passenger: p,
            seatId: seatId,
            due: due,
            col: controller.collectionFor(p, widget.bus.id, seatId),
            pendingClaim: controller.pendingClaimForPassenger(p.id),
          ),
        );
      }
    }
    lines.sort((a, b) => a.seatId.compareTo(b.seatId));
    return lines;
  }

  bool _passesFilter(_SeatCollectionLine line) => switch (_filter) {
    1 => line.isReturnDue, // To return
    2 => line.isShortfall, // To collect
    _ => true,
  };

  /// Pick To collect / To return when deep-linking a rider after a seat move.
  void _applyHighlightIfNeeded() {
    if (_highlightApplied) return;
    final id = widget.highlightPassengerId;
    if (id == null || id.isEmpty) {
      _highlightApplied = true;
      return;
    }
    final mine = _seatLines.where((l) => l.passenger.id == id).toList();
    if (mine.isEmpty) {
      // Roster not ready yet (or rider not on this bus) — try again next frame.
      return;
    }
    _highlightApplied = true;
    final next = mine.any((l) => l.isShortfall)
        ? 2
        : mine.any((l) => l.isReturnDue)
        ? 1
        : 0;
    if (next == _filter) return;
    // Never setState during Obx build — schedule after this frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _filter == next) return;
      setState(() => _filter = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    return UgamScaffold(
      body: SafeArea(
        child: Column(
          children: [
            UgamAppBar(
              eyebrow: tr('collection.eyebrow'),
              title: tr(
                'collection.app_bar_title',
                namedArgs: {'bus': widget.bus.name},
              ),
            ),
            Expanded(
              child: Obx(() {
                if (controller.isLoading.value &&
                    !controller.loadedOnce.value) {
                  return const MoneyLoadingSkeleton();
                }
                // A failed load leaves the collections empty; show the shared
                // retry rather than a roster where every seat falsely reads as
                // "not collected".
                if (_showLoadError) {
                  return UgamEmpty.error(
                    onRetry: () => controller.loadForTour(widget.tour.id),
                  );
                }

                _applyHighlightIfNeeded();

                final s = controller.summaryForBus(widget.bus.id);
                // Kept apart so the empty state can tell "the filter is hiding
                // them" from "nobody is seated on this bus at all" — two very
                // different situations that used to share one sentence.
                final allLines = _seatLines;
                final lines = allLines.where(_passesFilter).toList();

                return Column(
                  children: [
                    // Pinned compact summary — stays put while the roster scrolls.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UgamSpacing.gutter,
                        UgamSpacing.sm,
                        UgamSpacing.gutter,
                        UgamSpacing.md,
                      ),
                      child: _SummaryHeader(
                        collected: s.collected,
                        toReturn: s.toReturnTotal,
                        toCollect: s.toCollectTotal,
                      ),
                    ),
                    // Filter pills sit directly above the roster they control.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        UgamSpacing.gutter,
                        0,
                        UgamSpacing.gutter,
                        UgamSpacing.md,
                      ),
                      child: UgamTabPills(
                        currentIndex: _filter,
                        onChanged: (i) => setState(() => _filter = i),
                        items: [
                          UgamTabItem(label: tr('collection.filter_all')),
                          UgamTabItem(label: tr('collection.filter_to_return')),
                          UgamTabItem(
                            label: tr('collection.filter_to_collect'),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: lines.isEmpty
                          ? _emptyRoster(noSeats: allLines.isEmpty)
                          : RefreshIndicator(
                              // Chrome, not ownership — the pull spinner is
                              // neutral ink2 in every screen, so it never
                              // changes hue between tabs.
                              color: c.ink2,
                              onRefresh: () =>
                                  controller.refreshForTour(widget.tour.id),
                              child: ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(
                                  parent: BouncingScrollPhysics(),
                                ),
                                padding: const EdgeInsets.fromLTRB(
                                  UgamSpacing.gutter,
                                  0,
                                  UgamSpacing.gutter,
                                  UgamSpacing.huge,
                                ),
                                itemCount: lines.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: UgamSpacing.md),
                                itemBuilder: (_, i) {
                                  final line = lines[i];
                                  return _PassengerRow(
                                    line: line,
                                    bus: widget.bus,
                                    onTap: () =>
                                        _openCollectSheet(context, line),
                                    onMarkPaid: () => _markPaid(line),
                                    // Only a seat that actually holds recorded
                                    // money has anything to undo.
                                    onUndoPayment: line.hasRecordedMoney
                                        ? () => _confirmUndoPayment(line)
                                        : null,
                                  );
                                },
                              ),
                            ),
                    ),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// The roster's empty state. Kept apart from the filter so it can tell "the
  /// filter is hiding them" from "nobody is seated on this bus at all".
  Widget _emptyRoster({required bool noSeats}) {
    if (noSeats) {
      // Genuinely zero: there is no roster to filter.
      // The fix lives on the seat chart, so this state
      // says so instead of offering a dead button.
      return UgamEmpty(
        icon: Icons.event_seat_outlined,
        title: tr('collection.empty_no_seats_title'),
        body: tr('collection.empty_no_seats_body'),
      );
    }
    // Filtered to nothing — one action, and it is
    // always the right one.
    return UgamEmpty(
      icon: Icons.filter_alt_off_rounded,
      title: tr('collection.empty_no_match'),
      cta: UgamCTA(
        label: tr('collection.empty_show_all'),
        leadingIcon: Icons.list_rounded,
        onPressed: () => setState(() => _filter = 0),
      ),
    );
  }
}
