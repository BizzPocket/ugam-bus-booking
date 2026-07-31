// ============================================================
// send-push · lib.ts  —  pure, testable helpers
// ------------------------------------------------------------
// Kept separate from index.ts so unit tests can import the logic without
// `Deno.serve` binding a port. index.ts is a thin HTTP wrapper around these.
// ============================================================

export interface AdminPrefs {
  push_enabled: boolean;
  notify_booking_requests: boolean;
}

/// The single source of truth for "do we push a booking-request alert?".
/// Both switches must be ON; a missing admin row never notifies.
export function shouldNotifyBookingRequest(a: AdminPrefs | null | undefined): boolean {
  return !!a && a.push_enabled === true && a.notify_booking_requests === true;
}

/// "Do we push an inbound-WhatsApp-message alert?". A customer message is a
/// direct human reply, so it is gated only on the master `push_enabled` switch —
/// not the booking-requests preference (that toggle is about tour bookings, a
/// different surface). A missing admin row never notifies.
export function shouldNotifyMessage(
  a: { push_enabled?: boolean } | null | undefined,
): boolean {
  return !!a && a.push_enabled === true;
}

export interface WaMessageFcmInput {
  token: string;
  title: string;
  body: string;
  conversationId?: string;
}

/// Build the FCM HTTP v1 `message` for an inbound WhatsApp customer message.
/// `data.type` is "wa_message" so the app's tap handler deep-links to the Inbox
/// (and, when present, the specific conversation). Android pins it to the
/// "messages" channel the app creates on launch — MUST match PushService.
export function buildWaMessageFcm(
  { token, title, body, conversationId }: WaMessageFcmInput,
) {
  return {
    token,
    notification: { title, body },
    data: {
      type: "wa_message",
      ...(conversationId ? { conversation_id: String(conversationId) } : {}),
    },
    android: {
      priority: "HIGH",
      notification: { channel_id: "messages", sound: "default" },
    },
    apns: {
      headers: { "apns-priority": "10" },
      payload: { aps: { sound: "default" } },
    },
  };
}

export interface BookingRequestRow {
  id: string;
  customer_name: string;
  party_size: number;
}

/// 'created' = brand-new request; 'updated' = the customer edited their request;
/// 'cancelled' = the customer self-cancelled a still-pending request;
/// 'cancel_requested' = the customer asked to cancel an ALREADY-CONFIRMED /
/// seat-assigned booking — nothing is freed yet, it awaits the organiser's
/// approve/decline (distinct from 'cancelled', which already happened).
export type BookingEvent = "created" | "updated" | "cancelled" | "cancel_requested";

export interface FcmMessageInput {
  token: string;
  tourTitle: string;
  request: BookingRequestRow;
  event?: BookingEvent;
}

/// Build the FCM HTTP v1 `message` object for one device. The `notification`
/// block is what surfaces in the system tray when the app is backgrounded or
/// killed; `data` carries the deep-link target for the tap handler. Android
/// pins the alert to the "booking_requests" channel the app creates on launch.
/// `event` switches the copy between a new request and a customer edit; the
/// data.type stays "booking_request" either way so the tap handler is unchanged.
export function buildFcmMessage(
  { token, tourTitle, request, event = "created" }: FcmMessageInput,
) {
  const n = Number(request.party_size) || 1;
  const seats = n === 1 ? "1 seat" : `${n} seats`;
  let title: string;
  let body: string;
  if (event === "cancel_requested") {
    title = "Cancellation request";
    body =
      `${request.customer_name} wants to cancel a confirmed seat — your approval needed · ${tourTitle}`;
  } else if (event === "cancelled") {
    title = "Booking cancelled";
    body = `${request.customer_name} cancelled their booking · ${tourTitle}`;
  } else if (event === "updated") {
    title = "Booking request updated";
    body = `${request.customer_name} changed to ${seats} · ${tourTitle}`;
  } else {
    title = "New booking request";
    body = `${request.customer_name} requested ${seats} · ${tourTitle}`;
  }
  return {
    token,
    notification: { title, body },
    data: {
      type: "booking_request",
      event,
      request_id: String(request.id),
    },
    android: {
      priority: "HIGH",
      notification: { channel_id: "booking_requests", sound: "default" },
    },
    apns: {
      headers: { "apns-priority": "10" },
      payload: { aps: { sound: "default" } },
    },
  };
}

// ── FCM HTTP v1 OAuth (service-account JWT → access token) ──────────────

export interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
  token_uri?: string;
}

let cachedToken: { value: string; exp: number } | null = null;

/// Reset the in-isolate token cache (tests only).
export function _resetTokenCache() {
  cachedToken = null;
}

/// Base64url without padding — for both JWT segments and the signature.
export function b64url(input: ArrayBuffer | Uint8Array | string): string {
  let bytes: Uint8Array;
  if (typeof input === "string") bytes = new TextEncoder().encode(input);
  else if (input instanceof Uint8Array) bytes = input;
  else bytes = new Uint8Array(input);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): ArrayBuffer {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);
  return buf.buffer;
}

export async function signJwtRs256(
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  privateKeyPem: string,
): Promise<string> {
  const enc = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(privateKeyPem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(enc),
  );
  return `${enc}.${b64url(sig)}`;
}

/// Mint (and cache) a short-lived OAuth access token for the FCM send scope.
/// The token lives ~1h; we reuse it across invocations in the same warm isolate.
export async function getFcmAccessToken(sa: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.exp - 60 > now) return cachedToken.value;

  const tokenUri = sa.token_uri ?? "https://oauth2.googleapis.com/token";
  const jwt = await signJwtRs256(
    { alg: "RS256", typ: "JWT" },
    {
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: tokenUri,
      iat: now,
      exp: now + 3600,
    },
    sa.private_key,
  );

  const res = await fetch(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  const data = await res.json();
  if (!res.ok) {
    throw new Error(`FCM token exchange failed: ${JSON.stringify(data)}`);
  }
  cachedToken = { value: data.access_token, exp: now + (data.expires_in ?? 3600) };
  return cachedToken.value;
}

/// FCM v1 error statuses that mean "this token is dead, stop sending to it".
///
/// ONLY genuine unregistered / not-found signals prune a token. A malformed
/// PAYLOAD returns INVALID_ARGUMENT (HTTP 400) for EVERY recipient, so treating
/// that as a dead token would wipe out ALL of an admin's device tokens on a
/// single bad send. Never prune on INVALID_ARGUMENT or any other payload error —
/// leave the token in place so a fixed payload reaches it next time.
export function isDeadTokenStatus(httpStatus: number, errStatus?: string): boolean {
  return (
    httpStatus === 404 ||
    errStatus === "UNREGISTERED" ||
    errStatus === "NOT_FOUND" ||
    errStatus === "registration-token-not-registered"
  );
}
