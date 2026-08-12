// The visual seat chart and its price-band key.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import '../../components/combined_seat_grid.dart';
import '../../components/seat_chart_tile.dart';
import '../../design/group_color.dart';
import '../../design/price_band_color.dart';
import '../../design/ugam.dart';
import '../../models/bus_details.dart';
import '../../models/collection.dart';
import '../../models/passenger.dart';
import '../../utils/formatters.dart';
import '../../utils/seat_money_state.dart';

// ─── Group colour ──────────────────────────────────────────────────────

// Group ring colours come from the shared `groupColorForId` util
// (lib/design/group_color.dart) — an infinite, golden-angle hue generator that
// never collides with the warm priority ring or the one-way tint. The old
// copied 6-hue `_GroupPalette` was deleted so the handler reads exactly the
// same colour the agent seat-detail screen shows for a given group.

// ─── Seat grid card ────────────────────────────────────────────────────

class HandlerSeatGrid extends StatelessWidget {
  final Bus bus;

  /// EVERY distinct rider per seat — handed to the tile (so a sofa shared by up
  /// to four riders shows them all + the "+N" badge), drives the seat-level
  /// money dot, and is passed to the tap handler.
  final Map<String, List<Passenger>> fullOccupantsBySeat;

  /// Takes the whole [Passenger], not just an id: resolving an orphaned row
  /// after a seat move needs their current assignments.
  final Collection? Function(Passenger passenger, String seatId) collectionFor;
  final void Function(String seatId, List<Passenger> occupants) onTapSeat;

  const HandlerSeatGrid({
    super.key,
    required this.bus,
    required this.fullOccupantsBySeat,
    required this.collectionFor,
    required this.onTapSeat,
  });

