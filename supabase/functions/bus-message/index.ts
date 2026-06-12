// ============================================================
// bus-message  —  Supabase Edge Function
// ------------------------------------------------------------
// A per-bus WhatsApp announcement sent by an ANONYMOUS tour handler (the
// handler app has no Supabase session — it only knows its booking requestId).
// verify_jwt is OFF; authorization is done IN CODE with the service-role client:
//
//   1. is_request_handler(requestId) must be true (the request's
//      (tour_id, customer_phone) matches a passenger with is_handler = true).
//   2. The target bus (busId) must have handler_passenger_id equal to THAT
//      handler passenger's id — i.e. the handler may only message a bus they own.
//
// On success it sends the WhatsAppCloudConfig.busMessageTemplate
// ('bus_announcement', body var {{1}} = the free-text message) to every
// passenger seated on that bus (their assigned_seats jsonb contains the busId),
// reusing the exact Graph API call shape as quick-action (same secrets, version
// handling, buildComponents).
//
// Edge Function secrets (shared with quick-action):
//   supabase secrets set WHATSAPP_TOKEN=EAAG...
//   supabase secrets set WHATSAPP_PHONE_NUMBER_ID=1234567890
//   supabase secrets set WHATSAPP_GRAPH_VERSION=v25.0          # optional
// Plus the auto-injected SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.
//
// Deploy (folder name MUST equal the deployed function name):
//   supabase functions deploy bus-message
//
// Request body:  { "requestId": "<uuid>", "busId": "<uuid>", "message": "..." }
// Response:      { results: [ { to, ok, id?, error? } ], sent, failed }
// 403 (never sends) when the caller is not the bus's handler.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Approved Meta template for a free-text bus announcement (body var {{1}} = the
// message). Mirrors WhatsAppCloudConfig.busMessageTemplate on the app side.
const BUS_MESSAGE_TEMPLATE = "bus_announcement";
// Default template language — matches WhatsAppCloudConfig.defaultLanguage ('gu').
const TEMPLATE_LANGUAGE = "gu";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// Strip everything but digits (Graph wants country-code + number, no '+').
const normalizeTo = (raw: string) => (raw ?? "").replace(/[^\d]/g, "");

// Same component shape as quick-action: a single body parameter {{1}}.
function buildComponents(bodyParams: string[]) {
  const components: unknown[] = [];
  if (bodyParams.length > 0) {
    components.push({
      type: "body",
      parameters: bodyParams.map((t) => ({ type: "text", text: String(t) })),
    });
  }
  return components;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const token = Deno.env.get("WHATSAPP_TOKEN");
  const phoneNumberId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID");
  // Only a well-formed version (e.g. "v25.0") is used; a blank/garbled secret
  // would otherwise produce "graph.facebook.com//<id>/messages". Fall back.
  const rawVersion = (Deno.env.get("WHATSAPP_GRAPH_VERSION") ?? "").trim();
  const graphVersion = /^v\d+\.\d+$/.test(rawVersion) ? rawVersion : "v25.0";

  if (!token || !phoneNumberId) {
    return json(
      { error: "WHATSAPP_TOKEN / WHATSAPP_PHONE_NUMBER_ID not configured" },
      500,
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return json(
      { error: "SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not configured" },
      500,
    );
  }

  let payload: { requestId?: string; busId?: string; message?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const requestId = (payload.requestId ?? "").trim();
  const busId = (payload.busId ?? "").trim();
  const message = (payload.message ?? "").trim();
  if (!requestId || !busId || !message) {
    return json({ error: "Missing requestId, busId or message" }, 400);
  }

  // Service-role client — bypasses RLS; we do the authorization ourselves below.
  const db = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // --- Authorization step 1: is this request owned by a handler? ---
  const { data: isHandler, error: gateErr } = await db.rpc(
    "is_request_handler",
    { p_request_id: requestId },
  );
  if (gateErr) {
    return json({ error: `Authorization check failed: ${gateErr.message}` }, 500);
  }
  if (isHandler !== true) {
    return json({ error: "Not authorized for this request" }, 403);
  }

  // Resolve the request's (tour_id, customer_phone) so we can find the exact
  // handler passenger and confirm they own this bus.
  const { data: reqRow, error: reqErr } = await db
    .from("booking_requests")
    .select("tour_id, customer_phone")
    .eq("id", requestId)
    .maybeSingle();
  if (reqErr || !reqRow) {
    return json({ error: "Request not found" }, 403);
  }

  const { data: handlerRow, error: handlerErr } = await db
    .from("passengers")
    .select("id")
    .eq("tour_id", reqRow.tour_id)
    .eq("phone", reqRow.customer_phone)
    .eq("is_handler", true)
    .maybeSingle();
  if (handlerErr || !handlerRow) {
    return json({ error: "Handler passenger not found" }, 403);
  }

  // --- Authorization step 2: does this handler OWN the target bus? ---
  const { data: busRow, error: busErr } = await db
    .from("buses")
    .select("id, tour_id, handler_passenger_id")
    .eq("id", busId)
    .maybeSingle();
  if (busErr || !busRow) {
    return json({ error: "Bus not found" }, 403);
  }
  if (
    busRow.tour_id !== reqRow.tour_id ||
    busRow.handler_passenger_id !== handlerRow.id
  ) {
    return json({ error: "Not the handler of this bus" }, 403);
  }

  // --- Recipients: passengers of this bus's tour seated on this bus. ---
  // assigned_seats is a jsonb array of { busId, seatId }; @> matches any element
  // whose busId equals our bus.
  const { data: passengers, error: paxErr } = await db
    .from("passengers")
    .select("phone")
    .eq("tour_id", busRow.tour_id)
    .filter("assigned_seats", "cs", JSON.stringify([{ busId }]));
  if (paxErr) {
    return json({ error: `Could not load recipients: ${paxErr.message}` }, 500);
  }

  const phones = Array.from(
    new Set(
      (passengers ?? [])
        .map((p: { phone?: string }) => normalizeTo(p.phone ?? ""))
        .filter((p: string) => p.length > 0),
    ),
  );

  if (phones.length === 0) {
    return json({ results: [], sent: 0, failed: 0 });
  }

  const endpoint =
    `https://graph.facebook.com/${graphVersion}/${phoneNumberId}/messages`;

  const results: Array<
    { to: string; ok: boolean; id?: string; error?: string }
  > = [];

  // Sequential send keeps us under Cloud API burst limits and makes
  // per-recipient error reporting straightforward (same as quick-action).
  for (const to of phones) {
    const graphBody = {
      messaging_product: "whatsapp",
      to,
      type: "template",
      template: {
        name: BUS_MESSAGE_TEMPLATE,
        language: { code: TEMPLATE_LANGUAGE },
        components: buildComponents([message]),
      },
    };

    try {
      const res = await fetch(endpoint, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(graphBody),
      });
      const data = await res.json();
      if (res.ok) {
        results.push({ to, ok: true, id: data?.messages?.[0]?.id });
      } else {
        results.push({
          to,
          ok: false,
          error: data?.error?.message ?? `HTTP ${res.status}`,
        });
      }
    } catch (e) {
      results.push({ to, ok: false, error: String(e) });
    }
  }

  const sent = results.filter((r) => r.ok).length;
  return json({ results, sent, failed: results.length - sent });
});
