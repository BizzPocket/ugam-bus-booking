-- ============================================================
-- test_tours.sql   —   two disposable tours for end-to-end money testing
-- ------------------------------------------------------------
-- Creates exactly two tours, each with one bus, one ground expense and one
-- extra-income row, so every money surface has something real to show:
--
--   [TEST-A] Chart Booking   booking_mode = 'chart'    customer taps their own
--                                                      seat off the live chart
--   [TEST-B] Legacy Request  booking_mode = 'request'  customer sends a request,
--                                                      you assign the seats
--
-- The bus layouts below were produced by the app's OWN `BusLayout.generate`
-- (sleeper 36 / 12 singles, and seater 40), so the grids, seat ids and berth
-- counts are byte-for-byte what the Create Bus screen would have written.
--
-- IDEMPOTENT — re-running updates the same rows instead of making duplicates.
-- TEARDOWN is at the bottom of this file.
--
-- Run in the Supabase SQL editor. Everything is prefixed [TEST-, so these
-- tours are trivial to spot and delete when you are done.
-- ============================================================

do $$
declare
  -- ── who owns them ─────────────────────────────────────────
  -- Defaults to the owner of your most recent tour. To pin it explicitly,
  -- replace the whole select with:  v_owner := '<your auth.users id>'::uuid;
  v_owner   uuid;

  v_tour_a  uuid := 'aaaa1111-0000-4000-8000-000000000001';
  v_bus_a   uuid := 'aaaa1111-0000-4000-8000-0000000000b1';
  v_tour_b  uuid := 'bbbb2222-0000-4000-8000-000000000001';
  v_bus_b   uuid := 'bbbb2222-0000-4000-8000-0000000000b1';

  v_depart  date := current_date + 12;
  v_return  date := current_date + 14;

  -- Sleeper, 36 berths across 24 cells (12 single sofas + 12 double sofas).
  v_layout_sleeper jsonb := '{"rows":6,"cols":5,"hasBalcony":false,"grid":[
    {"row":0,"col":0,"seatType":"singleSofa","position":"upper","seatId":"SU1"},
    {"row":0,"col":1,"seatType":"singleSofa","position":"lower","seatId":"SL1"},
    {"row":0,"col":3,"seatType":"doubleSofa","position":"upper","seatId":"DU1"},
    {"row":0,"col":4,"seatType":"doubleSofa","position":"lower","seatId":"DL1"},
    {"row":1,"col":0,"seatType":"singleSofa","position":"upper","seatId":"SU2"},
    {"row":1,"col":1,"seatType":"singleSofa","position":"lower","seatId":"SL2"},
    {"row":1,"col":3,"seatType":"doubleSofa","position":"upper","seatId":"DU2"},
    {"row":1,"col":4,"seatType":"doubleSofa","position":"lower","seatId":"DL2"},
    {"row":2,"col":0,"seatType":"singleSofa","position":"upper","seatId":"SU3"},
    {"row":2,"col":1,"seatType":"singleSofa","position":"lower","seatId":"SL3"},
    {"row":2,"col":3,"seatType":"doubleSofa","position":"upper","seatId":"DU3"},
    {"row":2,"col":4,"seatType":"doubleSofa","position":"lower","seatId":"DL3"},
    {"row":3,"col":0,"seatType":"singleSofa","position":"upper","seatId":"SU4"},
    {"row":3,"col":1,"seatType":"singleSofa","position":"lower","seatId":"SL4"},
    {"row":3,"col":3,"seatType":"doubleSofa","position":"upper","seatId":"DU4"},
    {"row":3,"col":4,"seatType":"doubleSofa","position":"lower","seatId":"DL4"},
    {"row":4,"col":0,"seatType":"singleSofa","position":"upper","seatId":"SU5"},
    {"row":4,"col":1,"seatType":"singleSofa","position":"lower","seatId":"SL5"},
    {"row":4,"col":3,"seatType":"doubleSofa","position":"upper","seatId":"DU5"},
    {"row":4,"col":4,"seatType":"doubleSofa","position":"lower","seatId":"DL5"},
    {"row":5,"col":0,"seatType":"singleSofa","position":"upper","seatId":"SU6"},
    {"row":5,"col":1,"seatType":"singleSofa","position":"lower","seatId":"SL6"},
    {"row":5,"col":3,"seatType":"doubleSofa","position":"upper","seatId":"DU6"},
    {"row":5,"col":4,"seatType":"doubleSofa","position":"lower","seatId":"DL6"}]}'::jsonb;

  -- Seater, 40 seats across 10 rows.
  v_layout_seater jsonb := (
    select jsonb_build_object(
      'rows', 10, 'cols', 5, 'hasBalcony', false,
      'grid', jsonb_agg(jsonb_build_object(
                'row',      (i - 1) / 4,
                'col',      (array[0,1,3,4])[((i - 1) % 4) + 1],
                'seatType', 'seater',
                'seatId',   'ST' || i)
              order by i))
      from generate_series(1, 40) i);
