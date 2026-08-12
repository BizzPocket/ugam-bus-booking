// Server-side mirror of test/services/wa_template_params_test.dart.
//
// The SAME vectors run on both sides. If a rule ever drifts between the Dart
// composer and the Edge Functions, one of these two files fails — which is the
// entire point of keeping two implementations honest.
//
// Run:  deno test supabase/functions/_shared/wa_rules.test.ts

import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  characterCount,
  CONSERVATIVE_STATIC_CHARS,
  MAX_BODY_CHARS,
  renderedLength,
  sanitize,
  validateAll,
  validateOne,
  validateRendered,
  WHOLE,
} from "./wa_rules.ts";

// The REAL announcement the agent could not send (28 Jul 2026): an ordinary
// two-paragraph Gujarati message, well under 1024 characters, refused solely
// for the blank line between its paragraphs.
const realFailingMessage =
  "આવતી કાલે સવારે બાપા ના દર્શન કરી અને નાસ્તા પાણી કરી ને 7 વાગ્યા પહેલા બસ " +
  "પર પહોંચી જવું.. કોઈએ ખોટો સમય ખોટી કરવો નઈ.." +
  "\n\n" +
  "જય વાલમ બસ ગામ ના પાદર માં ખાલી થશે અન સમાધિ દર્શન કરી ને બપોરે પ્રસાદ લઈ ન " +
  "વહેલાસર સમય ખોટી કર્યા વગર ગામ ના પાદર પર પહોંચી જવું..";

const issues = (vs: { issue: string }[]) => vs.map((v) => v.issue);

Deno.test("the real failing announcement is rejected for its paragraph break", () => {
  assertEquals(issues(validateOne(realFailingMessage)), ["newline"]);
});

Deno.test("auto-fix makes it Meta-legal without losing a word", () => {
  const fixed = sanitize(realFailingMessage);
  assertEquals(validateOne(fixed), []);
  assertEquals(fixed.includes("ખોટી કરવો નઈ.. જય વાલમ બસ"), true);
});

Deno.test("blank / whitespace-only is rejected and shortcuts the rest", () => {
  assertEquals(issues(validateOne("   ")), ["empty"]);
  assertEquals(issues(validateOne("\n\n")), ["empty"]);
});

Deno.test("tabs are rejected", () => {
  assertEquals(issues(validateOne("bus\tleaves")), ["tab"]);
});

Deno.test("exactly 4 spaces is legal, 5 is not", () => {
  assertEquals(validateOne("a" + " ".repeat(4) + "b"), []);
  assertEquals(issues(validateOne("a" + " ".repeat(5) + "b")), [
    "consecutiveSpaces",
  ]);
});

Deno.test("several rules broken at once are all reported", () => {
  assertEquals(issues(validateOne("a\nb\tc" + " ".repeat(6) + "d")), [
    "newline",
    "tab",
    "consecutiveSpaces",
  ]);
});

Deno.test("violations carry the index of the offending parameter", () => {
  assertEquals(validateAll(["Rameshbhai", "Dwarka\nYatra", "Bus 1"]), [
    { issue: "newline", paramIndex: 1, count: 1 },
  ]);
});

Deno.test("an emoji is one character, not two UTF-16 code units", () => {
  assertEquals("🙏".length, 2);
  assertEquals(characterCount("🙏"), 1);
});

Deno.test("a ZWJ family emoji is one character", () => {
  assertEquals(characterCount("👨‍👩‍👧‍👦"), 1);
});

Deno.test("a Gujarati consonant carrying a matra is one character", () => {
  assertEquals(characterCount("કા"), 1);
});

Deno.test("a legal parameter still busts the limit once the template is added", () => {
  const param = "ક".repeat(900);
  assertEquals(validateOne(param), [], "the parameter alone looks fine");

  const vs = validateRendered([param], 200);
  assertEquals(issues(vs), ["renderedTooLong"]);
  assertEquals(vs[0].count, 1100);
  assertEquals(vs[0].paramIndex, WHOLE);
});

Deno.test("the same text fits when the template body is short", () => {
  assertEquals(validateRendered(["ક".repeat(900)], 100), []);
});

Deno.test("exactly 1024 rendered is legal, 1025 is not", () => {
  assertEquals(validateRendered(["ક".repeat(24)], 1000), []);
  assertEquals(issues(validateRendered(["ક".repeat(25)], 1000)), [
    "renderedTooLong",
  ]);
});

Deno.test("seven seat_allotment values are measured together", () => {
  const params = Array(7).fill("ક".repeat(150));
  assertEquals(params.every((p) => validateOne(p).length === 0), true);
  assertEquals(issues(validateRendered(params, 0)), ["renderedTooLong"]);
});

Deno.test("per-parameter faults are still reported alongside the total", () => {
  const vs = validateRendered(["fine", "has\nbreak"], 0);
  assertEquals(issues(vs), ["newline"]);
  assertEquals(vs[0].paramIndex, 1);
});

Deno.test("renderedLength adds the static template text", () => {
  assertEquals(renderedLength(["abc"], 100), 103);
  assertEquals(renderedLength([], 0), 0);
});

Deno.test("the shared constants match the Dart side", () => {
  assertEquals(MAX_BODY_CHARS, 1024);
  assertEquals(CONSERVATIVE_STATIC_CHARS, 224);
});

Deno.test("sanitize is idempotent", () => {
  const once = sanitize("a\n\nb\tc" + " ".repeat(7) + "d");
  assertEquals(sanitize(once), once);
  assertEquals(validateOne(once), []);
});
