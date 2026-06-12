-- ============================================================
-- 013_fix_customer_booking.sql
-- Fix: customers can't submit booking requests after migration 011.
--
-- Migration 011 (SEC-3) added a BEFORE INSERT trigger on booking_requests that
-- blocked the 4th+ request per phone, per tour, per hour. That window is hit
-- almost immediately while testing (and by any customer who edits/re-submits),
-- and the app then shows a generic "save failed". The app ALREADY enforces a
-- per-device cooldown + one-pending-request-per-trip, so the DB trigger was
-- redundant and too strict. Remove it.
--
-- Safe to run as-is in the Supabase SQL editor; idempotent.
-- ============================================================

drop trigger if exists booking_requests_rate_limit_trg on public.booking_requests;
drop function if exists public.booking_requests_rate_limit();

-- (If you later want DB-level spam protection, re-add it via a SECURITY DEFINER
--  RPC the client calls — never a hard trigger with a tight per-hour cap, which
--  blocks legitimate edits/re-submits.)
