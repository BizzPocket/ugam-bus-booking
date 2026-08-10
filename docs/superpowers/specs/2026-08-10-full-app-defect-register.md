# Full-app defect register

**Date:** 2026-08-10  
**Status:** Findings only — no fixes applied  
**Method:** 49-agent read-only sweep (8 areas), every critical/high adversarially reviewed by an agent tasked with refuting it. 100 raw findings, 54 survived.

## Headline

54 real defects across a Flutter/Supabase/GetX bus-booking app: one critical (migration 069 silently dropped hold finalization, so a paid chart hold never becomes a booking), 15 high (duplicate cash rows, online money missing from every Dart read, paid seats lapsing, and four unauthenticated or cross-tenant data exposures), the rest medium/low resilience, lifecycle and presentation issues.


## CRITICAL (1)

### 1. Migration 069 dropped 064's hold finalization from confirm_payment_claim — a paid chart hold never becomes a booking

`supabase/migrations/069_online_payment_single_post.sql:132` — est. 3h

**Impact.** 069 was rebased off 060 and lost 064 §7's 'finalize the linked hold first' block (verified: grep for chart_finalize_hold in 069 returns 0 hits; it appears only in 064 and 068). When the organiser confirms a hold-linked UPI claim, c.passenger_id is null, so the seat loop is skipped, no passenger and no collections row are created, and the whole amount posts as an unattached ar.rider remainder. The claim flips to 'confirmed' and disappears from the pending list, the 5-minute hold then lapses, and the seats go back on sale. The customer has paid, the organiser believes it is settled, and nobody is booked. This is the only in-app path from a paid advance to a seat; the alternative ('Pay later' on the money board) is a separate button on a different card.

**Fix.** Add migration 073 re-creating confirm_payment_claim with 069's body plus 064 §7 restored ahead of the status checks: when c.seat_hold_id is not null and c.passenger_id is null, call chart_finalize_party_holds(h.party_id) if the hold carries a party_id, else chart_finalize_hold(c.seat_hold_id); then re-select the claim row so the seat/collection loop sees the new passenger_id. Decide explicitly what a lapsed hold should do (re-seat vs refuse) rather than inheriting chart_finalize_hold's bare 'hold expired' raise.


## HIGH (15)

### 2. Handler chart never calls collectionRowForSeat — a moved rider gets a second collection row and a duplicate ledger posting; the repo's own wiring test is red

`lib/screens/handler_bus_chart_screen.dart:192` — est. 4h

**Impact.** The screen imports ../utils/collection_seat_resolver.dart at line 31 but never calls collectionRowForSeat (grep count 0; flutter analyze reports the unused import). Both the collect sheet and the per-seat money dot resolve through the strict (passenger, bus, seat) triple, so after a seat move the handler sees a blank sheet, collects again, and handler_upsert_collection's on conflict (passenger_id, bus_id, seat_id) misses — a second row is INSERTed. Migration 062's collections_ledger_sync trigger then posts a duplicate ledger line, and both engines fold collected per row, so the books show double the cash actually in hand. MoneyController.collectionFor (money_controller.dart:536) has the identical hole for the admin collection screen. test/screens/handler_bus_chart_screen_test.dart's 'a moved rider re-opens their EXISTING collection' currently FAILS.

**Fix.** Make _collectionFor take the Passenger and resolve through collectionRowForSeat(passenger:, busId:, seatId:, collections:) over the merged set of _collections.values plus _manifest!.collections (local cache overriding manifest rows by id), so both the sheet's `existing` and the money dot adopt the orphaned row. Apply the same change to MoneyController.collectionFor, then re-run the currently-red wiring test.

### 3. Online UPI advances are counted as cash in hand — the Dart Collection model never parses amount_online

`lib/models/collection.dart:80` — est. 6h

**Impact.** Collection has no amountOnline field; fromMap silently drops the column and netCollected is amountReceived - amountRefunded. Nothing in lib/ mentions amount_online at all (verified by grep). That figure flows into BusMoneySummary.collected, HandlerBusMoney.inHand/outstanding, and the handover sheet's pre-filled expected amount persisted onto bus_handovers. Meanwhile finance_bus_summary (063) restricts collected_minor to cash.handler cash_receipt/refund, so the ledger correctly excludes the online take. The handler is asked to hand over money that landed in the organiser's bank, outstanding never reaches zero, and the admin's board and the handler's board disagree by exactly the online amount — a cash dispute at the moment money changes hands.

**Fix.** Add amountOnline to Collection (parse amount_online in fromMap, keep it OUT of toMap so PATCH/handler_upsert_collection cannot clobber it), add the column to SyncReadProjections.collectionsSelect and to the collections key list in handler_tour_manifest (044 plus the drifted live body). Add a netCash => amountReceived - amountOnline - amountRefunded getter mirroring the ledger's collected_minor and use it for BusMoneySummary.collected and the tour rollup.

### 4. Retrying a failed handover / expense / income mints a fresh UUID, so the retry INSERTs a duplicate money row

`lib/screens/handler_bus_chart_screen.dart:509` — est. 2h

**Impact.** BusHandover/Expense/IncomeEntry are constructed inside onSave, and their constructors do id = id ?? Uuid().v4(), so every tap gets a new id. On failure the sheet stays open with its text intact and the CTA re-enables. The RPCs honour the client id and conflict on (id), so a retry after a commit-then-lost-response is a plain INSERT, not an upsert — and 062's bus_handovers_ledger_sync AFTER INSERT double-posts the handover to the finance ledger. bus_handovers has no natural-key uniqueness (only the PK), so Postgres cannot catch it. Affects all three handler write paths on exactly the 2G links the feature targets.

**Fix.** Mint the row id once per sheet, not per save: give _HandoverSheet/_ExpenseSheet/_IncomeSheet a `late final String _draftId = const Uuid().v4()`, or build the model in _openHandoverSheet/_showExpenseSheet/_showIncomeSheet before UgamSheet.show and pass it into onSave, so a retry re-sends the same id and `on conflict (id) do update` makes it idempotent.

### 5. Online (bank.gateway) money is invisible to every Dart money read, so the cash-basis Finance P&L understates revenue by the whole online take

`lib/controllers/finance_controller.dart:111` — est. 6h

**Impact.** 069 §2 posts the online slice with bus_id NULL on both legs, and finance_bus_summary filters `where l.bus_id is not null` — so the entry produces no row at all. For a fully-online collection the follow-on cash_receipt delta is zero and finance_post_delta returns early, so collected_minor is exactly 0. LedgerMoneySource selects no bank column, bank.gateway is never swept to cash.admin, and grep finds no Dart reader for it anywhere. FinanceController builds tour revenue as `revenue[tid] += r.collected`, so a fully-prepaid trip (a first-class mode: advancePerBerthPaise == 0 means the full amount due) reports ₹0 revenue against real rent and ground expenses and prints a LOSS. Pre-069 the double-post accidentally captured this money once; 069 killed the duplicate without adding a read path.

**Fix.** Expose the bank leg: add an online_minor/bank_minor figure (sum filtered on account_code='bank.gateway') via a tour-scoped rollup — a new finance_tour_summary view or a null-bus bucket, since finance_bus_summary excludes null-bus lines by design — select it in LedgerMoneySource._queryBusSummary, carry it on LedgerBusRollup, and add it to revenue[tid] in FinanceController._loadBody. Leave `collected` meaning cash-in-hand so expectedHandover stays correct.

### 6. A recorded UPI advance never extends the 5-minute seat hold, so paid berths lapse and are re-sold

`supabase/migrations/064_seat_holds_chart_finalize.sql:707` — est. 4h

**Impact.** expires_at is only ever written at hold creation (now() + 5 minutes). claim_upi_advance_for_hold updates only payment_claim_id/updated_at. There is no sweeper, trigger or cron. Finalization is a manual organiser action, and tour_pending_seat_holds filters `expires_at > now()`, so the moment the hold lapses the organiser cannot even see it on the money board. Because the advance is a direct-to-VPA deep link with no gateway callback, confirmation requires a human bank-statement check — unachievable inside the residual ~2 minutes. chart_seat_availability then releases the berths, a second customer buys them, and HoldCountdownStrip tells the customer who just paid to 'Re-book'. This breaks the designed happy path for essentially every advance-collecting chart booking, not a rare race.

**Fix.** In claim_upi_advance_for_hold, push the deadline out when the claim lands — `expires_at = greatest(expires_at, now() + interval '48 hours')`, applied to sibling holds sharing party_id too — or add a distinct awaiting_payment status that availability blocks on and the TTL ignores, released only by explicit reject. Pair this with the restored finalize hook from rank 1.

### 7. Split-party advance is claimed against one hold, so only the first bus's passenger is ever credited

`lib/screens/seat_booking_confirm_screen.dart:355` — est. 5h

**Impact.** _advancePaise is party-wide (advancePerBerthPaise x total berths across every bus) but is filed once against held.holds.first.holdId. 068 writes N holds and keeps one passenger per bus, and party_id lives only on booking_requests/seat_holds, never on passengers, so nothing server-side can relate the sibling riders. 064 §4 attaches the claim only where seat_hold_id = h.id, and 069 applies the whole amount across that one passenger's seats with any excess posting as an ar.rider credit to the same rider. Bus B's passenger gets nothing, handler_payment_claims joins on passenger_id so bus B's handler never sees the claim, and the party is either over-collected or has correct grand totals with wrong per-rider balances — a dispute on the bus, which is exactly what 060 was written to prevent.

**Fix.** In _confirmMultiBus, show the single UPI sheet for the party total but file one claim_upi_advance_for_hold per hold for that bus's own share (advancePerBerthPaise * selection.berths, rounding remainder on the first), and give each per-bus CustomerRequestEntry its own advancePaise share instead of carriesAdvance: i == 0.

