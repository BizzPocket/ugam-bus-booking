import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/handler_report.dart';

/// The agent's read side of the handler back-channel.
///
/// Authorisation is not this class's business: 090's owner-only RLS already
/// confines every read and every acknowledgement to the signed-in owner's
/// tours. The handler's write side goes through SECURITY DEFINER RPCs instead,
/// because handlers are anonymous.
class HandlerReportsRepository {
  SupabaseClient get _client => Supabase.instance.client;

  /// Reports raised on [tourId], newest first.
  Future<List<HandlerReport>> fetchForTour(String tourId) async {
    final rows = await _client
        .from('handler_reports')
        .select()
        .eq('tour_id', tourId)
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) => HandlerReport.fromMap(Map<String, dynamic>.from(r as Map)))
        .toList(growable: false);
  }

  /// Marks one report as seen. Idempotent — re-acknowledging leaves the
  /// original timestamp, so the agent's own second tap can't rewrite when they
  /// first saw a breakdown.
  Future<bool> acknowledge(String reportId) async {
    final rows = await _client
        .from('handler_reports')
        .update({'acknowledged_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', reportId)
        .isFilter('acknowledged_at', null)
        .select('id');
    return (rows as List).isNotEmpty;
  }

  /// Clears every open report on a tour in one round-trip — the "I've read the
  /// lot" action, which matters when a bus files four notes in a row.
  Future<int> acknowledgeAll(String tourId) async {
    final rows = await _client
        .from('handler_reports')
        .update({'acknowledged_at': DateTime.now().toUtc().toIso8601String()})
        .eq('tour_id', tourId)
        .isFilter('acknowledged_at', null)
        .select('id');
    return (rows as List).length;
  }
}
