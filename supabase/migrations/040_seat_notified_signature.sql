-- ============================================================
-- 040  Post-lock re-notify: remember the last-notified seat set
-- ------------------------------------------------------------
-- Organisers can now edit seats AFTER a tour is locked (the tour STAYS locked
-- through the edit). To let the Notify screen offer a TARGETED "re-notify
-- changed" instead of blindly re-blasting every rider, each passenger remembers
-- a signature of the seat-set that was last WhatsApp-notified to them. When
-- their current seats differ from it — a fresh lock (never sent) or a post-lock
-- edit — they are flagged as "changed" and can be re-notified on their own.
--
-- Nullable, NULL default: existing rows read as "never notified", which is
-- correct — the first seat-allocation send stamps the signature. The app
-- (Passenger.toMap / fromMap) owns the value; this migration only ADDS the
-- column so those writes have somewhere to land. No RLS change: the column
-- rides on the existing owner-scoped passengers policies.
--
-- Run THIS FILE ALONE in the Supabase SQL editor. Idempotent.
-- ============================================================

alter table public.passengers
  add column if not exists seats_notified_sig text;
