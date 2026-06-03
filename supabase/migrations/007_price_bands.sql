-- ============================================================
-- 007  Flexible per-bus price bands
-- ------------------------------------------------------------
-- Generalises the single rear zone (migration 005) into any number of named
-- price bands. A band is a contiguous, 0-based, INCLUSIVE row range priced at a
-- per-berth (per-person) amount:
--
--   { "label": text, "fromRow": int, "toRow": int, "price": numeric }
--
-- Stored as a JSON array in buses.price_bands. A band overrides the base price
-- (buses.price_per_seat) and the per-seat-type overrides for the rows it covers
-- — exactly like the rear zone did, but for arbitrary ranges (front premium,
-- back discount, an explicit middle band, etc.). The FIRST matching band wins on
-- overlapping rows.
--
-- Back-compat: rear_rows / rear_price (005) stay in place and keep working. The
-- app surfaces the rear zone to the pricing engine as a synthesized trailing
-- band, so old buses price exactly as before; where an explicit price_bands
-- entry overlaps the rear rows, the explicit band takes priority.
--
-- Must run AFTER 006 (it re-creates handler_tour_manifest from the 006 body,
-- adding price_bands to the buses payload). Idempotent.
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

alter table public.buses
  add column if not exists price_bands jsonb not null default '[]'::jsonb;

-- Re-create the handler manifest so the handler app receives price_bands and
-- resolves the same per-row fares as the admin. Identical to 006 except for the
-- added 'price_bands' field in the buses payload.
create or replace function public.handler_tour_manifest(p_request_id uuid)
returns jsonb
language sql security definer set search_path = public
as $$
  with req as (
    select br.tour_id, br.customer_phone
      from public.booking_requests br
     where br.id = p_request_id
  )
  select case
    when not public.is_request_handler(p_request_id) then null
    else jsonb_build_object(
      'buses', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',                b.id,
                     'tour_id',           b.tour_id,
                     'name',              b.name,
                     'registration_no',   b.registration_no,
                     'bus_type',          b.bus_type,
                     'total_seats',       b.total_seats,
                     'layout',            b.layout,
                     'price_per_seat',    b.price_per_seat,
                     'single_sofa_price', b.single_sofa_price,
                     'double_sofa_price', b.double_sofa_price,
                     'seater_price',      b.seater_price,
                     'rear_rows',         b.rear_rows,
                     'rear_price',        b.rear_price,
                     'price_bands',       b.price_bands
                   )
                   order by b.name
                 )
            from public.buses b
            join req on req.tour_id = b.tour_id
        ),
        '[]'::jsonb
      ),
      'passengers', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',             p.id,
                     'tour_id',        p.tour_id,
                     'name',           p.name,
                     'phone',          p.phone,
                     'age_group',      p.age_group,
                     'assigned_seats', p.assigned_seats,
                     'is_handler',     p.is_handler,
                     'trip_type',      p.trip_type,
                     'request_lines',  p.request_lines
                   )
                   order by p.name
                 )
            from public.passengers p
            join req on req.tour_id = p.tour_id
        ),
        '[]'::jsonb
      ),
      'collections', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',              col.id,
                     'tour_id',         col.tour_id,
                     'bus_id',          col.bus_id,
                     'passenger_id',    col.passenger_id,
                     'seat_id',         col.seat_id,
                     'amount_due',      col.amount_due,
                     'amount_received', col.amount_received,
                     'amount_refunded', col.amount_refunded,
                     'note',            col.note,
                     'collected_by',    col.collected_by,
                     'created_at',      col.created_at,
                     'updated_at',      col.updated_at
                   )
                   order by col.created_at
                 )
            from public.collections col
            join req on req.tour_id = col.tour_id
        ),
        '[]'::jsonb
      )
    )
  end;
$$;

revoke all on function public.handler_tour_manifest(uuid) from public;
grant execute on function public.handler_tour_manifest(uuid)
  to anon, authenticated;
