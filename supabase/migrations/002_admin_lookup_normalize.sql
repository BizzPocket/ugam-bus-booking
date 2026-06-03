-- ============================================================
-- 002  Harden admin_lookup_by_phone against stored phone formatting
-- ------------------------------------------------------------
-- The login screen normalises the typed phone to its last 10 digits before
-- calling admin_lookup_by_phone. The original function compared that against
-- admins.phone with `=`, so a registered admin whose stored phone carried any
-- formatting ("+91 97277 10359", "+919727710359", etc.) would NOT match and
-- the app would silently misclassify that admin as a password-less customer.
--
-- This version normalises BOTH sides to their last 10 digits, so the lookup
-- is tolerant of however the phone was stored. Behaviour is otherwise
-- identical (SECURITY DEFINER, exposes only id/phone/name).
--
-- Apply in the Supabase SQL editor (or `supabase db push`).
-- ============================================================

create or replace function public.admin_lookup_by_phone(p_phone text)
returns table(id uuid, phone text, name text)
language sql
security definer
set search_path = public
as $$
  select a.id, a.phone, a.name
    from public.admins a
   where right(regexp_replace(a.phone, '\D', '', 'g'), 10)
       = right(regexp_replace(p_phone, '\D', '', 'g'), 10)
   limit 1;
$$;

revoke all on function public.admin_lookup_by_phone(text) from public;
grant execute on function public.admin_lookup_by_phone(text)
  to anon, authenticated;
