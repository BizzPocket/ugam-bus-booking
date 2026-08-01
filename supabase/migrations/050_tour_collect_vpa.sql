-- ============================================================
-- 050  Collection UPI handle on the tour
-- ------------------------------------------------------------
-- The customer app renders a UPI QR so a rider can pay their seat advance by
-- scanning with GPay / PhonePe / Paytm. To draw that QR the CUSTOMER's device
-- needs the payee handle, so it has to be readable by an anonymous caller —
-- hence a column on `tours`, which already carries an anon SELECT policy for
-- public tours (`tours_public_read`).
--
-- Safe to expose: a VPA is a receive-only address. It is printed on shop
-- counters across India for exactly this purpose — knowing it lets you PAY the
-- trust, never withdraw from it.
--
-- Why per TOUR rather than per owner: a trust may collect different yatras into
-- different accounts, and a tour already carries its own pricing and advance
-- policy (049). Leaving it null simply means no QR is offered on that tour.
--
-- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent.
-- ============================================================

alter table public.tours
  add column if not exists collect_vpa text;

alter table public.tours
  add column if not exists collect_payee_name text;

-- Shape check only — a closed list of PSP handles would reject real banks as
-- new ones appear. Mirrors `isValidVpa` in lib/utils/upi_uri.dart.
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'tours_collect_vpa_chk'
  ) then
    alter table public.tours
      add constraint tours_collect_vpa_chk
      check (
        collect_vpa is null
        or collect_vpa ~ '^[a-zA-Z0-9.\-_]{2,}@[a-zA-Z][a-zA-Z0-9.\-_]*$'
      );
  end if;
end $$;
