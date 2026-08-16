import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/bus_details.dart';
import 'package:occubusbooking/models/request_band.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

void main() {
  group('RequestBand', () {
    test('snapshots a bus price band as integer paise', () {
      // The live buses price in rupees as doubles (1351.35). Money on this rail
      // is integer paise — see the ledger — so the snapshot must convert once,
      // here, and never carry a double forward.
      final band = RequestBand.fromPriceBand(
        const PriceBand(label: 'બેન્ડ', fromRow: 0, toRow: 3, price: 1351.35),
      );

      expect(band.pricePaise, 135135);
      expect(band.fromRow, 0);
      expect(band.toRow, 3);
      expect(band.label, 'બેન્ડ');
    });

    test('covers rows inclusively at both ends', () {
      const band =
          RequestBand(label: 'x', fromRow: 0, toRow: 3, pricePaise: 160000);

      expect(band.covers(0), isTrue);
      expect(band.covers(3), isTrue);
      expect(band.covers(4), isFalse);
    });

    test('covers normalises a band entered backwards', () {
      // PriceBand.covers tolerates toRow < fromRow; the snapshot must agree,
      // otherwise a reversed band silently binds a rider to no rows at all.
      const band =
          RequestBand(label: 'x', fromRow: 5, toRow: 2, pricePaise: 120000);

      expect(band.covers(3), isTrue);
    });

    test('round-trips through toMap/fromMap', () {
      const band =
          RequestBand(label: 'બેન્ડ', fromRow: 4, toRow: 4, pricePaise: 150000);

      expect(RequestBand.fromMap(band.toMap()), band);
    });
  });

  group('RequestLine.band', () {
    test('round-trips a banded line', () {
      const line = RequestLine(
        seatType: SeatType.doubleSofa,
        qty: 2,
        leg: TripType.roundTrip,
        band: RequestBand(
          label: 'બેન્ડ',
          fromRow: 0,
          toRow: 3,
          pricePaise: 160000,
        ),
      );

      final back = RequestLine.fromMap(line.toMap());

      expect(back.band, line.band);
      expect(back.seatType, SeatType.doubleSofa);
      expect(back.qty, 2);
    });

    test('a legacy line with no band parses to a null band', () {
      // Every request_lines row written before this feature has no `band` key.
      // Those must keep loading — a throw here fails the whole roster.
      final back = RequestLine.fromMap(const {
        'seatType': 'singleSofa',
        'qty': 1,
        'leg': 'roundTrip',
      });

      expect(back.band, isNull);
      expect(back.qty, 1);
    });

    test('a malformed band does not throw, it degrades to null', () {
      // Postgres type-checks nothing inside jsonb. RequestLine.fromMap already
      // coerces rather than casts for exactly this reason.
      final back = RequestLine.fromMap(const {
        'seatType': 'singleSofa',
        'qty': 1,
        'band': 'not-an-object',
      });

      expect(back.band, isNull);
    });
  });
}
