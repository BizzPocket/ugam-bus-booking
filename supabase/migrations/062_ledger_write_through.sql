-- ============================================================
-- 062_ledger_write_through.sql   —   the ledger starts tracking live writes
-- ------------------------------------------------------------
-- Until now the ledger only held what 058 backfilled. Every ongoing write went
-- to the old tables alone, so the ledger froze at backfill time. This makes it
-- follow along, automatically and atomically.
--
-- WHY TRIGGERS AND NOT CLIENT CODE
-- Money reaches these tables by at least four routes: the admin app's
-- `smartInsert`/`smartUpdate`, the handler's SECURITY DEFINER RPCs, the UPI
-- claim confirmation in 060, and hand-written SQL in the editor. Dual-writing
-- from Dart would cover exactly one of those, would not be atomic with the row
-- it describes, and would silently drift the moment anyone used the SQL editor.
-- A trigger is inside the same transaction as the row, so the ledger cannot
-- disagree with the table it mirrors.
--
-- HOW A CHANGE BECOMES AN ENTRY — deltas, never rewrites.
-- The ledger is append-only, so an edited row cannot edit its old entry. Each
-- change posts the DIFFERENCE:
--
--     received 300 -> 500   posts a +200 cash_receipt
--     expense  900 -> 850   posts a  -50 expense
--     archived  (soft delete) posts the negative of everything that row
--                             contributed, so it nets to zero
--     un-archived            posts it back
--
-- Soft delete is modelled as "the effective amount became zero", which makes
-- delete and un-delete fall out of the same subtraction as an ordinary edit —
-- one rule instead of three.
--
-- FARES follow the SEATING, not the collection row. `collections.amount_due` is
-- a snapshot the app already ignores (see seat_money_state.dart), so it posts
-- nothing. A rider's charge is recomputed from their live seats whenever their
-- assignment, cancellation or archival changes.
--
-- Requires 058 (backfill_post) and 056. Idempotent. Apply after 061.
-- ============================================================

do $$
begin
  if to_regclass('public.finance_entries') is null
     or not exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
                     where n.nspname='public' and p.proname='backfill_post') then
    raise exception '062 requires 056 and 058 to be applied first';
  end if;
end $$;


-- ── 0. Make the backfill and the triggers mutually exclusive ─
-- DOUBLE-COUNT HAZARD: the backfill keys its entries `backfill:<table>:<id>`
-- and the triggers key theirs `row:<table>:<id>:<n>`. Different keys, same
-- money. So a row created AFTER the triggers go live — already posted by its
-- own INSERT trigger — would be posted a SECOND time by any later run of
-- `backfill_finance_ledger()`, and every total on that bus would be wrong with
-- nothing on screen to explain it.
--
-- The intended order is 058 then 062, but "don't run that again" is not a
-- safeguard. This makes the backfill decline any row the triggers already own,
-- so the two can never both account for the same source row regardless of the
-- order they are run in.
create or replace function public.backfill_post(
  p_tour_id      uuid,
  p_kind         text,
  p_key          text,
  p_occurred_at  timestamptz,
  p_amount_minor bigint,
  p_debit_code   text,
  p_debit_bus    uuid,
  p_debit_pax    uuid,
  p_credit_code  text,
  p_credit_bus   uuid,
  p_credit_pax   uuid,
  p_source_table text,
  p_source_row   uuid,
  p_category     text default null,
  p_memo         text default null,
  out o_entry    uuid,
  out o_new      boolean
)
language plpgsql security definer set search_path = public
as $$
begin
  o_entry := null;
  o_new   := false;

  if p_amount_minor is null or p_amount_minor = 0 then
    return;
  end if;

  -- The guard described above. Only ever restrains the BACKFILL: trigger posts
  -- carry a `row:` key and pass straight through.
  if p_key like 'backfill:%' and p_source_row is not null and exists (
    select 1 from public.finance_entries
     where source_table = p_source_table
       and source_row_id = p_source_row
       and client_request_id like 'row:%'
  ) then
    return;
  end if;

  insert into public.finance_entries (
    tour_id, kind, occurred_at, recorded_at,
    actor_kind, actor_label, client_request_id,
    memo, source_table, source_row_id
  )
  values (
    p_tour_id, p_kind, coalesce(p_occurred_at, now()), now(),
    coalesce(public.finance_actor_kind(), 'system'),
    coalesce(nullif(public.finance_actor_label(), ''), 'backfill'),
    p_key, p_memo, p_source_table, p_source_row
  )
  on conflict (tour_id, client_request_id) do nothing
  returning id into o_entry;

  if o_entry is not null then
    o_new := true;
    insert into public.finance_lines
      (entry_id, account_code, bus_id, passenger_id, category, amount_minor)
    values
      (o_entry, p_debit_code,  p_debit_bus,  p_debit_pax,  p_category,  p_amount_minor),
      (o_entry, p_credit_code, p_credit_bus, p_credit_pax, p_category, -p_amount_minor);
    return;
  end if;

  select id into o_entry
    from public.finance_entries
   where tour_id = p_tour_id and client_request_id = p_key;
