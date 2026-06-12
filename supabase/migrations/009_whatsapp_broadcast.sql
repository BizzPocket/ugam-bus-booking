-- ============================================================
-- 009  WhatsApp Cloud API — broadcast + seat-allocation assets
-- ------------------------------------------------------------
-- Adds the phase-2 broadcast composer fields to tours, and two public
-- Storage buckets used by the WhatsApp Cloud API integration:
--
--   tour-broadcasts  -> optional hero image attached to a tour broadcast
--   seat-charts      -> the generated seat-chart PDF sent as a WhatsApp
--                       *document* with the seat-allocation message
--
-- Both buckets are PUBLIC-read: the WhatsApp Cloud API fetches template
-- header media by URL, so the file must be reachable without a signed token.
-- Writes are restricted to authenticated admins.
--
-- The actual sending happens in the `whatsapp-send` Edge Function, which
-- holds WHATSAPP_TOKEN + WHATSAPP_PHONE_NUMBER_ID as secrets. Nothing secret
-- lives in this migration or in the app.
-- ============================================================

-- 1. Broadcast columns on tours (idempotent; nullable so existing rows are fine)
alter table public.tours
  add column if not exists broadcast_message   text,
  add column if not exists broadcast_image_url text;

-- 2. Public Storage buckets
insert into storage.buckets (id, name, public)
values ('tour-broadcasts', 'tour-broadcasts', true)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('seat-charts', 'seat-charts', true)
on conflict (id) do nothing;

-- 3. Storage policies — public read, authenticated write/update/delete
do $$
begin
  -- tour-broadcasts
  if not exists (select 1 from pg_policies
                 where schemaname = 'storage' and tablename = 'objects'
                   and policyname = 'wa_broadcasts_public_read') then
    create policy "wa_broadcasts_public_read" on storage.objects
      for select to anon, authenticated
      using (bucket_id = 'tour-broadcasts');
  end if;

  if not exists (select 1 from pg_policies
                 where schemaname = 'storage' and tablename = 'objects'
                   and policyname = 'wa_broadcasts_auth_write') then
    create policy "wa_broadcasts_auth_write" on storage.objects
      for all to authenticated
      using (bucket_id = 'tour-broadcasts')
      with check (bucket_id = 'tour-broadcasts');
  end if;

  -- seat-charts
  if not exists (select 1 from pg_policies
                 where schemaname = 'storage' and tablename = 'objects'
                   and policyname = 'wa_seatcharts_public_read') then
    create policy "wa_seatcharts_public_read" on storage.objects
      for select to anon, authenticated
      using (bucket_id = 'seat-charts');
  end if;

  if not exists (select 1 from pg_policies
                 where schemaname = 'storage' and tablename = 'objects'
                   and policyname = 'wa_seatcharts_auth_write') then
    create policy "wa_seatcharts_auth_write" on storage.objects
      for all to authenticated
      using (bucket_id = 'seat-charts')
      with check (bucket_id = 'seat-charts');
  end if;
end $$;
