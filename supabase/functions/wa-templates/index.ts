// ============================================================
// wa-templates  —  Supabase Edge Function
// ------------------------------------------------------------
// Returns the app's approved WhatsApp templates AS META ACTUALLY HAS THEM.
//
// Why this exists: every length check in the app depends on a number only Meta
// knows — how many characters the approved template body spends on its own
// static text. Meta's 1024-character limit applies to the RENDERED body, so the
// budget for a free-text `{{1}}` is 1024 minus that static text. Hard-coding
// the number means it silently rots the moment somebody edits a template in
// Business Manager; measuring it here means the app is always right.
//
// It also surfaces `status`, so a PAUSED or REJECTED template is caught in one
// preflight check instead of failing once per recipient across a 400-passenger
// tour.
//
// SECRETS: none beyond what quick-action already uses.
//
// The WABA id is DERIVED from `WHATSAPP_PHONE_NUMBER_ID` (a phone number
// belongs to exactly one business account) or from the token's own granular
// scopes — see `_shared/waba_id.ts`. Setting `WHATSAPP_WABA_ID` explicitly
// still works and still wins; it is now an override, not a requirement. That
// matters because this deploy already carries the token and phone id for
// sending, and making an operator hunt down a third value in Business Manager
// — for a feature that is allowed to degrade silently — is a poor trade.
//
// The one thing that cannot be derived is SCOPE: reading templates needs a
// `WHATSAPP_TOKEN` carrying `whatsapp_business_management`, where sending only
// needs `whatsapp_business_messaging`. A send-only token resolves no id and
// gets the conservative fallback, which is correct and costs nothing.
//
// If anything is missing this returns 200 with { available: false, reason }.
// That is deliberate: the app must degrade to a conservative fallback rather
// than break sending. NOTHING here is allowed to block a send.
//
// Deploy:  supabase functions deploy wa-templates
//
// Response:
// { available: true,
//   wabaSource: "env" | "phone_number" | "token_scopes",
//   templates: [ { name, language, status, category,
//                  headerFormat, headerVarCount,
//                  bodyStaticChars, bodyVarCount, footerChars } ] }
// ============================================================

import { resolveWabaId, type WabaIdSource } from "../_shared/waba_id.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

interface MetaComponent {
  type?: string;
  format?: string;
  text?: string;
  example?: unknown;
}

interface MetaTemplate {
  name?: string;
  language?: string;
  status?: string;
  category?: string;
  components?: MetaComponent[];
}

/** Every distinct {{n}} placeholder in `text`. */
const PLACEHOLDER = /\{\{\s*\w+\s*\}\}/g;

function varCount(text: string): number {
  return new Set(text.match(PLACEHOLDER) ?? []).size;
}

/**
 * Characters the template spends on ITSELF — the approved body with every
 * placeholder removed — counted as grapheme clusters, the same way the app
 * counts a sender's text. This is the number the whole budget rests on.
 */
function staticChars(text: string): number {
  const bare = text.replace(PLACEHOLDER, "");
  if (typeof Intl !== "undefined" && "Segmenter" in Intl) {
    const seg = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    let n = 0;
    for (const _ of seg.segment(bare)) n++;
    return n;
  }
  return [...bare].length;
}

function normalize(t: MetaTemplate) {
  const components = t.components ?? [];
  const find = (type: string) =>
    components.find((c) => (c.type ?? "").toUpperCase() === type);

  const header = find("HEADER");
  const body = find("BODY");
  const footer = find("FOOTER");
  const bodyText = body?.text ?? "";

  return {
    name: t.name ?? "",
    language: t.language ?? "",
    status: (t.status ?? "").toUpperCase(),
    category: (t.category ?? "").toUpperCase(),
    // NONE when the template has no header at all; otherwise TEXT / IMAGE /
    // DOCUMENT / VIDEO / LOCATION. The app compares this against what it is
    // about to send, which is what 132012 punishes.
    headerFormat: header ? (header.format ?? "TEXT").toUpperCase() : "NONE",
    headerVarCount: varCount(header?.text ?? ""),
    bodyStaticChars: staticChars(bodyText),
    bodyVarCount: varCount(bodyText),
    footerChars: staticChars(footer?.text ?? ""),
  };
}

/**
 * Resolution cached for the life of the isolate.
 *
 * The derivation costs up to two Graph calls, and the answer cannot change
 * without a redeploy (a phone number does not move between businesses). Paying
 * it once per cold start rather than once per preflight keeps the derived path
 * as cheap as the explicit one.
 */
let cachedWaba: { id: string; source: WabaIdSource } | null = null;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const token = Deno.env.get("WHATSAPP_TOKEN");
  const rawVersion = (Deno.env.get("WHATSAPP_GRAPH_VERSION") ?? "").trim();
  const graphVersion = /^v\d+\.\d+$/.test(rawVersion) ? rawVersion : "v25.0";

  // A 200 with available:false, NOT an error. The app treats an unavailable
  // catalog as "use the conservative fallback", and a non-2xx here would make
  // that indistinguishable from a transport failure.
  if (!token) {
    return json({
      available: false,
      reason: "WHATSAPP_TOKEN not configured",
      templates: [],
    });
  }

  const waba = cachedWaba ??= await resolveWabaId({
    token,
    graphVersion,
    explicitId: Deno.env.get("WHATSAPP_WABA_ID"),
    phoneNumberId: Deno.env.get("WHATSAPP_PHONE_NUMBER_ID"),
  });

  if (!waba) {
    return json({
      available: false,
      // Named precisely, because the two causes need different fixes: a
      // send-only token needs its scope widened, whereas several candidate
      // businesses need a human to pick one via WHATSAPP_WABA_ID.
      reason:
        "Could not determine the WhatsApp Business Account. The token may lack " +
        "the whatsapp_business_management scope, or it may span more than one " +
        "business — set WHATSAPP_WABA_ID to choose.",
      templates: [],
    });
  }

  const wabaId = waba.id;
  const templates: ReturnType<typeof normalize>[] = [];
  let url: string | null =
    `https://graph.facebook.com/${graphVersion}/${wabaId}/message_templates` +
    `?fields=name,language,status,category,components&limit=100`;

  try {
    // Paginate, but with a hard stop: a runaway cursor must not hold the
    // function open. Three pages is 300 templates — far more than this app has.
    for (let page = 0; page < 3 && url; page++) {
      const res: Response = await fetch(url, {
        headers: { Authorization: `Bearer ${token}` },
      });
      const data = await res.json();

      if (!res.ok) {
        const err = data?.error;
        // A derived id that Graph then rejects must not be cached as good —
        // otherwise a warm isolate keeps re-sending the same bad id until it
        // is recycled.
        cachedWaba = null;
        return json({
          available: false,
          reason: err?.message ?? `HTTP ${res.status}`,
          code: typeof err?.code === "number" ? err.code : undefined,
          wabaSource: waba.source,
          templates: [],
        });
      }

      for (const t of (data?.data ?? []) as MetaTemplate[]) {
        templates.push(normalize(t));
      }
      url = data?.paging?.next ?? null;
    }
  } catch (e) {
    return json({ available: false, reason: String(e), templates: [] });
  }

  return json({ available: true, wabaSource: waba.source, templates });
});
