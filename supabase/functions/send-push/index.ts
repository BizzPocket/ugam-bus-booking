// ============================================================
// send-push  —  Supabase Edge Function
// ------------------------------------------------------------
// Delivers a Firebase Cloud Messaging (FCM HTTP v1) push to the admin who owns
// a tour. Two event shapes, both proven by the same shared secret (this function
// has no user session):
//
//   header  x-push-secret: <value>   ==   env PUSH_TRIGGER_SECRET
//
//   1. { "request_id": "<uuid>", "event"?: "created"|"updated" }
//        A customer booking request — invoked by the `booking_requests_notify_push`
//        Postgres trigger (via pg_net). Gated on push_enabled + notify_booking_requests.
//
//   2. { "type": "wa_message", "owner_id": "<uuid>", "title": "...", "body": "...",
//        "conversation_id"?: "<uuid>" }
//        An inbound WhatsApp customer message — invoked by the `wa-webhook`
//        function. Gated on push_enabled only.
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
// Response:  { sent, pruned, total } | { skipped } | { error }
// ============================================================

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type BookingEvent,
  buildFcmMessage,
  buildWaMessageFcm,
  getFcmAccessToken,
  isDeadTokenStatus,
  type ServiceAccount,
  shouldNotifyBookingRequest,
  shouldNotifyMessage,
} from "./lib.ts";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

interface Payload {
  // booking-request path
  request_id?: string;
  event?: string;
  // wa_message path
  type?: string;
  owner_id?: string;
  title?: string;
  body?: string;
  conversation_id?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // 1. Shared-secret gate (the DB trigger / wa-webhook are the only callers).
  const expected = Deno.env.get("PUSH_TRIGGER_SECRET");
  if (!expected || req.headers.get("x-push-secret") !== expected) {
    return json({ error: "unauthorized" }, 401);
  }

  let payload: Payload;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid JSON body" }, 400);
  }

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

  let sa: ServiceAccount;
  try {
    sa = JSON.parse(saJson) as ServiceAccount;
  } catch {
    return json({ error: "FCM_SERVICE_ACCOUNT is not valid JSON" }, 500);
  }

  if (payload.type === "wa_message") {
    return await handleWaMessage(sb, sa, payload);
  }
  return await handleBookingRequest(sb, sa, payload);
});

// ── Booking-request push (unchanged behaviour) ──────────────────────────────
async function handleBookingRequest(
  sb: SupabaseClient,
  sa: ServiceAccount,
  payload: Payload,
): Promise<Response> {
  const requestId = payload.request_id;
  if (!requestId) return json({ error: "missing request_id" }, 400);
  const event: BookingEvent = payload.event === "updated"
    ? "updated"
    : payload.event === "cancelled"
    ? "cancelled"
    : "created";

  // Booking request + its tour (title + owning admin). Service role bypasses RLS.
  const { data: reqRow, error: reqErr } = await sb
    .from("booking_requests")
    .select("id, customer_name, party_size, tour_id, tours(title, owner_id)")
    .eq("id", requestId)
    .single();
  if (reqErr || !reqRow) return json({ error: "request not found" }, 404);

  const tour = (reqRow as unknown as {
    tours: { title: string; owner_id: string } | null;
  }).tours;
  const ownerId = tour?.owner_id;
  const tourTitle = tour?.title ?? "your tour";
  if (!ownerId) return json({ error: "tour owner missing" }, 404);

  const { data: admin } = await sb
    .from("admins")
    .select("push_enabled, notify_booking_requests")
    .eq("id", ownerId)
    .single();
  if (!shouldNotifyBookingRequest(admin)) {
    return json({ skipped: "prefs_off_or_missing" });
  }

  return await deliver(sb, sa, ownerId, (token) =>
    buildFcmMessage({
      token,
      tourTitle,
      event,
      request: reqRow as unknown as {
        id: string;
        customer_name: string;
        party_size: number;
      },
    }));
}

// ── Inbound WhatsApp message push ───────────────────────────────────────────
async function handleWaMessage(
  sb: SupabaseClient,
  sa: ServiceAccount,
  payload: Payload,
): Promise<Response> {
  const ownerId = (payload.owner_id ?? "").trim();
  if (!ownerId) return json({ skipped: "no_owner" });
  const title = (payload.title ?? "New message").toString();
  const body = (payload.body ?? "").toString();
  const conversationId = payload.conversation_id;

  const { data: admin } = await sb
    .from("admins")
    .select("push_enabled")
    .eq("id", ownerId)
    .single();
  if (!shouldNotifyMessage(admin)) {
    return json({ skipped: "prefs_off_or_missing" });
  }

  return await deliver(sb, sa, ownerId, (token) =>
    buildWaMessageFcm({ token, title, body, conversationId }));
}

// ── Shared delivery: every device for an admin, prune dead tokens ───────────
async function deliver(
  sb: SupabaseClient,
  sa: ServiceAccount,
  ownerId: string,
  buildMessage: (token: string) => Record<string, unknown>,
): Promise<Response> {
  const { data: tokenRows } = await sb
    .from("device_tokens")
    .select("token")
    .eq("admin_id", ownerId);
  const tokens = (tokenRows ?? []).map((r) => r.token as string);
  if (tokens.length === 0) return json({ skipped: "no_tokens" });

  let accessToken: string;
  try {
    accessToken = await getFcmAccessToken(sa);
  } catch (e) {
    return json({ error: `FCM auth failed: ${e}` }, 502);
  }
  const endpoint =
    `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;

  let sent = 0;
  const dead: string[] = [];
  for (const token of tokens) {
    try {
      const res = await fetch(endpoint, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ message: buildMessage(token) }),
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

  if (dead.length > 0) {
    await sb.from("device_tokens").delete().in("token", dead);
  }

  return json({ sent, pruned: dead.length, total: tokens.length });
}
