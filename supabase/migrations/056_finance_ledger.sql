-- ============================================================
-- 056_finance_ledger.sql   —   P2 of the finance rebuild
-- ------------------------------------------------------------
-- The books. Append-only, self-balancing, in integer paise.
--
-- Every money event becomes ONE `finance_entries` row plus TWO OR MORE
-- `finance_lines` that sum to zero. A balance is `sum(amount_minor)` over an
-- account scope — never a formula reassembled from four tables, so the per-bus
-- board and the cross-tour report cannot disagree by construction.
--
-- WHAT THIS REPLACES (all of it becomes one primitive):
--   outstandingHandover  -> balance('cash.handler', bus)
--   toCollect / toReturn -> balance('ar.rider', passenger) sign-split
--   detachedCash, orphan* -> queries, not bespoke fields
--   busRent folded in 3 places -> a real posted entry, counted once
--   4 separate float epsilons -> nothing; integers need no tolerance
--
-- NOTHING READS THIS YET. Purely additive: no existing table, policy, function
-- or index is touched. The app is unaffected until P5/P6.
--
-- CURRENCY: rupees only, per the decision to defer multi-currency. Amounts are
-- named `amount_minor` (not `_paise`) and entries carry a defaulted `currency`
-- so switching it on later is relaxing a constraint, not migrating a column.
--
-- Idempotent, re-runnable. Requires 054 (soft delete) to be live.
-- Apply in the Supabase SQL editor, isolated, AFTER 055.
-- ============================================================

do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema='public' and table_name='collections' and column_name='deleted_at'
  ) then
    raise exception '056 requires 054_soft_delete.sql to be applied first'
      using hint = 'Apply 053 -> 054 -> 055 -> 056 in order.';
  end if;
end $$;


-- ── 1. Actor identity ────────────────────────────────────────
-- Handler RPCs run SECURITY DEFINER under an ANON jwt, so auth.uid() is NULL
-- inside them and cannot identify who acted. Every finance RPC therefore
-- stamps a transaction-local actor before writing, and the ledger + audit log
-- read it back here. Falls back to the signed-in admin.

