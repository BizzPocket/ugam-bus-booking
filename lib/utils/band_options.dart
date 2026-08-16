import '../models/bus_details.dart';
import '../models/request_band.dart';
import '../models/seat_layout.dart';
import '../models/seat_type.dart';
import '../models/trip_type.dart';
import 'chart_seat_availability.dart';

/// One choice in the band picker: a band the customer may buy into for a given
/// seat type, and what ONE unit of that type costs inside it.
class BandOption {
  /// The band as it will be snapshotted onto the request line if chosen.
  final RequestBand band;

  /// Price for one UNIT of the seat type this option was built for — a whole
  /// Double Sofa is two berths, so it is twice the band's per-berth price.
  final int unitPricePaise;

  /// True when this option is the synthesized fallback for rows no band
  /// covers, priced from the bus's per-type / per-seat price. The UI names it
  /// "Standard" rather than showing an authored band label it does not have.
  final bool isStandard;

  /// WHOLE units of this seat type still sellable as a FULL TRIP inside this
  /// band, across every bus that carries it.
  ///
  /// Whole units, not berths: a fresh pair cannot sit on a half-sold double
  /// sofa, so a half-taken double counts for nothing. Full trip, so a rider
  /// holding only the outbound leg still blocks it — a round-trip seat needs
  /// both legs, which is the whole 37-berths-or-74-one-leg arithmetic.
  ///
  /// ADVISORY ONLY. It is computed from a snapshot the customer's device
  /// fetched some seconds ago, so it can be stale by the time they tap Pay.
  /// It exists to stop someone paying for a seat that is visibly gone, NOT to
  /// guarantee the seat — that needs a server-side hold.
  final int freeUnits;

  const BandOption({
    required this.band,
    required this.unitPricePaise,
    this.isStandard = false,
    this.freeUnits = 0,
  });

  /// Nothing of this type left in this band for a full-trip rider.
  bool get soldOut => freeUnits <= 0;

  BandOption copyWith({int? freeUnits}) => BandOption(
        band: band,
        unitPricePaise: unitPricePaise,
        isStandard: isStandard,
        freeUnits: freeUnits ?? this.freeUnits,
      );

  /// Stable identity for de-duplication across buses and for widget keys.
  /// Deliberately excludes the label: the live tour carries three
  /// different-priced bands ALL labelled `બેન્ડ`, so the label identifies
  /// nothing. Rows plus price do.
  String get key =>
      '${band.fromRow}:${band.toRow}:${band.pricePaise}:$isStandard';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BandOption &&
          other.band == band &&
          other.unitPricePaise == unitPricePaise &&
          other.isStandard == isStandard;

  @override
  int get hashCode => Object.hash(band, unitPricePaise, isStandard);
}

/// The bands a customer may buy a [type] seat in, across every bus on the tour.
///
/// *** WHY THIS IS NOT JUST `bus.priceBands` ***
/// Three things have to happen before a band is safe to put in front of a
/// paying customer:
///
///   1. **It must contain a seat of that type.** A band is a ROW RANGE. If the
///      front rows hold only double sofas, "single sofa, front band" is a seat
///      that cannot be delivered — and this flow takes the money up front.
///   2. **Rows no band covers still need a price.** They fall through to the
///      per-type override, else the per-seat price (mirroring
///      [Bus.berthPriceFor]). Those rows are offered as one STANDARD option
///      rather than being silently unsellable.
///   3. **Identical bands across buses are ONE choice.** The live tour runs two
///      buses carrying the same three bands; the customer picks a price, not a
///      bus, and must not be shown each band twice.
///
/// Returns options ordered front to back by row — the physical order of the
/// coach, which is also how the agent thinks about price.
///
/// Empty when nothing can be honestly quoted: a bus with no layout (no rows to
/// price against) or a bus still priced at zero, which is the normal state of a
/// request-mode tour until the agent prices it. An empty list is what makes the
/// line unbanded, and an unbanded line joins the waiting list free of charge —
/// exactly today's behaviour, which is the right fallback.
List<BandOption> bandOptionsFor({
  required List<Bus> buses,
  required SeatType type,
  Map<String, SeatAvailability> availability = const {},
}) {
  final byKey = <String, BandOption>{};
  final ordered = <String>[];

  void add(BandOption option) {
    if (option.unitPricePaise <= 0) return;
    final existing = byKey[option.key];
    if (existing == null) {
      byKey[option.key] = option;
      ordered.add(option.key);
      return;
    }
    // The same band on a second bus is ONE choice with MORE seats behind it.
    byKey[option.key] =
        existing.copyWith(freeUnits: existing.freeUnits + option.freeUnits);
  }

  for (final bus in buses) {
    final layout = bus.layout;
    if (layout == null) continue;

    // Rows that actually hold a sellable seat of this type, and how many WHOLE
    // units of it are still free for a full-trip rider in each row. Reserved
    // cells are held by the agent and never sold, so they cannot justify a
    // band — `freeBerths` already returns 0 for them.
    final rowsWithType = <int>{};
    final freeByRow = <int, int>{};
    for (final SeatCell cell in layout.grid) {
      if (cell.seatId == null || cell.seatType != type || cell.reserved) {
        continue;
      }
      rowsWithType.add(cell.row);
      final free = freeBerths(
        cell: cell,
        occupancy: availability[SeatAvailability.keyFor(bus.id, cell.seatId!)],
        leg: TripType.roundTrip,
      );
      // A WHOLE unit must fit: a half-sold double sofa seats no fresh pair.
      if (free >= type.berthsPerUnit) {
        freeByRow[cell.row] = (freeByRow[cell.row] ?? 0) + 1;
      }
    }
    if (rowsWithType.isEmpty) continue;

    int freeIn(bool Function(int row) covers) {
      var n = 0;
      freeByRow.forEach((row, units) {
        if (covers(row)) n += units;
      });
      return n;
    }

    final bands = bus.effectiveBands;

    for (final band in bands) {
      final snapshot = RequestBand.fromPriceBand(band);
      if (!rowsWithType.any(snapshot.covers)) continue;
      add(BandOption(
        band: snapshot,
        unitPricePaise: snapshot.pricePaise * type.berthsPerUnit,
        freeUnits: freeIn(snapshot.covers),
      ));
    }

    // Rows of this type that NO band covers keep the per-type fallback price.
    final uncovered = rowsWithType.where(
      (r) => !bands.any((b) => b.covers(r)),
    ).toList()
      ..sort();
    if (uncovered.isEmpty) continue;

    // `berthPriceFor` on an uncovered row IS the fallback — read it from the
    // bus rather than re-deriving the per-type precedence here, so the two can
    // never disagree.
    final berthPaise = (bus.berthPriceFor(type, uncovered.first) * 100).round();
    add(BandOption(
      band: RequestBand(
        label: '',
        fromRow: uncovered.first,
        toRow: uncovered.last,
        pricePaise: berthPaise,
      ),
      unitPricePaise: berthPaise * type.berthsPerUnit,
      isStandard: true,
      freeUnits: freeIn(uncovered.contains),
    ));
  }

  final out = [for (final k in ordered) byKey[k]!]
    ..sort((a, b) => a.band.fromRow.compareTo(b.band.fromRow));
  return out;
}
