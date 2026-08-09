# S1 · The ledger becomes the single truth — design

**Date:** 2026-08-09
**Branch:** `feat/money-collection-settlement`
**Supersedes the open findings in:** [`docs/2026-08-09-money-ledger-audit.md`](../../2026-08-09-money-ledger-audit.md)

---

## Why this exists

The user asked for three things: automatic refunds without a payment gateway, a
UPI rail whose data can be trusted, and a clear answer to *"what happens to the
money when I move a rider onto a different bus at a different price, and where do
I see it?"*

All three compute from the same numbers. Those numbers are currently wrong in
ways that are documented and, in most cases, already fixed but not yet deployed.
Shipping a refund feature on top would refund the wrong amounts.

So this spec is the foundation, and it delivers **no new user-facing feature**.
Its entire output is *the money figures stop being wrong, and every screen says
which basis it is using*. S2 and S3 (below) are the visible work and depend on it.

---

## What changed since the audit was written

The audit doc is stale against the working tree. Verified state at the time of
writing:

| Finding | Status | Evidence |
|---|---|---|
| **C1** confirmed UPI advance credited twice | Written, **not applied** | [`069_online_payment_single_post.sql`](../../../supabase/migrations/069_online_payment_single_post.sql) |
| **C2 / D1–D4** three independent fare formulas | Written, **not applied** | [`070_one_fare_formula.sql`](../../../supabase/migrations/070_one_fare_formula.sql) |
| **H1** cancelled rider's fare never reversed | Written, **not applied** | 069 §5 `finance_repair_cancelled_fares()` |
| **F1** rider AR dumped on `assignedSeats.first.busId` | Fixed, uncommitted | [`money_controller.dart:964`](../../../lib/controllers/money_controller.dart#L964) `_arShareByBus` |
| **E1** orphan-bus money dropped from trip total | Fixed, uncommitted | [`money_controller.dart:1017`](../../../lib/controllers/money_controller.dart#L1017) |
| **E2** empty ledger hard-zeroes every money screen | Fixed, uncommitted | [`money_controller.dart:919`](../../../lib/controllers/money_controller.dart#L919) |
| **A1** no *ledger unavailable* state | Fixed, uncommitted | [`finance_controller.dart:44`](../../../lib/controllers/finance_controller.dart#L44) `ledgerEmpty` |
| **A2** Finance "revenue" is cash, unlabelled | Fixed, uncommitted | [`finance_screen.dart:356`](../../../lib/screens/finance_screen.dart#L356) `finance.basis_note` |
| **G1** dead advance helpers | Closed | [`money_controller.dart:357`](../../../lib/controllers/money_controller.dart#L357) — deliberately removed |
| **A3** rent missing from ledger for pre-062 buses | **Open** — operational | 058 §3f never run |
| **B1** four bottom lines, three still unlabelled | **Open** | Trip P&L, tour money board, bus money |

These two migrations have been renumbered twice mid-session by the concurrent
agent working in the same checkout — first 065/066 → 067/068 to clear a
collision with `065_protect_bus_layout.sql` / `066_customer_memory.sql`, then
067/068 → **069/070** to clear a second collision with
`067_chart_hold_status_lookup.sql`. Any instruction that says 065/066 or 067/068
for these two means **069 and 070**. Confirm the filenames on disk before
applying anything — `ls supabase/migrations/ | tail`.

**Net: S1 is a deploy-and-prove job plus two small gaps, not a rewrite.**

---

## Part A · Deploy and prove

Operational, run by hand in the Supabase SQL editor, one file at a time — the
established process on this project. Nothing here is automated, and no step
rewrites history on its own: both repairs report by default and only mutate when
passed `true`.

**Order is load-bearing.** 069 must precede 070: 069 adds
`collections.amount_online` and makes the collections trigger the single ledger
poster, and 070's `finance_resync_all_fares()` re-posts fares through that
trigger path. Running 070 first re-prices against a double-posting trigger.

1. Apply [`069_online_payment_single_post.sql`](../../../supabase/migrations/069_online_payment_single_post.sql).
2. Apply [`070_one_fare_formula.sql`](../../../supabase/migrations/070_one_fare_formula.sql).
3. Report, then repair, in this order:
   ```sql
   select * from public.finance_repair_online_double_post();      -- C1, dry run
   select * from public.finance_repair_online_double_post(true);
   select * from public.finance_repair_cancelled_fares();         -- H1, dry run
   select * from public.finance_repair_cancelled_fares(true);
   select * from public.finance_resync_all_fares();               -- C2 re-price
   ```
4. **A3 — rent.** `select * from public.backfill_finance_ledger();`
   Section 3f posts `expense.rent` / `payable.owner` for every bus carrying a
   `bus_price`. It is idempotent: `backfill_post` keys on
   `'backfill:rent:' || bus_id`, so a re-run posts nothing for buses already
   covered. Run per tour (`backfill_finance_ledger('<tour id>')`) if a
   whole-history run is too large in one transaction.

**Acceptance gate.** Every check in
[`supabase/diagnostics/finance_audit_checks.sql`](../../../supabase/diagnostics/finance_audit_checks.sql),
run one block at a time:

| Check | Must return |
|---|---|
| 1 · ledger deployed | tables and views present |
| 2 · 062 triggers live | all triggers present |
| 3 · what is in the ledger | informational — read it, nothing to assert |
| 4 · ledger vs legacy per tour | every `*_delta` = 0 |
| 5 · online advance double-count | **zero rows** |
| 6 · bus rent missing | **zero rows** |
| 7 · fare formula divergence | **zero rows** |
| 8 · money on off-tour buses | rows allowed — must match what the UI shows as orphan money, not vanish |
| 9 · `trip_type` contradicts request lines | rows still allowed; 070 makes them stop affecting price |
| 10 · `#`-suffixed seat ids | rows allowed; 070 makes them price correctly |

Checks 9 and 10 are *data untidiness*, not defects, and are expected to keep
returning rows. The point of 070 is that they no longer change what anyone is
charged. Recording that explicitly here so a future reader does not chase them.

### Risk and rollback

The ledger is append-only by design (056 §6), so every correction in Part A is a
reversing entry, never an edit. Rollback is therefore *another* reversal, not a
restore — which is why both repairs report before they apply. If check 4's
deltas do not reach 0 after the sequence, **stop and diagnose rather than
re-running repairs**: a second `finance_repair_online_double_post(true)` is
guarded by a `not exists (… reverses_entry_id …)` clause and will no-op, so a
non-zero delta after one run means something outside C1's shape.

---

## Part B · Every bottom line names its basis (B1)

Four screens headline a "net" and each computes it differently. Individually
defensible; side by side, with nothing naming the basis, any two look broken.

| Screen | Headline | Basis | Now reads |
|---|---|---|---|
| Finance (cross-tour) | `FinanceTotals.net` | **cash** | `money.basis_cash` caption |
| Trip P&L hero | `totalNetBilled` | **billed** | `money.basis_billed` caption |
| Tour money board · P&L card | `totalNetBilled` | **billed** | `money.basis_billed` caption |
| Tour money board · sticky pill | `totalNet` | **cash** | label reads **"NET (CASH)"** |
| Bus money · tour rollup | `totalNet` | **cash** | `money.basis_cash` caption |

Five headlines, not four: the tour money board carries **both** bases on one
screen — a BILLED P&L card and a CASH pill — which is the sharpest case of the
whole finding and was invisible until the labels went on.

The pill gets its basis in the label rather than a caption because it is a
thumb-strip chip with no room for a second line. Two dead keys were removed with
their last call sites: `finance.basis_note` and `bus_money.rollup_net_caption`
(the latter said "Across the whole tour", restating the "Tour totals" label
directly above it).

**Change.** Two shared translation keys, applied as a caption under each of the
three unlabelled headlines, matching the existing `finance.basis_note` treatment
(`UgamText.caption`, `c.ink3`):

- `money.basis_cash` — "Cash basis — money actually received, not what was billed."
- `money.basis_billed` — "Billed basis — what the seats are worth, not what has been collected."

`finance.basis_note` already carries the cash wording; it is re-pointed at
`money.basis_cash` so one string serves all four and they cannot drift. Added to
`en`, `gu` and `hi`.

Deliberately **not** doing: unifying the four formulas onto one basis. They
answer different questions — a handler settling cash needs cash, an agent
pricing a trip needs billed. The defect is the silence, not the difference.

---

## Part C · Flip the trip-wires

[`test/diagnostics/money_miscalculation_report_test.dart`](../../../test/diagnostics/money_miscalculation_report_test.dart)
asserts C1, D1, B1, E1, E2 and F1 as **open**, so it passes today and goes red as
each fix lands. That is the design — it is the acceptance signal, not a
regression.

Each `expect` that flips is rewritten to assert the **fixed** behaviour, and the
test's header comment is updated from "these defects are open" to "these defects
are closed; this file is the regression guard". A test asserting a bug still
exists is a liability the moment the bug is gone.

The `[TEST-A]` / `[TEST-B]` seed in
[`supabase/seeds/test_tours.sql`](../../../supabase/seeds/test_tours.sql) is the
manual counterpart: both buses were created after 062, so their rent must post
immediately. If the Finance report shows ₹0 expenses for those two tours after
Part A, A3 is not actually fixed.

---

## Part D · Commit

The F1/E1/E2/A1/A2 fixes are uncommitted and interleaved with the concurrent
agent's bus-layout and sync work in the same checkout. They ship as one commit
scoped to the money files listed in the status table above, leaving the layout
and sync changes alone.

The audit doc is rewritten to record what was actually found, fixed and deployed
— it currently describes a tree that no longer exists, and a stale audit is worse
than none.

---

## Testing

- `flutter test` — full suite green (baseline 1125 at the start of this work).
- `flutter test test/diagnostics/money_miscalculation_report_test.dart -r expanded`
  — the rewritten assertions pass against the fixed engine.
- `flutter analyze` — clean.
- The SQL gate in Part A, run against the live database.

No new unit tests are required for Part A: the diagnostics SQL *is* the test, and
it runs where the defect lives. Part B's strings need no test beyond the existing
translation-completeness check.

---

## Roadmap — what S1 unblocks

Agreed with the user, specced separately once S1 lands. Recorded here so the
decisions are not lost.

### S2 · UPI capture becomes real

The current rail opens the payer's UPI app through `url_launcher`
([`upi_payment_sheet.dart:17`](../../../lib/widgets/upi_payment_sheet.dart#L17)),
which uses `startActivity` — fire and forget. Android's UPI specification returns
the outcome (`Status`, `txnId`, `txnRef`, `responseCode`, `ApprovalRefNo`)
through `onActivityResult`, and **that response cannot be received through
`url_launcher` at all**. The only signal the app has today is a hand-typed UTR
with no validation.

Scope:

- Android platform channel using `startActivityForResult`; a `SUCCESS` response
  becomes a **self-verified** claim that auto-confirms without admin review,
  while `FAILURE` / user-cancelled records nothing.
- A trust tier on `payment_claims` separating *self-verified* from *asserted*, so
  the admin review queue only holds what actually needs a human.
- `<queries>` entry for the `upi` scheme in
  [`AndroidManifest.xml`](../../../android/app/src/main/AndroidManifest.xml) — it
  currently declares only `PROCESS_TEXT`, `wa.me` and the WhatsApp packages.
- iOS is labelled honestly. `LSApplicationQueriesSchemes` is `whatsapp, https`
  ([`Info.plist:32`](../../../ios/Runner/Info.plist#L32)) and iOS has no
  OS-level `upi://` handler regardless, so **"Open UPI app" cannot work on iPhone
  today**. iOS keeps the QR plus typed UTR, shown as unverified.

### S3 · Credit, refund and the Balances tab

The user's choice: **credit first, one-tap UPI payout.** No gateway, no payout
API — there is no way to push money out of a bare VPA automatically, and any
design claiming otherwise is describing a gateway.

- A `liability.customer_credit` account in the existing double-entry ledger.
  Money owed back is auto-posted the moment it arises — cheaper bus after a move,
  overpayment, cancellation — and auto-applies to the customer's next fare.
- Cash-out is one tap: `upi://pay` to the customer's VPA from the organiser's
  own app, with S2's result capture auto-marking the refund paid against a real
  UTR.
- A **Balances tab** on the tour money board: every rider with a non-zero live
  balance, each row carrying its reason (moved Bus A→B, band reprice, overpaid,
  cancelled) and a settle action.

The seat-move engine this builds on already exists and works —
[`CollectionReconciler`](../../../lib/services/collection_reconciler.dart)
re-homes collection rows onto the seats a rider actually holds and re-prices
against the destination bus's own bands, and
[`SeatMoveMoneyNotice`](../../../lib/widgets/seat_move_money_notice.dart) prompts
the agent. The gap S3 closes is that the prompt is the **only** statement of the
delta: dismiss the dialog and no list anywhere records who is owed what, or why.
