-- ============================================================
-- 043  handler_ctx must not be a public (uuid -> phone number) lookup
-- ------------------------------------------------------------
-- 042 introduced `handler_ctx(p_id uuid) -> (tour_id, customer_phone)` and
-- deliberately did NOT grant it, on the reasoning that it is only ever called
-- from inside SECURITY DEFINER functions (which execute as the owner and so
-- always retain execute on it). That reasoning is sound; the `revoke` was not.
--
-- `revoke all on function ... from public` only drops the implicit PUBLIC
-- grant. Supabase ships a default-privileges rule that grants EXECUTE on newly
-- created functions in `public` to `anon` and `authenticated` directly, and a
-- revoke aimed at PUBLIC does not touch a role-specific grant. So handler_ctx
-- landed on the live PostgREST API surface. Verified against production after
-- 042 was applied, with the anon key:
--
--     POST /rest/v1/rpc/handler_ctx  {"p_id":"<any passenger or request uuid>"}
--     -> [{"tour_id":"05853fca-…","customer_phone":"+9193271…"}]
--
-- That turns any leaked passenger/booking_request uuid into a phone number for
-- an unauthenticated caller. Low reach (uuids are not enumerable) but it is a
-- brand-new public endpoint that nothing in the app ever calls, so the correct
-- move is to close it rather than reason about its blast radius.
--
-- Revoking from anon/authenticated does NOT break the handler flow. Every
-- caller of handler_ctx — is_request_handler, handler_tour_manifest, and the
-- six handler_upsert_/handler_delete_ RPCs — is SECURITY DEFINER, so the nested
-- call runs with the OWNER's privileges, not the caller's. The anon-facing
-- surface is unchanged.
--
-- `service_role` keeps (and is explicitly granted) execute: the bus-message
-- Edge Function uses the service-role key and calls handler_ctx directly to
-- resolve a handler whose opaque ref is a passengers.id — see the matching fix
-- in supabase/functions/bus-message/index.ts.
--
-- Run THIS FILE ALONE in the Supabase SQL editor (the numbered migration
-- history is out of sync with live). Idempotent.
-- ============================================================

revoke execute on function public.handler_ctx(uuid) from anon;
revoke execute on function public.handler_ctx(uuid) from authenticated;

grant execute on function public.handler_ctx(uuid) to service_role;
