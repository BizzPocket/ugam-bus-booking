-- ============================================================
-- 098_handler_manifest_groups.sql
-- ------------------------------------------------------------
-- Adds `groups` (passenger_groups labels) to handler_tour_manifest JSON.
-- Patches the live function body in place (see 075 / 097).
-- ============================================================

do $$
declare
  v_oid     oid;
  v_src     text;
  v_new     text;
  v_anchor  text;
  v_added   text;
  v_anchors text[] := array[
    -- Post-055 (soft-deleted incomes excluded)
    $a1$
            from (select * from public.incomes where deleted_at is null) inc
           where inc.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      )
    )
  end;$a1$,
    -- Pre-055
    $a2$
            from public.incomes inc
           where inc.bus_id in (select id from my_buses)
        ),
        '[]'::jsonb
      )
    )
  end;$a2$
  ];
  c_tail_old constant text := $t$
        '[]'::jsonb
      )
    )
  end;$t$;
  c_tail_new constant text := $t$
        '[]'::jsonb
      ),
      'groups', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',          g.id,
                     'tour_id',     g.tour_id,
                     'label',       g.label,
                     'color_index', g.color_index,
                     'created_at',  g.created_at
                   )
                   order by g.label
                 )
            from public.passenger_groups g
            join req on req.tour_id = g.tour_id
        ),
        '[]'::jsonb
      )
    )
  end;$t$;
  c_groups_regex constant text := $r$,
      'groups', coalesce(
        (
          select jsonb_agg(
                   jsonb_build_object(
                     'id',          g.id,
                     'tour_id',     g.tour_id,
                     'label',       g.label,
                     'color_index', g.color_index,
                     'created_at',  g.created_at
                   )
                   order by g.label
                 )
            from public.passenger_groups g
            join req on req.tour_id = g.tour_id
        ),
        '[]'::jsonb
      )$r$;
begin
  select p.oid into v_oid
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'handler_tour_manifest'
   limit 1;

  if v_oid is null then
    raise exception '098: handler_tour_manifest() is not present';
  end if;

  v_src := pg_get_functiondef(v_oid);

  if position('''groups''' in v_src) > 0 then
    raise notice '098: handler_tour_manifest already carries groups';
    return;
  end if;

  -- Literal anchors (incomes FROM tail + shared CASE end).
  foreach v_anchor in array v_anchors
  loop
    if position(v_anchor in v_src) > 0 then
      v_added := replace(v_anchor, c_tail_old, c_tail_new);
      v_new := replace(v_src, v_anchor, v_added);
      execute v_new;
      raise notice '098: handler_tour_manifest patched (literal anchor)';
      return;
    end if;
  end loop;

  -- Regex fallback: incomes is the last jsonb_build_object key on all known bodies.
  v_new := regexp_replace(
    v_src,
    '(''incomes'', coalesce\(\([^]*''\[\]''::jsonb\s*\))(\s*\)\s*(end\s*;))',
    E'\\1' || c_groups_regex || E'\\2',
    'i'
  );

  if v_new is not distinct from v_src then
    raise exception
      '098: could not patch handler_tour_manifest for groups. '
      'Inspect: select pg_get_functiondef(''public.handler_tour_manifest''::regproc);';
  end if;

  execute v_new;
  raise notice '098: handler_tour_manifest patched (regex)';
end $$;