  /// The collection state for the WHOLE seat, aggregated across every rider
  /// sharing it: green only when ALL have squared off, otherwise the worst
  /// outstanding state wins — so a shared sofa with only one person's cash
  /// entered stays red instead of looking settled.
  SeatMoneyState _seatMoneyState(List<Passenger> occupants, String seatId) =>
      seatMoneyStateOf(
        occupants.map(
          (p) => riderMoneyStateOf(
            bus.amountDueForSeat(p, seatId),
            collectionFor(p, seatId),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final layout = bus.layout;
    if (layout == null || layout.totalCells == 0) {
      // Matches the two UgamEmpty states this screen already renders in _body;
      // this one used to be a lone grey caption line, which read as unfinished.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: UgamSpacing.lg),
        child: UgamEmpty(
          icon: Icons.event_seat_outlined,
          title: tr('handler_chart.no_seat_layout'),
        ),
      );
    }

    return UgamCard.plain(
      padding: const EdgeInsets.all(UgamSpacing.md),
      child: CombinedSeatGrid(
        layout: layout,
        cellWidth: kSeatTileW,
        cellHeight: kSeatTileH,
        // 6, matching charts_screen and fullscreen_chart_screen. CombinedSeatGrid
        // wraps rows in a scale-down FittedBox, so the old 8 forced a smaller
        // scale factor and rendered the SAME bus's tiles smaller here than on
        // the admin chart.
        colGap: 6,
        rowGap: 6,
        driverLabel: tr('handler_chart.driver'),
        tileBuilder: (ctx, cell) {
          // EVERY rider on this seat (up to four on a Double Sofa across
          // GO+RET). The canonical tile draws the leg split for the first two
          // and badges the rest; the tap hands the whole list to the chooser.
          // The tile detects the GO/RET split itself by trip type.
          final List<Passenger> occList = cell.seatId == null
              ? const <Passenger>[]
              : (fullOccupantsBySeat[cell.seatId!] ?? const <Passenger>[]);
          // The money dot is a SEAT-level summary across EVERY rider sharing
          // the berth — green only when ALL have squared off, so a shared sofa
          // with just one person's cash entered stays red, not green.
          final money = occList.isEmpty
              ? SeatMoneyState.uncollected
              : _seatMoneyState(occList, cell.seatId!);
          // Price-band wash for this seat's row, so the rows read as price
          // stripes (booked AND free seats). Null when the row is unbanded.
          final bandIdx = bus.bandIndexForRow(cell.row);
          final bandColor = bandIdx == null ? null : priceBandWash(bandIdx);
          return SizedBox(
            width: kSeatTileW,
            height: kSeatTileH,
            child: RepaintBoundary(
              child: SeatChartTile(
                cell: cell,
                occupants: occList,
                // Handler is customer-side with no PassengerGroup colour index;
                // the empty resolver falls back to stable id-hash colours.
                groupColors: const GroupColorResolver({}),
                bandColor: bandColor,
                moneyDotColor: occList.isEmpty
                    ? null
                    : money.dotColor(UgamColors.of(ctx)),
                onTapBooked: occList.isEmpty
                    ? null
                    : () => onTapSeat(cell.seatId!, occList),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─── Price-band key ────────────────────────────────────────────────────

/// The price-band legend: one row per effective band (precedence order) showing
/// the band's colour swatch — the SAME colour the grid washes that band's rows
/// with — its label, its row range, and its per-person price. Hidden entirely
/// when the bus has no bands configured. Each band's colour is keyed on its
/// index so the swatch and the row wash always agree (see `priceBandColor`).
class HandlerPriceBandKey extends StatelessWidget {
  final Bus bus;

  const HandlerPriceBandKey({super.key, required this.bus});

  @override
  Widget build(BuildContext context) {
    final c = UgamColors.of(context);
    final bands = bus.effectiveBands;
    if (bands.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: UgamSpacing.lg),
      child: UgamCard.plain(
        padding: const EdgeInsets.all(UgamSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 18 + sm, matching the expense / income section headers this
                // key stacks directly above.
                Icon(Icons.sell_outlined, size: 18, color: c.ink2),
                const SizedBox(width: UgamSpacing.sm),
                Text(
                  tr('handler_chart.price_bands'),
                  style: UgamText.titleS.copyWith(color: c.ink),
                ),
              ],
            ),
            const SizedBox(height: UgamSpacing.sm),
            for (var i = 0; i < bands.length; i++) ...[
              if (i > 0) const SizedBox(height: UgamSpacing.sm),
              _PriceBandRow(band: bands[i], color: priceBandColor(i), c: c),
            ],
          ],
        ),
      ),
    );
  }
}

/// One band line in the price-band key: colour swatch, label + row range, price.
class _PriceBandRow extends StatelessWidget {
  final PriceBand band;
  final Color color;
  final UgamColorSet c;

  const _PriceBandRow({
    required this.band,
    required this.color,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    // Normalise a band entered "backwards" and show 1-based, human row numbers.
    final lo = (band.fromRow <= band.toRow ? band.fromRow : band.toRow) + 1;
    final hi = (band.fromRow <= band.toRow ? band.toRow : band.fromRow) + 1;
    final raw = band.label.trim();
    // The legacy rear-zone band is synthesized with the hard-coded English
    // sentinel 'Rear' (see Bus.effectiveBands); localize it at render so the key
    // reads in the active language. Empty user labels fall back to band_unnamed.
    final label = raw.isEmpty
        ? tr('handler_chart.band_unnamed')
        : (raw == 'Rear' ? tr('handler_chart.band_rear') : raw);
    return Row(
      children: [
        // 12x12 / r3, exactly the swatch UgamSeatChartLegend paints. The two
        // legends stack on the same screen, so a 16px r4 swatch above a 12px r3
        // one read as two different systems.
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: color),
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: UgamText.bodyStrong.copyWith(color: c.ink),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                lo == hi
                    ? tr('handler_chart.band_row', namedArgs: {'row': '$lo'})
                    : tr(
                        'handler_chart.band_rows',
                        namedArgs: {'from': '$lo', 'to': '$hi'},
                      ),
                style: UgamText.micro.copyWith(color: c.ink2),
              ),
            ],
          ),
        ),
        const SizedBox(width: UgamSpacing.sm),
        Text(
          tr(
            'handler_chart.band_per_person',
            namedArgs: {'amount': Formatters.formatMoneyInr(band.price)},
          ),
          style: UgamText.tabular(UgamText.bodyStrong.copyWith(color: c.ink)),
        ),
      ],
    );
  }
}
