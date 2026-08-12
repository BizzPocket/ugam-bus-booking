// ============================================================
// quick-action  —  Supabase Edge Function
// ------------------------------------------------------------
// Server-side sender for the WhatsApp Cloud API (Meta Graph API). The
// permanent access token NEVER leaves the server — the Flutter app invokes
// this function with a list of messages to send, and the function injects the
// token + phone-number-id from its secrets.
//
// Set these as Edge Function secrets (NOT in the app, NOT in git):
//   supabase secrets set WHATSAPP_TOKEN=EAAG...                # permanent token
//   supabase secrets set WHATSAPP_PHONE_NUMBER_ID=1234567890   # from Meta
//   supabase secrets set WHATSAPP_GRAPH_VERSION=v25.0          # optional (code defaults to v25.0)
//
// Deploy (the folder name MUST equal the deployed function name):
//   supabase functions deploy quick-action
//
// The Flutter app calls this via WhatsAppCloudConfig.functionName ('quick-action').
// `headerTextParams` fills a variable that lives in a TEXT header, e.g. the
// "{{1}}" in a header like "Jai Gurudev {{1}}," (used by seat_allocation).
//
// Auth: verify_jwt is ON by default, so only a signed-in Supabase user (the
// admin app) can call it. The app passes its session automatically via
// functions.invoke.
//
// Request body:
// {
//   "messages": [
//     {
//       "to": "919876543210",            // country code + number, digits only
//       "template": "seat_allocation",    // approved Meta template name
//       "language": "gu",                 // template language code (en / gu / hi)
//       "headerImageUrl": "https://...",            // optional image header
//       "headerDocumentUrl": "https://...pdf",      // optional document header
//       "headerDocumentFilename": "seat-chart.pdf", // shown in WhatsApp
//       "bodyParams": ["Rameshbhai", "Dwarka Yatra", "A1, A2", "Bus 1", "12 Jun 2026"]
//     }
//   ]
// }
//
// Response: { results: [ { to, ok, id?, error?, code? } ], sent, failed }
//
// `code` is Meta's numeric error code (132000, 131026, …). The app maps it to
// a cause and a remedy (lib/services/wa_error.dart); without it every failure
// reads as the same opaque English sentence.
// ============================================================

import {
  CONSERVATIVE_STATIC_CHARS,
  sanitize,
  validateRendered,
  violationSummary,
} from "../_shared/wa_rules.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface OutMessage {
  to: string;
  template: string;
  language?: string;
  headerTextParams?: string[];
  headerImageUrl?: string;
  headerDocumentUrl?: string;
  headerDocumentFilename?: string;
  bodyParams?: string[];
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// Strip everything but digits (Graph wants country-code + number, no '+').
const normalizeTo = (raw: string) => (raw ?? "").replace(/[^\d]/g, "");

function buildComponents(m: OutMessage) {
  const components: unknown[] = [];

  if (m.headerTextParams && m.headerTextParams.length > 0) {
    components.push({
      type: "header",
      parameters: m.headerTextParams.map((t) => ({
        type: "text",
        text: String(t),
      })),
    });
  } else if (m.headerImageUrl) {
    components.push({
      type: "header",
      parameters: [{ type: "image", image: { link: m.headerImageUrl } }],
    });
  } else if (m.headerDocumentUrl) {
    components.push({
      type: "header",
      parameters: [
        {
          type: "document",
          document: {
            link: m.headerDocumentUrl,
            filename: m.headerDocumentFilename ?? "document.pdf",
          },
        },
      ],
    });
  }

  if (m.bodyParams && m.bodyParams.length > 0) {
    components.push({
      type: "body",
      parameters: m.bodyParams.map((t) => ({ type: "text", text: String(t) })),
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
  // would otherwise produce "https://graph.facebook.com//<id>/messages" and
  // Meta replies "Unknown path components". Fall back to a known-good version.
  const rawVersion = (Deno.env.get("WHATSAPP_GRAPH_VERSION") ?? "").trim();
  const graphVersion = /^v\d+\.\d+$/.test(rawVersion) ? rawVersion : "v25.0";

  if (!token || !phoneNumberId) {
    return json(
      { error: "WHATSAPP_TOKEN / WHATSAPP_PHONE_NUMBER_ID not configured" },
      500,
    );
  }

  let payload: { messages?: OutMessage[] };
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }

  const messages = payload.messages ?? [];
  if (!Array.isArray(messages) || messages.length === 0) {
    return json({ error: "No messages to send" }, 400);
  }

  const endpoint =
    `https://graph.facebook.com/${graphVersion}/${phoneNumberId}/messages`;

  type SendResult = {
    to: string;
    ok: boolean;
    id?: string;
    error?: string;
    code?: number;
  };

  // Send ONE message to the Graph API and shape the per-recipient result.
  const sendOne = async (m: OutMessage): Promise<SendResult> => {
    const to = normalizeTo(m.to);
    if (!to || !m.template) {
      return { to, ok: false, error: "Missing 'to' or 'template'" };
    }

    // Last line of defence before Meta. The app sanitizes too, but this
    // function is reachable by any signed-in caller, and a parameter carrying
    // a line break costs the WHOLE batch a per-recipient 132000 that nobody
    // could previously explain. Repair what can be repaired; refuse only what
    // genuinely cannot travel.
    const safe: OutMessage = {
      ...m,
      headerTextParams: m.headerTextParams?.map(sanitize),
      bodyParams: m.bodyParams?.map(sanitize),
    };
    const violations = validateRendered(
      [...(safe.headerTextParams ?? []), ...(safe.bodyParams ?? [])],
      CONSERVATIVE_STATIC_CHARS,
    );
    if (violations.length > 0) {
      return {
        to,
        ok: false,
        // Mirrors Meta's own wording so the app's classifier maps it to the
        // same cause it would have reached had Meta refused it.
        error: `(#132000) Rejected before sending: ${
          violationSummary(violations)
        }`,
        code: 132000,
      };
    }

    const graphBody = {
      messaging_product: "whatsapp",
      to,
      type: "template",
      template: {
        name: safe.template,
        language: { code: safe.language ?? "en" },
        components: buildComponents(safe),
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
      if (res.ok) return { to, ok: true, id: data?.messages?.[0]?.id };

      // Meta's shape: { error: { message, code, error_subcode, error_data:
      // { details } } }. `details` is usually the SPECIFIC reason (which
      // parameter, what about it) while `message` is the generic headline, so
      // keep both — the app quotes the text and maps the code.
      const err = data?.error;
      const details = err?.error_data?.details;
      const message = [err?.message, details].filter(Boolean).join(" — ");
      return {
        to,
        ok: false,
        error: message || `HTTP ${res.status}`,
        code: typeof err?.code === "number" ? err.code : undefined,
      };
    } catch (e) {
      return { to, ok: false, error: String(e) };
    }
  };

  // Bounded-concurrency send: a small worker pool fans out CONCURRENCY messages
  // to Meta at once (instead of one strictly after another) while staying under
  // the Cloud API burst limits. Results stay index-aligned with `messages`, so
  // per-recipient reporting is unchanged.
  const CONCURRENCY = 8;
  const results: SendResult[] = new Array(messages.length);
  let next = 0;
  const worker = async () => {
    while (true) {
      const i = next++;
      if (i >= messages.length) return;
      results[i] = await sendOne(messages[i]);
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(CONCURRENCY, messages.length) }, worker),
  );

  const sent = results.filter((r) => r.ok).length;
  return json({ results, sent, failed: results.length - sent });
});
