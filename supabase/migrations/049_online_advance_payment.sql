-- ============================================================
-- 049  Online advance payment (Razorpay)
-- ------------------------------------------------------------
-- Lets a customer pay an ADVANCE online after picking their seats. The seat is
-- already theirs the moment `chart_claim_seats` succeeds (048) — payment does
-- NOT gate the claim. That is deliberate:
--
--   * No seat hold, no TTL, no expiry job. GSRTC holds for 7 minutes and its
--     single most-reported bug is seats stuck "booked" after an abandoned
--     payment. With the claim already committed there is nothing to strand.
--   * It matches this market: 7 of 10 Gujarat operators surveyed run
--     phone-book -> PNR -> pay-online-later. The seat exists before the money.
--   * An unpaid booking is released by the ORGANISER, deliberately, not by a
--     background timer.
--
-- *** WHY AN ADVANCE, NOT THE FULL FARE ***
-- Razorpay costs 2% + 18% GST = 2.36%, and refunds never return it ("Fees and
-- taxes charged for a captured payment are not reversed"). Full online on a
-- ~40-berth bus of Rs 9,000 seats burns ~Rs 8,500 a trip; a Rs 2,000 advance
-- burns ~Rs 1,900. The balance keeps arriving as cash on the bus, through the
-- collection ledger that already exists.
--
-- We deliberately do NOT use Razorpay's `accept_partial`: it assumes the
-- balance also arrives through Razorpay, and there is no documented way to
-- close a `partially_paid` order once the rest is taken in cash. Instead the
-- Razorpay order is created for EXACTLY the advance, so it settles cleanly to
-- `paid` and reconciliation stays honest.
--
-- *** MONEY IS INTEGER PAISE HERE ***
-- Razorpay speaks only integer paise. Every amount below is `bigint` paise, not
-- a double — which also keeps this rail clear of the float-epsilon problem that
-- affects the rupee-denominated cash ledger.
--
-- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent.
-- ============================================================

-- ── 1. Per-tour advance policy ───────────────────────────────
-- Paise per BERTH the customer is asked to pay online up front.
--   NULL  -> no online payment offered on this tour (today's behaviour)
--   0     -> online payment offered for the FULL amount due
--   > 0   -> that much per berth, balance collected as cash on the bus
alter table public.tours
  add column if not exists advance_per_berth_paise bigint;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'tours_advance_per_berth_chk'
  ) then
    alter table public.tours
      add constraint tours_advance_per_berth_chk
      check (advance_per_berth_paise is null or advance_per_berth_paise >= 0);
  end if;
end $$;

-- ── 2. Per-berth price, in paise ─────────────────────────────
-- EXACT mirror of `Bus.berthPriceFor` in lib/models/bus_details.dart. The two
-- MUST agree — the Dart side quotes the customer, this side is what actually
-- gets charged. A parity test pins them together; change one, change both.
--
-- Precedence, same as Dart:
--   1. explicit price_bands, FIRST match by row wins
--   2. the legacy rear zone, appended AFTER the explicit bands
--   3. per-type override (double_sofa_price is the WHOLE sofa, so half a berth)
--   4. price_per_seat
create or replace function public.bus_berth_price_paise(
  p_bus_id    uuid,
  p_seat_type text,
  p_row       int
) returns bigint
language plpgsql stable security definer set search_path = public
as $$
declare
  b        record;
  v_rows   int;
  v_band   numeric;
  v_price  numeric;
  v_from   int;
begin
  select price_bands, rear_rows, rear_price, single_sofa_price,
         double_sofa_price, seater_price, price_per_seat, layout
    into b
    from public.buses
   where id = p_bus_id;
  if not found then
    return 0;
  end if;

  v_rows := coalesce((b.layout->>'rows')::int, 0);

  -- 1. Explicit bands, in declared order — first match wins.
  select (band->>'price')::numeric
    into v_band
    from jsonb_array_elements(coalesce(b.price_bands, '[]'::jsonb))
         with ordinality as t(band, ord)
   where p_row between least((band->>'fromRow')::int, (band->>'toRow')::int)
                   and greatest((band->>'fromRow')::int, (band->>'toRow')::int)
   order by t.ord
   limit 1;

  -- 2. Legacy rear zone — only consulted when no explicit band covered the row,
  --    matching Dart's `effectiveBands` (explicit bands, then the synthesized
  --    rear band appended last). Dart clamps the start row to [0, rows-1].
  if v_band is null
     and coalesce(b.rear_rows, 0) > 0
     and b.rear_price is not null
     and v_rows > 0 then
    v_from := least(greatest(v_rows - b.rear_rows, 0), v_rows - 1);
    if p_row >= v_from then
      v_band := b.rear_price;
    end if;
  end if;

  if v_band is not null then
    return round(v_band * 100)::bigint;
  end if;

  -- 3/4. Per-type override, else the base per-seat price.
  v_price := case p_seat_type
    when 'singleSofa' then coalesce(b.single_sofa_price, b.price_per_seat)
    when 'doubleSofa' then
      case when b.double_sofa_price is not null
           then b.double_sofa_price / 2.0   -- override is the WHOLE sofa
           else b.price_per_seat end
    when 'seater'     then coalesce(b.seater_price, b.price_per_seat)
    else b.price_per_seat
  end;

  return round(coalesce(v_price, 0) * 100)::bigint;
end;
$$;

revoke all on function public.bus_berth_price_paise(uuid, text, int) from public;
grant execute on function public.bus_berth_price_paise(uuid, text, int)
  to anon, authenticated;

