part of 'customer_requests_store.dart';

/// The handler-side (and UPI-claim) SECURITY DEFINER RPCs of
/// [CustomerRequestsStore]. Handlers and customers are anonymous, so every
/// read and write here goes through a server function keyed by the request.
mixin _CustomerRequestsHandlerRpcs {
  /// Whether this request belongs to the tour's designated handler. Only the
  /// handler may pull the full bus chart, so the UI gates on this first. Goes
  /// through a SECURITY DEFINER RPC since customers are anonymous. Any error
  /// or null result is treated as "not a handler".
  Future<bool> isRequestHandler(String requestId) async {
    final client = Supabase.instance.client;
    try {
      final result = await client.rpc(
        'is_request_handler',
        params: {'p_request_id': requestId},
      );
      return result as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Fetches the full tour manifest (every bus + every passenger) for the
  /// handler tied to [requestId]. Returns null when the RPC yields null (e.g.
  /// the request isn't a handler). Customers are anonymous, so this goes
  /// through a SECURITY DEFINER RPC.
  Future<HandlerManifest?> handlerTourManifest(String requestId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_tour_manifest',
      params: {'p_request_id': requestId},
    );
    if (result == null) return null;
    return HandlerManifest.fromJson(Map<String, dynamic>.from(result as Map));
  }

  /// Records the customer's assertion that they paid a UPI advance for
  /// [requestId] (migration 060).
  ///
  /// This is NOT a payment confirmation. The QR is a direct UPI deep-link to
  /// the organiser's own VPA — zero-MDR precisely because no gateway sits in
  /// the middle, so nothing ever calls the app back to say the transfer
  /// landed. The agent verifies it against their bank statement before it
  /// becomes money.
  ///
  /// Recording it unverified is still the fix for the real defect: without any
  /// record at all, the handler's collect sheet prices from the fare alone and
  /// charges the advance a SECOND time on the bus. A pending claim is visible
  /// to both the agent and the handler immediately.
  ///
  /// Returns the claim id, or null when the server refused (unknown booking,
  /// rate limit, implausible amount). Never throws — a failed claim must not
  /// block a booking that has already succeeded.
  Future<String?> claimUpiAdvance({
    required String requestId,
    required int amountPaise,
    String? reference,
  }) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'claim_upi_advance',
        params: {
          'p_request_id': requestId,
          'p_amount_paise': amountPaise,
          'p_upi_ref': reference,
        },
      );
      return result?.toString();
    } catch (e) {
      dev.log(
        'claimUpiAdvance failed for $requestId — $e',
        name: 'CustomerRequestsStore',
      );
      return null;
    }
  }

  /// UPI claim against a soft seat hold (advance chart flow) — no passenger yet.
  Future<String?> claimUpiAdvanceForHold({
    required String holdId,
    required int amountPaise,
    String? reference,
  }) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'claim_upi_advance_for_hold',
        params: {
          'p_hold_id': holdId,
          'p_amount_paise': amountPaise,
          'p_upi_ref': reference,
        },
      );
      return result?.toString();
    } catch (e) {
      dev.log(
        'claimUpiAdvanceForHold failed for $holdId — $e',
        name: 'CustomerRequestsStore',
      );
      return null;
    }
  }

  /// Inserts or updates a passenger [Collection] for the handler's tour via a
  /// SECURITY DEFINER RPC (customers are anonymous). The collection is sent as a
  /// jsonb payload; the server resolves the tour from the request and verifies
  /// the bus + passenger belong to it. Returns the upserted row, or null when
  /// the caller isn't the tour's handler. Lets exceptions propagate so the UI
  /// can surface a real failure.
  Future<Collection?> handlerUpsertCollection(
    String requestId,
    Collection c,
  ) async {
    return _rpcRow(
      'handler_upsert_collection',
      {'p_request_id': requestId, 'p_collection': c.toMap()},
      (m) => Collection.fromMap(Map<String, dynamic>.from(m)),
    );
  }

  /// Inserts or updates an [Attendance] row for the handler's tour via a
  /// SECURITY DEFINER RPC (customers are anonymous). The attendance is sent as a
  /// jsonb payload; the server resolves the tour from the request and verifies
  /// the bus + passenger belong to it. Returns the upserted row, or null when
  /// the caller isn't the tour's handler. Lets exceptions propagate so the UI
  /// can surface a real failure.
  Future<Attendance?> handlerUpsertAttendance(
    String requestId,
    Attendance a,
  ) async {
    return _rpcRow(
      'handler_upsert_attendance',
      {'p_request_id': requestId, 'p_attendance': a.toMap()},
      (m) => Attendance.fromMap(Map<String, dynamic>.from(m)),
    );
  }

  /// Inserts or updates a bus [Expense] for the handler's tour via a SECURITY
  /// DEFINER RPC (customers are anonymous). The expense is sent as a jsonb
  /// payload; the server resolves the tour from the request and verifies the
  /// bus belongs to it. Returns the upserted row, or null when the caller isn't
  /// the tour's handler (or the bus isn't on their tour). Lets exceptions
  /// propagate so the UI can surface a real failure.
  Future<Expense?> handlerUpsertExpense(String requestId, Expense e) async {
    return _rpcRow('handler_upsert_expense', {
      'p_request_id': requestId,
      'p_expense': e.toMap(),
    }, (m) => Expense.fromMap(Map<String, dynamic>.from(m)));
  }

  /// Deletes one expense the handler logged on their own tour via a SECURITY
  /// DEFINER RPC. Returns true when a row was removed (false when the caller
  /// isn't the handler or the expense isn't on their tour).
  Future<bool> handlerDeleteExpense(String requestId, String expenseId) async {
    return _rpcBool('handler_delete_expense', {
      'p_request_id': requestId,
      'p_expense_id': expenseId,
    });
  }

  /// Inserts or updates a bus [IncomeEntry] for the handler's tour via a SECURITY
  /// DEFINER RPC (customers are anonymous). The income is sent as a jsonb
  /// payload; the server resolves the tour from the request and verifies the
  /// bus belongs to it. Returns the upserted row, or null when the caller isn't
  /// the tour's handler (or the bus isn't on their tour). Lets exceptions
  /// propagate so the UI can surface a real failure.
  Future<IncomeEntry?> handlerUpsertIncome(
    String requestId,
    IncomeEntry i,
  ) async {
    return _rpcRow(
      'handler_upsert_income',
      {'p_request_id': requestId, 'p_income': i.toMap()},
      (m) => IncomeEntry.fromMap(Map<String, dynamic>.from(m)),
    );
  }

  /// Deletes one income the handler logged on their own tour via a SECURITY
  /// DEFINER RPC. Returns true when a row was removed (false when the caller
  /// isn't the handler or the income isn't on their tour).
  Future<bool> handlerDeleteIncome(String requestId, String incomeId) async {
    return _rpcBool('handler_delete_income', {
      'p_request_id': requestId,
      'p_income_id': incomeId,
    });
  }

  /// Every cash handover recorded against the buses this handler runs — the
  /// ones they logged themselves AND any the admin entered from the other side,
  /// so the handler sees the whole settlement picture for their bus.
  ///
  /// Deliberately NOT part of `handler_tour_manifest`: that RPC has been
  /// re-created verbatim across a dozen migrations and its live body has drifted
  /// from the files, so handovers are read through their own RPC rather than
  /// risk rewriting the manifest from a stale copy. Returns an empty list when
  /// the caller isn't a handler.
  Future<List<BusHandover>> handlerBusHandovers(String requestId) async {
    return _rpcList(
      'handler_bus_handovers',
      {'p_request_id': requestId},
      (m) => BusHandover.fromMap(Map<String, dynamic>.from(m)),
    );
  }

  /// Records (or corrects) one cash handover the handler made to the admin, via
  /// a SECURITY DEFINER RPC — handlers are anonymous, and `bus_handovers` is
  /// owner-only under RLS. The server resolves the tour, verifies the bus is one
  /// the CALLER handles, and stamps `source='handler'`; an admin-recorded row
  /// can never be overwritten this way. Returns the saved row, or null when the
  /// write was rejected. Lets exceptions propagate so the UI can surface a real
  /// failure.
  Future<BusHandover?> handlerUpsertHandover(
    String requestId,
    BusHandover h,
  ) async {
    return _rpcRow(
      'handler_upsert_handover',
      {'p_request_id': requestId, 'p_handover': h.toMap()},
      (m) => BusHandover.fromMap(Map<String, dynamic>.from(m)),
    );
  }

  /// Deletes one handover the handler logged themselves. Returns true when a row
  /// was removed — false for a non-handler, a bus they don't run, or a row the
  /// admin recorded (those stay read-only on the handler side).
  Future<bool> handlerDeleteHandover(
    String requestId,
    String handoverId,
  ) async {
    return _rpcBool('handler_delete_handover', {
      'p_request_id': requestId,
      'p_handover_id': handoverId,
    });
  }

  /// How far the handler's own bus has got through the journey.
  ///
  /// Deliberately its own RPC rather than new fields on `handler_tour_manifest`:
  /// that function's live body has drifted from the migration files, so it is
  /// never rewritten from a stale copy (the same reason handovers read through
  /// their own RPC). It supplies the one thing the manifest omits —
  /// `journey_done` — which is what tells the UI whether the GO leg is finished.
  /// Returns an empty list when the caller isn't a handler.
  Future<List<HandlerBusLegState>> handlerBusLegState(String requestId) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_bus_leg_state',
      params: {'p_request_id': requestId},
    );
    if (result is! List) return const [];
    return result.whereType<Map>().map((m) {
      int n(String k) => (m[k] as num?)?.toInt() ?? 0;
      return (
        busId: (m['bus_id'] ?? '').toString(),
        outboundOnlyTotal: n('outbound_only_total'),
        outboundOnlyDone: n('outbound_only_done'),
        ridersOnOutbound: n('riders_on_outbound'),
        ridersOnReturn: n('riders_on_return'),
      );
    }).toList();
  }

  /// Finishes the GO leg for ONE bus the handler runs: every outbound-only
  /// rider on it has completed their only journey, so their seats on this bus
  /// are released and they are marked `journey_done`. Round-trip and
  /// return-only riders are untouched.
  ///
  /// The server freezes this bus's outbound chart into `tour_seat_snapshots`
  /// in the SAME transaction before releasing anything, so — unlike the admin's
  /// best-effort client-side capture — seats can never be destroyed without
  /// their history being kept. Returns the number of riders cleared, or null
  /// when the caller doesn't handle that bus. Lets exceptions propagate so the
  /// UI can surface a real failure.
  Future<int?> handlerCompleteOutboundLeg(
    String requestId,
    String busId,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(
      'handler_complete_outbound_leg',
      params: {'p_request_id': requestId, 'p_bus_id': busId},
    );
    return (result as num?)?.toInt();
  }

  // ── Trip milestones (migration 090) ───────────────────────

  /// The departure / arrival / completion stamps for every bus this handler
  /// runs. These drive [resolveHandlerPhase], so they decide what the whole
  /// handler surface points at.
  ///
  /// Its own RPC for the same reason as leg state and handovers: the manifest's
  /// live body has drifted from the migration files and is never rewritten.
  /// Returns an empty list when the caller isn't a handler.
  Future<List<HandlerTripState>> handlerBusTripState(String requestId) async {
    return _rpcList('handler_bus_trip_state', {
      'p_request_id': requestId,
    }, HandlerTripState.fromMap);
  }

  /// The tour's dates + status, for the calendar auto-complete rules
  /// (`utils/trip_auto_complete.dart`). A plain read: `tours` is anon-readable
  /// (`is_public`), and the handler manifest RPC carries no dates. Returns a
  /// one-element list (or empty) so it fits the controller's best-effort reads.
  Future<List<TourSchedule>> tourSchedule(String tourId) async {
    if (tourId.isEmpty) return const [];
    final row = await Supabase.instance.client
        .from('tours')
        .select('departure_date, return_date, status')
        .eq('id', tourId)
        .maybeSingle();
    if (row == null) return const [];
    final s = TourSchedule.fromMap(row);
    return s == null ? const [] : [s];
  }

  /// Stamps one trip milestone on one bus and returns the bus's whole updated
  /// state.
  ///
  /// The milestone is sent by NAME and the server stamps `now()` itself rather
  /// than trusting a client clock — a handler's phone can be hours out, and
  /// these timestamps order the trip. The RPC is idempotent per milestone: a
  /// retry on a flaky link re-stamps nothing and returns the existing row, so
  /// the double-tap and the lost-response retry are both harmless.
  Future<HandlerTripState?> handlerStampMilestone(
    String requestId,
    String busId,
    HandlerMilestone milestone,
  ) async {
    return _rpcRow('handler_stamp_milestone', {
      'p_request_id': requestId,
      'p_bus_id': busId,
      'p_milestone': milestone.name,
    }, HandlerTripState.fromMap);
  }

  // ── Problem reports (migration 090) ───────────────────────

  /// Reports this handler has already raised, newest first — so the Trip tab
  /// can show what was sent and whether the agent has seen it.
  Future<List<HandlerReport>> handlerReports(String requestId) async {
    return _rpcList('handler_reports', {
      'p_request_id': requestId,
    }, HandlerReport.fromMap);
  }

  /// Raises a problem with the agent from the bus.
  ///
  /// The client mints the id so a retry after a lost response updates the same
  /// row instead of filing the breakdown twice — the same idempotency the cash
  /// writes needed. Returns the saved row, or null when rejected.
  Future<HandlerReport?> handlerCreateReport(
    String requestId,
    HandlerReport report,
  ) async {
    return _rpcRow('handler_create_report', {
      'p_request_id': requestId,
      'p_report': report.toMap(),
    }, HandlerReport.fromMap);
  }

  /// The UPI advances riders on the handler's bus have claimed (migration 060,
  /// `handler_payment_claims`): pending ones still awaiting the agent's check
  /// and confirmed ones alike, newest first. The RPC itself scopes to the
  /// buses this handler owns and answers `[]` for anyone else.
  ///
  /// Had no caller from August to September 2026, so the collect sheet priced
  /// from the seat fare alone and a rider who had already paid the advance was
  /// asked for the full fare again on the bus.
  Future<List<PaymentClaim>> handlerPaymentClaims(String requestId) async {
    return _rpcList(
      'handler_payment_claims',
      {'p_request_id': requestId},
      (m) => PaymentClaim.fromMap(Map<String, dynamic>.from(m)),
    );
  }

  // ── RPC plumbing ──────────────────────────────────────────

  /// Calls [fn] and parses a single-row answer; null when the server answered
  /// anything but a map (the caller isn't the handler / the write was
  /// rejected). Exceptions propagate.
  Future<T?> _rpcRow<T>(
    String fn,
    Map<String, dynamic> params,
    T Function(Map<dynamic, dynamic> m) parse,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(fn, params: params);
    if (result is! Map) return null;
    return parse(result);
  }

  /// Calls [fn] and parses every map row of a list answer; empty when the
  /// server answered anything but a list. Exceptions propagate.
  Future<List<T>> _rpcList<T>(
    String fn,
    Map<String, dynamic> params,
    T Function(Map<dynamic, dynamic> m) parse,
  ) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(fn, params: params);
    if (result is! List) return const [];
    return result.whereType<Map>().map(parse).toList();
  }

  /// Calls a delete-style [fn] answering whether a row was removed; a null
  /// answer reads as false. Exceptions propagate.
  Future<bool> _rpcBool(String fn, Map<String, dynamic> params) async {
    final client = Supabase.instance.client;
    final result = await client.rpc(fn, params: params);
    return result as bool? ?? false;
  }
}
