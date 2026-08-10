-- ============================================================
-- 088_finance_integrity_alerts.sql
-- ------------------------------------------------------------
-- The characteristic failure of this app is not a crash. It is a wrong number.
--
-- 079 gave the app somewhere to report exceptions, and that closes the "the
-- screen broke" gap. It does nothing for the gap that actually costs money: a
-- confirmed payment credited to nobody, a rider charged twice, an advance
-- applied to one bus of a party and not the others. None of those throw. None
-- of them crash. They sit in the tables looking like ordinary rows until a
-- handler argues with a passenger about cash.
--
-- Every check below is the SIGNATURE OF A BUG THAT ACTUALLY HAPPENED, taken
-- from the 2026-08-10 defect register and the migrations that fixed them
-- (073-077). The point is not to find new classes of problem — it is to notice
-- immediately if one of those regressions comes back, since nothing else will.
--
-- WHAT THIS IS
-- A view. No cron, no notification, no dependency on pg_cron being available.
-- Query it, put it on a dashboard, or poll it from wherever you already look.
-- An empty result means the books are internally consistent.
--
-- WHAT THIS IS NOT
-- It does not prove the numbers are RIGHT. It proves they are not obviously
-- WRONG. A fare that is consistently miscalculated everywhere is invisible to
-- every check here; only a human comparing against reality catches that.
--
-- security_invoker = true, deliberately and from the start. 087 had to
-- retrofit this onto five finance views that were silently bypassing RLS. An
-- alerting view that showed every operator every other operator's broken money
-- would be a worse leak than the bugs it reports.
--
-- Requires 056 (ledger), 069 (amount_online), 064 (seat_holds). Idempotent.
-- ============================================================

do $$
begin
  if to_regclass('public.finance_lines') is null then
    raise exception '088 requires 056_finance_ledger.sql first';
  end if;
  if current_setting('server_version_num')::int / 10000 < 15 then
    raise exception
      '088 sets security_invoker, which needs PostgreSQL 15+. Without it this '
      'view would show every operator every other operator''s broken money.';
  end if;
end $$;


create or replace view public.finance_integrity_alerts
with (security_invoker = true) as

-- ── The 073 signature ────────────────────────────────────────
-- A claim confirmed with no rider attached. This is exactly what 069's lost
-- finalize block produced: money recorded, nobody booked, seats resold.
select
  'CONFIRMED_CLAIM_WITHOUT_RIDER'::text as code,
  'critical'::text                      as severity,
  c.tour_id,
  c.id                                  as subject_id,
  'payment_claims'::text                as subject_table,
  format('claim confirmed for %s paise but passenger_id is null — the payer '
         'is not booked', c.amount_paise) as detail,
  c.updated_at                          as observed_from
from public.payment_claims c
where c.status = 'confirmed'
  and c.passenger_id is null

union all

-- ── The 077 signature ────────────────────────────────────────
-- A confirmed claim whose money reached no collection row at all. Before 077 a
-- split party credited only the first bus; the rest showed as owing in full.
select
  'CONFIRMED_CLAIM_UNAPPLIED',
  'high',
  c.tour_id,
  c.id,
  'payment_claims',
  format('claim confirmed for %s paise with a rider, but no collections row '
         'carries any amount_online', c.amount_paise),
  c.updated_at
from public.payment_claims c
where c.status = 'confirmed'
  and c.passenger_id is not null
  and not exists (
    select 1 from public.collections col
     where col.passenger_id = c.passenger_id
       and coalesce(col.amount_online, 0) > 0
       and col.deleted_at is null
  )

union all

-- ── The 074 signature ────────────────────────────────────────
-- Money taken against a hold that then lapsed. 074 stops it happening; this
-- catches it if the TTL or the release path regresses.
select
  'PAID_HOLD_LAPSED',
  'high',
  c.tour_id,
  h.id,
  'seat_holds',
  format('hold is %s but a claim against it is %s — the payer may have lost '
         'their berths', h.status, c.status),
  greatest(h.updated_at, c.updated_at)
from public.payment_claims c
join public.seat_holds h on h.id = c.seat_hold_id
where c.status in ('pending', 'confirmed')
  and (h.status in ('expired', 'released')
       or (h.status = 'pending' and h.expires_at <= now()))

union all

-- ── The defect #2 signature ──────────────────────────────────
-- Two live collection rows for one rider on one PHYSICAL seat. The berth
-- suffix is stripped because a double sofa is two assignment entries priced as
-- one unit — comparing raw seat ids would miss the duplicate and invent others.
select
  'DUPLICATE_SEAT_COLLECTION',
  'high',
  col.tour_id,
  -- Postgres has no min()/max() for uuid, so the representative row is picked
  -- explicitly: the OLDEST, which is the original rather than the duplicate.
  -- created_at then id, so the choice is deterministic when two rows share a
  -- timestamp.
  (array_agg(col.id order by col.created_at, col.id))[1],
  'collections',
  format('%s live rows for rider %s on %s seat %s — cash is being counted '
         'more than once', count(*), col.passenger_id, col.bus_id,
         split_part(col.seat_id, '#', 1)),
  max(col.updated_at)
