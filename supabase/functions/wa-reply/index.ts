// ============================================================
// wa-reply  —  Supabase Edge Function
// ------------------------------------------------------------
// Sends an ADMIN's free-text reply to a customer inside the WhatsApp inbox.
// The admin app HAS a Supabase session, so verify_jwt is ON — functions.invoke
// forwards the caller's JWT automatically. We use it to identify the admin
// (auth.getUser via the ANON key + forwarded Authorization header), then do all
// DB reads/writes with a SEPARATE service-role client that bypasses RLS.
//
// Authorization: the caller (uid) may reply on a conversation only if the
// conversation is theirs (owner_id === uid) OR unassigned (owner_id === null).
// An unassigned conversation is CLAIMED (owner_id set to uid) on first reply.
//
// Send channel is chosen by the WhatsApp 24h customer-service window:
//   * window OPEN  (last_inbound_at within 24h)  -> free-text session message.
//   * window CLOSED / never inbound              -> approved template 'bus_msg'
//     (language 'gu', body var {{1}} = the reply text) — same shape bus-message
//     uses. Templates are the only thing Meta allows outside the 24h window.
//
// Reuses the exact Graph API call shape as bus-message (same secrets, same
// version-validation regex, same endpoint building).
//
// Edge Function secrets (shared with bus-message):
//   supabase secrets set WHATSAPP_TOKEN=EAAG...
//   supabase secrets set WHATSAPP_PHONE_NUMBER_ID=1234567890
//   supabase secrets set WHATSAPP_GRAPH_VERSION=v25.0          # optional
// Plus the auto-injected SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY /
// SUPABASE_ANON_KEY.
//
// Deploy (folder name MUST equal the deployed function name):
//   supabase functions deploy wa-reply
//
// Request body:  { "conversationId": "<uuid>", "text": "..." }
// Response 200:  { ok: true,  channel: "session"|"template", message: <wa_messages row> }
//           or:  { ok: false, error: "<graph error message>" }   (nothing inserted)
// 401 (no session), 403 (not owner + not unassigned), 404 (conversation gone).
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Approved Meta template used to open a message outside the 24h session window
// (body var {{1}} = the reply text). Same template bus-message sends.
const BUS_MESSAGE_TEMPLATE = "bus_msg";
// Default template language — matches WhatsAppCloudConfig.defaultLanguage ('gu').
const TEMPLATE_LANGUAGE = "gu";

// The WhatsApp customer-service window: free-text session messages are only
// allowed within 24h of the customer's last inbound message.
const WINDOW_MS = 24 * 60 * 60 * 1000;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// Same component shape as bus-message: a single body parameter {{1}}.
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

