-- ============================================================
-- 071_ledger_invariant_sees_all_lines.sql
-- ------------------------------------------------------------
-- The ledger's balance invariant is evaluated THROUGH row-level security, so a
-- caller who may INSERT lines but not SELECT them is told their entry has no
-- lines — and the whole transaction is refused.
--
-- HOW THIS SURFACED
-- Calling `finance_resync_all_fares()` over PostgREST as the `anon` role failed
-- with:
--     finance entry 613e192c-… has no lines; an entry must record both sides
-- The lines were there. `finance_bus_summary` reports real rent / ground /
-- income figures that can only be computed from `finance_lines` rows, while a
-- direct `select` on `finance_lines` as anon returns 0 rows. The entry was fine;
-- the CHECK could not see it.
--
-- WHY
-- Both invariant functions from 056 §5 are plain `language plpgsql` — NOT
-- `security definer`:
--     finance_entry_balanced()    -- constraint trigger on finance_lines
--     finance_entry_has_lines()   -- constraint trigger on finance_entries
-- Each does `select … from public.finance_lines where entry_id = …`, and
-- `finance_lines` has RLS enabled with a single policy granting SELECT `to
-- authenticated` for tours the caller owns. Any other role reads zero rows and
-- the invariant concludes the entry is empty.
--
-- Both are CONSTRAINT triggers, `deferrable initially deferred`, so they fire at
-- COMMIT — after any `security definer` function that did the writing has
-- already returned and its elevated role has been dropped. A handler RPC (which
-- 062's own header notes runs SECURITY DEFINER under an ANON jwt) therefore has
-- its integrity check evaluated as anon, not as the definer.
--
-- THE FIX
-- An integrity invariant must be evaluated over the TRUE row set, never a
-- role-filtered view of one. Both functions become `security definer` so they
-- count every line of the entry they are checking, whoever is committing.
--
-- This makes the constraint STRICTER, not weaker: it can now catch an unbalanced
-- entry it would previously have waved through as "no lines to check" — the
-- `v_n = 0 -> return null` early exit in finance_entry_balanced() is exactly
-- that hole. Nothing about who may read, write or post is changed; RLS on the
-- tables themselves is untouched.
--
-- Requires 056. Idempotent, re-runnable, and changes no data.
-- ============================================================

do $$
begin
  if to_regclass('public.finance_lines') is null then
    raise exception '071 requires 056_finance_ledger.sql first';
  end if;
end $$;


-- ── 1. "The lines of an entry sum to zero" ───────────────────
-- Body identical to 056 §5 apart from `security definer`.
create or replace function public.finance_entry_balanced() returns trigger
language plpgsql security definer set search_path = public as $$
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


-- ── 2. "Every entry acquired its sides by COMMIT" ────────────
-- Body identical to 056 §5 apart from `security definer`. This is the one that
-- produced the false "has no lines" above.
create or replace function public.finance_entry_has_lines() returns trigger
language plpgsql security definer set search_path = public as $$
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


-- The triggers themselves are unchanged — `create or replace function` swaps the
-- body under the existing constraint triggers, so nothing needs re-attaching.


-- ============================================================
-- VERIFY
--
--   -- Was failing as anon before this file; must now return a row.
--   select * from public.finance_resync_all_fares('<a tour id>');
--
--   -- And the invariant still bites when it should. This MUST fail at commit:
--   begin;
--     insert into public.finance_entries (tour_id, kind, actor_kind, client_request_id)
--     values ('<a tour id>', 'cash_receipt', 'system', 'invariant-smoke-1')
--     returning id \gset e_
--     insert into public.finance_lines (entry_id, account_code, bus_id, amount_minor)
--     values (:'e_id', 'cash.handler', '<a bus id>', 27500);
--   commit;   -- expected: "does not balance (sum = 27500)"
-- ============================================================