end $$;


-- ── 1. Unique key per row-event ──────────────────────────────
-- A trigger fires once per committed change, so it needs a key that is unique
-- per EVENT, not per row. Deriving it from the values would collide on
-- 300 -> 500 -> 300, and the third change would be silently dropped.
create sequence if not exists public.finance_row_event_seq;


-- ── 2. Post the delta for one account pair ───────────────────
-- Wraps backfill_post with the delta arithmetic and the zero short-circuit, so
-- each trigger below reads as a single line per money dimension.
create or replace function public.finance_post_delta(
  p_tour_id      uuid,
  p_kind         text,
  p_old          bigint,
  p_new          bigint,
  p_debit_code   text,
  p_debit_bus    uuid,
  p_debit_pax    uuid,
  p_credit_code  text,
  p_credit_bus   uuid,
  p_credit_pax   uuid,
  p_source_table text,
  p_source_row   uuid,
  p_category     text default null,
  p_memo         text default null
) returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_delta bigint := coalesce(p_new, 0) - coalesce(p_old, 0);
  v_entry uuid;
begin
  if v_delta = 0 then
    return;
  end if;

  -- A NEGATIVE delta is the same entry with its sides swapped, which keeps
  -- every stored line positive-signed in its natural direction and makes the
  -- account statements readable.
  if v_delta > 0 then
    select o_entry into v_entry from public.backfill_post(
      p_tour_id, p_kind,
      'row:' || p_source_table || ':' || p_source_row || ':' ||
        nextval('public.finance_row_event_seq'),
      now(), v_delta,
      p_debit_code,  p_debit_bus,  p_debit_pax,
      p_credit_code, p_credit_bus, p_credit_pax,
      p_source_table, p_source_row, p_category, p_memo);
  else
    select o_entry into v_entry from public.backfill_post(
      p_tour_id, p_kind,
      'row:' || p_source_table || ':' || p_source_row || ':' ||
        nextval('public.finance_row_event_seq'),
      now(), -v_delta,
      p_credit_code, p_credit_bus, p_credit_pax,
      p_debit_code,  p_debit_bus,  p_debit_pax,
      p_source_table, p_source_row, p_category, p_memo);
  end if;
end $$;


-- ── 3. Collections ───────────────────────────────────────────
-- Cash in and cash back. `amount_due` posts nothing — the fare comes from the
-- seating (§6), and this column is the stale snapshot the app already ignores.
create or replace function public.finance_sync_collection() returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_old_recv bigint := 0;
  v_old_refd bigint := 0;
  v_new_recv bigint := 0;
  v_new_refd bigint := 0;
  v_row      record;
begin
  v_row := coalesce(new, old);

  if tg_op <> 'INSERT' and old.deleted_at is null then
    v_old_recv := round(old.amount_received * 100)::bigint;
    v_old_refd := round(old.amount_refunded * 100)::bigint;
  end if;
  if tg_op <> 'DELETE' and new.deleted_at is null then
    v_new_recv := round(new.amount_received * 100)::bigint;
    v_new_refd := round(new.amount_refunded * 100)::bigint;
  end if;

  perform public.finance_post_delta(
    v_row.tour_id, 'cash_receipt', v_old_recv, v_new_recv,
    'cash.handler', v_row.bus_id, null,
    'ar.rider',     null,         v_row.passenger_id,
    'collections', v_row.id, null, v_row.note);

  perform public.finance_post_delta(
    v_row.tour_id, 'refund', v_old_refd, v_new_refd,
    'ar.rider',     null,         v_row.passenger_id,
    'cash.handler', v_row.bus_id, null,
    'collections', v_row.id, null, v_row.note);

  return null;