### 8. chart_finalize_party_holds is dead code — a split party's sibling holds are never finalized and lapse after the advance is paid

`supabase/migrations/068_multi_bus_chart_claim.sql:467` — est. 4h

**Impact.** A repo-wide sweep finds the function only at its own definition and grants, one design-doc mention, and one Dart comment; 068 adds no trigger. tour_pending_seat_holds does not project party_id, so the money board renders one card per hold and 'Pay later' sends a single hold id to chart_finalize_hold. With 069 having removed the confirm-path finalize (rank 1), that per-hold button is now the ONLY finalize path in the app. The customer cannot rescue the sibling either: _entryFor sets advancePaise to 0 for every ticket after the first, so canPayAdvance is false and the retry button is dead. Money is collected for the whole party and the non-first bus's berths silently lapse.

**Fix.** Add party_id to the tour_pending_seat_holds projection and have MoneyController.payLaterFinalizeHold call chart_finalize_party_holds(party_id) when present, collapsing same-party holds into one card. Alternatively extract the per-hold body into an internal _chart_finalize_one_hold and make chart_finalize_hold fan out over party_id so every existing caller is fixed at once.

### 9. Chart and public RPCs ignore soft deletes: an archived bus stays sellable and an archived passenger blocks its seats forever

`supabase/migrations/048_customer_seat_chart_booking.sql:130` — est. 3h

**Impact.** Every anon-facing seat RPC omits deleted_at. chart_tour_buses, chart_claim_seats, chart_validate_bus_seats and public_tour_buses guard buses on tour_id + layout is not null only; chart_seat_availability, chart_seat_slot_usage and public_tour_availability guard passengers on cancelled_at is null only. Critically, nothing in lib/ ever writes cancelled_at — decline, bulk decline, approve-cancellation and cancelReturnSeat all stamp deleted_at and leave assigned_seats intact. The ghost seat reads FREE on the organiser chart (SyncService filters archived rows client-side) and OCCUPIED on the customer chart, permanently removing inventory from the sales funnel and undercounting 'seats left' on the public tour card. This is exactly the 'two charts that disagree' failure 048's own header says it exists to prevent.

**Fix.** Migration 073 re-emitting each anon seat RPC with the archive guard: `and b.deleted_at is null` on bus lookups in chart_tour_buses / chart_claim_seats / chart_validate_bus_seats / public_tour_buses, and `and p.deleted_at is null` alongside every existing `p.cancelled_at is null`. Back it with passengers_live / buses_live views so a future RPC cannot re-open the gap by writing only half the filter.

### 10. Money surfaces render MoneyController.tourSummary() without checking loadedTourId, showing another tour's cash

`lib/widgets/tour_detail/tour_overview_cockpit.dart:88` — est. 4h

**Impact.** MoneyController is a process-wide singleton holding rows for exactly one tour; every aggregation input resolves off _loadedTourId and TourMoneySummary.compute applies no tour filter. TourOverviewVitals reads tourSummary() behind only a Get.isRegistered check and renders on the DEFAULT tab of TourDetailScreen, which never loads money (only the money tab does). So once the dashboard hero has loaded tour A, opening tour B and staying on Overview deterministically shows A's 'Money due / Collected' under B's title. tour_money_board_screen and tour_money_tab have the same unguarded read, plus a one-frame flash on open and a one-tap race from the dashboard attention list, where A's pendingClaims confirm/reject actions appear under B's name. trip_hero.dart:113 already gates correctly, so the invariant is known.

**Fix.** Make the reads tour-scoped — tourSummary({required String tourId}) returning null on mismatch — so every call site names its tour, and have tour_money_board_screen, tour_money_tab and tour_overview_cockpit render a skeleton (and kick their own loadForTour) on mismatch, as trip_hero already does. Also no-op trip_hero's 1600ms deferred load when loadedTourId has since been claimed by another tour.

### 11. Anon SELECT policy left on storage.objects makes the "private" seat-charts bucket readable AND listable with the shipped publishable key

`supabase/migrations/009_whatsapp_broadcast.sql:59` — est. 2h

**Impact.** 009 creates wa_seatcharts_public_read `for select to anon, authenticated using (bucket_id = 'seat-charts')`. 011 flips buckets.public to false but drops only a policy name 009 never created, and no migration in the set ever drops this one. 051 records a live production test proving the /object/<bucket>/<path> route consults RLS, not the bucket flag. The predicate has no path component, so anon holds SELECT over every ROW — Supabase's list endpoint is RLS-filtered against those same rows, so an attacker with the key hardcoded in lib/config/supabase_config.dart can enumerate every tour folder and walk every passenger PNG. Each PNG is a rendered bus roster with every occupant's name. Unauthenticated, permanent, no user interaction.

**Fix.** Migration dropping wa_seatcharts_public_read (and wa_broadcasts_public_read if tour-broadcasts is to rely on its public flag), then replacing the bucket-wide write grants with an owner-scoped policy resolving split_part(storage.objects.name,'/',1)::uuid back to tours.owner_id = auth.uid(), mirroring 059's wa_media_owner_read. Nothing in the client reads seat-charts, so only the admin upload-and-sign path needs to keep working.

### 12. audit_log RLS is `using (true)` — any authenticated tenant can read every other tenant's money history and PII

`supabase/migrations/056_finance_ledger.sql:398` — est. 3h

**Impact.** Every sibling object in the same file is owner-scoped (finance_settlements, finance_entries, finance_lines) and so are all the audited source tables, but audit_row() writes to_jsonb(new)/to_jsonb(old) of those rows into the one table with no scoping and a single unconditional SELECT policy. That includes payment_claims (payer_name, payer_phone, upi_ref, amount_paise), buses (driver/owner names and phones, registration_no, full price_bands), collections, expenses, incomes, bus_handovers, plus actor_label on every row. Multi-tenancy is real here and has already failed once (migration 023 exists to fix cross-owner bleed). Any provisioned organiser can GET /rest/v1/audit_log?select=* and read every competitor's financial history.

**Fix.** Add owner_id uuid to public.audit_log, populate it in audit_row() (from buses.owner_id, and from tours.owner_id on coalesce(new.tour_id, old.tour_id) for the money tables), replace `using (true)` with `using (owner_id = auth.uid())` plus an index. Immediate stopgap: drop the audit_log_read policy entirely — no Dart code reads the table, so deny-by-default loses no functionality.

### 13. Handler money-write authority is granted by knowing a 10-digit phone number, callable by anon

`supabase/migrations/042_handler_gate_without_request.sql:160` — est. 16h

**Impact.** handler_requests_by_phone takes a bare phone, matches the last 10 digits against passengers where is_handler, and returns an opaque ref. That ref is the ONLY thing every handler RPC checks via is_request_handler — all SECURITY DEFINER, all granted to anon: handler_tour_manifest, handler_upsert_collection/expense/income/attendance/handover and the three deletes. No password, OTP, session or rate limit (the only limiter in the repo was dropped by 013). With the project URL and anon key committed in lib/config/supabase_config.dart this is two curl requests, no app needed. An attacker gets that bus's full passenger names and phones, plus write and archive authority over its collections, expenses, incomes and cash handovers, with no authenticated actor recorded. Narrowed but not closed by the locked/completed gate — which is precisely the window when the handler is holding cash.

**Fix.** Make handler_requests_by_phone return a non-authorising tour listing plus a challenge, and require redeeming a one-time code (SMS OTP or an organiser-set per-tour handler PIN on the passenger row) for a short-lived server-issued handler token; change is_request_handler to verify that token so every handler RPC inherits the check. Interim one-migration mitigation: rate-limit the lookup and gate the write RPCs behind an organiser-set PIN.

### 14. charts_admin_rw grants every authenticated admin read/write/delete over all tenants' seat-chart rosters

`supabase/migrations/011_audit_security_hardening.sql:146` — est. 3h

**Impact.** `for all to authenticated` with USING/WITH CHECK testing only bucket_id — no owner, tour or path predicate — while tenancy is otherwise defended by tours.owner_id = auth.uid() everywhere. Objects land at <tour.id>/<passenger.id>.png with nothing linking them to an owner, and each rendered image carries every occupant's name and phone for the whole bus (051 itself calls it 'personal data'). The bucket-only SELECT makes storage.search list every object, so UUID paths need no guessing. 009's wa_seatcharts_auth_write is an identical never-dropped grant, so fixing 011 alone does not close it. Any provisioned organiser can exfiltrate, overwrite or delete another organiser's rosters via the Storage REST API with their own JWT.

**Fix.** Drop charts_admin_rw plus the four never-removed 009 policies and recreate seat-charts access scoped like 059's wa_media_owner_read: bucket_id = 'seat-charts' and exists (select 1 from public.tours t where t.id::text = split_part(storage.objects.name,'/',1) and t.owner_id = auth.uid()) on both USING and WITH CHECK. For tour-broadcasts, first change create_tour_screen's upload path to <auth.uid()>/... so the same predicate works.

### 15. No HTTP timeout anywhere except SyncService — handler cash writes, the handler chart, Finance and pickup all hang with no feedback on a stalled link

`lib/services/customer_requests_store.dart:793` — est. 8h

**Impact.** Supabase.initialize is called with no httpClient and postgrest 2.8.0 applies no default timeout, so every bare client.rpc/.from awaits an unbounded socket. That covers 24 RPCs in CustomerRequestsStore (including handler_upsert_collection/expense/handover — cash records on a no-signal bus), all of SeatChartBookingService, MoneyController, AdminAuthService and PushService. The worst surface is the handler chart's cold start: _load sets _loading = true and both the retry card and the RefreshIndicator sit behind `_loading == false`, so a stalled handler_tour_manifest pins a skeleton with no retry and no pull-to-refresh — force-quit only, despite an in-file comment claiming that dead end was killed. FinanceController hangs the same way and never surfaces its retry affordance. The repo's own offline spec logs this as 'Finding 1 — the handler app hangs instead of failing (highest severity)'.

