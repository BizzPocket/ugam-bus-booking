-- ============================================================
-- 051  tour-broadcasts must actually BE public
-- ------------------------------------------------------------
-- Run THIS FILE ALONE in the Supabase SQL editor. The remote migration
-- history is empty, so `supabase db push` would replay 001..050. Idempotent.
--
-- (Numbered 051, not 048: 048/049/050 landed from another branch mid-session.
-- Note 004, 006 and 045 each already have TWO files sharing a number — worth
-- untangling separately, since duplicate numbers make "has this run?"
-- unanswerable from the filenames alone.)
--
-- THE BUG (verified against production, 2026-08-01)
--
-- `create_tour_screen.dart` stores the hero image URL built by
-- `getPublicUrl()` into `tours.broadcast_image_url` — a URL of the form
--   /storage/v1/object/public/tour-broadcasts/<file>
-- That route only serves when the BUCKET is flagged public. Live, it is not:
--
--   GET /object/tour-broadcasts/<file>          + apikey  -> 200, 136078 B image/jpeg
--   GET /object/public/tour-broadcasts/<file>   no creds  -> 400 NoSuchBucket
--
-- The object exists and is fine. The bucket flag is wrong. Two consequences,
-- both silent:
--
--   1. IN-APP — `Image.network` sends no apikey, so the hero image on the
--      tour detail screen always 400s. `errorBuilder` swaps in the graphite
--      backdrop, so it looks like a design choice rather than a failure.
--
--   2. WHATSAPP — Meta fetches the media URL from ITS OWN servers, with no
--      credentials. It receives a 98-byte JSON error where an image should be
--      and rejects the send. This is the likeliest source of the
--      image-header rejections on broadcast sends.
--
-- WHY 009 DIDN'T DO THIS
-- 009 inserts the bucket with `public => true`, but with
-- `on conflict (id) do nothing`. The buckets already existed (created out of
-- band, default private), so the insert was skipped and the flag never
-- applied. The migration file has looked correct ever since.
--
-- seat-charts is DELIBERATELY LEFT PRIVATE — see below.
-- ============================================================

update storage.buckets
   set public = true
 where id = 'tour-broadcasts';


-- ------------------------------------------------------------
-- seat-charts: DO NOT make this public, despite 009 saying so.
--
-- 009 created both buckets with the same `public => true`, but that intent
-- was wrong for this one. A seat chart is a rendered roster — passenger
-- NAMES and seat allocations, i.e. personal data. A public bucket serves any
-- object to anyone who has (or guesses) its path, with no auth and no RLS on
-- the read route.
--
-- It also does not need to be public. `whatsapp_outbound.dart` sends seat
-- charts via `uploadSigned()`, and a signed URL works fine against a private
-- bucket — which is why that path has been working while broadcasts break.
--
-- Left as an explicit no-op with reasoning attached, so a later reader who
-- notices the asymmetry against 009 doesn't "fix" it and publish the roster.
-- ------------------------------------------------------------


-- ============================================================
-- VERIFY
-- ============================================================
-- select id, public from storage.buckets
--  where id in ('tour-broadcasts','seat-charts');
--   -> tour-broadcasts | t
--   -> seat-charts     | f      <-- must stay false
--
-- Then, from any shell (NO credentials — this is what Meta does):
--   curl -s -o /dev/null -w '%{http_code} %{content_type}\n' \
--     "https://rhyqjzulpvaeslbaymex.supabase.co/storage/v1/object/public/tour-broadcasts/broadcast_1785465268589.jpg"
--   -> 200 image/jpeg      (before this migration: 400 application/json)
