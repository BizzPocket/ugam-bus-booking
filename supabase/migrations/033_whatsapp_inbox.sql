-- ============================================================
-- 033  WhatsApp inbox  (two-way conversations — owner-scoped)
-- ------------------------------------------------------------
-- A real two-way WhatsApp inbox for admins, built on the official WhatsApp
-- Cloud API. Every customer number the business talks to becomes ONE
-- `wa_conversations` row; every message (inbound customer -> business, or
-- outbound business -> customer) becomes a `wa_messages` row under it.
--
-- WHO WRITES WHAT
--   * The Meta webhook Edge Function (SERVICE ROLE) is the ONLY writer of
--     conversations and inbound messages. On each inbound event it upserts the
--     conversation (by customer_phone), resolves the owning admin via
--     wa_resolve_owner(), appends the message, bumps unread_count and the
--     last_* markers. Because it runs with the service role it BYPASSES RLS —
--     none of the authenticated policies below constrain it.
--   * The wa-reply Edge Function (SERVICE ROLE) inserts OUTBOUND messages after
--     the Graph send succeeds (storing Graph's message id in wa_message_id) and
--     later patches `status` from delivery webhooks. Also RLS-exempt.
--   * The Flutter admin app (role `authenticated`, admins.id = auth.uid())
--     only ever READS its own conversations/messages and calls wa_mark_read /
--     claims an unassigned thread — governed by the RLS policies below.
--
-- OWNER ROUTING
--   owner_id is NULLABLE: null means "unassigned" (we received a message from a
--   number we can't yet map to an admin). wa_resolve_owner(phone) matches the
--   LAST 10 digits of the number against booking_requests (most recent first),
--   then passengers, and returns that tour's owner_id so the webhook can stamp
--   the thread. Unassigned threads are visible to every authenticated admin
--   (owner_id IS NULL in the policies) so one of them can pick it up.
--
--   owner_id -> public.admins(id): in the LIVE DB admins.id EQUALS the Supabase
--   auth user id (auth.uid()), so per-owner isolation is simply
--   `owner_id = auth.uid()`. Service-role bypasses RLS.
--
-- DEPLOYMENT
--   Run THIS FILE ALONE in the Supabase SQL editor (do NOT `supabase db push` —
--   the numbered migration history table is empty / out of sync with live, and
--   push would replay the old pre-owner-model schema). Written against the LIVE
--   schema (admins, tours.owner_id, booking_requests). Fully idempotent:
--   create-if-not-exists tables/indexes, drop-if-exists policies before create,
--   and a guarded publication add.
-- ============================================================

begin;

-- ── 1. Conversations — one row per customer phone number ───
create table if not exists public.wa_conversations (
  id                   uuid primary key default gen_random_uuid(),
  owner_id             uuid references public.admins(id) on delete cascade,  -- NULL = unassigned
  customer_phone       text not null unique,        -- Graph digits form, e.g. 919876543210
  customer_name        text,                         -- best-effort (WA profile name or booking lookup)
  last_message_at      timestamptz not null default now(),
  last_message_preview text,
  last_inbound_at      timestamptz,                  -- last INBOUND msg time; drives the 24h reply window
  unread_count         integer not null default 0,
  created_at           timestamptz not null default now()
);

-- ── 2. Messages — one row per inbound/outbound message ─────
create table if not exists public.wa_messages (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.wa_conversations(id) on delete cascade,
  wa_message_id   text unique,        -- Meta inbound id / Graph outbound id; dedup key
  direction       text not null check (direction in ('in','out')),
  body            text,
  msg_type        text not null default 'text',   -- 'text'|'image'|'document'|'audio'|'video'|'other'
  status          text,               -- outbound only: 'sent'|'delivered'|'read'|'failed'
  created_at      timestamptz not null default now()
);

-- ── 3. Indexes ─────────────────────────────────────────────
-- customer_phone + wa_message_id already carry unique indexes from their
-- UNIQUE constraints above; these cover the two hot read paths.
create index if not exists wa_messages_conv_created_idx
  on public.wa_messages(conversation_id, created_at);

create index if not exists wa_conversations_owner_last_msg_idx
  on public.wa_conversations(owner_id, last_message_at desc);

-- ── 4. RLS ─────────────────────────────────────────────────
alter table public.wa_conversations enable row level security;
alter table public.wa_messages      enable row level security;

-- Conversations: an admin sees/updates their own threads AND any unassigned
-- one (so they can claim it). No INSERT/DELETE for authenticated — the
-- service-role webhook is the sole creator. UPDATE (owner-or-null) is what lets
-- wa_mark_read reset unread_count and a claim set owner_id.
drop policy if exists "wa_conversations_owner_select" on public.wa_conversations;
create policy "wa_conversations_owner_select" on public.wa_conversations
  for select to authenticated
  using (owner_id = auth.uid() or owner_id is null);

drop policy if exists "wa_conversations_owner_update" on public.wa_conversations;
create policy "wa_conversations_owner_update" on public.wa_conversations
  for update to authenticated
  using (owner_id = auth.uid() or owner_id is null)
  with check (owner_id = auth.uid() or owner_id is null);

-- Messages: readable when the parent conversation is the admin's own or
-- unassigned. No direct write for authenticated — the wa-reply Edge Function
-- inserts outbound rows with the service role.
drop policy if exists "wa_messages_owner_select" on public.wa_messages;
create policy "wa_messages_owner_select" on public.wa_messages
  for select to authenticated
  using (exists (
    select 1 from public.wa_conversations c
     where c.id = wa_messages.conversation_id
       and (c.owner_id = auth.uid() or c.owner_id is null)
  ));

-- ── 5. wa_resolve_owner — map a phone to its owning admin ──
-- Normalizes by comparing the LAST 10 digits (non-digits stripped). Looks in
-- booking_requests first (most recent by created_at), then passengers, and
-- returns that tour's owner_id, else null. SECURITY DEFINER so the webhook /
-- any caller can resolve regardless of RLS; search_path locked to public.
create or replace function public.wa_resolve_owner(p_phone text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_norm  text;
  v_owner uuid;
begin
  v_norm := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  if v_norm is null or length(v_norm) < 10 then
    return null;
  end if;

  -- Most recent booking request from this number.
  select t.owner_id
    into v_owner
    from public.booking_requests br
    join public.tours t on t.id = br.tour_id
   where right(regexp_replace(coalesce(br.customer_phone, ''), '\D', '', 'g'), 10) = v_norm
     and t.owner_id is not null
   order by br.created_at desc
   limit 1;

  if v_owner is not null then
    return v_owner;
  end if;

  -- Fall back to the passenger roster.
  select t.owner_id
    into v_owner
    from public.passengers p
    join public.tours t on t.id = p.tour_id
   where right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 10) = v_norm
     and t.owner_id is not null
   order by p.created_at desc
   limit 1;

  return v_owner;
end;
$$;

-- ── 6. wa_mark_read — clear a thread's unread badge ────────
-- SECURITY DEFINER; only clears a conversation the caller actually owns (or an
-- unassigned one). Runs under the definer but auth.uid() still reflects the
-- CALLING admin's JWT, so cross-owner clears are impossible.
create or replace function public.wa_mark_read(p_conversation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.wa_conversations
     set unread_count = 0
   where id = p_conversation_id
     and (owner_id = auth.uid() or owner_id is null);
end;
$$;

revoke all on function public.wa_resolve_owner(text) from public;
revoke all on function public.wa_mark_read(uuid)      from public;
grant execute on function public.wa_resolve_owner(text) to authenticated;
grant execute on function public.wa_mark_read(uuid)      to authenticated;

-- ── 7. Realtime ────────────────────────────────────────────
-- The admin inbox subscribes to both tables for live updates. Guarded so a
-- re-run never errors if the table is already in the publication.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'wa_conversations'
  ) then
    alter publication supabase_realtime add table public.wa_conversations;
  end if;

  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'wa_messages'
  ) then
    alter publication supabase_realtime add table public.wa_messages;
  end if;
end $$;

commit;
