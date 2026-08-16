-- ============================================================
-- 091  handler_upsert_collection — infer the PARTIAL unique index
-- ------------------------------------------------------------
-- The handler cannot record a single rupee from the seat chart. Tapping Save
-- spins the button and nothing lands: every call to handler_upsert_collection
-- aborts inside Postgres with
--
--   42P10: there is no unique or exclusion constraint matching the
--          ON CONFLICT specification
--
-- WHY. 054 narrowed collections_passenger_bus_seat_unique to live rows —
-- otherwise a soft-deleted collection would occupy its (passenger, bus, seat)
-- key forever:
--
--   create unique index collections_passenger_bus_seat_unique
--     on public.collections (passenger_id, bus_id, seat_id)
--     where deleted_at is null;          -- 054:79-119
--
-- ON CONFLICT infers its arbiter from the column list. A PARTIAL index only
-- qualifies when the statement repeats the index predicate, so the bare
-- `on conflict (passenger_id, bus_id, seat_id)` this function has carried since
-- 004 stopped matching any index the moment 054 ran. It is a PLAN-time error,
-- so it fires on the very first save — not on some later edge case.
--
-- The body is otherwise reproduced VERBATIM from 042:418-482 (which was itself
-- verbatim from 004): the authorization gate, the tour resolution through
-- handler_ctx, and both membership checks are untouched. The ONLY change is the
-- five-word predicate on line `on conflict ... where deleted_at is null`.
--
-- Every collection upsert written AFTER 054 already does this — 060:316,
-- 064:654, 069:201, 073:202, 077:206 all carry the predicate. This function was
-- last touched in 042, before 054 existed, and was the only one left behind.
-- That is exactly why the customer money paths (UPI advance, chart finalize,
-- online payment, party advance) kept working while the handler's did not.
--
-- SOFT-DELETED ROWS. With the predicate in place a soft-deleted collection no
-- longer collides: it is outside the arbiter index, so a fresh live row is
-- inserted beside it rather than the archived row being silently resurrected.
-- That is the same semantics 069/073/077 already rely on.
--
-- Idempotent: safe to re-run. Run THIS FILE ALONE in the SQL editor; never
-- `db push` (the history table is empty, so a push would replay everything).
-- ============================================================

create or replace function public.handler_upsert_collection(
  p_request_id uuid,
  p_collection jsonb
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tour_id      uuid;
  v_bus_id       uuid;
  v_passenger_id uuid;
  v_seat_id      text;
  v_id           uuid;
  v_row          public.collections;
begin
  if not public.is_request_handler(p_request_id) then
    return null;
  end if;

  select ctx.tour_id into v_tour_id
    from public.handler_ctx(p_request_id) ctx;

  v_bus_id       := (p_collection->>'bus_id')::uuid;
  v_passenger_id := (p_collection->>'passenger_id')::uuid;
  v_seat_id      := coalesce(nullif(p_collection->>'seat_id', ''), '');
  v_id           := coalesce(nullif(p_collection->>'id', '')::uuid, gen_random_uuid());

  if not exists (
    select 1 from public.passengers p
     where p.id = v_passenger_id and p.tour_id = v_tour_id
  ) then
    return null;
  end if;

  if not exists (
    select 1 from public.buses b
     where b.id = v_bus_id and b.tour_id = v_tour_id
  ) then
    return null;
  end if;

  insert into public.collections (
    id, tour_id, bus_id, passenger_id, seat_id,
    amount_due, amount_received, amount_refunded, note, collected_by
  )
  values (
    v_id, v_tour_id, v_bus_id, v_passenger_id, v_seat_id,
    coalesce((p_collection->>'amount_due')::numeric, 0),
    coalesce((p_collection->>'amount_received')::numeric, 0),
    coalesce((p_collection->>'amount_refunded')::numeric, 0),
    nullif(p_collection->>'note', ''),
    nullif(p_collection->>'collected_by', '')
  )
  -- THE FIX. Without `where deleted_at is null` this infers nothing and the
  -- whole statement raises 42P10 before a row is ever touched.
  on conflict (passenger_id, bus_id, seat_id) where deleted_at is null
  do update set
    amount_due      = excluded.amount_due,
    amount_received = excluded.amount_received,
    amount_refunded = excluded.amount_refunded,
    note            = excluded.note,
    collected_by    = excluded.collected_by,
    updated_at      = now()
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

-- 084 warns that a re-created function gets fresh Supabase defaults, so the
-- grants are re-stated here exactly as 042:484-486 left them.
revoke all on function public.handler_upsert_collection(uuid, jsonb) from public;
grant execute on function public.handler_upsert_collection(uuid, jsonb)
  to anon, authenticated;


-- ============================================================
-- VERIFY
--
-- 1. The arbiter index really is partial (this is what broke the inference):
--
--      select indexdef from pg_indexes
--       where schemaname = 'public'
--         and indexname  = 'collections_passenger_bus_seat_unique';
--
--    expect a trailing `WHERE (deleted_at IS NULL)`.
--
-- 2. Collect from the handler app, twice, on the SAME seat. The first press
--    exercises the INSERT branch, the second the DO UPDATE branch — which is
--    the branch the arbiter is actually needed for. Both must save, and the
--    seat must end with ONE live collection row, not two:
--
--      select count(*), sum(amount_received)
--        from public.collections
--       where passenger_id = '<p>' and bus_id = '<b>' and seat_id = '<s>'
--         and deleted_at is null;
--
-- 3. The money still reaches the ledger — the collections_ledger_sync trigger
--    (062:232) fires on both branches:
--
--      select entry_kind, amount_minor from public.finance_entries
--       where source_table = 'collections' order by recorded_at desc limit 4;
-- ============================================================
