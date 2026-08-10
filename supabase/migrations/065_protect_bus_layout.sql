-- 065 — Refuse to erase a bus seat layout.
--
-- WHY
-- ---
-- Cold start deliberately fetches buses WITHOUT their `layout` jsonb: it is
-- ~71% of bus bytes on a live probe and the 2G read budget cannot afford it.
-- The client therefore holds `layout = null` for a bus that has a perfectly
-- good seat grid on the server, until an on-demand fetch fills it in.
--
-- Every bus write used to send the WHOLE row, so any write landing inside that
-- window — naming a bus handler, copying prices, editing a driver name —
-- shipped `layout: null` and destroyed the seat map. Two live buses on the
-- Shravan Sud Bij tour lost their charts this way while keeping `total_seats`
-- and all 72 passenger seat assignments, which then pointed at seat ids that
-- existed nowhere.
--
-- The client is fixed (bus writes are column-scoped now), but agent and handler
-- phones keep running older builds until they update, and those builds keep
-- issuing the destructive write. This trigger is the durable guarantee.
--
-- WHAT IT DOES
-- ------------
-- Silently keeps the existing layout when an UPDATE tries to replace a non-null
-- layout with NULL. Nothing in the app legitimately clears a layout — the bus
-- editor REGENERATES one and writes the new grid — so this has no false
-- positives. Setting a layout, changing a layout, and writing a layout onto a
-- bus that had none all pass through untouched.
--
-- Deliberately silent rather than raising: a raise would abort the whole
-- UPDATE, so an old build would also fail to save the driver name it was
-- actually trying to change. Preserving the column lets the legitimate part of
-- the write succeed while the destructive part is neutralised.

create or replace function public.bus_layout_never_null()
returns trigger
language plpgsql
as $$
begin
  if new.layout is null and old.layout is not null then
    new.layout := old.layout;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_bus_layout_never_null on public.buses;

create trigger trg_bus_layout_never_null
  before update on public.buses
  for each row
  execute function public.bus_layout_never_null();

comment on function public.bus_layout_never_null() is
  'Guards buses.layout against whole-row writes made before the lazily-fetched layout jsonb has loaded. See migration 065.';
