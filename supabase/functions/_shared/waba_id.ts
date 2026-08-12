// ============================================================
// waba_id  —  work out WHICH WhatsApp Business Account to read
// ------------------------------------------------------------
// WHY THIS EXISTS
// Listing approved templates is the only call in this project that needs a
// WABA id. Every other WhatsApp call addresses a PHONE NUMBER, so the deploy
// already carries `WHATSAPP_TOKEN` and `WHATSAPP_PHONE_NUMBER_ID` and nothing
// else. Asking the operator to go and find a third value in Business Manager —
// for a feature that is allowed to degrade silently — is a poor trade.
//
// The id is derivable from what is already configured, so it is derived:
//
//   1. `WHATSAPP_WABA_ID` if set. An explicit value always wins; a multi-WABA
//      setup, or a token whose scopes span several, needs a human to pick.
//   2. The phone number node: a phone number belongs to exactly one WABA, and
//      `?fields=whatsapp_business_account` returns it.
//   3. The token itself: `debug_token` reports `granular_scopes`, and the
//      `whatsapp_business_management` entry lists the WABAs the token may
//      manage. Used only when there is exactly ONE — more than one is
//      ambiguous, and guessing would read the wrong business's templates.
//
// EVERY path is allowed to fail. Returning null means "no catalog", which the
// caller turns into the conservative fallback. Nothing here may block a send.
// ============================================================

export type WabaIdSource = "env" | "phone_number" | "token_scopes";

export interface WabaResolution {
  id: string;
  source: WabaIdSource;
}

export interface ResolveWabaIdOptions {
  token: string;
  graphVersion: string;
  /** `WHATSAPP_WABA_ID`, when the operator has set one. */
  explicitId?: string | null;
  /** `WHATSAPP_PHONE_NUMBER_ID` — already required for sending. */
  phoneNumberId?: string | null;
  /** Injectable for tests. Defaults to global fetch. */
  fetchImpl?: typeof fetch;
}

/** A Graph id: digits only. Guards against a pasted URL or a stray quote. */
const GRAPH_ID = /^\d{5,}$/;

function cleanId(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return GRAPH_ID.test(trimmed) ? trimmed : null;
}

/** GET json, never throwing. Null on any transport or non-2xx failure. */
async function getJson(
  url: string,
  token: string,
  fetchImpl: typeof fetch,
): Promise<Record<string, unknown> | null> {
  try {
    const res = await fetchImpl(url, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (!res.ok) return null;
    const body = await res.json();
    return body && typeof body === "object"
      ? body as Record<string, unknown>
      : null;
  } catch {
    return null;
  }
}

/**
 * The WABA id to read templates from, or null when it cannot be established.
 *
 * Never throws. Costs at most two extra Graph calls, and only on a cold
 * isolate where `WHATSAPP_WABA_ID` is unset — the caller caches the result.
 */
export async function resolveWabaId(
  opts: ResolveWabaIdOptions,
): Promise<WabaResolution | null> {
  const {
    token,
    graphVersion,
    explicitId,
    phoneNumberId,
    fetchImpl = fetch,
  } = opts;

  if (!token) return null;

  // ── 1. Explicit wins ────────────────────────────────────────
  const explicit = cleanId(explicitId);
  if (explicit) return { id: explicit, source: "env" };

  const base = `https://graph.facebook.com/${graphVersion}`;

  // ── 2. Ask the phone number which account owns it ───────────
  const phone = cleanId(phoneNumberId);
  if (phone) {
    const body = await getJson(
      `${base}/${phone}?fields=whatsapp_business_account`,
      token,
      fetchImpl,
    );
    const account = body?.whatsapp_business_account;
    const fromPhone = cleanId(
      account && typeof account === "object"
        ? (account as Record<string, unknown>).id
        : null,
    );
    if (fromPhone) return { id: fromPhone, source: "phone_number" };
  }

  // ── 3. Ask the token what it is allowed to manage ───────────
  const debug = await getJson(
    `${base}/debug_token?input_token=${encodeURIComponent(token)}`,
    token,
    fetchImpl,
  );
  const data = debug?.data;
  const scopes = data && typeof data === "object"
    ? (data as Record<string, unknown>).granular_scopes
    : null;

  if (Array.isArray(scopes)) {
    for (const entry of scopes) {
      if (!entry || typeof entry !== "object") continue;
      const row = entry as Record<string, unknown>;
      if (row.scope !== "whatsapp_business_management") continue;
      const targets = Array.isArray(row.target_ids) ? row.target_ids : [];
      const ids = targets.map(cleanId).filter((v): v is string => v !== null);
      // Exactly one, or not at all. Picking the first of several would read
      // some other business's templates and silently mis-budget every send.
      if (ids.length === 1) return { id: ids[0], source: "token_scopes" };
      break;
    }
  }

  return null;
}
