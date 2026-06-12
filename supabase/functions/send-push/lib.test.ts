// Run: deno test supabase/functions/send-push/lib.test.ts
import {
  assert,
  assertEquals,
  assertFalse,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  b64url,
  buildFcmMessage,
  isDeadTokenStatus,
  shouldNotifyBookingRequest,
  signJwtRs256,
} from "./lib.ts";

Deno.test("shouldNotifyBookingRequest — both switches gate delivery", () => {
  assertFalse(shouldNotifyBookingRequest(null));
  assertFalse(shouldNotifyBookingRequest(undefined));
  assert(
    shouldNotifyBookingRequest({
      push_enabled: true,
      notify_booking_requests: true,
    }),
  );
  assertFalse(
    shouldNotifyBookingRequest({
      push_enabled: false,
      notify_booking_requests: true,
    }),
  );
  assertFalse(
    shouldNotifyBookingRequest({
      push_enabled: true,
      notify_booking_requests: false,
    }),
  );
});

Deno.test("buildFcmMessage — singular/plural seats + deep-link data", () => {
  const one = buildFcmMessage({
    token: "tok1",
    tourTitle: "Dwarka Yatra",
    request: { id: "r1", customer_name: "Ramesh", party_size: 1 },
  });
  assertEquals(one.token, "tok1");
  assertEquals(one.notification.body, "Ramesh requested 1 seat · Dwarka Yatra");
  assertEquals(one.data.type, "booking_request");
  assertEquals(one.data.request_id, "r1");
  assertEquals(one.android.notification.channel_id, "booking_requests");

  const many = buildFcmMessage({
    token: "tok2",
    tourTitle: "Char Dham",
    request: { id: "r2", customer_name: "Sita", party_size: 4 },
  });
  assertEquals(many.notification.body, "Sita requested 4 seats · Char Dham");
  assertEquals(many.data.event, "created");
});

Deno.test("buildFcmMessage — customer edit varies title/body, same deep-link", () => {
  const edit = buildFcmMessage({
    token: "tok3",
    tourTitle: "Dwarka Yatra",
    request: { id: "r3", customer_name: "Ramesh", party_size: 3 },
    event: "updated",
  });
  assertEquals(edit.notification.title, "Booking request updated");
  assertEquals(edit.notification.body, "Ramesh changed to 3 seats · Dwarka Yatra");
  // Tap target unchanged so the app's handler needs no edit.
  assertEquals(edit.data.type, "booking_request");
  assertEquals(edit.data.event, "updated");
});

Deno.test("isDeadTokenStatus — only terminal token errors prune", () => {
  assert(isDeadTokenStatus(404));
  assert(isDeadTokenStatus(400, "UNREGISTERED"));
  assert(isDeadTokenStatus(400, "NOT_FOUND"));
  assert(isDeadTokenStatus(400, "INVALID_ARGUMENT"));
  assertFalse(isDeadTokenStatus(503, "UNAVAILABLE"));
  assertFalse(isDeadTokenStatus(500, "INTERNAL"));
  assertFalse(isDeadTokenStatus(200));
});

Deno.test("signJwtRs256 — produces a verifiable RS256 JWT", async () => {
  // Generate a throwaway RSA keypair and export the private key as PKCS8 PEM.
  const kp = await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", kp.privateKey),
  );
  let bin = "";
  for (const b of pkcs8) bin += String.fromCharCode(b);
  const pem = `-----BEGIN PRIVATE KEY-----\n${
    btoa(bin).replace(/(.{64})/g, "$1\n")
  }\n-----END PRIVATE KEY-----`;

  const jwt = await signJwtRs256(
    { alg: "RS256", typ: "JWT" },
    { iss: "test@x.iam", iat: 1, exp: 2 },
    pem,
  );
  const parts = jwt.split(".");
  assertEquals(parts.length, 3);

  // The signature must verify against the matching public key.
  const enc = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const sigBin = atob(parts[2].replace(/-/g, "+").replace(/_/g, "/"));
  const sig = new Uint8Array(sigBin.length);
  for (let i = 0; i < sigBin.length; i++) sig[i] = sigBin.charCodeAt(i);
  const ok = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    kp.publicKey,
    sig,
    enc,
  );
  assert(ok);
});

Deno.test("b64url — url-safe, unpadded", () => {
  // 0xfb 0xff -> standard '+/8=' ; url-safe drops padding and swaps chars.
  assertEquals(b64url(new Uint8Array([0xfb, 0xff])), "-_8");
});
