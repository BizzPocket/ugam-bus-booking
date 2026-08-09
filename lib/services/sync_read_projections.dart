/// Column projections for PostgREST reads on the cold-start / 2G path.
///
/// Live measurement (admin JWT, 2026-08-09) on project `rhyqjzulpvaeslbaymex`:
///   passengers *     → ~52 KB / 52 rows
///   passengers proj  → ~46 KB (~10% save; heavy cols are still required)
///   buses *          → ~129 KB / 50 rows (owner-wide)
///   buses layout-only→ ~92 KB  (**71% of bus * is `layout` jsonb**)
///   active-tour buses with layout → ~6.6 KB; without → ~2.2 KB
///
/// Cold start therefore:
///   1. Never `select *` on passengers / buses.
///   2. Never pull `layout` until a chart / seating / capacity screen needs it.
///   3. Always scope buses/passengers by tour id (never owner-wide bus dumps).
///
/// The passenger column set is pinned by
/// `test/fuzz/passenger_column_subset_fuzz_test.dart` — update both together.
library;

class SyncReadProjections {
  SyncReadProjections._();

  /// Load-bearing passenger columns (see fuzz test). Omits `updated_at`.
  static const List<String> passengerColumns = [
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
  ];

  static String get passengerSelect => passengerColumns.join(',');

  /// Bus metadata needed for lists, money, dashboard counts — **no layout**.
  /// `registration_no` maps to [Bus.busNumber]; pricing columns stay so
  /// collect/amountDue work before a chart is opened.
  static const List<String> busListColumns = [
    'id',
    'owner_id',
    'tour_id',
    'handler_passenger_id',
    'name',
    'registration_no',
    'driver_name',
    'driver_phone',
    'owner_name',
    'owner_phone',
    'is_ac',
    'bus_type',
    'total_seats',
    'price_per_seat',
    'bus_price',
    'boarding_point',
    'departure_time',
    'single_sofa_price',
    'double_sofa_price',
    'seater_price',
    'rear_rows',
    'rear_price',
    'price_bands',
    'notes',
    'created_at',
    'updated_at',
  ];

  static String get busListSelect => busListColumns.join(',');

  /// On-demand chart payload — deliberately tiny.
  static const String busLayoutSelect = 'id,layout';

  /// Money tables — only columns [Collection]/[Expense]/[BusHandover]/
  /// [IncomeEntry] deserialize. Avoids select(*) on every board load.
  static const String collectionsSelect =
      'id,tour_id,bus_id,passenger_id,seat_id,amount_due,amount_received,'
      'amount_refunded,note,collected_by,created_at,updated_at';

  static const String expensesSelect =
      'id,tour_id,bus_id,category,label,amount,paid_by,note,created_at,updated_at';

  static const String handoversSelect =
      'id,tour_id,bus_id,expected_amount,handed_over_amount,note,source,'
      'settled_at,created_at';

  static const String incomesSelect =
      'id,tour_id,bus_id,category,label,amount,received_by,note,created_at,updated_at';

  static const String paymentClaimsSelect =
      'id,tour_id,booking_request_id,passenger_id,amount_paise,upi_ref,'
      'payer_name,payer_phone,status,claimed_at,reviewed_at,review_note,'
      'finance_entry_id,seat_hold_id';

  static const String customerMemorySelect =
      'id,owner_id,phone,name,priority_status,priority_reason,companions,'
      'created_at,updated_at';

  static const String pickupLocationsSelect =
      'id,name,code,sort_order,is_active';

  /// True when PostgREST says a relation is not in the schema cache (undeployed
  /// migration). Callers must stop retrying these — they will never heal on
  /// reconnect the way a timeout would.
  static bool isMissingTableError(String? error) {
    if (error == null || error.isEmpty) return false;
    final e = error.toLowerCase();
    return e.contains('pgrst205') ||
        (e.contains('could not find the table') && e.contains('schema cache'));
  }
}