begin
  select t.owner_id into v_owner
    from public.tours t
   where t.owner_id is not null
   order by t.created_at desc
   limit 1;

  if v_owner is null then
    raise exception 'Could not resolve an owner_id. Pin it by hand at the top of this file.';
  end if;

  -- ══ TOUR A — customer picks their own seat off the chart ══
  insert into public.tours (
    id, owner_id, title, from_city, to_city,
    departure_date, departure_time, return_date, return_time,
    price_per_seat, description, status, is_public
  ) values (
    v_tour_a, v_owner, '[TEST-A] Chart Booking', 'Ahmedabad', 'Dwarka',
    v_depart, '21:00', v_return, '06:00',
    1200, 'Disposable test tour — customers pick their own seats.',
    'collecting', true
  )
  on conflict (id) do update set
    title          = excluded.title,
    from_city      = excluded.from_city,
    to_city        = excluded.to_city,
    departure_date = excluded.departure_date,
    return_date    = excluded.return_date,
    status         = excluded.status,
    is_public      = excluded.is_public,
    deleted_at     = null;

  -- Booking-mode / advance columns live in migrations 048–050 and are written
  -- separately by the app for the same reason: if 048–050 are not applied on
  -- this database, only THIS statement fails and the tour above still exists.
  begin
    update public.tours
       set booking_mode            = 'chart',
           advance_per_berth_paise = 50000,          -- ₹500 asked up front
           collect_vpa             = 'ugamtest@upi',
           collect_payee_name      = 'Ugam Test'
     where id = v_tour_a;
  exception when undefined_column then
    raise notice 'Tour A stays in request mode: migrations 048-050 are not applied here.';
  end;

  -- Bus A · sleeper 36. Front two rows are a price BAND (₹1,600/berth); the
  -- rows behind fall back to the per-type overrides. That exercises the band
  -- path and the override path on one bus.
  insert into public.buses (
    id, owner_id, tour_id, name, registration_no, driver_name, driver_phone,
    owner_name, owner_phone, is_ac, bus_type, total_seats,
    price_per_seat, bus_price, boarding_point, departure_time,
    single_sofa_price, double_sofa_price, seater_price,
    rear_rows, rear_price, price_bands, layout
  ) values (
    v_bus_a, v_owner, v_tour_a, 'Test Bus A1', 'GJ01TEST01',
    'Test Driver A', '9000000001', 'Test Owner A', '9000000002',
    true, 'Sleeper', 36,
    1200, 30000, 'Paldi Cross Roads', '21:00',
    1400,           -- single sofa, per berth
    2200,           -- WHOLE double sofa → 1100 per berth
    null,
    0, null,
    '[{"label":"Front Premium","fromRow":0,"toRow":1,"price":1600}]'::jsonb,
    v_layout_sleeper
  )
  on conflict (id) do update set
    tour_id           = excluded.tour_id,
    price_per_seat    = excluded.price_per_seat,
    bus_price         = excluded.bus_price,
    single_sofa_price = excluded.single_sofa_price,
    double_sofa_price = excluded.double_sofa_price,
    price_bands       = excluded.price_bands,
    layout            = excluded.layout,
    deleted_at        = null;

  -- ══ TOUR B — legacy request flow ══════════════════════════
  insert into public.tours (
    id, owner_id, title, from_city, to_city,
    departure_date, departure_time, return_date, return_time,
    price_per_seat, description, status, is_public
  ) values (
    v_tour_b, v_owner, '[TEST-B] Legacy Request', 'Surat', 'Ambaji',
    v_depart, '20:30', v_return, '07:00',
    800, 'Disposable test tour — customers send a request, you assign seats.',
    'collecting', true
  )
  on conflict (id) do update set
    title          = excluded.title,
    from_city      = excluded.from_city,
    to_city        = excluded.to_city,
    departure_date = excluded.departure_date,
    return_date    = excluded.return_date,
    status         = excluded.status,
    is_public      = excluded.is_public,
    deleted_at     = null;

  begin
    update public.tours set booking_mode = 'request' where id = v_tour_b;
  exception when undefined_column then
    null;   -- pre-048 database: request mode is already the only behaviour
  end;

  -- Bus B · seater 40, using the LEGACY rear zone (last 2 rows at ₹600) rather
  -- than a price band, so the rear-zone→synthesized-band path is covered too.
  insert into public.buses (
    id, owner_id, tour_id, name, registration_no, driver_name, driver_phone,
    owner_name, owner_phone, is_ac, bus_type, total_seats,
    price_per_seat, bus_price, boarding_point, departure_time,
    single_sofa_price, double_sofa_price, seater_price,
    rear_rows, rear_price, price_bands, layout
  ) values (
    v_bus_b, v_owner, v_tour_b, 'Test Bus B1', 'GJ01TEST02',
    'Test Driver B', '9000000003', 'Test Owner B', '9000000004',
    false, 'Seater', 40,
    800, 22000, 'Udhna Darwaja', '20:30',
    null, null, 800,
    2, 600,          -- legacy rear zone: last 2 rows at ₹600 per person
    '[]'::jsonb,
    v_layout_seater
  )
  on conflict (id) do update set
    tour_id        = excluded.tour_id,
    price_per_seat = excluded.price_per_seat,
    bus_price      = excluded.bus_price,
    seater_price   = excluded.seater_price,
    rear_rows      = excluded.rear_rows,
    rear_price     = excluded.rear_price,
    layout         = excluded.layout,
    deleted_at     = null;

  -- ══ One ground expense + one extra income per tour ════════
  -- Gives the P&L a non-zero cost and a non-zero extra income on day one, so a
  -- ₹0 report is unambiguously a bug rather than an empty tour.
  insert into public.expenses (id, tour_id, bus_id, category, label, amount, paid_by)
  values
    ('aaaa1111-0000-4000-8000-0000000000e1', v_tour_a, v_bus_a, 'fuel',  '[TEST] Diesel', 4000, 'handler'),
    ('bbbb2222-0000-4000-8000-0000000000e1', v_tour_b, v_bus_b, 'fuel',  '[TEST] Diesel', 3200, 'handler')
  on conflict (id) do update set amount = excluded.amount, deleted_at = null;

  insert into public.incomes (id, tour_id, bus_id, category, label, amount, received_by)
  values
    ('aaaa1111-0000-4000-8000-0000000000f1', v_tour_a, v_bus_a, 'cabin', '[TEST] Cabin seat', 1500, 'handler'),
    ('bbbb2222-0000-4000-8000-0000000000f1', v_tour_b, v_bus_b, 'other', '[TEST] Luggage',     900, 'handler')
  on conflict (id) do update set amount = excluded.amount, deleted_at = null;

  raise notice 'Seeded. Tour A = %  Tour B = %  owner = %', v_tour_a, v_tour_b, v_owner;
