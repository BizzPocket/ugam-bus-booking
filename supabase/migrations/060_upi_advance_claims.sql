-- ============================================================
-- 060_upi_advance_claims.sql   —   the UPI advance stops being invisible
-- ------------------------------------------------------------
-- THE DEFECT, precisely: `_offerAdvance` in seat_booking_confirm_screen.dart
-- shows the customer a UPI QR, awaits it, and returns void. It writes NOTHING.
-- The money lands in the organiser's account and the app never knows. So the
-- handler's collect sheet — which prices from `Bus.amountDueForSeat`, not from
-- anything the customer has paid — shows the FULL fare and collects it again.
-- The rider pays twice, and the argument happens on a bus with nobody able to
-- check.
--
-- WHY A CLAIM AND NOT A PAYMENT
-- This rail is a direct UPI deep-link to the organiser's own VPA (050). It is
-- zero-MDR precisely BECAUSE no gateway sits in the middle — and therefore
-- nothing calls us back. There is no webhook, no order id, no signature to
-- verify. Anything the app records at this moment is the CUSTOMER'S ASSERTION
-- that they paid, not proof.
--
-- Pretending otherwise would be worse than the current bug: a fabricated claim
-- that silently reduced what the handler collects is a way to ride for free.
-- So a claim is recorded as unverified, is visible to the admin AND the handler
-- immediately, and only becomes money when a human confirms it.
--
-- That ordering is the whole fix. Even before anyone confirms, the handler sees
-- "customer says they paid ₹500, ref 4471…" on the collect sheet, and stops
-- charging it twice.
--
-- 049's Razorpay tables stay untouched and unused. If a gateway is ever wired
-- up, `record_online_payment` is the verified path and this one remains for the
-- QR rail.
--
-- Requires 056 (ledger) and 058 (backfill helpers). Idempotent.
-- Apply in the Supabase SQL editor, isolated.
-- ============================================================

do $$
begin
  if to_regclass('public.finance_entries') is null then
    raise exception '060 requires 056_finance_ledger.sql first';
  end if;
end $$;


-- ── 1. The claim ─────────────────────────────────────────────