end $$;

drop trigger if exists collections_ledger_sync on public.collections;
create trigger collections_ledger_sync
  after insert or update or delete on public.collections
  for each row execute function public.finance_sync_collection();


-- ── 4. Expenses and incomes ──────────────────────────────────
create or replace function public.finance_sync_expense() returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_old bigint := 0;
  v_new bigint := 0;
  v_row record;
begin
  v_row := coalesce(new, old);
  if tg_op <> 'INSERT' and old.deleted_at is null then
    v_old := round(old.amount * 100)::bigint;
  end if;
  if tg_op <> 'DELETE' and new.deleted_at is null then
    v_new := round(new.amount * 100)::bigint;
  end if;

  perform public.finance_post_delta(
    v_row.tour_id, 'expense', v_old, v_new,
    'expense.ground', v_row.bus_id, null,
    'cash.handler',   v_row.bus_id, null,
    'expenses', v_row.id, v_row.category, v_row.label);

  return null;
end $$;

drop trigger if exists expenses_ledger_sync on public.expenses;
create trigger expenses_ledger_sync
  after insert or update or delete on public.expenses
  for each row execute function public.finance_sync_expense();


create or replace function public.finance_sync_income() returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_old bigint := 0;
  v_new bigint := 0;
  v_row record;
begin
  v_row := coalesce(new, old);
  if tg_op <> 'INSERT' and old.deleted_at is null then
    v_old := round(old.amount * 100)::bigint;
  end if;
  if tg_op <> 'DELETE' and new.deleted_at is null then
    v_new := round(new.amount * 100)::bigint;
  end if;

  perform public.finance_post_delta(
    v_row.tour_id, 'extra_income', v_old, v_new,
    'cash.handler',  v_row.bus_id, null,
    'revenue.extra', v_row.bus_id, null,
    'incomes', v_row.id, v_row.category, v_row.label);

  return null;
end $$;

drop trigger if exists incomes_ledger_sync on public.incomes;
create trigger incomes_ledger_sync
  after insert or update or delete on public.incomes
  for each row execute function public.finance_sync_income();


-- ── 5. Handovers ─────────────────────────────────────────────
create or replace function public.finance_sync_handover() returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_old bigint := 0;
  v_new bigint := 0;
  v_row record;
begin
  v_row := coalesce(new, old);
  if tg_op <> 'INSERT' and old.deleted_at is null then
    v_old := round(old.handed_over_amount * 100)::bigint;
  end if;
  if tg_op <> 'DELETE' and new.deleted_at is null then
    v_new := round(new.handed_over_amount * 100)::bigint;
  end if;

  perform public.finance_post_delta(
    v_row.tour_id, 'handover', v_old, v_new,
    'cash.admin',   null,         null,
    'cash.handler', v_row.bus_id, null,
    'bus_handovers', v_row.id, null, v_row.note);

  return null;
end $$;

drop trigger if exists bus_handovers_ledger_sync on public.bus_handovers;
create trigger bus_handovers_ledger_sync
  after insert or update or delete on public.bus_handovers
  for each row execute function public.finance_sync_handover();


