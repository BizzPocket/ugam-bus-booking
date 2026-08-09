import '../models/ledger_bus_rollup.dart';
import '../utils/ledger_money.dart';
import 'supabase_service.dart';

/// Reads ledger views for money summaries. Writes stay on legacy tables;
/// triggers keep these views current.
class LedgerMoneySource {
  LedgerMoneySource({SupabaseService? supabase})
      : _supabase = supabase ?? SupabaseService.instance;

  final SupabaseService _supabase;

  /// Optional inject for tests — when set, [fetchBusRollups] / rider fetch
  /// use these instead of PostgREST.
  Future<List<Map<String, dynamic>>> Function(String tourId)? debugFetchBusRows;
  Future<List<Map<String, dynamic>>> Function(String tourId)? debugFetchRiderRows;

  /// Per-bus rollups for a tour (only rows with a non-null bus_id).
  Future<List<LedgerBusRollup>> fetchBusRollups(String tourId) async {
    final rows = debugFetchBusRows != null
        ? await debugFetchBusRows!(tourId)
        : await _queryBusSummary(tourId: tourId);
    return [
      for (final row in rows) LedgerBusRollup.fromMap(row),
    ];
  }

  /// All bus rollups visible to the signed-in owner (RLS). Used by Finance P&L.
  Future<List<LedgerBusRollup>> fetchAllBusRollups() async {
    final rows = debugFetchAllBusRows != null
        ? await debugFetchAllBusRows!()
        : await _queryBusSummary(tourId: null);
    return [
      for (final row in rows) LedgerBusRollup.fromMap(row),
    ];
  }

  Future<List<Map<String, dynamic>>> Function()? debugFetchAllBusRows;

  /// passengerId → owes in rupees (positive = still due, negative = change due).
  Future<Map<String, double>> fetchRiderOwesRupees(String tourId) async {
    final rows = debugFetchRiderRows != null
        ? await debugFetchRiderRows!(tourId)
        : await _queryRiderBalances(tourId);
    final out = <String, double>{};
    for (final row in rows) {
      final pid = row['passenger_id'] as String?;
      if (pid == null || pid.isEmpty) continue;
      final v = row['owes_minor'];
      final minor = v is int
          ? v
          : v is num
              ? v.round()
              : int.tryParse('$v') ?? 0;
      out[pid] = minorToRupees(minor);
    }
    return out;
  }

  Future<List<Map<String, dynamic>>> _queryBusSummary({String? tourId}) async {
    var q = _supabase.client.from('finance_bus_summary').select(
          'tour_id, bus_id, outstanding_handover_minor, billed_minor, '
          'income_minor, ground_expenses_minor, rent_minor, owner_unpaid_minor, '
          'collected_minor, handed_over_minor, to_collect_minor, to_return_minor',
        );
    if (tourId != null) {
      q = q.eq('tour_id', tourId);
    }
    final raw = await q;
    return [
      for (final r in (raw as List)) Map<String, dynamic>.from(r as Map),
    ];
  }

  Future<List<Map<String, dynamic>>> _queryRiderBalances(String tourId) async {
    final raw = await _supabase.client
        .from('finance_rider_balance')
        .select('tour_id, passenger_id, owes_minor')
        .eq('tour_id', tourId);
    return [
      for (final r in (raw as List)) Map<String, dynamic>.from(r as Map),
    ];
  }
}