// Meta refuses a TEMPLATE PARAMETER containing a new-line, a tab, or more than
// four consecutive spaces:
//
//   (#132000) Param text cannot have new-line/tab characters or more than 4
//   consecutive spaces
//
// A reply typed in a chat composer is exactly the kind of text that trips this
// — the agent presses Enter mid-message and the send fails with a Graph error
// the UI reduced to "Couldn't send". The rule is NOT about the message being
// long, and it does NOT apply to the free-text session path, where new-lines are
// perfectly legal. So this collapses whitespace ONLY on the template branch,
// mirroring WaTemplateParams.sanitize in lib/services/wa_template_params.dart
// (same three rules, same order). Length is deliberately not truncated: cutting
// the tail off an agent's reply is worse than reporting 132005.
const sanitizeTemplateParam = (value: string): string =>
  value
    .replace(/[\r\n]+/g, " ")
    .replace(/\t+/g, " ")
    .replace(/ {5,}/g, " ")
    .trim();

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
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !serviceRoleKey || !anonKey) {
    return json(
      {
        error:
          "SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / SUPABASE_ANON_KEY not configured",
      },
      500,
    );
  }

  let payload: { conversationId?: string; text?: string };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const conversationId = (payload.conversationId ?? "").trim();
  const text = (payload.text ?? "").trim();
  if (!conversationId || !text) {
    return json({ error: "Missing conversationId or text" }, 400);
  }

  // --- Identify the caller from the forwarded JWT (ANON key + Authorization). ---
  const authHeader = req.headers.get("authorization") ?? "";
  const asCaller = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await asCaller.auth.getUser();
  const uid = userData?.user?.id;
  if (userErr || !uid) {
    return json({ error: "Not authenticated" }, 401);
  }

  // Service-role client — bypasses RLS; we do the authorization ourselves.
  const db = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // --- Load the conversation and authorize. ---
  const { data: convo, error: convoErr } = await db
    .from("wa_conversations")
    .select("id, owner_id, customer_phone, last_inbound_at")
    .eq("id", conversationId)
    .maybeSingle();
  if (convoErr) {
    return json({ error: `Could not load conversation: ${convoErr.message}` }, 500);
  }
  if (!convo) {
    return json({ error: "Conversation not found" }, 404);
  }
  if (convo.owner_id !== null && convo.owner_id !== uid) {
    return json({ error: "Not your conversation" }, 403);
  }
  // Unassigned conversation -> claim it (owner_id set in the update below).
  const claiming = convo.owner_id === null;

  const to = String(convo.customer_phone ?? "").replace(/[^\d]/g, "");
  if (!to) {
    return json({ error: "Conversation has no customer phone" }, 500);
  }

  // --- Choose the send channel by the 24h customer-service window. ---
  const lastInbound = convo.last_inbound_at
    ? new Date(convo.last_inbound_at).getTime()
    : null;
  const windowOpen =
    lastInbound !== null && Date.now() - lastInbound <= WINDOW_MS;

  // What the customer will actually receive. The thread is logged with THIS,
  // not the raw draft: if the template branch had to collapse the agent's line
  // breaks, the chat history should show the message as it was delivered rather
  // than a version the customer never saw.
  const sentText = windowOpen ? text : sanitizeTemplateParam(text);
  if (!sentText) {
    return json({ ok: false, error: "Reply is empty after formatting" });
  }

  const graphBody = windowOpen
    ? {
        messaging_product: "whatsapp",
        to,
        type: "text",
        text: { body: sentText },
      }
    : {
        messaging_product: "whatsapp",
        to,
        type: "template",
        template: {
          name: BUS_MESSAGE_TEMPLATE,
          language: { code: TEMPLATE_LANGUAGE },
          components: buildComponents([sentText]),
        },
      };

  const endpoint =
    `https://graph.facebook.com/${graphVersion}/${phoneNumberId}/messages`;

  let graphData: {
    messages?: Array<{ id?: string }>;
    error?: { message?: string };
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
    graphData = await res.json();
    if (!res.ok) {
      // Graph failure: surface the error, insert nothing.
      return json({
        ok: false,
        error: graphData?.error?.message ?? `HTTP ${res.status}`,
      });
    }
  } catch (e) {
    return json({ ok: false, error: String(e) });
  }

  const waMessageId = graphData?.messages?.[0]?.id ?? null;

  // --- Graph success: record the outbound message. ---
  const { data: inserted, error: insErr } = await db
    .from("wa_messages")
    .insert({
      conversation_id: conversationId,
      wa_message_id: waMessageId,
      direction: "out",
      body: sentText,
      msg_type: "text",
      status: "sent",
    })
    .select()
    .single();
  if (insErr) {
    return json({ ok: false, error: `Send ok but log failed: ${insErr.message}` });
  }

  // --- Bump the conversation (and claim it if it was unassigned). ---
  const convoUpdate: Record<string, unknown> = {
    last_message_at: new Date().toISOString(),
    last_message_preview: sentText,
    unread_count: 0,
  };
  if (claiming) convoUpdate.owner_id = uid;
  await db.from("wa_conversations").update(convoUpdate).eq("id", conversationId);

  return json({
    ok: true,
    channel: windowOpen ? "session" : "template",
    message: inserted,
  });
});