**Fix.** Give Supabase.initialize a custom http.Client enforcing a per-request deadline so no PostgREST call can await forever, then extract SyncService's _withTimeout/_withRetry into a shared helper and route the highest-stakes bare RPCs (handler cash writes, LedgerMoneySource._queryBusSummary, the chart RPCs) through it with the cellular-aware budgets. In handler_bus_chart_screen._load, ensure a TimeoutException lands in the existing catch so the error card appears instead of the retry-less skeleton.

### 16. isRetryable misses http.ClientException, so mid-stream connection closes are terminal on every write path

`lib/services/sync_retry_policy.dart:63` — est. 1h

**Impact.** package:http's IOClient converts dart:io HttpException into a bare ClientException (which implements only Exception), so a clean mid-stream close — carrier-proxy/NAT teardown, stale pooled keep-alive reuse — reaches the policy as a type it does not recognise and returns false on attempt 1. postgrest's own built-in retry covers GETs but explicitly excludes POST/PATCH/DELETE, so for smartInsert/smartUpdate/updatePatch/smartDelete/applySeatAssignments the app's 3-attempt ladder is the only protection and it never engages. There is no offline write queue as a backstop. A bus edit on EDGE gets a hard error where the design promises three tries; the existing test asserting HttpException is retryable is dead code because that type cannot reach the policy in this app.

**Fix.** Import package:http and add `if (e is http.ClientException) return true;` alongside the SocketException/HttpException checks (safe: postgrest surfaces status errors as PostgrestException, so any ClientException here is transport-layer), with a regression test constructing a real ClientException('Connection closed before full header was received'). Leave isPreSendConnectionError SocketException-only — the non-idempotent swap RPC depends on pre-send certainty.


## MEDIUM (26)

### 17. chart_claim_seats (single-bus instant claim) ignores active seat_holds and can take a held berth

`supabase/migrations/048_customer_seat_chart_booking.sql:317` — est. 2h

**Impact.** Per-seat occupancy is computed purely from passengers.assigned_seats, with no holds union, and the function is still granted to anon. Every sibling path was taught about holds (chart_hold_seats, chart_validate_bus_seats, chart_finalize_hold), and 068's own header states 'ACTIVE HOLDS block a claim'. So the invariant is enforced only by a client-side branch on a possibly-stale Tour snapshot. The outcome is not a double-book (chart_finalize_hold re-validates and raises), but the hold guarantee breaks and the organiser then cannot record a UPI advance the customer already paid, because confirm_payment_claim re-raises the finalize failure.

**Fix.** Redefine chart_claim_seats so its occupancy check calls chart_seat_slot_usage(p_tour_id, p_bus_id, v_seat_id) instead of the inline passengers-only subquery — ideally by delegating the whole seat loop to 068's chart_validate_bus_seats, so all four claim/hold RPCs share one occupancy source.

### 18. Same-bus seat move across price bands skips the reprice prompt and leaves collections.amount_due stale

`lib/controllers/money_controller.dart:624` — est. 2h

**Impact.** `if (!isLoadedTour && !crossedBus) return const [];` discards the same-bus case, and the on-demand smartFetch below it is behind the same gate. Neither the seat-assignment screen nor charts_screen touches MoneyController, so the tour is genuinely not loaded. Commit cca4ff5 ('surface seat-move money deltas for same-bus band changes') fixed the reconciler but never revisited this gate, and the gate's doc comment is now factually stale. Result: SeatMoveMoneyNotice never fires, so the agent is not prompted to collect the difference when a rider moves into a dearer band, and the stale amount_due understates HandlerBusMoney.toCollect and the admin's legacy fallback. The ledger re-prices server-side and every collect surface prices live, so no money is silently lost — the harm is a missed prompt and a wrong aggregate.

**Fix.** Drop !crossedBus from the early return so the on-demand smartFetch also runs for same-bus moves, or widen the gate to `crossedBus || busHasDifferentiatedBands(tour, busId)` so only a flat-priced bus skips the round trip. Update the stale doc comment and add a controller test for 'same-bus move into a dearer band with the tour NOT loaded still re-prices'.

### 19. Availability poll never reconciles the basket — a seat lost mid-selection still renders and prices as "yours", and cannot be deselected

`lib/screens/seat_selection_screen.dart:146` — est. 3h

**Impact.** chartSeatState returns ChartSeatState.selected before freeBerths is consulted, so a basket seat structurally cannot render taken. _refreshAvailability replaces the snapshot and prunes nothing, so a half-lost double still paints as a solid amber whole tile, the footer price and the 'you're sorted' banner stay wrong, and 064's holds union means seats vanish as soon as another customer reaches checkout. Worse, _tapSeat puts `if (free <= 0) return;` ABOVE the deselect branch, so a dead seat cannot be removed from the basket — Confirm fails permanently until the customer changes leg (clearing everything) or leaves. The failure branch then calls _basket.clear(), destroying the typed name/phone/pickup, contradicting the confirm screen's own stated rule.

**Fix.** After adopting a new snapshot in _refreshAvailability (and the pull-to-refresh path), clamp every basket entry to freeBerths for its cell under the current leg, dropping or reducing shrunken seats and naming them in a snackbar. Move _tapSeat's `if (free <= 0) return;` below the `current > 0` deselect branch so a basket seat can always be tapped off.

### 20. Recording a second handover pre-fills the FULL expected amount, and the resulting over-settlement is hidden (unverified)

`lib/screens/bus_money_screen.dart:380` — est. 1.5h

**Impact.** Unverified by adversarial review. Handovers are cumulative (BusMoneySummary.handedOver folds every row) but the Record action always opens the sheet on s.expectedHandover rather than s.outstandingHandover, and the sheet seeds the input with that value verbatim with no warning that earlier handovers exist. On a ₹12,000 expected with ₹5,000 already recorded, accepting the default stores ₹17,000 handed over. _OutstandingHero then clamps a negative outstanding to 0, so the screen reads a calm settled ₹0 while the books are ₹5,000 out.

**Fix.** Pass s.outstandingHandover (clamped at 0) as the sheet's seed for a NEW handover, show the already-recorded total in the sheet header, and stop the hero clamping — render a distinct over-settled state so a negative outstanding is visible rather than hidden.

### 21. CollectionReconciler does not strip the '#' berth suffix, so a whole double sofa can be priced twice (unverified)

`lib/services/collection_reconciler.dart:157` — est. 1h

**Impact.** Unverified by adversarial review. Every other money path normalises via split('#').first (Bus.amountDueFor does exactly that before de-duplicating, and collection_seat_resolver.baseSeatId exists for this). _planForPassenger de-duplicates on the RAW seatId, so DL1 and DL1#2 become two entries, and each then calls bus.amountDueForSeat, which itself strips the suffix and returns the FULL sofa price. A rider holding one ₹4,000 double sofa has totalDue computed as ₹8,000, so the seat-move notice tells the agent to collect a second full sofa fare, and an orphaned row can be re-homed onto the phantom DL1#2 slot.

