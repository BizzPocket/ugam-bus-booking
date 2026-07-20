// ============================================================
// wa-webhook  —  Supabase Edge Function
// ------------------------------------------------------------
// Receives INBOUND WhatsApp messages (and delivery-status receipts) from Meta's
// WhatsApp Cloud API webhook and lands them in the in-app WhatsApp inbox
// (public.wa_conversations / public.wa_messages, created by migration
// 033_whatsapp_inbox.sql). Meta has no Supabase session, so this is deployed
// WITHOUT a verified JWT; it authenticates META itself two ways:
//
//   GET  handshake — hub.verify_token must equal WHATSAPP_WEBHOOK_VERIFY_TOKEN.
//   POST event     — the 'x-hub-signature-256' header must be
//                    'sha256=' + hex(HMAC_SHA256(WHATSAPP_APP_SECRET, rawBody)).
//                    (If WHATSAPP_APP_SECRET is unset the check is SKIPPED with a
//                    warning — set it in production.)
//
// After authenticating Meta it writes with the service-role client (bypasses the
// per-owner RLS). Every inbound message resolves-or-creates a conversation,
// dedupes on Meta's message id, bumps the conversation's unread/last-seen fields,
// and fires an admin push via the send-push function (type 'wa_message').
//
// It ALWAYS answers 200 so Meta never enters its retry storm — per-item errors
// are caught and logged, not surfaced.
//
// Edge Function secrets (set via `supabase secrets set`, NEVER in git):
//   WHATSAPP_WEBHOOK_VERIFY_TOKEN   the token you type into the Meta webhook UI
//   WHATSAPP_APP_SECRET             (optional) Meta App Secret — HMAC signature
//   PUSH_TRIGGER_SECRET             shared secret forwarded to send-push
// Plus the auto-injected SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY.
//
// Deploy (folder name MUST equal the deployed function name; no JWT for Meta):
//   supabase functions deploy wa-webhook --no-verify-jwt
//
// GET  response:  200 text/plain <hub.challenge>  |  403
// POST response:  200 { ok: true }  (always, even on partial failure)
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-hub-signature-256",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// Human placeholder shown in the conversation list when a message has no text
// body (media is not downloaded yet). Keeps last_message_preview meaningful.
const previewForType = (msgType: string): string => {
  switch (msgType) {
    case "image":
      return "[image]";
    case "document":
      return "[document]";
    case "audio":
      return "[audio]";
    case "video":
      return "[video]";
    default:
      return "[message]";
  }
};

// Meta's msg_type column only allows this closed set; anything else -> 'other'.
const normalizeMsgType = (t: string): string =>
  ["text", "image", "document", "audio", "video"].includes(t) ? t : "other";

// Unix-seconds string (Meta's m.timestamp) -> ISO string. Null if unparseable so
// the caller can fall back to the column default.
const tsToIso = (ts: unknown): string | null => {
  const n = Number(ts);
  if (!Number.isFinite(n) || n <= 0) return null;
  return new Date(n * 1000).toISOString();
};

// 'sha256=' + lowercase hex of HMAC_SHA256(appSecret, rawBody).
async function computeSignature(
  appSecret: string,
  rawBody: string,
): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(appSecret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(rawBody));
  const hex = Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `sha256=${hex}`;
}

