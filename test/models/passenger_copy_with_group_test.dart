import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/models/passenger.dart';
import 'package:occubusbooking/models/request_line.dart';
import 'package:occubusbooking/models/seat_type.dart';
import 'package:occubusbooking/models/trip_type.dart';

/// Regression for a SILENT SERVER-SIDE WIPE.
///
/// `TourController._passengerWithGroup` used to rebuild the passenger with the
/// full constructor, listing every field by hand — so each field added to
/// [Passenger] afterwards was silently dropped. The rebuild is persisted via
/// `toMap()`, so (un)grouping a passenger nulled those COLUMNS on Supabase:
/// the pickup point vanished, a cancelled rider was resurrected onto the active
/// roster, a pending cancel request disappeared from the organiser's queue, and
/// every grouped passenger falsely read "seats changed since notified".
///
/// The fix routes group changes through `copyWith(clearGroup:)`, which can't
/// drop a field. These tests pin that: group AND ungroup must preserve
/// everything, and `toMap()` must not emit nulls for the preserved fields.

/// A passenger carrying every field that the old hand-rolled rebuild dropped.
Passenger _fullPassenger({String? groupId}) => Passenger(
  id: 'p1',
  tourId: 't1',
  name: 'Asha',
  phone: '+919824011223',
  requestLines: const [RequestLine(seatType: SeatType.singleSofa, qty: 1)],
  tripType: TripType.roundTrip,
  groupId: groupId,
  isConfirmed: true,
  journeyDone: true,
  pickupLocationId: 'pl1',
  pickupLocationName: 'Surat',
  cancelledAt: DateTime.utc(2026, 7, 20),
  cancelRequestedAt: DateTime.utc(2026, 7, 19),
  seatsNotifiedSig: 'sig-abc',
);

void main() {
  group('copyWith clearGroup', () {
    test('ungrouping clears ONLY the group id', () {
      final grouped = _fullPassenger(groupId: 'g1');
      final ungrouped = grouped.copyWith(groupId: null, clearGroup: true);

      expect(ungrouped.groupId, isNull, reason: 'the one field that changes');

      // Everything the old rebuild silently nulled.
      expect(ungrouped.pickupLocationId, 'pl1');
      expect(ungrouped.pickupLocationName, 'Surat');
      expect(ungrouped.cancelledAt, DateTime.utc(2026, 7, 20));
      expect(ungrouped.cancelRequestedAt, DateTime.utc(2026, 7, 19));
      expect(ungrouped.seatsNotifiedSig, 'sig-abc');
      // …and the two the original rebuild had already been patched to keep.
      expect(ungrouped.isConfirmed, isTrue);
      expect(ungrouped.journeyDone, isTrue);
      // Identity must survive too — it's the row key the update targets.
      expect(ungrouped.id, 'p1');
      expect(ungrouped.createdAt, grouped.createdAt);
    });

    test('grouping into a group preserves the same fields', () {
      final loose = _fullPassenger();
      final grouped = loose.copyWith(groupId: 'g1');

      expect(grouped.groupId, 'g1');
      expect(grouped.pickupLocationId, 'pl1');
      expect(grouped.cancelledAt, isNotNull);
      expect(grouped.cancelRequestedAt, isNotNull);
      expect(grouped.seatsNotifiedSig, 'sig-abc');
    });

    test('without clearGroup a null groupId is a no-op (the ?? fallback)', () {
      final grouped = _fullPassenger(groupId: 'g1');
      expect(
        grouped.copyWith(groupId: null).groupId,
        'g1',
        reason: 'this is exactly why clearGroup has to exist',
      );
    });

    test('the persisted payload keeps the columns instead of nulling them', () {
      // toMap() is what smartUpdate ships to Supabase — assert at that boundary,
      // since that is where the data was actually being destroyed.
      final map = _fullPassenger(groupId: 'g1')
          .copyWith(groupId: null, clearGroup: true)
          .toMap();

      expect(map['group_id'], isNull);
      expect(map['pickup_location_id'], 'pl1');
      expect(map['pickup_location_name'], 'Surat');
      expect(map['cancelled_at'], isNotNull);
      expect(map['cancel_requested_at'], isNotNull);
      expect(map['seats_notified_sig'], 'sig-abc');
    });
  });
}