-- ── 3. What a booking owes, in paise ─────────────────────────
-- Sums every berth the booking's passenger holds, each at its own row price and
-- its own leg factor (a one-way berth pays half — `Bus.tripFactor`). Returns
-- (total_paise, berths).
create or replace function public.booking_amount_paise(p_request_id uuid)
returns table (total_paise bigint, berths int)
language sql stable security definer set search_path = public
as $$
  with pax as (
    select p.id, p.assigned_seats, p.trip_type
      from public.booking_requests br
      join public.passengers p on p.id = br.passenger_id
     where br.id = p_request_id
       and p.cancelled_at is null
  ),
  berth as (
    select seat->>'busId' as bus_id,
           seat->>'seatId' as seat_id,
           coalesce(nullif(seat->>'leg', ''), pax.trip_type, 'roundTrip') as leg
      from pax
      cross join lateral jsonb_array_elements(
        coalesce(pax.assigned_seats, '[]'::jsonb)
      ) as seat
  ),
  priced as (
    select
      round(
        public.bus_berth_price_paise(
          berth.bus_id::uuid,
          cell->>'seatType',
          (cell->>'row')::int
        )
        -- Round trip pays full, a single leg pays half.
        * case when berth.leg = 'roundTrip' then 1.0 else 0.5 end
      )::bigint as paise
      from berth
      join public.buses b on b.id = berth.bus_id::uuid
      cross join lateral jsonb_array_elements(
        coalesce(b.layout->'grid', '[]'::jsonb)
      ) as cell
     where cell->>'seatId' = berth.seat_id
  )
  select coalesce(sum(paise), 0)::bigint, count(*)::int from priced;
$$;

revoke all on function public.booking_amount_paise(uuid) from public;
grant execute on function public.booking_amount_paise(uuid) to anon, authenticated;

-- ── 4. Payment attempts ──────────────────────────────────────
-- One row per Razorpay order. `rzp_order_id` is unique so a retry can never
-- create a second live order for the same attempt.
create table if not exists public.payment_attempts (
  id                 uuid primary key default gen_random_uuid(),
  booking_request_id uuid not null references public.booking_requests(id)
                       on delete cascade,
  tour_id            uuid references public.tours(id) on delete set null,
  rzp_order_id       text not null unique,
  rzp_payment_id     text unique,
  -- What we ASKED for (the advance), and what actually landed.
  amount_paise       bigint not null check (amount_paise > 0),
  paid_paise         bigint not null default 0,
  refunded_paise     bigint not null default 0,
  currency           text   not null default 'INR',
  -- created | attempted | paid | failed | refunded | partially_refunded
  status             text   not null default 'created',
  method             text,               -- upi / card / netbanking
  vpa                text,               -- payer UPI handle, when they use UPI
  -- 'callback' (the app told us) or 'webhook' (Razorpay told us). The webhook
  -- is authoritative; the callback only ever moves the UI along.
  verified_by        text,
  raw_event          jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists payment_attempts_booking_idx
  on public.payment_attempts(booking_request_id);
create index if not exists payment_attempts_tour_idx
  on public.payment_attempts(tour_id);

alter table public.payment_attempts enable row level security;

-- Owner of the parent tour reads/writes; customers never touch this table
-- directly (the Edge Functions use the service role).
drop policy if exists "payment_attempts_owner_all" on public.payment_attempts;
create policy "payment_attempts_owner_all" on public.payment_attempts
  for all to authenticated
  using (exists (select 1 from public.tours t
                  where t.id = payment_attempts.tour_id
                    and t.owner_id = auth.uid()))
  with check (exists (select 1 from public.tours t
                       where t.id = payment_attempts.tour_id
                         and t.owner_id = auth.uid()));

-- ── 5. Webhook idempotency ledger ────────────────────────────
-- Razorpay guarantees AT-LEAST-ONCE delivery and does not guarantee order, so
-- duplicates are certain. `x-razorpay-event-id` is unique per event; inserting
-- it first makes every handler run exactly once.
create table if not exists public.razorpay_webhook_events (
  event_id    text primary key,
  event       text not null default '',
  received_at timestamptz not null default now()
);

alter table public.razorpay_webhook_events enable row level security;
-- No policies: only the service role (Edge Function) ever touches this.

-- ── 6. Record a settled payment, idempotently ────────────────
-- BOTH paths — the client callback and the webhook — funnel through here, so a
-- double report is a no-op and whichever arrives first wins. Returns true when
-- this call actually moved the row to paid.
create or replace function public.record_online_payment(
  p_rzp_order_id   text,
  p_rzp_payment_id text,
  p_paid_paise     bigint,
  p_verified_by    text,
  p_method         text default null,
  p_vpa            text default null,
  p_raw            jsonb default null
) returns boolean
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
begin
  select id into v_id
    from public.payment_attempts
   where rzp_order_id = p_rzp_order_id
     and status <> 'paid'
   for update;

  if v_id is null then
    return false;  -- unknown order, or already paid — either way, nothing to do
  end if;

  update public.payment_attempts
     set rzp_payment_id = coalesce(p_rzp_payment_id, rzp_payment_id),
         paid_paise     = p_paid_paise,
         status         = 'paid',
         method         = coalesce(p_method, method),
         vpa            = coalesce(p_vpa, vpa),
         verified_by    = p_verified_by,
         raw_event      = coalesce(p_raw, raw_event),
         updated_at     = now()
   where id = v_id;

  return true;
end;
$$;

revoke all on function public.record_online_payment(
  text, text, bigint, text, text, text, jsonb
) from public;
-- Deliberately NOT granted to anon: only the Edge Functions (service role)
-- may mark money as received.