-- ── 6. Fares follow the seating ──────────────────────────────
-- A rider's charge is the sum of their live seat fares. Re-seat them, move them
-- to a dearer bus, cancel them, and the charge must move with it — which is
-- exactly the snapshot-vs-live problem `liveBalanceOf` works around today.
--
-- Reconciles to a TARGET rather than posting per change: compute what the rider
-- should be charged now, compare with what the ledger already charged them, and
-- post the difference. That converges no matter how the seating got there, and
-- costs one entry per actual change.
-- RECONCILED PER BUS, not as one net figure. A cross-bus move must REMOVE the
-- charge from the old bus and ADD it to the new one; a single net delta posted
-- against "the rider's current bus" leaves the old bus permanently carrying
-- revenue for someone who is no longer on it, and the two buses silently stop
-- adding up to the trip total.
--
-- The bus set is the UNION of where they sit now and where the ledger has
-- already charged them — the second half is what lets a bus they have LEFT be
-- zeroed out. Losing that union is exactly how this drifted the first time.
create or replace function public.finance_resync_passenger_fare(p_passenger_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_pax record;
  v_bus record;
begin
  select id, tour_id, cancelled_at, deleted_at
    into v_pax
    from public.passengers where id = p_passenger_id;
  if not found then
    return;
  end if;

  for v_bus in
    with
    -- What they should be charged on each bus right now. A cancelled or
    -- archived rider owes nothing anywhere; their payments stay recorded,
    -- which is precisely how "we owe them a refund" becomes visible.
    target as (
      select s.bus_id,
             sum(public.baseline_seat_due_paise(
                   p_passenger_id, s.bus_id, s.seat_id))::bigint as amount
        from (
          select distinct
                 (e->>'busId')::uuid            as bus_id,
                 split_part(e->>'seatId','#',1) as seat_id
            from public.passengers p
            cross join lateral jsonb_array_elements(
              coalesce(p.assigned_seats,'[]'::jsonb)) e
           where p.id = p_passenger_id
             and v_pax.cancelled_at is null
             and v_pax.deleted_at is null
             and coalesce(e->>'busId','')  <> ''
             and coalesce(e->>'seatId','') <> ''
        ) s
       group by s.bus_id
    ),
    -- What the ledger has already charged them, per bus.
    current as (
      select l.bus_id, coalesce(-sum(l.amount_minor), 0)::bigint as amount
        from public.finance_lines l
        join public.finance_entries en on en.id = l.entry_id
       where l.account_code = 'revenue.fare'
         and en.source_table = 'passengers'
         and en.source_row_id = p_passenger_id
         and l.bus_id is not null
       group by l.bus_id
    )
    select coalesce(t.bus_id, c.bus_id)   as bus_id,
           coalesce(c.amount, 0)          as current_amount,
           coalesce(t.amount, 0)          as target_amount
      from target t
      full outer join current c on c.bus_id = t.bus_id
  loop
    perform public.finance_post_delta(
      v_pax.tour_id, 'reprice', v_bus.current_amount, v_bus.target_amount,
      'ar.rider',     null,          p_passenger_id,
      'revenue.fare', v_bus.bus_id,  null,
      'passengers', p_passenger_id, null, 'seating changed');
  end loop;
end $$;


create or replace function public.finance_sync_passenger() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  -- Only the three things that can change what a rider owes.
  if tg_op = 'UPDATE'
     and new.assigned_seats is not distinct from old.assigned_seats
     and new.cancelled_at   is not distinct from old.cancelled_at
     and new.deleted_at     is not distinct from old.deleted_at then
    return null;
  end if;

  perform public.finance_resync_passenger_fare(coalesce(new.id, old.id));
  return null;
end $$;

drop trigger if exists passengers_ledger_sync on public.passengers;
create trigger passengers_ledger_sync
  after insert or update or delete on public.passengers
  for each row execute function public.finance_sync_passenger();


-- ── 7. Owner rent follows the bus price ──────────────────────
create or replace function public.finance_sync_bus_rent() returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_old bigint := 0;
  v_new bigint := 0;
  v_row record;
begin
  v_row := coalesce(new, old);
  if tg_op <> 'INSERT' and old.deleted_at is null then
    v_old := round(old.bus_price * 100)::bigint;
  end if;
  if tg_op <> 'DELETE' and new.deleted_at is null then
    v_new := round(new.bus_price * 100)::bigint;
  end if;

  perform public.finance_post_delta(
    v_row.tour_id, 'owner_rent', v_old, v_new,
    'expense.rent',  v_row.id, null,
    'payable.owner', v_row.id, null,
    'buses', v_row.id, 'rent', 'owner rent');

  return null;
end $$;

drop trigger if exists buses_ledger_sync on public.buses;
create trigger buses_ledger_sync
  after insert or update or delete on public.buses
  for each row execute function public.finance_sync_bus_rent();


-- ============================================================
-- VERIFY — the strongest test available: change anything, then prove the
-- ledger still equals the tables.
--
--   select public.capture_finance_baseline('after-writes','post-trigger') as r;
--   select * from public.verify_finance_backfill('<that r>') where not ok;
--
-- An empty result means every write since the backfill landed in both places.
-- Run it after a real day of collecting.
-- ============================================================