end $$;


-- ── What the books MUST say the moment this finishes ─────────
-- Nothing has been collected yet, so every "collected" figure is ₹0 — but
-- expenses, rent and extra income are all real. Run this straight after the
-- seed; if the ledger is healthy the two sides agree.
--
--            TOUR A            TOUR B
--   rent     ₹30,000           ₹22,000
--   ground   ₹4,000            ₹3,200
--   expenses ₹34,000           ₹25,200      (rent + ground)
--   income   ₹1,500            ₹900
--   billed   ₹0 (nobody seated yet)
--   net      -₹32,500          -₹24,300     (income − expenses)
--
-- Fully sold, Tour A bills ₹48,000 (12 front berths × ₹1,600 = ₹19,200, plus
-- 4 rows × ₹7,200 = ₹28,800) and Tour B bills ₹30,400 (32 × ₹800 + 8 × ₹600).
select t.title,
       coalesce(sum(f.rent_minor), 0)            / 100.0 as ledger_rent,
       coalesce(sum(f.ground_expenses_minor), 0) / 100.0 as ledger_ground,
       coalesce(sum(f.income_minor), 0)          / 100.0 as ledger_income,
       coalesce(sum(f.billed_minor), 0)          / 100.0 as ledger_billed,
       coalesce(sum(f.collected_minor), 0)       / 100.0 as ledger_collected
  from public.tours t
  left join public.finance_bus_summary f on f.tour_id = t.id
 where t.id in ('aaaa1111-0000-4000-8000-000000000001',
                'bbbb2222-0000-4000-8000-000000000001')
 group by t.title
 order by t.title;


-- ============================================================
-- TEARDOWN — removes both test tours and everything hanging off them.
-- Uncomment and run when you are finished testing.
-- ============================================================
-- begin;
--   with dead as (
--     select unnest(array['aaaa1111-0000-4000-8000-000000000001',
--                         'bbbb2222-0000-4000-8000-000000000001']::uuid[]) as id
--   )
--   delete from public.tours t using dead d where t.id = d.id;
--   -- collections / expenses / incomes / bus_handovers / passengers /
--   -- booking_requests all cascade on tour_id. `buses.tour_id` is ON DELETE SET
--   -- NULL, so the two test buses survive as unassigned fleet rows — drop them:
--   delete from public.buses
--    where id in ('aaaa1111-0000-4000-8000-0000000000b1',
--                 'bbbb2222-0000-4000-8000-0000000000b1');
-- commit;
--
-- NOTE: finance_entries / finance_lines are APPEND-ONLY by design (056 §6) and
-- reference tours(id), so the DELETE above will fail while ledger rows exist.
-- If it does, that is the ledger working correctly — either keep the tours, or
-- post reversing entries first.
