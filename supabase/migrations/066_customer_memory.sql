-- 066 — Create `customer_memory` on databases that predate it.
--
-- WHY
-- ---
-- `customer_memory` is defined in the root `database.sql` (the full-schema
-- bootstrap used to stand up a FRESH project) but never got a corresponding
-- incremental migration. Any database created before it was added to that file
-- therefore never receives the table, and the live one reports:
--
--   PGRST205 — Could not find the table 'public.customer_memory' in the schema cache
--
-- The app already degrades cleanly on this: CustomerMemoryController checks
-- SyncReadProjections.isMissingTableError, sets `tableUnavailable`, and stops
-- retrying — memory is a best-effort enhancement and never blocks the app. The
-- only cost is that the feature it powers stays inert: a returning phone does
-- not get its agent-set priority auto-restored, and its usual travel companions
-- are not offered as a one-tap group.
--
-- Columns mirror CustomerMemory.toMap() and SyncReadProjections
-- .customerMemorySelect. Written idempotently because migrations here are
-- applied by hand, one file at a time, against databases in differing states.

create table if not exists public.customer_memory (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references auth.users(id) on delete cascade,
  phone           text not null,            -- 10-digit normalised key
  name            text not null default '',
  priority_status text not null default 'none',
  priority_reason text,
  companions      jsonb not null default '[]'::jsonb,  -- companion phones
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- One memory row per (admin, phone) — upserts target this constraint.
create unique index if not exists customer_memory_owner_phone_unique
  on public.customer_memory(owner_id, phone);
create index if not exists customer_memory_phone_idx
  on public.customer_memory(phone);

drop trigger if exists customer_memory_set_updated_at on public.customer_memory;
create trigger customer_memory_set_updated_at
  before update on public.customer_memory
  for each row execute function public.set_updated_at();

alter table public.customer_memory enable row level security;

-- Per-admin isolation: an agent only ever sees their own customer memory.
drop policy if exists "customer_memory_owner_all" on public.customer_memory;
create policy "customer_memory_owner_all" on public.customer_memory
  for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

comment on table public.customer_memory is
  'Per-admin, phone-keyed memory of returning customers (priority + travel companions), snapshotted before a tour is deleted. See migration 066.';
