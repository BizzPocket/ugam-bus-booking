-- ============================================================
-- 008  Admin self-service settings
-- ------------------------------------------------------------
-- Backs the four Settings options that previously had no-op taps:
--
--   Account Details   -> business_name, business_email
--   WhatsApp Settings -> whatsapp_number (already present), wa_handoff_template
--   Payment Settings  -> upi_id, payee_name, default_advance, receipt_note
--   Notifications     -> notify_* flags + push_enabled
--
-- All columns hang off the existing public.admins row, so they are written
-- through the existing "admins_update_self" RLS policy (id = auth.uid()) —
-- no new policy or RPC is required. Every column is nullable / defaulted so
-- existing admin rows keep working untouched.
-- ============================================================

alter table public.admins
  add column if not exists business_name           text,
  add column if not exists business_email          text,
  add column if not exists upi_id                  text,
  add column if not exists payee_name              text,
  add column if not exists default_advance         numeric(12, 2),
  add column if not exists receipt_note            text,
  add column if not exists wa_handoff_template     text,
  add column if not exists notify_booking_requests boolean not null default true,
  add column if not exists notify_payment_reminders boolean not null default true,
  add column if not exists notify_departure_reminders boolean not null default true,
  add column if not exists push_enabled            boolean not null default true;
