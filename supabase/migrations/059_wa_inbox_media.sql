-- ============================================================
-- 059 — WhatsApp inbox: actually keep the media
--
-- PROBLEM: a customer sends a photo, a voice note or a video and the inbox shows
-- "[image]" and nothing else — forever. This is not a rendering bug. 033's
-- `wa_messages` has no column that could hold media, and `wa-webhook` says so in
-- as many words:
--
--     body = null; // media download deferred
--
-- It records the KIND of attachment and throws the attachment away. Meta hosts
-- inbound media for ~14 days behind an authenticated URL and gives us only a
-- media id in the webhook payload, so an attachment that is not fetched during
-- that window is gone permanently. Every photo any customer has ever sent this
-- inbox is already unrecoverable; this migration stops the bleeding from here.
--
-- FIX: somewhere to put it (a private `wa-media` bucket) and something to point
-- at it (five columns on wa_messages). The webhook change that fills them ships
-- alongside this file.
--
-- WHY A PRIVATE BUCKET: these are messages from named customers — photos of
-- people, payment screenshots showing account numbers, voice notes. `seat-charts`
-- was deliberately made private in 051 for exactly this reason (it carries names
-- and allocations) while `tour-broadcasts` stayed public because it holds only
-- marketing posters. Inbox media is firmly in the first category. The app reads
-- it with the signed URLs the authenticated client asks for, never a bare path.
--
-- THE READ POLICY MIRRORS THE ROW POLICY: 033 scopes a conversation to
-- `owner_id = auth.uid() or owner_id is null`. Objects are keyed by
-- `<conversation_id>/<file>`, so the storage policy resolves the first path
-- segment back to the conversation and applies that same test. An admin can see
-- attachments from their own threads and unassigned ones, and nothing else —
-- the same boundary as the message rows themselves.
--
-- Run THIS FILE ALONE in the Supabase SQL editor (do NOT `supabase db push` —
-- the numbered migration history is out of sync with live). Idempotent.
-- ============================================================

begin;

-- ── 1. Columns ─────────────────────────────────────────────
-- media_id       Meta's media id. Kept even after a successful download: it is
--                the only handle for a re-fetch, and its presence next to a null
--                media_path is precisely how a failed download is spotted.
-- media_path     Object path inside the `wa-media` bucket. NULL until the bytes
--                land, so `media_id is not null and media_path is null` reads as
--                "attachment known, not stored" and nothing more.
-- media_mime     Meta's declared mime type — decides picture vs player vs file.
-- media_filename Original filename; documents only, and only when Meta sends it.
-- media_size     Bytes, for the "12.4 MB" hint before a download on mobile data.
alter table public.wa_messages
  add column if not exists media_id       text,
  add column if not exists media_path     text,
  add column if not exists media_mime     text,
  add column if not exists media_filename text,
  add column if not exists media_size     bigint;

-- Finds attachments whose download failed, so a retry sweep never has to scan
-- the whole table. Partial: healthy rows are the overwhelming majority and do
-- not belong in this index.
create index if not exists wa_messages_media_pending_idx
  on public.wa_messages(created_at)
  where media_id is not null and media_path is null;

-- ── 2. The bucket ──────────────────────────────────────────
-- public => false. See the header: this is customer content, not marketing.
insert into storage.buckets (id, name, public)
values ('wa-media', 'wa-media', false)
on conflict (id) do nothing;

-- 051's lesson: `on conflict do nothing` silently keeps whatever flag the bucket
-- already had, so a bucket created by hand as public would stay public and this
-- file would look like it had worked. Assert the flag instead of assuming it.
update storage.buckets set public = false
 where id = 'wa-media' and public is distinct from false;

-- ── 3. Storage policies ────────────────────────────────────
-- Read: authenticated admins, scoped by the owning conversation (see header).
drop policy if exists "wa_media_owner_read" on storage.objects;
create policy "wa_media_owner_read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'wa-media'
    and exists (
      select 1
        from public.wa_conversations c
       where c.id::text = split_part(storage.objects.name, '/', 1)
         and (c.owner_id = auth.uid() or c.owner_id is null)
    )
  );

-- No INSERT/UPDATE/DELETE policy for `authenticated` on purpose. The webhook
-- writes with the service-role key, which bypasses RLS entirely; granting the
-- app write access would let any signed-in admin plant or delete an object in
-- someone else's conversation, and nothing in the app needs it.
drop policy if exists "wa_media_auth_write" on storage.objects;

commit;

-- ── 4. Verify ──────────────────────────────────────────────
-- Expect: one row, public = false.
-- select id, public from storage.buckets where id = 'wa-media';
--
-- Expect: the five media_* columns.
-- select column_name from information_schema.columns
--  where table_schema = 'public' and table_name = 'wa_messages'
--    and column_name like 'media%';
