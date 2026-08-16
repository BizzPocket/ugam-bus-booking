-- ============================================================
-- 092_fare_follows_bus_price.sql
-- ------------------------------------------------------------
-- Re-price the ledger when a BUS is re-priced.
--
-- THE HOLE
-- A seat's fare is a pure function of the bus's own pricing columns —
-- `bus_berth_price_paise` (049 §2) reads `price_bands`, `rear_rows`,
-- `rear_price`, `single_sofa_price`, `double_sofa_price`, `seater_price`,
-- `price_per_seat` and `layout` off the `buses` row, and `baseline_seat_due_paise`
-- (070) is built on it.
--
-- But the only trigger on `public.buses` is `buses_ledger_sync`, and
-- `finance_sync_bus_rent` (062 §7) posts the owner's RENT delta and nothing
-- else. The riders' `revenue.fare` / `ar.rider` lines are re-posted by exactly
-- one thing — `finance_sync_passenger`, which fires only when a rider's
-- `assigned_seats`, `cancelled_at` or `deleted_at` change (062:420-425).
--
-- So: change a bus's price and every rider already seated on it keeps their OLD
-- fare in the ledger. Permanently. Nothing else re-posts it, and the app never
-- calls `finance_resync_all_fares` (zero references in lib/).
--
-- WHAT THE OPERATOR SEES
-- The roster prices seats from the LIVE bus (`Bus.amountDueForSeat`), so it
-- moves the instant the fare is edited. Everything derived from the ledger does
-- not. The trip's billed revenue — and therefore the headline profit — is
-- computed on the stale fare, and `finance_rider_balance` reports phantom
-- balances against it: "still owes ₹X" for a rider who is square, "refund ₹X" to
-- somebody nobody can name. Only the riders whose seats happened to move since
-- the price edit are correct, which is why one bus shows money to collect AND
-- money to hand back at the same time.
--
-- THE FIX
-- A second AFTER trigger on `buses` that re-prices every rider seated on that
-- bus whenever a pricing column moves. `finance_resync_passenger_fare` (062 §6)
-- reconciles a rider to a TARGET rather than posting per change, so this posts
-- one entry per genuinely mispriced rider and nothing at all for the rest —
-- it is safe to fire more often than strictly needed.
--
-- Kept as its OWN trigger rather than folded into `finance_sync_bus_rent`: rent
-- and fares are independent postings, and a separate trigger can be dropped or
-- reasoned about without touching 062's. Both are AFTER ... FOR EACH ROW, and
-- they touch different accounts, so firing order is irrelevant.
--
-- NOT INCLUDED IN THE GUARD
--   - `bus_price` — that is the owner's rent, already handled by 062 §7. A rent
--     edit changes no passenger's fare.
--   - `deleted_at` — soft-deleting a bus does not change what
--     `bus_berth_price_paise` returns (it does not filter on it), so a resync
--     here would post nothing. Whether an archived bus should stop billing is a
--     separate question and deliberately not decided by this file.
--
-- No recursion: `finance_resync_passenger_fare` writes only to
-- `finance_entries` / `finance_lines`, never back to `buses` or `passengers`.
--
-- Requires 062 (write-through) + 070 (one fare formula). Idempotent.
-- ============================================================

do $$
begin
  if to_regprocedure('public.finance_resync_passenger_fare(uuid)') is null then
    raise exception '092 requires 062_ledger_write_through.sql first';
  end if;
  if to_regprocedure('public.baseline_seat_due_paise(uuid, uuid, text)') is null then
    raise exception '092 requires 070_one_fare_formula.sql first';
  end if;
end $$;


create or replace function public.finance_sync_bus_fares() returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_bus_id   uuid;
  v_tour_id  uuid;
  v_pax      uuid;
begin
  -- Nothing that can move a fare changed → nothing to re-price. Compared with
  -- `is not distinct from` so a NULL price behaves like any other value; the
  -- app PATCHes the whole bus row on every save, so without this guard an
  -- unrelated edit (name, handler, plate) would resync the entire roster.
  if tg_op = 'UPDATE'
     and new.price_bands        is not distinct from old.price_bands
     and new.price_per_seat     is not distinct from old.price_per_seat
     and new.rear_rows          is not distinct from old.rear_rows
     and new.rear_price         is not distinct from old.rear_price
     and new.single_sofa_price  is not distinct from old.single_sofa_price
     and new.double_sofa_price  is not distinct from old.double_sofa_price
     and new.seater_price       is not distinct from old.seater_price
     and new.layout             is not distinct from old.layout then
    return null;
  end if;

  v_bus_id  := coalesce(new.id, old.id);
  v_tour_id := coalesce(new.tour_id, old.tour_id);

  perform public.finance_set_actor('system', 'bus re-priced');

  -- Every rider holding a seat on THIS bus. Scoped by tour_id as well as bus id
  -- so the scan uses the tour index instead of walking every passenger in the
  -- database; `assigned_seats` carries the bus id, and a seat can only belong to
  -- a bus on its own tour.
  for v_pax in
    select distinct p.id
      from public.passengers p
      cross join lateral jsonb_array_elements(
        coalesce(p.assigned_seats, '[]'::jsonb)) s
     where p.tour_id = v_tour_id
       and p.deleted_at is null
       -- Guard the cast: a malformed or empty busId must skip the row, not
       -- abort the operator's price edit with an invalid-uuid error.
       and coalesce(s->>'busId', '') <> ''
       and (s->>'busId')::uuid = v_bus_id
  loop
    perform public.finance_resync_passenger_fare(v_pax);
  end loop;

  return null;
end $$;

drop trigger if exists buses_ledger_fare_sync on public.buses;
create trigger buses_ledger_fare_sync
  after insert or update or delete on public.buses
  for each row execute function public.finance_sync_bus_fares();


-- ── Repair the drift already on the books ────────────────────
-- Every bus re-priced before this trigger existed left its riders' fares frozen.
-- `finance_resync_passenger_fare` posts only the difference, so this is a no-op
-- for riders who were already correct.
select * from public.finance_resync_all_fares();


-- ============================================================
-- VERIFY
--
-- 1. The trigger is live:
--      select tgname from pg_trigger
--       where tgrelid = 'public.buses'::regclass and not tgisinternal;
--                          -- expect buses_ledger_sync AND buses_ledger_fare_sync
--
-- 2. No fare drift is left. Check 7 in
--    supabase/diagnostics/finance_audit_checks.sql must return ZERO rows.
--    Run it BEFORE applying this file too, and keep the output — that is the
--    evidence of what was wrong, and the rows it lists are the riders whose
--    on-screen figures were disagreeing with the ledger.
--
-- 3. It stays at zero after a price change. Edit any bus's price in the app,
--    then re-run check 7: still zero rows. Before this file, every seated rider
--    on that bus would appear.
--
-- 4. A NON-pricing edit does not churn the ledger. Rename a bus, then:
--      select count(*) from public.finance_entries
--       where kind = 'reprice' and created_at > now() - interval '1 minute';
--                                             -- expect 0
-- ============================================================
