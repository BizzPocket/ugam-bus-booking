-- ============================================================================
-- Account self-deletion RPC  (Play Store / App Store data-deletion requirement)
-- ============================================================================
-- Run this once in the Supabase SQL editor for the production project.
--
-- An authenticated admin can permanently delete their own account by calling
-- `delete_my_account()`. The function removes the caller's row from
-- auth.users; every owned record cascades away via the existing
-- `ON DELETE CASCADE` foreign keys:
--
--   auth.users
--     └─ admins.id            -> auth.users(id) on delete cascade
--     └─ tours.owner_id       -> auth.users(id) on delete cascade
--          └─ passengers.tour_id        -> tours(id) on delete cascade
--          └─ booking_requests.tour_id  -> tours(id) on delete cascade
--          └─ buses.tour_id             -> tours(id) on delete set null
--     └─ buses.owner_id       -> auth.users(id) on delete cascade
--     └─ admin_contacts.owner_id -> auth.users(id) on delete cascade
--
-- SECURITY DEFINER lets the function delete from auth.users (which the
-- `authenticated` role cannot do directly). It only ever deletes the CALLER's
-- own row (auth.uid()), so one admin can never delete another's account.
-- ============================================================================

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  -- Cascades to admins / tours / buses / admin_contacts / passengers /
  -- booking_requests via their ON DELETE CASCADE foreign keys.
  delete from auth.users where id = v_uid;
end;
$$;

-- Lock the function down: only signed-in users may call it; never anon.
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