create or replace function public.finance_set_actor(
  p_kind         text,
  p_label        text default null,
  p_passenger_id uuid default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_kind not in ('admin','handler','customer','system') then
    raise exception 'finance_set_actor: unknown actor kind %', p_kind;
  end if;
  perform set_config('app.actor_kind',  p_kind, true);
  perform set_config('app.actor_label', coalesce(p_label, ''), true);
  perform set_config('app.actor_pid',   coalesce(p_passenger_id::text, ''), true);
end $$;

revoke all on function public.finance_set_actor(text, text, uuid) from public;

create or replace function public.finance_actor_kind() returns text
language sql stable set search_path = public as $$
  select coalesce(
    nullif(current_setting('app.actor_kind', true), ''),
    case when auth.uid() is not null then 'admin' else 'system' end
  );
$$;

create or replace function public.finance_actor_label() returns text
language sql stable set search_path = public as $$
  select coalesce(nullif(current_setting('app.actor_label', true), ''), '');
$$;

create or replace function public.finance_actor_pid() returns uuid
language sql stable set search_path = public as $$
  select nullif(current_setting('app.actor_pid', true), '')::uuid;
$$;


-- ── 2. Settlements ───────────────────────────────────────────
-- What "settled" means, and what reopening costs. A settlement scopes a bus
-- (or the whole tour when bus_id is null) and can be CLOSED. Closing freezes
-- posting; reopening is admin-only, needs a reason, and starts a NEW
-- generation so the history of "settled at X, reopened, now Y" survives.

create table if not exists public.finance_settlements (
  id                    uuid primary key default gen_random_uuid(),
  tour_id               uuid not null references public.tours(id),
  bus_id                uuid references public.buses(id),
  generation            int  not null default 1,
  status                text not null default 'open'
                          check (status in ('open','closed')),
  closing_balance_minor bigint,
  closed_at             timestamptz,
  closed_by_user_id     uuid,
  closed_by_label       text,
  reopened_at           timestamptz,
  reopened_by_user_id   uuid,
  reopen_reason         text,
  created_at            timestamptz not null default now(),
  unique (tour_id, bus_id, generation)
);

-- At most ONE open settlement per scope. coalesce() keeps the tour-level
-- (bus_id null) scope distinct from any real bus, and works on PG14 —
-- `nulls not distinct` is PG15+ and this repo dry-runs on 14.
create unique index if not exists finance_settlements_one_open
  on public.finance_settlements
     (tour_id, coalesce(bus_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status = 'open';

create index if not exists finance_settlements_tour_idx
  on public.finance_settlements(tour_id);

alter table public.finance_settlements enable row level security;
drop policy if exists "finance_settlements_owner_read" on public.finance_settlements;
create policy "finance_settlements_owner_read" on public.finance_settlements
  for select to authenticated
  using (exists (select 1 from public.tours t
                  where t.id = finance_settlements.tour_id
                    and t.owner_id = auth.uid()));


-- ── 3. Entries ───────────────────────────────────────────────

create table if not exists public.finance_entries (
  id                 uuid primary key default gen_random_uuid(),
  tour_id            uuid not null references public.tours(id),
  settlement_id      uuid references public.finance_settlements(id),
  kind               text not null check (kind in (
                       'fare_charge','reprice','cash_receipt','refund',
                       'expense','extra_income','handover','owner_rent',
                       'owner_payment','online_payment','write_off','reversal')),
  currency           char(3) not null default 'INR',

  -- When it happened on the ground vs when the server learned. These differ
  -- for anything recorded offline, and reports must key on occurred_at.
  occurred_at        timestamptz not null default now(),
  recorded_at        timestamptz not null default now(),

  actor_kind         text not null check (actor_kind in ('admin','handler','customer','system')),
  actor_user_id      uuid,
  actor_passenger_id uuid references public.passengers(id),
  actor_label        text not null default '',

  -- Idempotency. The DEVICE supplies this, so a retry from a bus with flaky
  -- signal converges instead of double-posting.
  client_request_id  text not null,

  -- Corrections are reversals, never edits.
  reverses_entry_id  uuid references public.finance_entries(id),

  memo               text,
  -- Backfill provenance; null for natively-posted entries.
  source_table       text,
  source_row_id      uuid,

  constraint finance_entries_idem unique (tour_id, client_request_id)
);

create index if not exists finance_entries_tour_idx
  on public.finance_entries(tour_id, occurred_at);
create index if not exists finance_entries_settlement_idx
  on public.finance_entries(settlement_id);
create index if not exists finance_entries_source_idx
  on public.finance_entries(source_table, source_row_id);

alter table public.finance_entries enable row level security;
drop policy if exists "finance_entries_owner_read" on public.finance_entries;
create policy "finance_entries_owner_read" on public.finance_entries
  for select to authenticated
  using (exists (select 1 from public.tours t
                  where t.id = finance_entries.tour_id
                    and t.owner_id = auth.uid()));


-- ── 4. Lines ─────────────────────────────────────────────────
-- Signed paise. DR positive, CR negative. Sum per entry MUST be zero.
--
-- No chart-of-accounts table: the account IS (code, bus_id, passenger_id).
-- That avoids a second table to keep in sync and a PG15-only unique-key trick,
-- and at this app's scale the indexes below give the same rollups.

create table if not exists public.finance_lines (
  id           bigserial primary key,
  entry_id     uuid not null references public.finance_entries(id),
  account_code text not null check (account_code in (
                 'cash.handler','cash.admin','bank.gateway',
                 'ar.rider','payable.owner',
                 'revenue.fare','revenue.extra',
                 'expense.ground','expense.rent','expense.writeoff')),
  bus_id       uuid references public.buses(id),
  passenger_id uuid references public.passengers(id),
  category     text,
  amount_minor bigint not null
                 check (amount_minor <> 0
                    and amount_minor between -100000000000 and 100000000000)
);

create index if not exists finance_lines_entry_idx on public.finance_lines(entry_id);
create index if not exists finance_lines_acct_idx  on public.finance_lines(account_code, bus_id);
create index if not exists finance_lines_rider_idx on public.finance_lines(passenger_id)
  where passenger_id is not null;

alter table public.finance_lines enable row level security;
drop policy if exists "finance_lines_owner_read" on public.finance_lines;
create policy "finance_lines_owner_read" on public.finance_lines
  for select to authenticated
  using (exists (select 1
                   from public.finance_entries e
                   join public.tours t on t.id = e.tour_id
                  where e.id = finance_lines.entry_id
                    and t.owner_id = auth.uid()));


-- ── 5. The invariant ─────────────────────────────────────────
-- Deferred to COMMIT so lines can be inserted one at a time. This is what
-- makes "the books balance" a property of the database rather than a hope.

create or replace function public.finance_entry_balanced() returns trigger
language plpgsql set search_path = public as $$
declare
  v_sum bigint;
  v_n   int;
begin
  select coalesce(sum(amount_minor), 0), count(*)
    into v_sum, v_n
    from public.finance_lines where entry_id = new.entry_id;

  -- An entry whose lines were all rolled back is fine; it simply has none.
  if v_n = 0 then
    return null;
  end if;
  if v_n < 2 then
    raise exception 'finance entry % has only % line; an entry needs at least two sides',
      new.entry_id, v_n;
  end if;
  if v_sum <> 0 then
    raise exception 'finance entry % does not balance (sum = %)', new.entry_id, v_sum;
  end if;
  return null;
end $$;

drop trigger if exists finance_lines_balanced on public.finance_lines;
create constraint trigger finance_lines_balanced
  after insert on public.finance_lines
  deferrable initially deferred
  for each row execute function public.finance_entry_balanced();

-- The trigger above hangs off finance_LINES, so an entry inserted with NO
-- lines at all never fires it and would survive as a dangling row that means
-- nothing and balances nothing. This one hangs off the ENTRY, so every entry
-- must have acquired its sides by COMMIT.
create or replace function public.finance_entry_has_lines() returns trigger
language plpgsql set search_path = public as $$
declare
  v_sum bigint;
  v_n   int;
begin
  select coalesce(sum(amount_minor), 0), count(*)
    into v_sum, v_n
    from public.finance_lines where entry_id = new.id;

  if v_n = 0 then
    raise exception 'finance entry % has no lines; an entry must record both sides', new.id;
  end if;
  if v_n < 2 then
    raise exception 'finance entry % has only % line; an entry needs at least two sides',
      new.id, v_n;
  end if;
  if v_sum <> 0 then
    raise exception 'finance entry % does not balance (sum = %)', new.id, v_sum;
  end if;
  return null;
end $$;

drop trigger if exists finance_entries_have_lines on public.finance_entries;
create constraint trigger finance_entries_have_lines
  after insert on public.finance_entries
  deferrable initially deferred
  for each row execute function public.finance_entry_has_lines();


-- ── 6. Immutability ──────────────────────────────────────────
-- A posted entry is history. Fix mistakes with a reversing entry.

create or replace function public.finance_immutable() returns trigger
language plpgsql as $$
begin
  raise exception
    'the finance ledger is append-only (% on %); post a reversing entry instead',
    tg_op, tg_table_name;
end $$;

drop trigger if exists finance_entries_no_mutate on public.finance_entries;
create trigger finance_entries_no_mutate
  before update or delete on public.finance_entries
  for each row execute function public.finance_immutable();

drop trigger if exists finance_lines_no_mutate on public.finance_lines;
create trigger finance_lines_no_mutate
  before update or delete on public.finance_lines
  for each row execute function public.finance_immutable();


-- ── 7. Posting guard ─────────────────────────────────────────
-- Nothing may post into a CLOSED settlement. Late arrivals from an offline
-- device go to the held lane (§8) instead of being rejected or silently
-- reopening settled books.

create or replace function public.finance_entry_settlement_open() returns trigger
language plpgsql set search_path = public as $$
declare v_status text;
begin
  if new.settlement_id is null then
    return new;
  end if;
  select status into v_status
    from public.finance_settlements where id = new.settlement_id;
  if v_status = 'closed' then
    raise exception 'settlement % is closed; hold the entry or reopen first', new.settlement_id
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists finance_entries_settlement_open on public.finance_entries;
create trigger finance_entries_settlement_open
  before insert on public.finance_entries
  for each row execute function public.finance_entry_settlement_open();


-- ── 8. Held lane ─────────────────────────────────────────────
-- An entry recorded offline BEFORE a settlement closed, arriving AFTER.
-- Rejecting loses real money; auto-reopening unfreezes settled books behind
-- the agent's back. So it waits here for an explicit decision.
--
-- A separate table, not a status column, so the ledger keeps a strict
-- append-only shape with no UPDATE path to except.

create table if not exists public.finance_entries_held (
  id                uuid primary key default gen_random_uuid(),
  tour_id           uuid not null references public.tours(id),
  bus_id            uuid references public.buses(id),
  payload           jsonb not null,
  client_request_id text not null,
  occurred_at       timestamptz not null,
  received_at       timestamptz not null default now(),
  reason            text not null default 'settlement_closed',
  resolved_at       timestamptz,
  resolution        text check (resolution in ('accepted','rejected')),
  resolution_reason text,
  unique (tour_id, client_request_id)
);

create index if not exists finance_entries_held_open_idx
  on public.finance_entries_held(tour_id) where resolved_at is null;

alter table public.finance_entries_held enable row level security;
drop policy if exists "finance_held_owner_read" on public.finance_entries_held;
create policy "finance_held_owner_read" on public.finance_entries_held
  for select to authenticated
  using (exists (select 1 from public.tours t
                  where t.id = finance_entries_held.tour_id
                    and t.owner_id = auth.uid()));


-- ── 9. Audit log ─────────────────────────────────────────────
-- The ledger records money. This records everything that CHANGES money
-- without being money — above all a price-band edit, which today re-prices
-- every rider on a bus and leaves no trace anywhere.

create table if not exists public.audit_log (
  id            bigserial primary key,
  at            timestamptz not null default now(),
  table_name    text not null,
  row_id        uuid,
  op            text not null check (op in ('INSERT','UPDATE','DELETE')),
  actor_kind    text,
  actor_user_id uuid,
  actor_label   text,
  before        jsonb,
  after         jsonb,
  changed_keys  text[],
  txid          bigint not null default txid_current()
);

create index if not exists audit_log_row_idx
  on public.audit_log(table_name, row_id, at desc);
create index if not exists audit_log_at_idx on public.audit_log(at desc);

alter table public.audit_log enable row level security;
-- Read-only to the app; only triggers (definer) ever write.
drop policy if exists "audit_log_read" on public.audit_log;
create policy "audit_log_read" on public.audit_log
  for select to authenticated using (true);

create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_before jsonb;
  v_after  jsonb;
  v_keys   text[];
  v_id     uuid;
begin
  if tg_op = 'INSERT' then
    v_after := to_jsonb(new);
  elsif tg_op = 'UPDATE' then
    v_before := to_jsonb(old);
    v_after  := to_jsonb(new);
    select array_agg(key order by key) into v_keys
      from jsonb_each(v_after)
     where v_before -> key is distinct from v_after -> key;
    -- A no-op update is noise, not history.
    if v_keys is null then
      return new;
    end if;
  else
    v_before := to_jsonb(old);
  end if;

  begin
    v_id := coalesce((v_after->>'id')::uuid, (v_before->>'id')::uuid);
  exception when others then
    v_id := null;
  end;

  insert into public.audit_log
    (table_name, row_id, op, actor_kind, actor_user_id, actor_label,
     before, after, changed_keys)
  values
    (tg_table_name, v_id, tg_op,
     public.finance_actor_kind(), auth.uid(), public.finance_actor_label(),
     v_before, v_after, v_keys);

  return coalesce(new, old);
end $$;

-- Attach to what moves money, and to what silently re-prices it.
drop trigger if exists collections_audit    on public.collections;
create trigger collections_audit    after insert or update or delete on public.collections
  for each row execute function public.audit_row();
drop trigger if exists expenses_audit       on public.expenses;
create trigger expenses_audit       after insert or update or delete on public.expenses
  for each row execute function public.audit_row();
drop trigger if exists incomes_audit        on public.incomes;
create trigger incomes_audit        after insert or update or delete on public.incomes
  for each row execute function public.audit_row();
drop trigger if exists bus_handovers_audit  on public.bus_handovers;
create trigger bus_handovers_audit  after insert or update or delete on public.bus_handovers
  for each row execute function public.audit_row();
-- Buses: a price_bands / bus_price edit is a money event with no money row.
drop trigger if exists buses_audit          on public.buses;
create trigger buses_audit          after insert or update or delete on public.buses
  for each row execute function public.audit_row();


-- ── 10. Balances ─────────────────────────────────────────────
-- The single primitive every screen will read.

create or replace view public.finance_balances as
select
  e.tour_id,
  l.account_code,
  l.bus_id,
  l.passenger_id,
  sum(l.amount_minor)::bigint as balance_minor,
  count(*)::int               as line_count,
  max(e.occurred_at)          as last_movement_at
from public.finance_lines l
join public.finance_entries e on e.id = l.entry_id
group by e.tour_id, l.account_code, l.bus_id, l.passenger_id;

-- Per-bus rollup shaped like today's BusMoneySummary, so P4 can diff the two
-- side by side. Every figure here is a sum of ledger lines — no formula.
create or replace view public.finance_bus_summary as
select
  e.tour_id,
  l.bus_id,
  -- cash the handler still holds for this bus == what they owe the admin
  coalesce(sum(l.amount_minor) filter (where l.account_code = 'cash.handler'), 0)::bigint
    as outstanding_handover_minor,
  coalesce(-sum(l.amount_minor) filter (where l.account_code = 'revenue.fare'), 0)::bigint
    as billed_minor,
  coalesce(-sum(l.amount_minor) filter (where l.account_code = 'revenue.extra'), 0)::bigint
    as income_minor,
  coalesce(sum(l.amount_minor) filter (where l.account_code = 'expense.ground'), 0)::bigint
    as ground_expenses_minor,
  coalesce(sum(l.amount_minor) filter (where l.account_code = 'expense.rent'), 0)::bigint
    as rent_minor,
  coalesce(-sum(l.amount_minor) filter (where l.account_code = 'payable.owner'), 0)::bigint
    as owner_unpaid_minor
from public.finance_lines l
join public.finance_entries e on e.id = l.entry_id
where l.bus_id is not null
group by e.tour_id, l.bus_id;

-- What each rider owes (positive) or is owed (negative), live.
create or replace view public.finance_rider_balance as
select
  e.tour_id,
  l.passenger_id,
  sum(l.amount_minor)::bigint as owes_minor
from public.finance_lines l
join public.finance_entries e on e.id = l.entry_id
where l.account_code = 'ar.rider'
  and l.passenger_id is not null
group by e.tour_id, l.passenger_id;


-- ============================================================
-- SMOKE TEST (safe to run; rolls back):
--
--   begin;
--     insert into public.finance_entries (tour_id, kind, actor_kind, client_request_id)
--     values ('<a tour id>', 'cash_receipt', 'system', 'smoke-1')
--     returning id \gset e_
--     insert into public.finance_lines (entry_id, account_code, bus_id, amount_minor)
--     values (:'e_id', 'cash.handler', '<a bus id>', 27500);
--     -- this COMMIT must FAIL: the entry does not balance
--   commit;
--
-- Then the same with the matching credit line added; it must succeed.
-- ============================================================
