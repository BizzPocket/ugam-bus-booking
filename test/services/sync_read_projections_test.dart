import 'package:flutter_test/flutter_test.dart';
import 'package:occubusbooking/services/sync_read_projections.dart';

void main() {
  group('SyncReadProjections — 2G cold-start contracts', () {
    test('passenger select includes every load-bearing column from the fuzz set',
        () {
      final cols = SyncReadProjections.passengerColumns.toSet();
      expect(
        cols,
        containsAll({
          'id',
          'tour_id',
          'user_id',
          'name',
          'phone',
          'age_group',
          'request_lines',
          'assigned_seats',
          'payment_status',
          'is_handler',
          'is_waitlisted',
          'is_confirmed',
          'note',
          'trip_type',
          'group_id',
          'priority_status',
          'priority_reason',
          'journey_done',
          'pickup_location_id',
          'pickup_location_name',
          'cancelled_at',
          'cancel_requested_at',
          'seats_notified_sig',
          'created_at',
        }),
      );
      expect(cols.contains('updated_at'), isFalse,
          reason: 'updated_at is not load-bearing — drop on the wire');
    });

    test('cold-start bus select never requests layout jsonb', () {
      expect(SyncReadProjections.busListSelect.contains('layout'), isFalse);
      expect(SyncReadProjections.busListColumns, isNot(contains('layout')));
      expect(SyncReadProjections.busListColumns, containsAll(['id', 'tour_id']));
    });

    test('layout fetch is id + layout only', () {
      expect(SyncReadProjections.busLayoutSelect, 'id,layout');
    });

    test('PostgREST missing-table errors are classified as unavailable', () {
      expect(
        SyncReadProjections.isMissingTableError(
          'Could not find the table \'public.customer_memory\' in the schema cache (PGRST205)',
        ),
        isTrue,
      );
      expect(
        SyncReadProjections.isMissingTableError('connection timed out'),
        isFalse,
      );
    });
  });
}
