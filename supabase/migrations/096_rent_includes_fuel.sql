-- 096  Pakku bhadu flag on buses
-- When true (default), agreed bus rent includes diesel; fuel and owner-advance
-- expenses deduct from Malik settlement rather than stacking on top of bhadu.

alter table public.buses
  add column if not exists rent_includes_fuel boolean not null default true;

comment on column public.buses.rent_includes_fuel is
  'True when bus bhadu is pakku (includes diesel). Trip fuel/advances reduce owner payout.';
