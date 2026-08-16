import '../utils/json_coerce.dart';
import 'bus_details.dart';

/// The price band a customer CHOSE and PAID FOR when they submitted a request,
/// snapshotted onto the [RequestLine] it was chosen for.
///
/// *** WHY THIS IS A SNAPSHOT AND NOT A POINTER ***
/// A [PriceBand] lives on the bus, and the agent may re-price a bus at any time
/// (migration 092 exists precisely because a re-priced bus has to re-post its
/// riders' fares). A request that has ALREADY been paid must not silently
/// re-quote itself when that happens — the money is in the bank at the old
/// number. So the row range and the price are copied here, once, at the moment
/// the customer commits.
///
/// *** WHY THE PRICE IS PAISE ***
/// Bands are authored in rupees as doubles (`1351.35`). Every money rail in
/// this app is integer minor units for the float-epsilon reasons the finance
/// ledger was rebuilt over. The conversion happens exactly once, in
/// [RequestBand.fromPriceBand], and nothing downstream sees a double.
///
/// *** THE PRICE IS PER BERTH ***
/// Mirrors [Bus.berthPriceFor]: inside a band every berth costs the band price
/// regardless of seat type, so a WHOLE Double Sofa is 2 x [pricePaise].
///
/// [fromRow]/[toRow] are retained because they are the BINDING — the customer
/// paid for a seat in those rows, and seat assignment has to honour it.
class RequestBand {
  /// Display label copied from the bus's band. NOT an identity: live buses
  /// carry three different-priced bands all labelled `બેન્ડ`, so the UI
  /// identifies a band by its price and rows, never by this string.
  final String label;

  /// Inclusive, 0-based row bounds — the rows this rider paid to sit in.
  final int fromRow;
  final int toRow;

  /// Per-berth price in paise, frozen at request time.
  final int pricePaise;

  const RequestBand({
    required this.label,
    required this.fromRow,
    required this.toRow,
    required this.pricePaise,
  });

  /// Snapshot a live bus band. Rupees become paise here and nowhere else.
  factory RequestBand.fromPriceBand(PriceBand band) => RequestBand(
        label: band.label,
        fromRow: band.fromRow,
        toRow: band.toRow,
        pricePaise: (band.price * 100).round(),
      );

  /// True when [row] falls inside this band. Bounds are normalised so a band
  /// authored backwards (`toRow < fromRow`) still binds the intended rows —
  /// [PriceBand.covers] tolerates it, and a snapshot that did not would bind a
  /// paying rider to no rows at all.
  bool covers(int row) {
    final lo = fromRow <= toRow ? fromRow : toRow;
    final hi = fromRow <= toRow ? toRow : fromRow;
    return row >= lo && row <= hi;
  }

  Map<String, dynamic> toMap() => {
        'label': label,
        'fromRow': fromRow,
        'toRow': toRow,
        'pricePaise': pricePaise,
      };

  /// Coerced, not cast — this parses an element of the `request_lines` jsonb
  /// array and Postgres type-checks nothing inside jsonb. Returns null for
  /// anything that isn't a usable band so a corrupt row degrades to "unbanded"
  /// instead of failing the entire roster load.
  static RequestBand? fromMap(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    if (!map.containsKey('pricePaise')) return null;
    return RequestBand(
      label: coerceString(map['label']) ?? '',
      fromRow: coerceInt(map['fromRow']),
      toRow: coerceInt(map['toRow']),
      pricePaise: coerceInt(map['pricePaise']),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RequestBand &&
          other.label == label &&
          other.fromRow == fromRow &&
          other.toRow == toRow &&
          other.pricePaise == pricePaise;

  @override
  int get hashCode => Object.hash(label, fromRow, toRow, pricePaise);

  @override
  String toString() =>
      'RequestBand($label, rows $fromRow-$toRow, ${pricePaise}p)';
}
