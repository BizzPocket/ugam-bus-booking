import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../controllers/handler_controller.dart';
import '../../design/ugam.dart';
import '../../models/bus_details.dart';
import '../../models/handler_phase.dart';
import '../../models/passenger.dart';
import '../../utils/seat_occupants.dart';
import '../../widgets/handler/handler_collect_sheet.dart';
import '../../widgets/handler/handler_occupant_chooser.dart';
import '../../widgets/handler/handler_seat_grid.dart';

/// The visual seat chart.
///
/// Unchanged in behaviour — tap a seat, collect from whoever sits there — but
/// it is no longer the only route to the expense and income ledgers, which used
/// to hang off the bottom of this view for no reason other than that the old
/// screen had nowhere else to put them.
class HandlerChartTab extends StatelessWidget {
  final HandlerController controller;
  final Bus bus;

  const HandlerChartTab({
    super.key,
    required this.controller,
    required this.bus,
  });

  HandlerController get c => controller;

  /// Whether THIS BUS has finished its outbound leg — the seed for the shared-
  /// seat chooser's default leg.
  ///
  /// BUS-scoped on purpose, and deliberately NOT [Tour.goLegCompleted]. That
  /// getter answers a TOUR-level question, and this screen is one bus: the
  /// chooser it seeds lists the riders of one berth on [bus]. Reading the tour
  /// is the exact multi-bus false positive the tour-level fix called out — the
  /// first bus to arrive would flip every other bus's chart to the return leg
  /// while those buses were still boarding. (It is also unreachable here: the
  /// handler surface holds a [HandlerManifest], never a `Tour`.)
  ///
  /// Nor can the tour's quantifier simply be re-scoped to this bus's riders.
  /// Completing the leg RELEASES the retired riders' seats
  /// (`handler_complete_outbound_leg`, migration 046; `assignedSeats: const []`
  /// in `TourController.completeOutboundLeg`), so once the leg is done there
  /// are no outbound-only riders left holding a seat here to quantify over —
  /// `oneWay.isNotEmpty` would be false forever. `handler_bus_leg_state`'s
  /// `outboundOnlyTotal`/`Done` are counted off those same released seats and
  /// collapse to 0/0 the same way.
  ///
  /// The bus-scoped answer the codebase already trusts is the trip milestone:
  /// [HandlerTripState.goArrivedAt] is documented as what ENDS the GO leg (not
  /// the seat release — a bus of only round-trip riders has no seats to
  /// release). Reading it through [HandlerController.phaseForBus] applies the
  /// same rule [HandlerController.legForBoarding] uses for the boarding list,
  /// so the collect chooser and the boarding roster can no longer disagree
  /// about which leg this bus is on. [HandlerPhase.settling] / [closed] count
  /// as done: they are only reachable past arrival, and an outbound-only bus
  /// lands in `settling` straight from arriving.
  ///
  /// The old inline `passengers.any((p) => p.journeyDone)` said "true" off ONE
  /// retired rider anywhere on the tour — so a cancelled return (which demotes
  /// a rider to outbound-only + journeyDone, `cancelReturnSeatTransform`) also
  /// flipped this bus's chooser to the return leg before it had even departed.
  bool get _outboundDone {
    final phase = c.phaseForBus(bus);
    return phase.isReturnSide ||
        phase == HandlerPhase.settling ||
        phase == HandlerPhase.closed;
  }

  void _onSeatTapped(
    BuildContext context,
    String seatId,
    List<Passenger> occupants,
  ) {
    HapticFeedback.selectionClick();
    if (occupants.isEmpty) return;
    // A Double Sofa can carry up to four riders across GO+RET, so a shared
    // berth needs a chooser before the collect sheet.
    if (occupants.length == 1) {
      _openCollect(context, seatId, occupants.first);
      return;
    }
    _openChooser(context, seatId, occupants);
  }

  Future<void> _openChooser(
    BuildContext context,
    String seatId,
    List<Passenger> occupants,
  ) {
    // Once THIS BUS has closed its outbound leg, the riders still aboard are
    // the return ones — so the chooser opens on the RETURN leg. See
    // [_outboundDone] for why this is bus-scoped, not tour-scoped.
    final outboundDone = _outboundDone;
    return UgamSheet.show<void>(
      context,
      title: tr('handler_chart.seat_shared_title', namedArgs: {'seat': seatId}),
      builder: (sheetCtx) => HandlerOccupantChooserSheet(
        seatId: seatId,
        busId: bus.id,
        occupants: occupants,
        outboundDone: outboundDone,
        // Pushed OVER the chooser rather than replacing it: backing out of the
        // collect sheet returns to the rider list, so a four-rider sofa can be
        // worked through without dropping back to the grid each time.
        onPick: (p) async {
          final saved = await _openCollect(context, seatId, p);
          if (saved == true && sheetCtx.mounted) {
            Navigator.of(sheetCtx).pop();
          }
        },
      ),
    );
  }

  Future<bool?> _openCollect(
    BuildContext context,
    String seatId,
    Passenger passenger,
  ) {
    final due = bus.amountDueForSeat(passenger, seatId);
    return UgamSheet.show<bool>(
      context,
      title: tr('handler_chart.collect_title'),
      builder: (_) => HandlerCollectSheet(
        passenger: passenger,
        seatId: seatId,
        due: due,
        existing: c.collectionFor(passenger, bus.id, seatId),
        onSave: (received, returned, collectedBy, note) => c.saveCollection(
          bus: bus,
          passenger: passenger,
          seatId: seatId,
          due: due,
          received: received,
          manualReturned: returned,
          collectedBy: collectedBy,
          note: note,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = UgamColors.of(context);
    return Obx(() {
      final layout = bus.layout;
      if (layout == null || layout.totalCells == 0) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(UgamSpacing.lg),
            child: Text(
              tr('handler_chart.no_seat_layout'),
              style: UgamText.caption.copyWith(color: colors.ink2),
              textAlign: TextAlign.center,
            ),
          ),
        );
      }

      // Resolved once for the whole bus, not per cell. Keeps EVERY rider on a
      // seat so the tile can show them all, the money dot can aggregate across
      // the berth, and a tap can offer the full roster.
      final fullOccupantsBySeat = occupantListForBus(
        c.manifest.value?.passengers ?? const [],
        bus.id,
      );

      return ListView(
        padding: const EdgeInsets.fromLTRB(
          UgamSpacing.gutter,
          UgamSpacing.md,
          UgamSpacing.gutter,
          UgamSpacing.huge3,
        ),
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        children: [
          HandlerSeatGrid(
            bus: bus,
            fullOccupantsBySeat: fullOccupantsBySeat,
            collectionFor: (p, seatId) => c.collectionFor(p, bus.id, seatId),
            onTapSeat: (seatId, occupants) =>
                _onSeatTapped(context, seatId, occupants),
          ),
          const SizedBox(height: UgamSpacing.lg),
          UgamSeatChartLegend(c: colors),
          HandlerPriceBandKey(bus: bus),
        ],
      );
    });
  }
}
