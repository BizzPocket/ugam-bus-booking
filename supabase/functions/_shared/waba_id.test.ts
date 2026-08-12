// Tests for the WABA-id resolver.
//
// The point of the resolver is that an operator who has already configured
// sending does NOT have to go and find a third value in Business Manager. So
// the cases that matter are: the derivations work, an explicit value still
// overrides them, and EVERY failure degrades to null rather than throwing —
// because null means "conservative fallback" and a throw would block a send.
//
// Run:  deno test supabase/functions/_shared/waba_id.test.ts

import {
  assertEquals,
  assertStrictEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { resolveWabaId } from "./waba_id.ts";

const TOKEN = "tok-abc";
const VERSION = "v25.0";
const PHONE = "109876543210987";
const WABA = "123456789012345";

/** A fetch stub driven by a url->response map. Records what was asked. */
function stubFetch(
  routes: Record<string, { status?: number; body: unknown }>,
): { fetch: typeof fetch; calls: string[] } {
  const calls: string[] = [];
  const impl = ((url: string | URL | Request) => {
    const href = typeof url === "string" ? url : url.toString();
    calls.push(href);
    for (const [needle, res] of Object.entries(routes)) {
      if (href.includes(needle)) {
        const status = res.status ?? 200;
        return Promise.resolve(
          new Response(JSON.stringify(res.body), { status }),
        );
      }
    }
    return Promise.resolve(new Response("{}", { status: 404 }));
  }) as unknown as typeof fetch;
  return { fetch: impl, calls };
}

Deno.test("an explicit WHATSAPP_WABA_ID wins and costs no Graph call", async () => {
  const { fetch: f, calls } = stubFetch({});
  const got = await resolveWabaId({
    token: TOKEN,
    graphVersion: VERSION,
    explicitId: WABA,
    phoneNumberId: PHONE,
    fetchImpl: f,
  });

  assertEquals(got, { id: WABA, source: "env" });
  assertEquals(calls.length, 0, "an explicit id must not hit the network");
});

Deno.test("it derives the id from the phone number already configured", async () => {
  const { fetch: f } = stubFetch({
    [`/${PHONE}?fields=whatsapp_business_account`]: {
      body: { whatsapp_business_account: { id: WABA }, id: PHONE },
    },
  });

  const got = await resolveWabaId({
    token: TOKEN,
    graphVersion: VERSION,
    phoneNumberId: PHONE,
    fetchImpl: f,
  });

  assertEquals(got, { id: WABA, source: "phone_number" });
});

Deno.test("it falls back to the token's granular scopes", async () => {
  const { fetch: f } = stubFetch({
    // Phone lookup denied — an older token without the management scope.
    [`/${PHONE}?fields=`]: { status: 403, body: { error: { code: 200 } } },
    "debug_token": {
      body: {
        data: {
          granular_scopes: [
            { scope: "whatsapp_business_messaging", target_ids: ["999"] },
            { scope: "whatsapp_business_management", target_ids: [WABA] },
          ],
        },
      },
    },
  });

  const got = await resolveWabaId({
    token: TOKEN,
    graphVersion: VERSION,
    phoneNumberId: PHONE,
    fetchImpl: f,
  });

  assertEquals(got, { id: WABA, source: "token_scopes" });
});

Deno.test("two candidate WABAs is ambiguous, so it refuses to guess", async () => {
  const { fetch: f } = stubFetch({
    [`/${PHONE}?fields=`]: { status: 403, body: {} },
    "debug_token": {
      body: {
        data: {
          granular_scopes: [
            {
              scope: "whatsapp_business_management",
              target_ids: [WABA, "555555555555555"],
            },
          ],
        },
      },
    },
  });

  assertStrictEquals(
    await resolveWabaId({
      token: TOKEN,
      graphVersion: VERSION,
      phoneNumberId: PHONE,
      fetchImpl: f,
    }),
    null,
    "picking one of two would read the wrong business templates",
  );
});

Deno.test("every lookup failing yields null, never a throw", async () => {
  const { fetch: f } = stubFetch({});
  assertStrictEquals(
    await resolveWabaId({
      token: TOKEN,
      graphVersion: VERSION,
      phoneNumberId: PHONE,
      fetchImpl: f,
    }),
    null,
  );
});

Deno.test("a network error is swallowed, not propagated", async () => {
  const boom = (() => Promise.reject(new Error("dns"))) as unknown as
    typeof fetch;
  assertStrictEquals(
    await resolveWabaId({
      token: TOKEN,
      graphVersion: VERSION,
      phoneNumberId: PHONE,
      fetchImpl: boom,
    }),
    null,
    "a send must never fail because the catalog lookup did",
  );
});

Deno.test("a junk id is rejected rather than sent to Graph", async () => {
  const { fetch: f, calls } = stubFetch({});
  const got = await resolveWabaId({
    token: TOKEN,
    graphVersion: VERSION,
    explicitId: "https://business.facebook.com/wa/manage/  ",
    phoneNumberId: "not-a-number",
    fetchImpl: f,
  });

  assertStrictEquals(got, null);
  assertEquals(
    calls.filter((c) => c.includes("not-a-number")).length,
    0,
    "a non-numeric phone id must not be interpolated into a Graph URL",
  );
});

Deno.test("no token means no lookup at all", async () => {
  const { fetch: f, calls } = stubFetch({});
  assertStrictEquals(
    await resolveWabaId({
      token: "",
      graphVersion: VERSION,
      phoneNumberId: PHONE,
      fetchImpl: f,
    }),
    null,
  );
  assertEquals(calls.length, 0);
});

Deno.test("the phone-number response missing the account degrades cleanly", async () => {
  const { fetch: f } = stubFetch({
    [`/${PHONE}?fields=`]: { body: { id: PHONE } }, // no whatsapp_business_account
    "debug_token": { body: { data: {} } },
  });

  assertStrictEquals(
    await resolveWabaId({
      token: TOKEN,
      graphVersion: VERSION,
      phoneNumberId: PHONE,
      fetchImpl: f,
    }),
    null,
  );
});