create table if not exists public.payment_claims (
  id                 uuid primary key default gen_random_uuid(),
  tour_id            uuid not null references public.tours(id),
  booking_request_id uuid references public.booking_requests(id) on delete set null,
  passenger_id       uuid references public.passengers(id),

  amount_paise       bigint not null check (amount_paise > 0),
  -- The UPI reference / UTR the payer reads off their own app. Free text: it is
  -- a lookup aid for the admin checking their bank statement, never a proof.
  upi_ref            text,
  payer_name         text,
  payer_phone        text,

  status             text not null default 'pending'
                       check (status in ('pending','confirmed','rejected')),
  claimed_at         timestamptz not null default now(),
  reviewed_at        timestamptz,
  reviewed_by        uuid,
  review_note        text,

  -- Set when confirmation posts to the ledger, so a double-confirm is visible.
  finance_entry_id   uuid references public.finance_entries(id),

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists payment_claims_tour_idx
  on public.payment_claims(tour_id, status);
create index if not exists payment_claims_pending_idx
  on public.payment_claims(tour_id) where status = 'pending';
create index if not exists payment_claims_passenger_idx
  on public.payment_claims(passenger_id) where passenger_id is not null;
create index if not exists payment_claims_request_idx
  on public.payment_claims(booking_request_id);

alter table public.payment_claims enable row level security;

-- The owning agent reads and reviews. Customers never touch the table
-- directly; they go through the SECURITY DEFINER RPC below.
drop policy if exists "payment_claims_owner_all" on public.payment_claims;
create policy "payment_claims_owner_all" on public.payment_claims
  for all to authenticated
  using (exists (select 1 from public.tours t
                  where t.id = payment_claims.tour_id and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                       where t.id = payment_claims.tour_id and t.owner_id = auth.uid()));


-- ── 2. Customer files a claim ────────────────────────────────
-- Anon-callable, because the payer has no session. Everything that matters is
-- derived server-side from the booking request; the caller supplies only the
-- amount and their reference. Rate-limited to stop a bored client filing
-- hundreds against one booking.

create or replace function public.claim_upi_advance(
  p_request_id   uuid,
  p_amount_paise bigint,
  p_upi_ref      text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_tour   uuid;
  v_pax    uuid;
  v_name   text;
  v_phone  text;
  v_recent int;
  v_id     uuid;
begin
  if p_amount_paise is null or p_amount_paise <= 0 then
    raise exception 'claim amount must be positive';
  end if;
  -- A tour advance is not a lakh. Bound it so a fat finger or a hostile client
  -- cannot park an absurd figure in front of the agent.
  if p_amount_paise > 100000000 then          -- ₹10,00,000
    raise exception 'claim amount is implausibly large';
  end if;

  select br.tour_id, br.passenger_id, br.customer_name, br.customer_phone
    into v_tour, v_pax, v_name, v_phone
    from public.booking_requests br
   where br.id = p_request_id;

  if v_tour is null then
    raise exception 'unknown booking request';
  end if;

  -- Rate limit: at most 5 claims per booking in 10 minutes.
  select count(*) into v_recent
    from public.payment_claims
   where booking_request_id = p_request_id
     and claimed_at > now() - interval '10 minutes';
  if v_recent >= 5 then
    raise exception 'too many payment claims for this booking; please wait';
  end if;

  insert into public.payment_claims (
    tour_id, booking_request_id, passenger_id,
    amount_paise, upi_ref, payer_name, payer_phone
  )
  values (
    v_tour, p_request_id, v_pax,
    p_amount_paise, nullif(btrim(coalesce(p_upi_ref, '')), ''), v_name, v_phone
  )
  returning id into v_id;

  return v_id;
end $$;

revoke all on function public.claim_upi_advance(uuid, bigint, text) from public;
grant execute on function public.claim_upi_advance(uuid, bigint, text)
  to anon, authenticated;


-- ── 3. What the customer may read back ───────────────────────
-- Their own claims for their own booking. No other booking's data.

create or replace function public.my_payment_claims(p_request_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select jsonb_agg(jsonb_build_object(
              'id',           c.id,
              'amount_paise', c.amount_paise,
              'upi_ref',      c.upi_ref,
              'status',       c.status,
              'claimed_at',   c.claimed_at,
              'reviewed_at',  c.reviewed_at
            ) order by c.claimed_at desc)
       from public.payment_claims c
      where c.booking_request_id = p_request_id),
    '[]'::jsonb
  );
$$;

revoke all on function public.my_payment_claims(uuid) from public;
grant execute on function public.my_payment_claims(uuid) to anon, authenticated;


-- ── 4. What the HANDLER sees ─────────────────────────────────
-- The point of the whole file. Before anyone confirms anything, the handler's
-- collect sheet can show "this rider says they already paid ₹500" and stop
-- charging it twice.
--
-- Scoped to riders seated on THIS handler's buses — the same boundary
-- handler_owns_bus() enforces everywhere else. A separate function rather than
-- another patch to the 190-line manifest.

create or replace function public.handler_payment_claims(p_request_id uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select case
    when not public.is_request_handler(p_request_id) then '[]'::jsonb
    else coalesce(
      (select jsonb_agg(jsonb_build_object(
                'id',           c.id,
                'passenger_id', c.passenger_id,
                'amount_paise', c.amount_paise,
                'upi_ref',      c.upi_ref,
                'status',       c.status,
                'claimed_at',   c.claimed_at
              ) order by c.claimed_at desc)
         from public.payment_claims c
         join public.passengers p on p.id = c.passenger_id
        where c.status in ('pending','confirmed')
          and p.deleted_at is null
          and exists (
            select 1
              from jsonb_array_elements(coalesce(p.assigned_seats,'[]'::jsonb)) s
             where public.handler_owns_bus(p_request_id, (s->>'busId')::uuid)
          )),
      '[]'::jsonb
    )
  end;
$$;

revoke all on function public.handler_payment_claims(uuid) from public;
grant execute on function public.handler_payment_claims(uuid) to anon, authenticated;


-- ── 5. Admin confirms — the claim becomes money ──────────────
-- Posts to the ledger AND to the legacy `collections` rows, because the app
-- still reads collections until P6. Both or neither: one transaction.
--
-- The advance is spread across the rider's seats on the bus, filling each
-- seat's due in turn. In the ledger this distribution is unnecessary —
-- `ar.rider` is passenger-scoped, which is exactly the point — but the legacy
-- table is keyed (passenger, bus, seat) and has to be fed something coherent.

create or replace function public.confirm_payment_claim(
  p_claim_id uuid,
  p_note     text default null
) returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  c            record;
  v_entry      uuid;
  v_remaining  bigint;
  v_seat       record;
  v_due        bigint;
  v_apply      bigint;
  v_bus        uuid;
begin
  select * into c from public.payment_claims where id = p_claim_id;
  if not found then
    raise exception 'unknown payment claim';
  end if;

  -- Owner-only. SECURITY DEFINER bypasses RLS, so the check is explicit.
  if not exists (
    select 1 from public.tours t
     where t.id = c.tour_id and t.owner_id = auth.uid()
  ) then
    raise exception 'not authorized for this tour';
  end if;

  if c.status = 'confirmed' then
    return c.finance_entry_id;        -- idempotent
  end if;
  if c.status = 'rejected' then
    raise exception 'claim was already rejected';
  end if;

  perform public.finance_set_actor('admin', 'advance confirmation');

  -- Ledger: money in the bank, rider owes that much less.
  select o_entry into v_entry from public.backfill_post(
    c.tour_id, 'online_payment', 'claim:' || c.id,
    c.claimed_at, c.amount_paise,
    'bank.gateway', null, null,
    'ar.rider',     null, c.passenger_id,
    'payment_claims', c.id, 'upi_advance',
    coalesce(p_note, 'UPI advance' ||
      case when c.upi_ref is null then '' else ' ref ' || c.upi_ref end)
  );

  -- Legacy collections, so the handler's sheet reflects it before P6.
  v_remaining := c.amount_paise;
  if c.passenger_id is not null then
    for v_seat in
      select distinct
             (s->>'busId')::uuid              as bus_id,
             split_part(s->>'seatId','#',1)   as seat_id
        from public.passengers p
        cross join lateral jsonb_array_elements(
          coalesce(p.assigned_seats,'[]'::jsonb)) s
       where p.id = c.passenger_id
         and coalesce(s->>'busId','') <> ''
       order by 1, 2
    loop
      exit when v_remaining <= 0;
      v_due  := public.baseline_seat_due_paise(
                  c.passenger_id, v_seat.bus_id, v_seat.seat_id);
      v_apply := least(v_remaining, greatest(v_due, 0));
      if v_apply > 0 then
        insert into public.collections (
          tour_id, bus_id, passenger_id, seat_id,
          amount_due, amount_received, amount_refunded, note, collected_by
        )
        values (
          c.tour_id, v_seat.bus_id, c.passenger_id, v_seat.seat_id,
          v_due / 100.0, v_apply / 100.0, 0,
          'UPI advance' || case when c.upi_ref is null then ''
                                else ' ref ' || c.upi_ref end,
          'online'
        )
        on conflict (passenger_id, bus_id, seat_id) where deleted_at is null
        do update set
          amount_received = public.collections.amount_received
                            + excluded.amount_received,
          -- APPEND, never replace. The handler may already have written a note
          -- on this row, and overwriting it would destroy their record. But
          -- without adding anything, the row's amount silently grows with no
          -- statement of why — the ledger would know and the person holding
          -- the phone would not.
          note = case
                   when coalesce(btrim(public.collections.note), '') = ''
                     then excluded.note
                   else public.collections.note || ' · ' || excluded.note
                 end,
          updated_at = now();
        v_remaining := v_remaining - v_apply;
      end if;
    end loop;
  end if;

  update public.payment_claims
     set status = 'confirmed',
         reviewed_at = now(),
         reviewed_by = auth.uid(),
         review_note = p_note,
         finance_entry_id = v_entry,
         updated_at = now()
   where id = p_claim_id;

  return v_entry;
end $$;

revoke all on function public.confirm_payment_claim(uuid, text) from public;
grant execute on function public.confirm_payment_claim(uuid, text) to authenticated;


-- ── 6. Admin rejects ─────────────────────────────────────────
-- No money moves. The row stays forever with its reason — a rejected claim is
-- exactly the kind of thing someone asks about three months later.

create or replace function public.reject_payment_claim(
  p_claim_id uuid,
  p_reason   text
) returns void
language plpgsql security definer set search_path = public
as $$
declare c record;
begin
  select * into c from public.payment_claims where id = p_claim_id;
  if not found then
    raise exception 'unknown payment claim';
  end if;
  if not exists (
    select 1 from public.tours t
     where t.id = c.tour_id and t.owner_id = auth.uid()
  ) then
    raise exception 'not authorized for this tour';
  end if;
  if c.status = 'confirmed' then
    raise exception 'claim was already confirmed; reverse it in the ledger instead';
  end if;

  update public.payment_claims
     set status = 'rejected',
         reviewed_at = now(),
         reviewed_by = auth.uid(),
         review_note = coalesce(nullif(btrim(p_reason), ''), 'rejected'),
         updated_at = now()
   where id = p_claim_id;
end $$;

revoke all on function public.reject_payment_claim(uuid, text) from public;
grant execute on function public.reject_payment_claim(uuid, text) to authenticated;


-- ── 7. Audit ─────────────────────────────────────────────────
drop trigger if exists payment_claims_audit on public.payment_claims;
create trigger payment_claims_audit
  after insert or update or delete on public.payment_claims
  for each row execute function public.audit_row();


-- ============================================================
-- VERIFY
--   select public.claim_upi_advance('<booking request id>', 50000, 'UTR123');
--   select * from public.payment_claims where status = 'pending';
--   select public.confirm_payment_claim('<claim id>');
--   -- rider now owes 500 less:
--   select * from public.finance_rider_balance where passenger_id = '<pax>';
-- ============================================================