from public.collections col
where col.deleted_at is null
-- tour_id is grouped rather than aggregated: it is functionally determined by
-- bus_id, so this changes nothing about the grouping and avoids needing an
-- aggregate over a uuid.
group by col.tour_id, col.passenger_id, col.bus_id,
         split_part(col.seat_id, '#', 1)
having count(*) > 1

union all

-- ── Arithmetic that cannot be true ───────────────────────────
select
  'ONLINE_EXCEEDS_RECEIVED',
  'high',
  col.tour_id,
  col.id,
  'collections',
  format('amount_online %s exceeds amount_received %s — the handler appears '
         'to owe negative cash', col.amount_online, col.amount_received),
  col.updated_at
from public.collections col
where col.deleted_at is null
  and coalesce(col.amount_online, 0) > coalesce(col.amount_received, 0) + 0.005

union all

select
  'NEGATIVE_COLLECTION',
  'medium',
  col.tour_id,
  col.id,
  'collections',
  format('amount_received is %s', col.amount_received),
  col.updated_at
from public.collections col
where col.deleted_at is null
  and coalesce(col.amount_received, 0) < 0

union all

-- ── The ledger's own invariants, checked from outside ────────
-- 056's constraint triggers should make both of these impossible, and 071 made
-- them see every line rather than an RLS-filtered subset. If either ever
-- appears, a trigger has been dropped or disabled — which is worth knowing
-- long before the books are reconciled.
select
  'UNBALANCED_ENTRY',
  'critical',
  e.tour_id,
  e.id,
  'finance_entries',
  format('lines sum to %s, not zero — a constraint trigger is missing',
         sum(l.amount_minor)),
  -- recorded_at, not occurred_at. 056 notes that REPORTS key on occurred_at,
  -- but an alert wants to know when the problem ARRIVED: an entry recorded
  -- offline can carry a days-old occurred_at, and sorting by it would bury a
  -- problem that landed thirty seconds ago. (There is no created_at on this
  -- table — occurred_at and recorded_at are the only two timestamps.)
  max(e.recorded_at)
from public.finance_entries e
join public.finance_lines l on l.entry_id = e.id
group by e.id, e.tour_id
having sum(l.amount_minor) <> 0

union all

select
  'SINGLE_SIDED_ENTRY',
  'critical',
  e.tour_id,
  e.id,
  'finance_entries',
  format('entry has %s line(s); double entry needs at least two',
         count(l.entry_id)),
  max(e.recorded_at)
from public.finance_entries e
left join public.finance_lines l on l.entry_id = e.id
group by e.id, e.tour_id
-- count(l.entry_id), not count(l.*): with a LEFT JOIN the unmatched side is a
-- row of nulls, and counting a specific non-null column is the unambiguous way
-- to get 0 for an entry with no lines at all.
having count(l.entry_id) < 2;


comment on view public.finance_integrity_alerts is
  'Money-integrity checks, one per bug that actually reached production '
  '(register 2026-08-10, fixed by 073-077). Empty means internally '
  'consistent — NOT that the numbers are right. security_invoker: each '
  'operator sees only their own tours.';


-- ============================================================
-- OPERATING IT
--
--   -- The daily question. Empty is the good answer.
--   select severity, code, count(*)
--     from public.finance_integrity_alerts
--    group by 1, 2 order by 1, 3 desc;
--
--   -- Anything critical, newest first:
--   select * from public.finance_integrity_alerts
--    where severity = 'critical'
--    order by observed_from desc;
--
--   -- Scoped to one tour, when a handler disputes a figure:
--   select * from public.finance_integrity_alerts where tour_id = '<tour id>';
--
-- Look at this after every release, and after any hand-applied migration that
-- touches money. It is the only thing in the system that will notice 073's bug
-- coming back — client_errors cannot see a wrong number, and no test runs
-- against production data.
--
-- ============================================================
-- VERIFY
--
-- 1. It exists and respects RLS:
--      select (select option_value from pg_options_to_table(c.reloptions)
--               where option_name = 'security_invoker') as security_invoker
--        from pg_class c join pg_namespace n on n.oid = c.relnamespace
--       where n.nspname='public' and c.relname='finance_integrity_alerts';
--      -- expect 'true'
--
-- 2. Run it. On a healthy database this returns few or no rows:
--      select severity, code, count(*) from public.finance_integrity_alerts
--       group by 1,2 order by 1;
--
--    Rows here are NOT proof the view is broken — they may be real, historic
--    damage from the bugs 073-077 fixed, which those migrations did not
--    retroactively repair. Read each one before dismissing it.
--
-- 3. Prove a check actually fires, on a scratch tour:
--      insert into public.payment_claims
--        (tour_id, amount_paise, status, payer_name, payer_phone)
--      values ('<scratch tour>', 10000, 'confirmed', 'probe', '0000000000');
--      select * from public.finance_integrity_alerts
--       where code = 'CONFIRMED_CLAIM_WITHOUT_RIDER';   -- expect the row
--      -- then delete the probe
--
-- 4. Cross-tenant: as a second operator, the probe above must NOT be visible.
-- ============================================================
