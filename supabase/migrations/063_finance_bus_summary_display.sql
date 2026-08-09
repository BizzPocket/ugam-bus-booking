-- ============================================================
-- 063_finance_bus_summary_display.sql
-- ------------------------------------------------------------
-- Extends finance_bus_summary with the display fields the Flutter money
-- board needs (collected, handed over) so summaries can cut over to the
-- ledger without reassembling four legacy tables.
--
-- to_collect / to_return stay out of this bus rollup: ar.rider lines are
-- passenger-scoped (bus_id usually null). The app reads finance_rider_balance
-- and attributes riders to buses via live seating.
--
-- Requires 056 (ledger) + 062 (write-through kinds). Idempotent.
-- Apply AFTER 062.
-- ============================================================

do $$
begin
  if to_regclass('public.finance_entries') is null
     or to_regclass('public.finance_lines') is null then
    raise exception '063 requires 056_finance_ledger.sql first';
  end if;
end $$;

create or replace view public.finance_bus_summary as
select
  e.tour_id,
  l.bus_id,
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
    as owner_unpaid_minor,
  -- Net passenger cash into the handler on this bus (receipts minus refunds).
  -- Both kinds hit cash.handler; refunds post negative amounts.
  coalesce(sum(l.amount_minor) filter (
    where l.account_code = 'cash.handler'
      and e.kind in ('cash_receipt', 'refund')
  ), 0)::bigint
    as collected_minor,
  -- Handover credits cash.handler (negative line). Absolute value = handed over.
  coalesce(-sum(l.amount_minor) filter (
    where l.account_code = 'cash.handler'
      and e.kind = 'handover'
  ), 0)::bigint
    as handed_over_minor,
  -- Reserved for clients that cannot join seating; prefer finance_rider_balance.
  0::bigint as to_collect_minor,
  0::bigint as to_return_minor
from public.finance_lines l
join public.finance_entries e on e.id = l.entry_id
where l.bus_id is not null
group by e.tour_id, l.bus_id;

comment on view public.finance_bus_summary is
  'Per-bus ledger rollup for money board / finance P&L. Amounts in paise.';
