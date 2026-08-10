-- ============================================================
-- 076_finance_tour_summary_bank_leg.sql
-- ------------------------------------------------------------
-- A fully prepaid trip reports ZERO revenue and prints a loss.
--
-- WHY
-- 069 §2 posts the online slice of a payment with `bus_id` NULL on BOTH legs —
-- the money arrived at the organiser's gateway, not on any particular bus, so
-- there is no bus to attribute it to. `finance_bus_summary` ends with
--
--     where l.bus_id is not null
--
-- so an online-only entry produces no row at all. Not a zero row — no row. The
-- follow-on `cash_receipt` delta is zero, `finance_post_delta` returns early,
-- and `collected_minor` is exactly 0.
--
-- FinanceController then builds tour revenue as `revenue[tid] += r.collected`
-- over those per-bus rollups. Advance-only booking is a first-class mode here
-- (`advancePerBerthPaise == 0` means the full amount is due up front), so a
-- trip whose riders all paid by UPI shows no revenue against real rent and
-- ground expenses — and reports a loss.
--
-- Pre-069 the double-post accidentally captured this money once. 069 removed
-- the duplicate without adding a read path for the surviving copy, so the
-- money became invisible rather than double-counted.
--
-- WHY A SEPARATE VIEW AND NOT A FIX TO finance_bus_summary
-- That view is per-BUS by definition and its `where l.bus_id is not null` is
-- correct — dropping it would emit a phantom bus row with a NULL bus_id that
-- every existing consumer would have to learn to skip. The bank leg is a
-- TOUR-level fact. It gets a tour-level view.
--
-- WHAT collected_minor STILL MEANS
-- Unchanged: cash in the handler's pocket. `expectedHandover` and the handover
-- sheet depend on that and must not start including money that went to a bank.
-- This view is additive — a second figure, not a redefinition of the first.
--
-- NO DOUBLE COUNTING. 069's single-post rule means a rupee lands on exactly one
-- of `cash.handler` or `bank.gateway`, never both, so revenue may safely add
-- them. `bank.gateway` is never swept to `cash.admin`, so the balance stays put
-- and the sum is the whole online take.
--
-- Requires 056 (the ledger) and 069. Idempotent. Changes no data.
-- ============================================================

do $$
begin
  if to_regclass('public.finance_lines') is null then
    raise exception '076 requires 056_finance_ledger.sql first';
  end if;
end $$;


create or replace view public.finance_tour_summary as
select
  e.tour_id,
  -- Net money sitting at the payment gateway for this tour. Receipts post a
  -- positive debit here; a reversal posts negative, so the sum is already net.
  coalesce(
    sum(l.amount_minor) filter (where l.account_code = 'bank.gateway'),
    0
  )::bigint as online_minor,
  -- The same figure restricted to lines no bus could claim. Kept separate so a
  -- caller adding this to a per-bus rollup cannot count a bus-attributed
  -- gateway line twice, if one ever starts being written.
  coalesce(
    sum(l.amount_minor) filter (
      where l.account_code = 'bank.gateway' and l.bus_id is null
    ),
    0
  )::bigint as online_unattributed_minor
from public.finance_lines l
join public.finance_entries e on e.id = l.entry_id
group by e.tour_id;

comment on view public.finance_tour_summary is
  'Tour-level ledger rollup for facts that belong to no single bus — chiefly '
  'the bank.gateway (online/UPI) leg, which finance_bus_summary excludes by '
  'design because it filters on bus_id is not null. Amounts in paise.';


-- ============================================================
-- VERIFY
--
-- 1. The money finance_bus_summary cannot see is now visible. For a tour with
--    UPI advances, this must be > 0 where the per-bus view showed nothing:
--      select * from public.finance_tour_summary where tour_id = '<tour id>';
--
-- 2. The two views must not overlap — a rupee is cash OR bank, never both:
--      select
--        (select coalesce(sum(collected_minor),0)
--           from public.finance_bus_summary where tour_id = '<tour id>') as cash,
--        (select online_minor
--           from public.finance_tour_summary where tour_id = '<tour id>') as online,
--        (select coalesce(sum(l.amount_minor),0)
--           from public.finance_lines l
--           join public.finance_entries e on e.id = l.entry_id
--          where e.tour_id = '<tour id>'
--            and l.account_code in ('cash.handler','bank.gateway')) as both;
--    `cash + online` should equal `both` (allowing for handover lines, which
--    move cash.handler out and are excluded from collected_minor by kind).
--
-- 3. RLS still applies. As a non-owner, this must return no rows for someone
--    else's tour — the view inherits finance_lines / finance_entries policies:
--      select count(*) from public.finance_tour_summary;
-- ============================================================
