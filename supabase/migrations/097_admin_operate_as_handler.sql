-- ============================================================
-- 097  Tour owner may operate a single bus through the handler app
-- ------------------------------------------------------------
-- Agents sometimes run boarding / collections themselves when the assigned
-- handler is unavailable. The handler surface is already built (HandlerShell)
-- and every write RPC keys off an opaque ref resolved by handler_ctx.
--
-- Convention: when the authenticated tour owner passes a buses.id as that
-- opaque ref, they get handler capability scoped to THAT bus only — same
-- lock/completed gate as a real handler, no anonymous access.
--
-- Patches:
--   is_admin_bus_handler_ref(uuid)
--   handler_ctx(uuid)            — rank-2 branch: buses.id + owner match
--   is_request_handler(uuid)     — OR admin bus ref
--   handler_owns_bus(uuid,uuid)  — OR admin ref for the same bus id
--   handler_tour_manifest(uuid)  — my_buses union for admin ref
-- ============================================================

create or replace function public.is_admin_bus_handler_ref(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.buses b
      join public.tours t on t.id = b.tour_id
     where b.id = p_id
       and t.owner_id = auth.uid()
       and t.status in ('locked', 'completed')
  );
$$;

revoke all on function public.is_admin_bus_handler_ref(uuid) from public;
-- Internal + optional client preflight for signed-in admins only.
grant execute on function public.is_admin_bus_handler_ref(uuid) to authenticated;


create or replace function public.handler_ctx(p_id uuid)
returns table (tour_id uuid, customer_phone text)
language sql
stable
security definer
set search_path = public
as $$
  select c.tour_id, c.customer_phone
    from (
      select br.tour_id         as tour_id,
             br.customer_phone  as customer_phone,
             0                  as src_rank
        from public.booking_requests br
       where br.id = p_id
      union all
      select p.tour_id  as tour_id,
             p.phone    as customer_phone,
             1          as src_rank
        from public.passengers p
       where p.id = p_id
         and p.is_handler = true
      union all
      -- Tour owner operating as handler: opaque ref is the bus id.
      select b.tour_id         as tour_id,
             ''::text          as customer_phone,
             2                 as src_rank
        from public.buses b
        join public.tours t on t.id = b.tour_id
       where b.id = p_id
         and t.owner_id = auth.uid()
         and t.status in ('locked', 'completed')
    ) c
   order by c.src_rank
   limit 1;
$$;

revoke all on function public.handler_ctx(uuid) from public;


create or replace function public.is_request_handler(p_request_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select coalesce(
    exists (
      select 1
        from public.handler_ctx(p_request_id) ctx
        join public.passengers p
          on p.tour_id = ctx.tour_id
         and p.phone   = ctx.customer_phone
        join public.tours t
          on t.id = ctx.tour_id
       where p.is_handler = true
         and t.status in ('locked', 'completed')
    ),
    false
  )
  or public.is_admin_bus_handler_ref(p_request_id);
$$;

revoke all on function public.is_request_handler(uuid) from public;
grant execute on function public.is_request_handler(uuid)
  to anon, authenticated;


create or replace function public.handler_owns_bus(p_request_id uuid, p_bus_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.handler_ctx(p_request_id) ctx
      join public.passengers p
        on p.tour_id = ctx.tour_id
       and p.phone   = ctx.customer_phone
       and p.is_handler = true
      join public.buses b
        on b.id = p_bus_id
       and b.tour_id = ctx.tour_id
       and b.handler_passenger_id = p.id
  )
  or (
    public.is_admin_bus_handler_ref(p_request_id)
    and p_bus_id = p_request_id
  );
$$;

revoke all on function public.handler_owns_bus(uuid, uuid) from public;


-- Patch handler_tour_manifest in place (live body may differ from migration files).
do $$
declare
  v_oid oid;
  v_src text;
  v_new text;
begin
  select p.oid into v_oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'handler_tour_manifest'
   limit 1;

  if v_oid is null then
    raise exception '097: handler_tour_manifest() not found';
  end if;

  v_src := pg_get_functiondef(v_oid);

  if v_src ~* 'is_admin_bus_handler_ref' then
    raise notice '097: handler_tour_manifest already includes admin bus ref';
    return;
  end if;

  v_new := regexp_replace(
    v_src,
    'where\s+b\.handler_passenger_id\s+in\s+\(\s*select\s+id\s+from\s+handler_p\s*\)',
    E'where b.handler_passenger_id in (select id from handler_p)\n    union\n    select b_admin.id\n      from public.buses b_admin\n     where public.is_admin_bus_handler_ref(p_request_id)\n       and b_admin.id = p_request_id',
    'gi'
  );

  if v_new is not distinct from v_src then
    raise exception
      '097: could not patch my_buses in handler_tour_manifest — inspect pg_get_functiondef';
  end if;

  execute v_new;
  raise notice '097: handler_tour_manifest my_buses patched for admin operate';
end $$;
