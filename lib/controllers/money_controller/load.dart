part of '../money_controller.dart';

/// Per-tour load / refresh, ledger rollups, claims and seat holds.
mixin _MoneyLoad on _MoneySettlement {
  // ── Load / refresh ────────────────────────────────────────

  Future<void> loadForTour(String tourId) async {
    if (tourId.isEmpty) return;
    // Same-tour concurrent callers share one in-flight request (hero + money
    // tab + collection screen all fire loadForTour on open).
    if (_loadInFlight != null && _loadInFlightTourId == tourId) {
      return _loadInFlight!;
    }
    final future = _loadForTourBody(tourId);
    _loadInFlight = future;
    _loadInFlightTourId = tourId;
    try {
      await future;
    } finally {
      if (_loadInFlightTourId == tourId) {
        _loadInFlight = null;
        _loadInFlightTourId = null;
      }
    }
  }

  Future<void> _loadForTourBody(String tourId) async {
    final gen = ++_loadGeneration;
    // A genuine tour SWITCH must never render the previous tour's rows. Clear
    // the four cached lists up-front, BEFORE the fetch, so tour B can never show
    // tour A's collections + rent even if B's read fails (loadFailed then drives
    // the retry surface). A SAME-tour reload is left untouched — its transient
    // read failures still preserve last-known rows (see below), the intended
    // resilience behaviour.
    final isSwitch = tourId != _loadedTourId;
    // Before the OUTGOING tour's rows are cleared below, snapshot its
    // outstanding handover into [settlementByTour] via the same
    // [tourSummary] → [TourMoneySummary.compute] path [outstandingHandoverFor]
    // uses for the live tour — no extra network call, no divergence. Without
    // this, a tour that WAS the loaded tour has no cached snapshot the moment
    // it stops being loaded (loadSettlementSnapshots explicitly skips
    // _loadedTourId), so its genuine outstanding handover would silently drop
    // out of the dashboard's "needs attention" list until some unrelated
    // event re-ran the snapshot pass. Gated on [loadedOnce] so a tour that was
    // never actually fetched (still holding empty/initial lists) isn't cached
    // as a false "settled" (0) — that must stay "unknown" (null).
    if (isSwitch && _loadedTourId != null && loadedOnce.value) {
      settlementByTour[_loadedTourId!] = tourSummary().totalOutstandingHandover;
    }
    if (isSwitch) {
      collections.clear();
      expenses.clear();
      handovers.clear();
      incomes.clear();
      paymentClaims.clear();
      pendingSeatHolds.clear();
      loadedOnce.value = false;
      _clearLedgerCache();
    }
    _loadedTourId = tourId;
    isLoading.value = true;
    loadFailed.value = false;
    try {
      final results = await _fetchMoneyTables(tourId);
      if (gen != _loadGeneration || _loadedTourId != tourId) return;

      // smartFetch never throws — it returns [] with a per-call `failed` flag on
      // any failure or when offline. The four reads run concurrently; this load
      // has failed if ANY of them did. Each flag is that call's OWN outcome (no
      // shared service field), so an unrelated concurrent read can't corrupt it.
      // Only COMMIT the fetched rows when the load genuinely succeeded: a
      // transient timeout must keep whatever we already hold rather than blank
      // the money board to ₹0 (which reads as "this tour has no money" — the bug
      // this guard fixes). The screens observe [loadFailed] to show a retry.
      final failed = results.any((r) => r.failed);
      if (!failed) {
        collections.assignAll(results[0].rows.map(Collection.fromMap).toList());
        expenses.assignAll(results[1].rows.map(Expense.fromMap).toList());
        handovers.assignAll(results[2].rows.map(BusHandover.fromMap).toList());
        incomes.assignAll(results[3].rows.map(IncomeEntry.fromMap).toList());
        loadedOnce.value = true;

        // Claims + holds + ledger are independent — run in parallel instead of
        // three sequential round-trips on 2G.
        final secondary = await Future.wait([
          _loadPaymentClaims(tourId),
          _loadPendingSeatHolds(tourId),
          _loadLedgerForTour(tourId),
        ]);
        if (gen != _loadGeneration || _loadedTourId != tourId) return;
        final ledgerOk = secondary[2] as bool;
        if (!ledgerOk) loadFailed.value = true;
      }
      if (gen != _loadGeneration || _loadedTourId != tourId) return;
      loadFailed.value = failed || loadFailed.value;
    } catch (e, st) {
      if (gen != _loadGeneration || _loadedTourId != tourId) return;
      // Leave whatever we already hold in place — a transient fetch
      // failure shouldn't blank the money screen.
      dev.log(
        'loadForTour failed for $tourId: $e\n$st',
        name: 'MoneyController',
      );
      loadFailed.value = true;
    } finally {
      if (gen == _loadGeneration) isLoading.value = false;
    }
  }

  void _clearLedgerCache() {
    _ledgerReady = false;
    _ledgerByBus.clear();
  }

  /// Returns false when the ledger views could not be read.
  Future<bool> _loadLedgerForTour(String tourId) async {
    try {
      final rollups = await _ledgerSource.fetchBusRollups(tourId);
      if (_loadedTourId != tourId) return false;
      _ledgerByBus
        ..clear()
        ..addEntries([
          for (final r in rollups)
            if (r.busId != null && r.busId!.isNotEmpty) MapEntry(r.busId!, r),
        ]);
      _ledgerReady = true;
      return true;
    } catch (e, st) {
      if (_loadedTourId != tourId) return false;
      dev.log(
        'ledger load failed for $tourId: $e\n$st',
        name: 'MoneyController',
      );
      _clearLedgerCache();
      return false;
    }
  }

  Future<void> _loadPaymentClaims(String tourId) async {
    try {
      final raw = await SupabaseService.instance.client
          .from('payment_claims')
          .select(SyncReadProjections.paymentClaimsSelect)
          .eq('tour_id', tourId)
          .order('claimed_at', ascending: false);
      if (_loadedTourId != tourId) return;
      paymentClaims.assignAll([
        for (final r in (raw as List))
          PaymentClaim.fromMap(Map<String, dynamic>.from(r as Map)),
      ]);
    } catch (e, st) {
      if (_loadedTourId != tourId) return;
      // Claims table may be undeployed — keep empty, don't fail the board.
      dev.log(
        'payment_claims load failed for $tourId: $e\n$st',
        name: 'MoneyController',
      );
      paymentClaims.clear();
    }
  }

  Future<void> _loadPendingSeatHolds(String tourId) async {
    try {
      final raw = await SupabaseService.instance.client.rpc(
        'tour_pending_seat_holds',
        params: {'p_tour_id': tourId},
      );
      if (_loadedTourId != tourId) return;
      if (raw is! List) {
        pendingSeatHolds.clear();
        return;
      }
      pendingSeatHolds.assignAll([
        for (final r in raw)
          if (r is Map) Map<String, dynamic>.from(r),
      ]);
    } catch (e, st) {
      if (_loadedTourId != tourId) return;
      dev.log(
        'pending seat holds load failed for $tourId: $e\n$st',
        name: 'MoneyController',
      );
      pendingSeatHolds.clear();
    }
  }

  /// Admin: lock held seats without waiting for UPI confirm (pay on bus).
  Future<void> payLaterFinalizeHold(String holdId) async {
    await SupabaseService.instance.client.rpc(
      'chart_finalize_hold',
      params: {'p_hold_id': holdId},
    );
    final tourId = _loadedTourId;
    if (tourId != null) {
      await refreshForTour(tourId);
      if (Get.isRegistered<TourController>()) {
        await Get.find<TourController>().refreshTours();
      }
    }
  }

  List<PaymentClaim> get pendingClaims =>
      paymentClaims.where((c) => c.isPending).toList();

  /// The rider's UNVERIFIED claim, if any — "I paid you, here's the reference".
  /// Surfaced on the collect sheet so the agent can confirm or reject it; it is
  /// deliberately NOT money until they do.
  ///
  /// There is intentionally no `confirmedAdvanceForPassenger` / `dueAfterAdvances`
  /// counterpart. Confirming a claim writes a real `collections` row
  /// (`confirm_payment_claim`, migration 060/069), so a confirmed advance is
  /// already inside `netCollectedOf` and every balance derived from it. A helper
  /// that subtracted it a SECOND time would reproduce, client-side, exactly the
  /// double-count that migration 069 removes from the ledger — so the pair was
  /// deleted rather than left lying around unused.
  PaymentClaim? pendingClaimForPassenger(String passengerId) =>
      paymentClaims.firstWhereOrNull(
        (c) => c.passengerId == passengerId && c.isPending,
      );

  Future<void> confirmPaymentClaim(String claimId, {String? note}) async {
    await SupabaseService.instance.client.rpc(
      'confirm_payment_claim',
      params: {
        'p_claim_id': claimId,
        'p_note': ?note,
      },
    );
    final tourId = _loadedTourId;
    if (tourId != null) {
      await refreshForTour(tourId);
    }
    _invalidateFinance();
  }

  /// Record a payment the ORGANISER collected from a waitlisted rider, and
  /// post it to the ledger.
  ///
  /// Goes claim -> confirm rather than writing a collection row, for a concrete
  /// reason: `collections` is keyed (passenger, bus, seat) and a waitlisted
  /// rider has no seat yet, so there is nothing to key a row to. The claim rail
  /// is passenger-scoped and already posts bank.gateway -> ar.rider through
  /// `confirm_payment_claim`, which is exactly the entry this money needs.
  ///
  /// Returns null on success, or a reason the caller can show. The commonest
  /// failure is a rider the ORGANISER added by hand: they have no
  /// booking_requests row, and `claim_upi_advance` is keyed by one. That is
  /// reported rather than swallowed — silently confirming a rider whose money
  /// never reached the ledger is how a tour's books stop adding up.
  Future<String?> recordWaitlistPayment({
    required String tourId,
    required String passengerId,
    required int amountPaise,
    String? reference,
  }) async {
    if (amountPaise <= 0) return 'amount';
    final client = SupabaseService.instance.client;
    try {
      final rows = await client
          .from('booking_requests')
          .select('id')
          .eq('passenger_id', passengerId)
          .limit(1);
      final list = rows as List;
      if (list.isEmpty) return 'no_request';
      final requestId = (list.first as Map)['id']?.toString();
      if (requestId == null || requestId.isEmpty) return 'no_request';

      final claimId = await client.rpc(
        'claim_upi_advance',
        params: {
          'p_request_id': requestId,
          'p_amount_paise': amountPaise,
          'p_upi_ref': reference,
        },
      );
      if (claimId == null) return 'claim_failed';

      await client.rpc(
        'confirm_payment_claim',
        params: {
          'p_claim_id': claimId.toString(),
          'p_note': 'waitlist collection',
        },
      );
      await refreshForTour(tourId);
      _invalidateFinance();
      return null;
    } catch (e, st) {
      dev.log(
        'recordWaitlistPayment failed for $passengerId: $e\n$st',
        name: 'MoneyController',
      );
      return 'failed';
    }
  }

  Future<void> rejectPaymentClaim(String claimId, {String? note}) async {
    await SupabaseService.instance.client.rpc(
      'reject_payment_claim',
      params: {
        'p_claim_id': claimId,
        'p_note': ?note,
      },
    );
    final tourId = _loadedTourId;
    if (tourId != null) await _loadPaymentClaims(tourId);
  }

  /// Force a fresh fetch by invalidating the three per-tour cache keys
  /// before reloading.
  Future<void> refreshForTour(String tourId) async {
    await _sync.invalidateCache(_collectionsKey(tourId));
    await _sync.invalidateCache(_expensesKey(tourId));
    await _sync.invalidateCache(_handoversKey(tourId));
    await _sync.invalidateCache(_incomesKey(tourId));
    await loadForTour(tourId);
  }
}