**Fix.** Key the `seats` set on baseSeatId(a.seatId) (or reuse Bus.amountDueFor's `seen` de-duplication) so each physical seat contributes once, and add a unit test with a passenger holding DL1 + DL1#2.

### 22. A not-yet-fetched bus layout is treated as "fare = ₹0", zeroing billed revenue and flattening the cross-bus AR split (unverified)

`lib/controllers/money_controller.dart:866` — est. 3h

**Impact.** Unverified by adversarial review. Bus.amountDueFor returns 0 when layout is null, and busListColumns deliberately omits layout while the money board never calls ensureBusLayoutsForTour — so 'not fetched yet' is indistinguishable from 'fare is zero'. On a cold start straight from the dashboard into a tour's money tile, the P&L card headlines income minus expenses (a large phantom loss for a fully-booked trip), the legacy path shows 'to collect ₹0' for a bus full of riders, and _arShareByBus falls into its total <= 0 branch and splits a cross-bus rider's balance EVENLY instead of by what each bus billed — the exact bug its own comment claims to have fixed.

**Fix.** Have TourMoneyBoardScreen/MoneyController await ensureBusLayoutsForTour before computing billed figures, and make the zero case explicit: return null (not 0) from the billing helpers when layout is null, so callers render a skeleton and _arShareByBus falls back only on a genuine zero rather than on missing data.

### 23. Clearing a tour's online advance is a local no-op, and opening the booking-settings sheet can silently disable advance collection (unverified)

`lib/controllers/tour_controller.dart:3457` — est. 2h

**Impact.** Unverified by adversarial review. updateBookingSettings writes advance_per_berth_paise = null to Postgres when clearAdvance is true, but the optimistic local update passes null into copyWith, whose body is `advancePerBerthPaise ?? this.advancePerBerthPaise` — null means keep, so the in-memory tour keeps quoting an advance the server has dropped until a refresh. Separately, the sheet sends clearAdvance whenever rupees <= 0 and seeds the field blank for a tour already at 0, so an agent opening Booking settings to fix a payee name and pressing Save silently turns off online collection for that tour — every subsequent chart booking is confirmed with no money taken.

**Fix.** Give copyWith an explicit clear flag (or a sentinel wrapper) so a deliberate null actually clears, and separate 'no advance' from 'full amount due' in _BookingSettingsSheet — either expose the 0 policy explicitly or never send clearAdvance on a field the user did not touch.

### 24. Marking an OCCUPIED seat as reserved erases its rider from every capacity figure (unverified)

`lib/controllers/tour_controller.dart:3287` — est. 2h

**Impact.** Unverified by adversarial review. _updateSeatFlag applies the reserved flag with no occupancy check, and the seat-flags sheet offers the switch on any tapped cell. Every loop in computeTourCapacity skips reserved cells outright, so the occupant's berths vanish from capacity, occupied, the go/ret maps and the by-type breakdown — while computeActualCapacity keeps counting the rider from assignedSeats against the now-smaller denominator. Holding back an occupied double sofa makes the Requests capacity banner report 2 more free round-trip berths than physically exist, and the tour-overview meter and the banner disagree on the same bus while the grid still draws the couple in the seat.

**Fix.** Refuse (or confirm loudly) the reserved toggle when the cell has an occupant, and make computeTourCapacity count a reserved-but-occupied cell as occupied rather than absent so the two capacity engines cannot diverge.

### 25. swapSeats commits local state before validating both passengers, leaving one side moved and unpersisted (unverified)

`lib/controllers/tour_controller.dart:2148` — est. 1.5h

**Impact.** Unverified by adversarial review. _updateTourLocal resolves each side with firstWhere(..., orElse: () => t.passengers.first) and commits the rewritten list; only afterwards does the method check `if (a == null || b == null) return;`. When one id is stale (the passenger was cancelled on another device between the guard and the write), the map still rewrites the OTHER passenger's assignedSeats, the early return skips both the RPC and the fallback, and no refreshTours is issued. The chart then shows a rider on a seat the server says belongs to someone else until the next full refresh, and a subsequent move keyed off that phantom position writes the wrong seat.

**Fix.** Resolve and validate both passengers BEFORE mutating: look them up with firstWhereOrNull, bail (and refreshTours) if either is missing, and only then call _updateTourLocal. Drop the orElse fallback to t.passengers.first, which silently substitutes an unrelated rider.

### 26. A lost response on a booking submit or chart claim leaves a server-side booking with no local ticket, and the retry duplicates it (unverified)

`lib/screens/customer_booking_request_screen.dart:331` — est. 4h

**Impact.** Unverified by adversarial review. _submitCreate mints requestId locally but writes the device journal entry only AFTER the unbounded RPC returns. If the write lands and the response is lost, no ticket is stored; the customer sees a failure, waits out the 15s cooldown, taps again — and a fresh UUID produces a second passenger row, a second organiser push, and two seats held for one traveller, with no local ticket for either. The same shape exists at seat_booking_confirm_screen: SeatChartBookingService catches only PostgrestException, so a TimeoutException/SocketException skips the CustomerRequestsStore.upsert entirely. Since customers are anonymous, that journal entry is the device's only handle on the booking.

**Fix.** Persist the client-generated request id (as a pending journal entry) BEFORE the RPC and reconcile it afterwards, and reuse that same id on a user-initiated retry instead of minting a new UUID; on a non-Postgrest transport failure, point the customer at Find-my-seat rather than implying nothing happened.

### 27. UPI advance claim is dropped with no timeout, retry or local record, and the success toast masks the error

`lib/services/customer_requests_store.dart:820` — est. 4h

**Impact.** claimUpiAdvance and claimUpiAdvanceForHold catch everything, log, and return null — no timeout, no retry, nothing persisted, and CustomerRequestEntry has no claim field. The recovery window is the 5-minute hold on both sides, and once it lapses no retry can record the payment and the seats are gone too. At checkout the failure is invisible: AppSnackBar reuses the live toast, and _confirm fires 'Seats held' on the very next statement, overwriting 'Couldn't record that payment' within microseconds. The money stays reconcilable from the organiser's bank statement, but nobody is prompted to look, so the agent never confirms a claim, no collections row is written, and the handler prices the full fare.

**Fix.** Give both claim RPCs a bounded timeout plus SyncRetryPolicy retry, and persist the assertion locally with a client-generated idempotency key on the CustomerRequestEntry journal so it replays on reconnect — paired with the unique-key migration the offline design doc already specifies. Stop the success toast at seat_booking_confirm_screen:201/:361 from overwriting the claim-failed toast.

### 28. Failed optimistic write is never rolled back when the recovery refresh also fails

`lib/controllers/tour_controller.dart:3392` — est. 3h

**Impact.** _write calls optimistic() then, on failure, awaits refreshTours() — with no snapshot and no rollback, so recovery depends entirely on the refresh reaching the server. When the header read also throws and tours is non-empty, _loadTours shows 'showing cached' and returns without touching tours, leaving the optimistic mutation in place. The user IS told the save failed (an error toast fires and rethrows), so nothing looks saved — but the list contradicts the message. On a stalled-but-nominally-connected 2G link neither the offline→online reconnect reaction nor _ensureOnline fires, so a deleted tour stays hidden and a phantom created tour stays visible until a manual pull-to-refresh. Server truth is never corrupted (there is no write queue to replay stale state).

**Fix.** Snapshot the affected state before optimistic(), have _loadTours/refreshTours report whether it actually re-synced, and restore the snapshot when it did not. Add a test that a failing persist plus a failing refresh leaves `tours` byte-identical to the pre-write state.

### 29. Writes fail-fast on a sticky `isOnline` false negative with no recovery path, locking the whole admin surface read-only

`lib/services/sync_service.dart:726` — est. 2h

**Impact.** apply() is the only writer of isOnline.value, and onConnectivityChanged.listen is registered BEFORE checkConnectivity().then(apply), so a stale false-negative future resolving after the stream's initial emission overwrites a correct value. Nothing corrects it afterwards — no lifecycle re-check, no success-based reset, checkConnectivity is never called again. The file's own comment says this exact pathology was observed in production and justified removing the gate from READS, yet _ensureOnline keeps it for writes. All six gated entry points sit under _write, which every mutating TourController method routes through (~35 call sites), so reads keep working on a healthy network while every write is refused and the optimistic edit is snapped back.

**Fix.** Make the gate self-healing: when isOnline.value is false, re-run Connectivity().checkConnectivity() and feed it through apply before refusing, and only refuse if it still reports none — or drop _ensureOnline entirely and let writes fail on a real socket error, matching the read path's documented policy. Throw a typed OfflineException mapped to a localized errors.offline key instead of concatenating raw English into '$failure $e'.

### 30. Seat chart polls availability every 20s with no in-flight guard and no timeout, so requests overlap and accumulate on 2G

`lib/screens/seat_selection_screen.dart:108` — est. 1h

**Impact.** Timer.periodic fires _refreshAvailability with no _refreshing flag, and SeatChartBookingService.availability is a bare rpc with no timeout — SyncService's cellular read-slot cap (max 2) and 28s budget wrap only SyncService's own methods, and this service reaches Supabase.instance.client directly. The repo's own measurements put an EDGE read at ~10.7s and justified a 28s budget, so whenever service time exceeds the 20s interval the in-flight count diverges instead of settling. The timer also fires while the initial _load is still awaiting, and there is no AppLifecycleState guard, so a backgrounded chart keeps polling. Costs latency, battery and the customer's data; no correctness impact since claims re-validate server-side.

**Fix.** Add a bool _refreshing guard so a tick returns immediately while a poll (or the initial _load) is in flight, put a .timeout() shorter than the interval (e.g. 15s) on SeatChartBookingService.availability, and pause the timer on AppLifecycleState.paused.

### 31. TourController's `ever(_sync.isOnline)` Worker is never disposed, leaving zombie refetch listeners on the permanent SyncService

`lib/controllers/tour_controller.dart:292` — est. 0.5h

**Impact.** ever() returns a Worker that must be manually disposed; onClose cancels only _realtimeSub and _refreshDebounce. SyncService is a permanent GetxService whose isOnline Rx is never closed, and TourController is lazyPut(fenix) under GetX's default SmartManagement.full, so it is deleted and rebuilt on every route teardown that owns it — logout, login, splash→home on every admin cold start, and every push-notification tap. Each cycle adds another live subscription. On the next offline→online edge, N zombies each run an independent 3-phase load (headers with retries, relations, per-bus layout prefetch) on the 2G link this app targets, and each surfaces its own 'showing cached' toast. No data corruption, but unbounded redundant traffic and retained memory within a session. The sibling worker in customer_memory_controller is safe (that controller is permanent).

**Fix.** Store the worker — `Worker? _onlineWorker = ever(_sync.isOnline, ...)` — and dispose it in onClose alongside the existing cleanup, matching the `Worker? _tabReentryWorker` pattern already used in requests_screen.dart.

### 32. _reloadToursWhenReady's poll never waits, so cold start force-builds TourController under the splash route and then throws it away

`lib/controllers/auth_controller.dart:183` — est. 1.5h

**Impact.** Get.isRegistered is true for an un-instantiated lazyPut (the correct test is isPrepared), so the 40x50ms wait is dead code and the loop always takes the branch on iteration 0. That constructs TourController while /splash is current, binding it to that route; Get.offAllNamed then disposes splash, deleting the instance and forcing a fresh one on the next find. The result is 2-3 redundant tour fetches contending for only 2 cellular read slots on cold start (invalidateCache is a no-op stub and fetchTourRows has no in-flight dedup), a transient empty/loading flash on the admin home, and a window where the mounted tree holds a closed instance whose realtime subscription was cancelled. No wrong data (_loadGeneration guards that).

**Fix.** Gate the poll on Get.isPrepared<TourController>() and only call refreshTours once it is false, so auth never constructs the controller under the splash route; correct the false doc comment at auth_controller.dart:173-176. Consider dropping the cold-start refresh entirely, since _bootstrapLoad already awaits whenRestored.

### 33. logout() is fragile at both ends — an unbounded first await can hang it, and a throw skips local teardown leaving a phantom-admin session

`lib/controllers/auth_controller.dart:449` — est. 1h

**Impact.** Two defects in one four-line method. (a) The first await is PushService.unregister(), which awaits getToken() and an untimed unregister_device_token RPC — on a stalled link the button does nothing forever and the deliberately-offline-capable local sign-out below it is unreachable. (b) adminAuth.signOut() is bare: gotrue always POSTs /logout even for local scope, and a transport failure becomes AuthRetryableFetchException, which the 401/403/404 whitelist rethrows. The single caller neither awaits nor catches, and the app has no global error handler, so the failure is invisible: _clearSessionLocally() and Get.offAllNamed('/splash') never run and the admin shell stays up with isLoggedIn true. The session is genuinely destroyed in memory and on disk beforehand, so there is no retained authorization — but the cold-start path sets isLoggedIn true before checking currentSession, so the phantom shell can survive a restart with RLS-denied reads.

**Fix.** Wrap the remote sign-out in try/catch (or move it after local teardown) so _clearSessionLocally and the navigation always run, and give unregister() a short timeout — or move it after the local teardown entirely. Separately, make _restoreSession treat 'persisted admin prefs but currentSession == null' as logged-out rather than setting isLoggedIn true at line 119.

### 34. Supabase session (access + refresh token) persisted in plaintext SharedPreferences/NSUserDefaults instead of the flutter_secure_storage the app already ships

`lib/main.dart:111` — est. 3h

**Impact.** Supabase.initialize is called with only url and anonKey, and nothing in lib/ overrides authOptions, so supabase_flutter installs SharedPreferencesLocalStorage and writes the full session JSON — access_token, refresh_token, user object — on every auth state change including each hourly refresh. On iOS that is a Library/Preferences plist included in Finder and iCloud device backups; Android is closed by allowBackup=false. flutter_secure_storage is a direct dependency used only by the biometric store, and pubspec's own comment claims it exists for session refresh tokens. docs/legal/PRIVACY_POLICY.md:62 tells users the session is in 'the platform's secure storage', which is currently false — a written-commitment mismatch as well as a hardening gap.

**Fix.** Pass authOptions: FlutterAuthClientOptions(localStorage: ...) with a LocalStorage adapter over FlutterSecureStorage(aOptions: encryptedSharedPreferences: true, iOptions: KeychainAccessibility.first_unlock_this_device) — this_device_only is what actually keeps the token out of restorable iOS backups — and migrate then delete the legacy sb-<ref>-auth-token key on first run. Correct the privacy policy, DESIGN_AGENT_BRIEF and the main.dart:83 comment.

### 35. Biometric store keeps the admin's real Supabase password in plaintext, gated only in Dart, with iOS keychain defaults that let it ride a device backup onto another handset

`lib/services/biometric_credential_store.dart:49` — est. 2h

**Impact.** enroll() writes the literal Supabase Auth password verbatim, and logout() never clears it, so it persists across logout by design. The single FlutterSecureStorage instantiation sets no IOSOptions, and the package default is kSecAttrAccessibleWhenUnlocked (not ...ThisDeviceOnly), so on iOS — a live target — the item is carried in encrypted backups and restores onto a different device. The biometric gate is a Dart boolean, so on a rooted device or a Frida-hooked repackaged build the value is one read away with no prompt. The secret chosen is the worst possible one: a non-expiring, non-revocable, non-device-scoped password for an account with financial authority, and sign-in is a bare signInWithPassword against a URL and key committed in the repo, so a recovered password authenticates by curl from anywhere.

**Fix.** Add `iOptions: const IOSOptions(accessibility: KeychainAccessibility.unlocked_this_device)` so the item is excluded from backups and cannot migrate handsets. Better, stop persisting the password: store the revocable refresh token and re-establish the session with it, and move to a plugin or platform channel that binds the key to a fresh biometric auth (kSecAccessControl / setUserAuthenticationRequired) rather than a Dart-side boolean.

### 36. WhatsApp send path logs passenger PII and a 7-day signed private-bucket URL to logcat in release builds

`lib/services/whatsapp_cloud_service.dart:211` — est. 1h

**Impact.** debugPrint logs to console even in release (Flutter's own doc says so) and nothing in this repo overrides it or wraps these calls in kDebugMode. The logged body is {'messages': chunk.map(toJson)} — up to 20 recipients per line, each carrying `to` (phone), bodyParams and headerImageUrl. Because 011 and 051 make seat-charts private, that URL is a genuine 7-day unauthenticated capability to a rendered page showing the whole bus's roster, not just one passenger. R8's isMinifyEnabled does not strip the engine's native logger. The vectors are ADB, adb bugreport, the system bug-report share flow and OEM diagnostics — so PII plus a remotely-usable bearer capability leave the device the moment a log does.

**Fix.** Wrap every debugPrint in whatsapp_cloud_service, whatsapp_outbound and requests_screen in `if (kDebugMode)` (matching push_service) and stop interpolating the payload at all — log chunk counts, template name and HTTP status only. Belt and braces: install a release no-op `debugPrint = (m, {wrapWidth}) {}` in main() under kReleaseMode, and fix the stale uploadSigned docstring that still claims seat-charts is public-read.

### 37. ErrorWidget.builder renders raw exception text and full stack traces on screen in release builds (unverified)

`lib/main.dart:43` — est. 0.25h

**Impact.** Unverified by adversarial review. The global ErrorWidget.builder is overridden unconditionally — no kDebugMode guard — to paint details.exceptionAsString() plus details.stack into a scrollable box, and the code labels itself 'DIAGNOSTIC (temporary)' while version 1.0.23+26 still ships it. Any build() that throws shows the user a PostgrestException's message, details, hint and Postgres error code, or a range/format error that can embed the offending passenger phone or name, plus internal class and method names. It is on screen to be screenshotted and shared.

**Fix.** Guard the override with `if (kDebugMode)` and, for release, substitute a plain localized 'Something went wrong' card. Report the FlutterErrorDetails through a logger rather than the UI.

### 38. unawaited markSeatsNotified rethrows into nothing and the recovery refresh reverts the stamps, so paid WhatsApp templates get sent twice (unverified)

`lib/screens/notify_screen.dart:613` — est. 1h

**Impact.** Unverified by adversarial review. markSeatsNotified is wrapped in unawaited() with no catchError. Internally it goes through TourController._write, whose catch calls refreshTours() — overwriting the optimistic seats_notified_sig patch — then rethrows into a void with no global error handler. The in-session UI still shows the riders as notified because _sentIds was set via setState. After the next app restart the Notify screen re-flags all of them as unnotified and the agent re-sends the paid WhatsApp Cloud template to the whole bus.

**Fix.** Await the call (or attach a catchError) and, on failure, roll _sentIds back and tell the agent the stamps did not save, so the seat-notified state on screen matches the server. Better: make _write preserve the optimistic patch when its recovery refresh did not actually re-sync (see rank 28).

### 39. profiles_select has no TO clause, exposing every admin's name, phone and role to anon (unverified)

`supabase/migrations/001_initial_schema.sql:142` — est. 0.5h

**Impact.** Unverified by adversarial review; grep confirms no other migration touches the profiles table or this policy. `FOR SELECT USING (true)` with no TO clause applies to every role including anon, and the on_auth_user_created trigger populates profiles with name, phone and role for every provisioned organiser. With only the anon key compiled into the shipped APK, GET /rest/v1/profiles?select=* returns a complete customer list for the product — plus each admin's auth.uid, which is the same value used as tours.owner_id and therefore the join key against any other anon-readable surface. It also defeats the stated rationale for admin_lookup_by_phone existing ('admins RLS hides every row from anon'). No Dart code reads profiles, so nothing would break by locking it down.

**Fix.** Replace with `for select to authenticated using (id = auth.uid())`, or drop the policy outright since nothing in lib/ queries profiles. Confirm against the live database first with `select policyname, roles, qual from pg_policies where tablename = 'profiles';`.

### 40. Fire-and-forget network hydration is issued from build() and inside Obx, and a failing hydrate re-fires on every rebuild with an unhandled async error

`lib/screens/manage_buses_screen.dart:220` — est. 1.5h

**Impact.** ensureTourReadyForSeating performs two network reads and is called unawaited directly inside build() here and inside the hero's Obx builder at trip_hero.dart:89. The idempotence memo only latches on SUCCESS (_hydratedTourIds.add is after the awaits) while _hydrationsInFlight is cleared in whenComplete, so a failed hydrate leaves no memo. Since the returned Future is neither awaited nor caught, each rejection is an unhandled zone error and every rebuild — including every coalesced realtime tours.refresh() burst — issues another fetch with no backoff, hammering the radio on exactly the 2G links this deferral scheme exists for.

**Fix.** Move the hydration out of build()/Obx into initState or a post-frame callback with a mounted guard, attach a catchError, and record a negative memo with backoff so a persistently failing tour is retried on an interval rather than on every rebuild.

### 41. setState after an awaited network write with no mounted guard in the seat-assignment auto-advance

`lib/screens/tour_seat_assignment_screen.dart:1256` — est. 1h

**Impact.** _placeBerths awaits _ctrl.assignSeats (a Supabase write with a 12s budget) and then calls setState with no mounted check anywhere in the method. flutter analyze cannot catch this — use_build_context_synchronously covers BuildContext, not setState — and the same file guards other paths, so this is an omission rather than house style. An agent who taps a seat on a slow link and immediately backs out gets 'setState() called after dispose()'; in release that lands in the overridden ErrorWidget.builder / error log. The same unguarded shape exists at seat_booking_confirm_screen.dart:533, customer_booking_request_screen.dart:172, tour_groups_screen.dart:149 and add_bus_screen.dart:471.

**Fix.** Add `if (!mounted) return;` after each await that precedes a setState in these five methods, and consider a small lint or review checklist item since the analyzer does not cover it.

### 42. Contact picker spins forever on a platform exception — unawaited _load() with no catch and no error state (unverified)

`lib/widgets/booking_capture_form.dart:1504` — est. 0.5h

**Impact.** Unverified by adversarial review. _load() is called fire-and-forget from initState with no try/catch and awaits ContactSyncService.pullDeviceContacts()/hasPermission(), neither of which catches anything — both wrap FlutterContacts platform-channel calls that raise PlatformException/MissingPluginException. If either throws, the setState that clears _loading is never reached, _loading stays at its initial true, and build returns the spinner branch forever. The _denied fallback is unreachable and, with no PlatformDispatcher.onError, the exception is never reported. On an OEM ROM whose contacts provider errors, the agent can never use contact autofill and gets no explanation.

**Fix.** Wrap _load()'s body in try/catch, set _loading = false plus an error flag in the catch, and render a retry/permission message. Also catch inside ContactSyncService so a platform failure degrades to an empty list rather than propagating.


## LOW (12)

### 43. My Requests refresh is an unbounded, untimed sequential sweep with no staleness surface

`lib/services/customer_requests_store.dart:654` — est. 2h

**Impact.** refreshAll() is a strictly sequential await loop with no timeout on any RPC, bypassing SyncService's 12s/28s read budgets, so one stalled socket pins the pull-to-refresh spinner for the OS TCP timeout. Failures are unsurfaced: lastRefreshedAt is written but read by no widget, and _loadFailed requires the list to be empty, so a customer with tickets sees nothing even if every row failed. CustomerRequestsStore.remove has no caller anywhere in lib/, so the journal is never pruned and the sweep burns round trips on tours that departed months ago and are filtered out of the UI. The list stays rendered and interactive throughout, so the harm is a pinned spinner and lost observability, not blocked interaction.

**Fix.** Skip isPast entries, run the remainder in bounded-concurrency batches (Future.wait over chunks of 4), and wrap each RPC in a .timeout() matching SyncService's cellular budget. Return a failed-row count so the screen can surface 'couldn't confirm N tickets' and render the already-stored lastRefreshedAt.

### 44. Cached tickets and money figures render as authoritative with no staleness signal; lastRefreshedAt is write-only

`lib/screens/customer_my_requests_screen.dart:121` — est. 3h

**Impact.** lastRefreshedAt is stamped in seven places and read by no widget (the only non-write reference in the repo is a test assertion). refreshAll swallows per-row failures and returns the on-disk list, so a total network failure is indistinguishable from a clean refresh. Every error surface is gated on the list being EMPTY — _loadFailed = fresh.isEmpty && offline here, and the same shape in tour_money_board, bus_money, collection and trip_pnl screens — so with even one cached row present a fully-failed refresh produces no banner, no chip and no timestamp. There is no offline banner anywhere in lib/ and no 'last updated' string in the catalogues. Self-heals on the next good refresh, and the handler chart's own pull-to-refresh already shows a stale-aware toast.

**Fix.** Have refreshAll return a per-row failure count instead of catch (_), drop the isEmpty gate, and render a persistent 'last updated {relative}' line from the stored lastRefreshedAt plus a stale/offline chip when rows failed. Apply the same non-blocking stale badge to the money surfaces.

### 45. Dashboard hero's _moneyLoadedFor memo never invalidates, so the hero's money panel blanks for the rest of the session

`lib/widgets/dashboard/trip_hero.dart:89` — est. 1h

**Impact.** The dashboard is IndexedStack tab 0 so its State survives the session, and _moneyLoadedFor resets only when the hero tour id changes. MoneyController._loadedTourId moves the moment any other tour's money surface is opened — reachable in one tap from the dashboard's own attention list — and the hero's Obx is subscribed to the money lists that a tour switch clears, so it rebuilds into the loadedTourId != tour.id branch and stays there. Fail-safe (never shows the wrong tour's numbers) and partially redundant: the attention row still shows 'Settle ₹X'. The uncompensated loss is the hero's entire P&L lower panel rendering '—' for locked and departed tours plus a degraded urgency ranking, persisting until a trip-picker round trip or a restart.

**Fix.** Stop making the hero depend on which tour the shared controller happens to hold: read a per-tour value (money.outstandingHandoverFor(tour.id), or a per-tour cached TourMoneySummary alongside settlementByTour). If the memo is kept, only invalidate on drift while the dashboard is the visible route — an unconditional drift-reload would let the offscreen hero steal the slot and repaint an open money board with the wrong tour's figures.

### 46. Chart quote sums unrounded per-seat fares while the ledger sums per-seat rounded fares

`lib/screens/seat_selection_screen.dart:326` — est. 0.5h

**Impact.** _total is Σ(unrounded per-seat) while Bus.amountDueForSeat and migration 070's baseline_seat_due_paise are Σ(round(per-seat)); rounding a sum is not summing rounded parts. Reachable via one-way legs (tripFactor 0.5) on odd rupee prices, which add_bus accepts unvalidated — a ₹999 seat, Go-only, two berths on two seats quotes ₹999 and bills ₹1,000. Bounded at ₹0.5 per seat with _maxSeats = 6, so at most ~₹3, and no money moves incorrectly in any app-reachable configuration (the perBerth == 0 branch that would turn this into a real payment mismatch cannot be produced by the UI). The doc comment above _total claiming it 'uses the SAME function the organiser bills from' is inaccurate — it calls berthPriceFor, not amountDueForSeat.

**Fix.** Round each distinct seat's due before summing (`sum += (bus.berthPriceFor(...) * berths * Bus.tripFactor(_leg)).roundToDouble();`), ideally by extracting that per-seat expression into a shared Bus helper both the quote and the bill call. Separately delete or assert-out the dead perBerth == 0 branch in _advancePaise.

### 47. Confirm-screen summary card omits every bus after the first on a split checkout

`lib/screens/seat_booking_confirm_screen.dart:642` — est. 1h

**Impact.** _soleBus/_solePicks are correctly guarded in _confirm (behind the isMultiBus early return) but used unguarded in _summary, which build renders unconditionally with no multi-bus branch. Since _berths folds all selections and totalRupees is the cross-bus total, the card shows a visible contradiction: 'Confirm 5' above a three-seat list. Reachable both via autoPick's automatic split when no single bus fits and via manual picking across bus tabs (which deliberately preserve the basket). Display-only: the claim itself is atomic across buses, and ChartSummaryBar on the immediately preceding screen already names both buses in its headline, so the customer was told about the split.

**Fix.** Iterate widget.selections in _summary, emitting a bus-name line plus its own seat list per selection (single-bus output stays byte-identical), and add a widget test asserting both bus names and all seat ids appear when selections.length > 1.

### 48. Bus.totalSeats (physical, includes reserved) and busBerths().sellable are both used as occupancy denominators, so a bus with held-back seats can never read "full"

`lib/screens/tour_detail_screen.dart:1983` — est. 2h

**Impact.** BusLayout.totalSeats counts every cell with no reserved check, while busBerths() splits reserved out of sellable. The seating engine never fills a reserved cell, so occupiedBerthsFor tops out at sellable while the bar compares it against bus.totalSeats: on a bus with any held berth the progress bar never reaches 100%, the occupancy chip never flips to good, and it reads '70/74 filled' while the seats cockpit next door reads 70/70 and the bus is genuinely sold out. Same for the fleet-filled %, the sticky CTA and the hero vitals. No sell-side or money consequence — every path that could oversell a held berth already excludes reserved — and charts_screen deliberately reports the physical size.

**Fix.** Route every occupancy denominator through busBerths().sellable — tour_detail_screen:1843/1983-2053/2441/2601, tours_screen:350 and Tour.biggestBusSeats — while leaving the deliberately-physical readouts (charts_screen:232, the customer 'N seats' chip) as sellable + reserved, documented on Bus.totalSeats. Also switch _BusRow's `total` and the `total > 0` snapshot gate in tour_overview_screen to sellable so the status dot and the meter cannot disagree.

### 49. Biometric unlock deletes the stored credential on any transient network or 5xx failure, and mislabels it "password incorrect"

`lib/controllers/auth_controller.dart:346` — est. 0.5h

**Impact.** gotrue wraps every transport failure and any 5xx into AuthRetryableFetchException, which extends AuthException — so `on AuthException catch (_)` treats offline, DNS failure, timeout, a gateway blip and a 429 exactly like a rejected password: it calls biometric.clear() and destroys the hardware-backed secret. A brief Supabase outage wipes the credential on every device whose owner taps fingerprint during the window. Re-enrolment is possible via Settings, but the one-time enroll prompt is permanently latched off (auth_biometric_offered), so it is not self-healing. The message shown actively misinforms an admin about their account password and could send them down a needless reset. No lockout, no data loss, no security exposure.

**Fix.** Add an `on AuthRetryableFetchException` clause (and treat any AuthException with a null or >= 500 statusCode the same) ahead of the existing catch, routing it to the connection-error snackbar without clearing. Reserve clear-and-fall-back for a genuine 4xx invalid_credentials. Apply the same discrimination in verifyAdminPassword:302, ideally via a shared helper next to sync_retry_policy.dart.

### 50. PushService.init() latches _initialised before its platform setup, so one throw permanently drops the tap-to-deep-link subscription

`lib/services/push_service.dart:82` — est. 0.5h

**Impact.** _initialised = true is set before four awaits, and the FirebaseMessaging.onMessage/onMessageOpenedApp subscriptions land after them; dispose() (the only reset) has no caller. Both entry points then no-op forever. The pure-Dart onMessageOpenedApp listener would work even when the local-notifications plugin is broken, so a throw from createNotificationChannel on an unusual OEM ROM permanently kills tap-to-deep-link (Requests tab / inbox route) for the process. Narrower than it looks: the named trigger (@mipmap/ic_launcher) is valid, setForegroundNotificationPresentationOptions cannot throw on Android, and background/killed-state pushes still render in the tray with no Dart listener involved.

**Fix.** Wrap only the fragile platform-setup awaits (channel creation, _local.initialize, presentation options) in their own try/catch so the pure-Dart subscriptions at lines 109-111 always get wired. Do NOT simply move the latch to the end of init() — that would rethrow into register()'s catch and skip FCM token registration, losing all pushes instead of just the deep link.

### 51. manage_buses.layout_locked_title/body exist only in English, and Gujarati is the app's default locale (unverified)

`assets/translations/gu.json:1` — est. 0.25h

**Impact.** Unverified by adversarial review, but confirmed by direct grep: both keys appear twice in en.json and zero times in gu.json and hi.json, while tour_controller.dart:2673-2739 uses them in three AppSnackBar.info calls. These are the only two genuine cross-locale gaps in a 2,502-key catalogue. Since i18n_config pins startLocale AND fallbackLocale to gu, the most likely reader of this snackbar sees the raw key or an English string. It went unnoticed because the test harness emits 2,823 'Localization key not found' warnings, 355 of whose 356 distinct keys actually exist — so a real gap is indistinguishable from the noise.

**Fix.** Add manage_buses.layout_locked_title and layout_locked_body to gu.json and hi.json. Separately, load a locale in the widget-test harness so the warning stream stops being noise and a missing key becomes a visible signal.

### 52. recoverBusLayout never varies seaterCount, so a mixed bus with seaters cannot be recovered by the controller path

`lib/utils/bus_layout_recovery.dart:64` — est. 1h

**Impact.** seaterCount is a fixed parameter defaulting to 0, not a search dimension, so for BusType.mixed no candidate layout ever generates an ST id and recovery returns false with every seater seat listed as unmatched (reproduced empirically; passing seaterCount: 12 recovers the same bus). Contradicts the doc's claim of 'generating every layout the bus could plausibly have had'. Impact is minimal in practice: the app can no longer create a mixed bus (add_bus hardcodes BusType.sleeper since commit 3c81b1e), reaching BusType.mixed needs a legacy English-locale row storing exactly 'Mixed', and recoverBusLayoutFor has no invocation path at all — no screen, no debug tool, no script calls it. Fails safe (refuses rather than inventing a grid) and names the unmatched ids.

**Fix.** When busType == BusType.mixed, nest an outer `for (var seaters = 0; seaters <= totalSeats; seaters++)` around the existing loops (cheap for a 40-berth bus). If mixed is to stay unsupported, return early with a reason naming seaterCount as an input the tool cannot infer, so the report never reads as inconsistent data.

### 53. No route guards anywhere, and a dead verifyOtp branch navigates straight to the admin shell (unverified)

`lib/routes/app_routes.dart:40` — est. 1h

**Impact.** Unverified by adversarial review. All 18 GetPage entries declare no middleware and MainShell performs no isAdmin/isLoggedIn check, so every admin surface is reachable purely by route name — the only thing keeping an unauthenticated user out is splash_screen choosing the destination. auth_controller.dart:316-322 is a live example of that assumption failing: verifyOtp() falls through to Get.offAllNamed('/') with no credential check. It currently has no caller, and the OTP naming is vestigial (there is no OTP in this app), which makes the dead branch easy to mistake for a working path when wiring a deep link, app shortcut or push payload.

**Fix.** Add an auth middleware to the admin GetPage entries (redirect to /login when !isLoggedIn || !isAdmin) and delete the vestigial sendOtp/verifyOtp pair, which has no caller and no OTP behind it.

### 54. admin_lookup_by_phone is an anon-callable account-enumeration and admin-PII oracle (unverified)

`supabase/migrations/002_admin_lookup_normalize.sql:31` — est. 1h

**Impact.** Unverified by adversarial review. The function is SECURITY DEFINER, granted to anon, and returns id, phone and name for any matching admins row, with no rate limit (the repo's only limiter was dropped by 013). It legitimately must be anon-reachable — it runs before authentication — but returning the name and auth uuid rather than a bare boolean turns it into an oracle: scripting it across a number range with the committed publishable key enumerates valid accounts for password guessing against the synthetic-email sign-in and discloses each operator's real identity, which the login screen then renders pre-authentication.

**Fix.** Return only what the login flow needs — a boolean or the id — and move the display name behind successful authentication; add a per-IP/per-phone rate limit on the function.


## Cross-cutting themes

- ONE FARE, MANY FORMULAS — AND ONE OF THEM IS MISSING A COLUMN. Migrations 069/070 consolidated the server-side fare and posting rules, but the Dart layer was never brought along: Collection has no amount_online field at all, finance_bus_summary's bank leg has no reader, and the chart quote sums unrounded per-seat fares while the ledger sums rounded ones. Every money surface should read one named basis (cash-in-hand vs accrual vs bank) through one accessor rather than each screen folding raw rows. Ranks 3, 5, 21, 22, 46.

- SEAT IDENTITY IS NOT NORMALISED CONSISTENTLY. The (passenger, bus, seat) triple, the '#n' berth suffix, and the reserved flag are each handled correctly in some code paths and ignored in others — collectionRowForSeat exists and is never called, CollectionReconciler dedups on the raw suffixed id, capacity engines disagree about whether a reserved-but-occupied cell counts. A single seat-identity module that every money and capacity path must go through would close ranks 2, 21, 24 and 48 at once.

- THE SEAT-HOLD LIFECYCLE WAS DESIGNED AND THEN LEFT HALF-WIRED. 064 built holds, 068 built party holds and chart_finalize_party_holds, and 069 then rebased confirm_payment_claim off 060 and silently deleted the finalize step. The party function has zero callers, the TTL is never extended when money arrives, and the only surviving finalize path is a per-hold 'Pay later' button that cannot see party siblings. The whole advance-collecting flow needs an end-to-end trace and an integration test, not four independent patches. Ranks 1, 6, 7, 8, 17.

- MIGRATIONS ARE REBASED, NOT DIFFED — AND NOTHING TESTS SQL. 069's header says 'identical to 060's version except…', which is how 064's block vanished. There is no pgTAP or SQL test harness at all, so RPC-body regressions, RLS policy drift and grant mistakes are invisible to CI. Several policies from 009/011 were never dropped despite later migrations claiming to harden them. Ranks 1, 11, 12, 14, 17, 39.

- ANON IS A PRIVILEGED ROLE HERE AND ITS SURFACE WAS NEVER INVENTORIED. The publishable key ships in the APK (correctly), but the boundary that key runs against has holes: a phone number is a write credential for handler money, a storage policy makes a 'private' roster bucket listable, profiles is world-readable, and audit_log is readable across tenants. What is needed is a single audit of every policy and every `grant … to anon`, not four separate patches. Ranks 11, 12, 13, 14, 39, 54.

- NETWORK CALLS HAVE NO DEADLINE UNLESS THEY GO THROUGH SyncService. Supabase.initialize passes no httpClient, so ~37 direct call sites across 12 files await unbounded sockets — and the surfaces most exposed to bad signal (the handler chart, the customer store, Finance, pickup) are exactly the ones that bypass the bounded harness. Compounding it, the one retry classifier that does exist misses the transport exception package:http actually throws. A single custom http.Client plus routing the high-stakes RPCs through _withTimeout/_withRetry fixes a whole class. Ranks 15, 16, 30, 33, 43.

- OPTIMISTIC WRITES HAVE NO ROLLBACK AND RETRIES HAVE NO IDEMPOTENCY KEY. _write mutates first and depends on a network refresh to undo itself; handler sheets mint a fresh UUID per save attempt; booking submits journal the ticket only after the response arrives. The offline write queue was deliberately removed, which is defensible — but nothing replaced the invariants it provided. Ranks 4, 26, 27, 28, 38.

- SHARED SINGLETON CONTROLLERS HOLD ONE TOUR'S STATE WHILE MANY SCREENS READ THEM. MoneyController is process-wide and holds exactly one tour, yet several money widgets read tourSummary() with no loadedTourId check (trip_hero already does it correctly). Combined with GetX's SmartManagement.full delete/recreate cycle and an undisposed Worker, the app has genuine instance-identity hazards. Make tour-scoped reads take a tourId and return null on mismatch. Ranks 10, 31, 32, 45.

- ERRORS ARE SWALLOWED OR MISCLASSIFIED AT THE BOUNDARY. There is no FlutterError.onError, no PlatformDispatcher.onError, no runZonedGuarded and no crash reporter anywhere in lib/ — so unawaited rethrows vanish, a transient auth failure is treated as a wrong password, and a shipped diagnostic ErrorWidget prints raw stack traces to users instead. Ranks 37, 38, 40, 41, 42, 49, 50.

- STALENESS IS TRACKED BUT NEVER SHOWN. lastRefreshedAt is stamped in seven places and read by no widget, and every money/ticket screen gates its error state on the list being EMPTY, so a fully-failed refresh is pixel-identical to a fresh one. In a cash-reconciliation app used on 2G, 'these numbers are 40 minutes old' is load-bearing information. Ranks 43, 44, 45.


## Refuted — do not re-raise

- Sheet-local TextEditingControllers in collection_screen.dart (lines 306/309/310), bus_money_screen.dart:474, add_bus_screen.dart:1844 and tour_groups_screen.dart:180 are created per sheet-open and never disposed — REFUTED as a memory leak. They are method locals referenced only by the modal route's closures and the async frame; when the sheet pops both die and the objects are garbage collected. TextEditingController is a pure-Dart ValueNotifier with no platform handle or global registry, EditableTextState.dispose() removes its own listener during teardown, and the project has no leak_tracker configuration that could observe it. Adding dispose() would be cosmetic consistency, not a fix.

- 'Fixing _total's rounding prevents a real UPI mispayment' — REFUTED. _advancePaise only reads totalRupees when advancePerBerthPaise == 0, and the only writer (booking_settings_sheet.dart:90-96) converts any value <= 0 to NULL, which makes collectsAdvance false and shows no advance sheet at all. With perBerth > 0 the UPI amount is exact integer paise. Also, every render of _total goes through Formatters.formatMoneyInr which rounds, so the customer never sees a fractional quote.

- 'The same-bus seat-move gate makes the money board and the handler's collect sheet show a repriced rider as square' — REFUTED. 062's passengers_ledger_sync trigger re-prices revenue.fare/ar.rider per bus from live seating on any assigned_seats change, so summaryForBus is correct without client help; handler_bus_chart_screen.dart:664 and collection_screen.dart:98 both compute due live via amountDueForSeat and deliberately ignore the stored snapshot. The real loss is the missing SeatMoveMoneyNotice prompt and a stale collections.amount_due aggregate.

- 'chart_claim_seats ignoring holds causes a double-booking' — REFUTED. chart_finalize_hold re-validates against passengers and raises 'Seat % no longer free', so two passengers never land on the same berth. The harm is the broken hold guarantee and the organiser being unable to record an already-paid advance.

- 'Bus.totalSeats divergence lets an oversized group be accepted, and charts_screen reads the wrong denominator' — REFUTED. Tour.largestBusSeats does not exist (the real symbol is biggestBusSeats, used only as a soft blocking warning on group creation), and charts_screen.dart:231 deliberately computes sellable + reserved with a comment explaining it wants the PHYSICAL size. The 'reads /0 forever' scenario also requires a non-null but empty grid, which no client path produces, and migration 065 guards the null case that actually occurred in production.

- 'PushService's latch is tripped by an invalid @mipmap/ic_launcher icon and kills all foreground notifications' — REFUTED. The mipmap resource exists in all density buckets and flutter_local_notifications resolves the explicit mipmap/ type correctly; setForegroundNotificationPresentationOptions early-returns on Android and cannot throw; and background/killed-state pushes still render from the notification payload with no Dart listener. Also note the obvious fix is wrong: moving the latch below the awaits would rethrow into register() and skip FCM token registration entirely.

- 'The 2,823 Localization-key-not-found warnings in the test suite indicate missing translations' — REFUTED. 355 of the 356 distinct warned keys exist in all three catalogues; the warnings only prove the widget-test harness never loads a locale. The one true gap is manage_buses.layout_locked_title/body (ranked separately), and requests.chip.seats_unit is a complete plural node seen through plural().

- 'Supabase.ping() is the login screen's reachability probe, so a hang there blocks login' — REFUTED. ping() has zero callers in lib/ or test/; login_screen calls AuthController.prepareLoginScreen()/submitPhone(). It is dead code with a stale doc comment.

- 'The committed sb_publishable_... anon key in lib/config/supabase_config.dart is a leaked secret' — REFUTED. It is a Supabase publishable key, designed to ship in clients and carrying no privilege beyond the anon role; the security boundary is RLS. The real issue is the absence of environment indirection (no staging target, rotation requires a store release), which is a structural/process concern rather than a leak.

- 'The app hashes admin passwords client-side with crypto/SHA-256 and gets the salt wrong' — REFUTED. package:crypto is declared in pubspec with an aspirational comment but is imported nowhere in lib/ or test/. Authentication is a plain signInWithPassword over TLS with server-side bcrypt, which is correct. The only plaintext password at rest is the biometric store (ranked separately).

- 'The offline write queue / pendingEntityIdsForTable is a broken safety mechanism' — REFUTED as a bug. The queue removal is a deliberate, documented architectural decision (sync_service.dart:175-177 and the offline design spec); pendingEntityIdsForTable is vestigial dead code, not a guard that stopped working. The genuine defect is the missing rollback in _write (ranked separately).

- 'Writes are blocked during the cold-start window before checkConnectivity() resolves' — REFUTED. isOnline is initialised to TRUE, so writes are permitted during that window; the finding inverted its own polarity. The live trigger is the narrower listener-vs-future ordering race that leaves the flag stuck false with no self-correction.

- 'One dropped packet blanks the tour list because reads are not retried' — REFUTED. postgrest 2.8.0 retries GET/HEAD up to 4 attempts on Exception with retryEnabled defaulting to true, and fetchTourRows is a GET. The uncovered band is writes (POST/PATCH/DELETE/RPC), which postgrest explicitly excludes.

- 'The lost UPI claim destroys the only record that money moved, and the handler reads payment_claims' — REFUTED on both counts. By design the authoritative trace is the organiser's bank statement (the claim is an unverified assertion requiring human reconciliation), and the handler app never reads claims at all — handler_payment_claims has zero Dart callers and HandlerManifest has no claim field. What reaches the handler is the collections row written after the agent confirms.

- 'A cross-tenant seat-chart write lets an attacker substitute the image a customer receives' — REFUTED. whatsapp_outbound re-uploads with upsert:true immediately before minting the signed URL in the same call, and Meta fetches media once at send time. The real impacts of the storage policies are roster exfiltration and cross-tenant delete/overwrite.


## Coverage gaps

- NO LIVE DATABASE. Every SQL finding is read from supabase/migrations/*.sql, and this repo states repeatedly that the live schema has diverged: 051 says 'the remote migration history is empty' and must be run file-by-file in the SQL editor; 055 and 061 patch live function bodies via pg_get_functiondef because 'the live definitions have diverged from the files before'; 043 documents a production policy that contradicted its migration's intent; handler_bus_chart_screen.dart:161 carries a comment warning that handler_tour_manifest has drifted; and MEMORY notes two RPCs (bus_layouts_for_request, booking_request_status_lookup) that exist ONLY live and are in no migration file. There are also duplicate migration numbers (004, 006, 045, 058). Before acting, confirm each SQL finding with one query: `select prosrc from pg_proc where proname in ('confirm_payment_claim','chart_claim_seats','claim_upi_advance_for_hold');` and `select policyname, roles, cmd, qual from pg_policies where tablename in ('audit_log','profiles','objects');`.

- NO DEVICE AND NO REAL RADIO. Every latency, hang, overlap and backlog claim is reasoned from source plus the pinned dependency behaviour in the pub cache (http 1.6.0, postgrest 2.8.0, supabase 2.14.0, gotrue 2.26.0, get 4.7.3, flutter_secure_storage 9.2.4), not measured. The 2G scenarios rest on the repo's own recorded EDGE measurement (~10.7s read payload) rather than a fresh one. iOS was audited only from Info.plist, entitlements and package defaults — no iOS build was produced, so the keychain-accessibility and backup claims are from documented API defaults.

- NO STORE ACCESS AND NO SUPABASE DASHBOARD. Could not check whether project-level email signup is open (which decides whether the audit_log and storage findings need a provisioned account or not), JWT expiry, refresh-token rotation/reuse-detection settings, /token rate limits, or the Edge Function secrets. supabase/functions/ (bus-message, quick-action, send-push, wa-reply, wa-webhook) was NOT audited for its own authorization — only confirmed that the WhatsApp token correctly lives there and not in the client.

- A CONCURRENT AGENT WAS EDITING THIS CHECKOUT THROUGHOUT. HEAD moved mid-audit (7a676c7 → f6e4df6) and 34 files were modified-uncommitted. lib/utils/collection_seat_resolver.dart is untracked and handler_bus_chart_screen.dart is dirty, so rank 2 looks like that agent's half-finished wiring rather than shipped code — its 15 pure unit tests pass while the screen-level wiring test fails. All quoted lines were re-read at the end of each sweep, but any of them may have moved since. Two sweeps declined to run flutter analyze or flutter test for exactly this reason, so a few findings rest on reading alone.

- THE ONE RED TEST IS FOREIGN WORK. `flutter test` = 1312 passed, 1 failed, run twice with identical results. The single failure (test/screens/handler_bus_chart_screen_test.dart, 'a moved rider re-opens their EXISTING collection') is on an ADDED line in the uncommitted diff — it is the other agent's in-flight change, and it is the evidence for rank 2, not an unrelated breakage.

- NO TEST CAN SEE THE WIRE. No test in the suite executes a real .select()/.rpc() string — every service test injects rows behind a debug hook or a fake SyncService. So column renames, RPC parameter renames (p_hold_id, p_buses, p_leg), RLS denials and the amount_online omission (rank 3) are all structurally unobservable to CI. There is likewise no SQL/pgTAP harness, so nothing tests a migration.

- LARGE MODULES SAMPLED, NOT READ. lib/services/seating_engine.dart (1946 lines), swap_candidate_finder.dart, seat_drop_engine.dart, seat_fit.dart, group_cascade.dart and seat_chart_pdf.dart were only read at their call sites — engine-internal placement bugs are out of scope for this register. handler_bus_chart_screen.dart (3910 lines) and tour_controller.dart (3607 lines) were read in the load/write/money/seat regions only. lib/design/ (32% test-imported) and lib/widgets/ (27%) were spot-checked.

- KNOWN HOLE FOUND BUT NOT REPORTED FOR LACK OF A CONCRETE FAILURE: the admin/agent seat-assignment path has no knowledge of seat_holds at all — grep for seat_holds in lib/ hits only MoneyController's read-only list — so an organiser can seat someone onto a berth a customer currently holds, surfacing later as chart_finalize_hold raising 'Seat X no longer free'. Worth a deliberate design decision rather than a bug fix.

- TEST-SUITE HYGIENE ITEMS RECORDED HERE RATHER THAN AS DEFECTS: test/widget_test.dart:12 is the untouched scaffold placeholder asserting expect(true, true); test/design/responsive_scale_test.dart:276 runs ~26 pump cycles and only prints a table with zero expect() calls, so a total freeze of responsive scaling would still pass it; lib/services/seat_swap_guard.dart (the leg-overbooking gate on every seat swap, whose _capOf silently returns 1 for a seat missing from the layout grid) has no test file at all; lib/app.dart and lib/main.dart are imported by no test. Nothing in the suite forces isOnline false, and no test invokes any mutating MoneyController method.

- NOT ASSESSABLE STATICALLY: translation QUALITY in Gujarati and Hindi (only script presence, placeholder-token parity and identity-with-English were checked); whether the remote translation overlay (remote_translation_loader deep-merges a CDN delta over the bundled catalogue) is already patching the two missing manage_buses keys in production; and the real distribution of '#'-suffixed seat ids in live data, which is why rank 21 is marked unverified.
