// ============================================================
// send-push  —  Supabase Edge Function
// ------------------------------------------------------------
// Delivers a Firebase Cloud Messaging (FCM HTTP v1) push to the admin who owns
// a tour when a customer submits a booking_request. Invoked ONLY by the
// `booking_requests_notify_push` Postgres trigger (via pg_net) — never by the
// app or the public.
//
// Auth model: deployed WITHOUT a verified JWT (the DB trigger has no user
// session), so it proves itself with a shared secret header instead:
//   header  x-push-secret: <value>   ==   env PUSH_TRIGGER_SECRET
//
// Secrets (set via `supabase secrets set`, NEVER in git):
//   PUSH_TRIGGER_SECRET   shared secret, also stored in DB vault as
//                         'push_trigger_secret' (see database.sql §9b)
//   FCM_SERVICE_ACCOUNT   the Firebase service-account JSON, one line:
//                           supabase secrets set FCM_SERVICE_ACCOUNT="$(cat sa.json)"
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected by the runtime.
//
// Deploy (folder name MUST equal the function name):
//   supabase functions deploy send-push --no-verify-jwt
//
// Request body: { "request_id": "<uuid>" }
// Response:     { sent, pruned, total } | { skipped } | { error }
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type BookingEvent,
  buildFcmMessage,
  getFcmAccessToken,
  isDeadTokenStatus,
  type ServiceAccount,
  shouldNotifyBookingRequest,
} from "./lib.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // 1. Shared-secret gate (the trigger is the only legitimate caller).
  const expected = Deno.env.get("PUSH_TRIGGER_SECRET");
  if (!expected || req.headers.get("x-push-secret") !== expected) {
    return json({ error: "unauthorized" }, 401);
  }

  let payload: { request_id?: string; event?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }
  const requestId = payload.request_id;
  if (!requestId) return json({ error: "missing request_id" }, 400);
  // 'updated' = customer edited an existing request; default to 'created'.
  const event: BookingEvent = payload.event === "updated" ? "updated" : "created";

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const saJson = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!supabaseUrl || !serviceKey) {
    return json({ error: "Supabase env not injected" }, 500);
  }
  if (!saJson) return json({ error: "FCM_SERVICE_ACCOUNT not configured" }, 500);

  const sb = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  // 2. Booking request + its tour (title + owning admin). Service role bypasses
  //    RLS, so we read the joined tour directly.
  const { data: reqRow, error: reqErr } = await sb
    .from("booking_requests")
    .select("id, customer_name, party_size, tour_id, tours(title, owner_id)")
    .eq("id", requestId)
    .single();
  if (reqErr || !reqRow) return json({ error: "request not found" }, 404);

  // supabase-js types the embedded relation loosely; narrow by hand.
  const tour = (reqRow as unknown as {
    tours: { title: string; owner_id: string } | null;
  }).tours;
  const ownerId = tour?.owner_id;
  const tourTitle = tour?.title ?? "your tour";
  if (!ownerId) return json({ error: "tour owner missing" }, 404);

  // 3. Honour the admin's notification preferences (server-side source of
  //    truth — a stale token on a disabled admin still gets nothing).
  const { data: admin } = await sb
    .from("admins")
    .select("push_enabled, notify_booking_requests")
    .eq("id", ownerId)
    .single();
  if (!shouldNotifyBookingRequest(admin)) {
    return json({ skipped: "prefs_off_or_missing" });
  }

  // 4. Every registered device for this admin.
  const { data: tokenRows } = await sb
    .from("device_tokens")
    .select("token")
    .eq("admin_id", ownerId);
  const tokens = (tokenRows ?? []).map((r) => r.token as string);
  if (tokens.length === 0) return json({ skipped: "no_tokens" });

  // 5. FCM access token + endpoint.
  let sa: ServiceAccount;
  try {
    sa = JSON.parse(saJson) as ServiceAccount;
  } catch {
    return json({ error: "FCM_SERVICE_ACCOUNT is not valid JSON" }, 500);
  }
  let accessToken: string;
  try {
    accessToken = await getFcmAccessToken(sa);
  } catch (e) {
    return json({ error: `FCM auth failed: ${e}` }, 502);
  }
  const endpoint =
    `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;

  // 6. Send sequentially; collect dead tokens to prune.
  let sent = 0;
  const dead: string[] = [];
  for (const token of tokens) {
    const message = buildFcmMessage({
      token,
      tourTitle,
      event,
      request: reqRow as unknown as {
        id: string;
        customer_name: string;
        party_size: number;
      },
    });
    try {
      const res = await fetch(endpoint, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ message }),
      });
      if (res.ok) {
        sent++;
      } else {
        const err = await res.json().catch(() => ({}));
        const status = err?.error?.status as string | undefined;
        if (isDeadTokenStatus(res.status, status)) dead.push(token);
      }
    } catch {
      // Transient network error — leave the token in place, try again next time.
    }
  }

  // 7. Prune dead tokens so the table doesn't accumulate uninstalled devices.
  if (dead.length > 0) {
    await sb.from("device_tokens").delete().in("token", dead);
  }

  return json({ sent, pruned: dead.length, total: tokens.length });
});