// Constant-time-ish compare of two equal-purpose strings.
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// deno-lint-ignore no-explicit-any
type Json = any;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);

  // --- GET: Meta webhook verification handshake ---------------------------
  if (req.method === "GET") {
    const mode = url.searchParams.get("hub.mode");
    const verifyToken = url.searchParams.get("hub.verify_token");
    const challenge = url.searchParams.get("hub.challenge") ?? "";
    const expected = Deno.env.get("WHATSAPP_WEBHOOK_VERIFY_TOKEN");
    if (mode === "subscribe" && expected && verifyToken === expected) {
      // Meta expects the raw challenge echoed back as plain text.
      return new Response(challenge, {
        status: 200,
        headers: { ...CORS, "Content-Type": "text/plain" },
      });
    }
    return new Response("forbidden", {
      status: 403,
      headers: { ...CORS, "Content-Type": "text/plain" },
    });
  }

  if (req.method !== "POST") return json({ error: "GET or POST only" }, 405);

  // --- POST: an inbound event ---------------------------------------------
  // Read the RAW body FIRST — the signature is computed over these exact bytes,
  // so re-serializing parsed JSON would not match.
  const rawBody = await req.text();

  // Signature verification (proves the POST came from Meta). A mismatch returns
  // 200 with no work done, so Meta does not retry an attacker's forged event.
  const appSecret = Deno.env.get("WHATSAPP_APP_SECRET");
  if (appSecret) {
    const provided = req.headers.get("x-hub-signature-256") ?? "";
    let ok = false;
    try {
      const expectedSig = await computeSignature(appSecret, rawBody);
      ok = safeEqual(provided, expectedSig);
    } catch (e) {
      console.error("wa-webhook: signature computation failed", e);
    }
    if (!ok) {
      console.warn("wa-webhook: invalid x-hub-signature-256; ignoring event");
      return json({ ok: true });
    }
  } else {
    console.warn(
      "wa-webhook: WHATSAPP_APP_SECRET not set — skipping signature check",
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    // Nothing we can do, but still 200 so Meta doesn't hammer retries.
    console.error("wa-webhook: SUPABASE_URL / SERVICE_ROLE_KEY not injected");
    return json({ ok: true });
  }

  let event: Json;
  try {
    event = JSON.parse(rawBody);
  } catch {
    console.error("wa-webhook: body was not valid JSON");
    return json({ ok: true });
  }

  // Service-role client — bypasses RLS; Meta was already authenticated above.
  const db = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const pushSecret = Deno.env.get("PUSH_TRIGGER_SECRET");

  // Best-effort admin push for a new inbound message. Swallows every error —
  // a failed notification must never fail the webhook.
  const firePush = async (args: {
    ownerId: string | null;
    conversationId: string;
    title: string;
    body: string;
  }) => {
    if (!args.ownerId) return; // nobody to notify (unassigned conversation)
    if (!pushSecret) {
      console.warn("wa-webhook: PUSH_TRIGGER_SECRET not set — skipping push");
      return;
    }
    try {
      await fetch(`${supabaseUrl}/functions/v1/send-push`, {
        method: "POST",
        headers: {
          "x-push-secret": pushSecret,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          type: "wa_message",
          owner_id: args.ownerId,
          conversation_id: args.conversationId,
          title: args.title,
          body: args.body,
        }),
      });
    } catch (e) {
      console.error("wa-webhook: push fetch failed (ignored)", e);
    }
  };

  // Resolve or create the conversation for a phone. Returns the row (or null on
  // hard DB error, in which case the caller skips the message).
  const resolveConversation = async (
    from: string,
    contactName: string | null,
  ): Promise<
    { id: string; owner_id: string | null; customer_name: string | null } | null
  > => {
    const { data: existing, error: selErr } = await db
      .from("wa_conversations")
      .select("id, owner_id, customer_name")
      .eq("customer_phone", from)
      .maybeSingle();
    if (selErr) {
      console.error("wa-webhook: conversation select failed", selErr.message);
      return null;
    }
    if (existing) return existing;

    // No conversation yet — resolve the owning admin from this customer's most
    // recent tour, and best-effort a display name from the WA contact profile.
    let ownerId: string | null = null;
    try {
      const { data: resolved, error: rpcErr } = await db.rpc(
        "wa_resolve_owner",
        { p_phone: from },
      );
      if (rpcErr) {
        console.error("wa-webhook: wa_resolve_owner failed", rpcErr.message);
      } else if (typeof resolved === "string") {
        ownerId = resolved;
      }
    } catch (e) {
      console.error("wa-webhook: wa_resolve_owner threw", e);
    }

    const { data: inserted, error: insErr } = await db
      .from("wa_conversations")
      .insert({
        owner_id: ownerId,
        customer_phone: from,
        customer_name: contactName,
      })
      .select("id, owner_id, customer_name")
      .maybeSingle();
    if (insErr || !inserted) {
      // Lost an insert race? Re-select the row the other request created.
      const { data: raced } = await db
        .from("wa_conversations")
        .select("id, owner_id, customer_name")
        .eq("customer_phone", from)
        .maybeSingle();
      if (raced) return raced;
      console.error(
        "wa-webhook: conversation insert failed",
        insErr?.message ?? "unknown",
      );
      return null;
    }
    return inserted;
  };

  // Walk entry[].changes[].value — the standard Cloud API envelope.
  const entries: Json[] = Array.isArray(event?.entry) ? event.entry : [];
  for (const entry of entries) {
    const changes: Json[] = Array.isArray(entry?.changes) ? entry.changes : [];
    for (const change of changes) {
      const value: Json = change?.value ?? {};

      // ---- Inbound messages -------------------------------------------------
      const contacts: Json[] = Array.isArray(value?.contacts)
        ? value.contacts
        : [];
      const messages: Json[] = Array.isArray(value?.messages)
        ? value.messages
        : [];

      for (const m of messages) {
        try {
          const from: string = String(m?.from ?? "").trim();
          const waMessageId: string = String(m?.id ?? "").trim();
          if (!from || !waMessageId) continue;

          // Idempotency — Meta re-delivers on any non-200; skip known ids.
          const { data: dupe } = await db
            .from("wa_messages")
            .select("id")
            .eq("wa_message_id", waMessageId)
            .maybeSingle();
          if (dupe) continue;

          const rawType: string = String(m?.type ?? "text");
          let body: string | null;
          let msgType: string;
          if (rawType === "text") {
            body = m?.text?.body ?? null;
            msgType = "text";
          } else {
            body = null; // media download deferred
            msgType = normalizeMsgType(rawType);
          }

          const msgIso = tsToIso(m?.timestamp);

          // Best-effort display name from this message's WA contact profile.
          const contact = contacts.find(
            (c) => String(c?.wa_id ?? "") === from,
          );
          const contactName: string | null =
            contact?.profile?.name ?? null;

          const convo = await resolveConversation(from, contactName);
          if (!convo) continue;

          // Insert the inbound message. Omit created_at when we couldn't parse a
          // timestamp so the column default (now()) applies.
          const messageRow: Json = {
            conversation_id: convo.id,
            wa_message_id: waMessageId,
            direction: "in",
            body,
            msg_type: msgType,
          };
          if (msgIso) messageRow.created_at = msgIso;

          const { error: msgErr } = await db
            .from("wa_messages")
            .insert(messageRow);
          if (msgErr) {
            // Unique-violation on wa_message_id = another delivery beat us; fine.
            if (!String(msgErr.message).toLowerCase().includes("duplicate")) {
              console.error("wa-webhook: message insert failed", msgErr.message);
            }
            continue;
          }

          // Bump conversation counters. Read-then-write for unread_count is fine
          // at this volume. Only set customer_name if we now have one and it was
          // previously blank.
          const preview = body ?? previewForType(msgType);
          const nowIso = msgIso ?? new Date().toISOString();

          const { data: cur } = await db
            .from("wa_conversations")
            .select("unread_count, customer_name")
            .eq("id", convo.id)
            .maybeSingle();
          const nextUnread = (cur?.unread_count ?? 0) + 1;

          const convoUpdate: Json = {
            last_message_at: nowIso,
            last_message_preview: preview,
            last_inbound_at: nowIso,
            unread_count: nextUnread,
          };
          if (!cur?.customer_name && contactName) {
            convoUpdate.customer_name = contactName;
          }

          const { error: updErr } = await db
            .from("wa_conversations")
            .update(convoUpdate)
            .eq("id", convo.id);
          if (updErr) {
            console.error(
              "wa-webhook: conversation update failed",
              updErr.message,
            );
          }

          // Notify the owning admin (best-effort, never blocks the 200).
          const displayName =
            contactName ?? convo.customer_name ?? from;
          await firePush({
            ownerId: convo.owner_id,
            conversationId: convo.id,
            title: displayName,
            body: body ?? "Sent a photo",
          });
        } catch (e) {
          // Per-message isolation — one bad message never drops the batch.
          console.error("wa-webhook: message handling threw", e);
        }
      }

      // ---- Outbound delivery-status receipts --------------------------------
      const statuses: Json[] = Array.isArray(value?.statuses)
        ? value.statuses
        : [];
      for (const s of statuses) {
        try {
          const statusId: string = String(s?.id ?? "").trim();
          const status: string = String(s?.status ?? "").trim();
          if (!statusId || !status) continue;
          const { error: stErr } = await db
            .from("wa_messages")
            .update({ status })
            .eq("wa_message_id", statusId);
          if (stErr) {
            console.error("wa-webhook: status update failed", stErr.message);
          }
        } catch (e) {
          console.error("wa-webhook: status handling threw", e);
        }
      }
    }
  }

  // ALWAYS 200 so Meta does not enter its retry storm.
  return json({ ok: true });
});
