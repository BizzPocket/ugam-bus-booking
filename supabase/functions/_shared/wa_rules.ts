// ============================================================
// wa_rules.ts  —  shared WhatsApp template parameter rules
// ------------------------------------------------------------
// The server-side mirror of lib/services/wa_template_params.dart. Imported by
// BOTH quick-action and bus-message so that no send path can put a parameter
// on the wire that Meta will refuse — regardless of which client built it.
//
// Why this exists rather than trusting the app: the HANDLER announcement path
// (bus-message) is called by the handler app, which has no Supabase session
// and, until now, no validation on either side. A handler typing a two-
// paragraph message produced a 132000 for every passenger on the bus, with
// nothing anywhere explaining why.
//
// The rules, from Meta's Cloud API:
//   * a body parameter may not contain a new-line or a tab,
//   * it may not contain more than four consecutive spaces,
//   * it may not be empty,
//   * the RENDERED body — approved template text plus every substituted
//     value — may not exceed 1024 characters.
//
// Keep this file in lockstep with wa_template_params.dart. The vectors in
// wa_rules.test.ts are the same ones in test/services/wa_template_params_test.dart.
// ============================================================

/** Max characters in a rendered template body. */
export const MAX_BODY_CHARS = 1024;

/** Meta allows up to four consecutive spaces; the fifth is a violation. */
export const MAX_CONSECUTIVE_SPACES = 4;

/**
 * Static-text allowance assumed when the caller does not know the approved
 * template's own length. Mirrors WaTemplateParams.conservativeStaticChars.
 */
export const CONSERVATIVE_STATIC_CHARS = 224;

export type WaParamIssue =
  | "empty"
  | "newline"
  | "tab"
  | "consecutiveSpaces"
  | "tooLong"
  | "renderedTooLong";

export interface WaParamViolation {
  issue: WaParamIssue;
  /** 0-based index within bodyParams, or -1 when the whole message is at fault. */
  paramIndex: number;
  /** Offending-run count, or the measured length for the two length rules. */
  count: number;
}

/** paramIndex for a violation that belongs to the message, not a parameter. */
export const WHOLE = -1;

const NEWLINE = /[\r\n]+/g;
const TAB = /\t+/g;
// Five or more spaces — i.e. MORE than the four Meta permits.
const TOO_MANY_SPACES = / {5,}/g;

/**
 * How many characters `value` is, counted as grapheme clusters — the way the
 * sender sees them. `String.length` is UTF-16 code units, so an emoji counts
 * twice and a ZWJ family emoji counts eleven times; both over-count a legal
 * message into a false refusal.
 *
 * Mirrors WaTemplateParams.characterCount, which uses Dart's `characters`.
 */
export function characterCount(value: string): number {
  // Deno ships Intl.Segmenter; the fallback keeps this module usable if a
  // future runtime does not, at the cost of the old emoji over-count.
  if (typeof Intl !== "undefined" && "Segmenter" in Intl) {
    const seg = new Intl.Segmenter(undefined, { granularity: "grapheme" });
    let n = 0;
    for (const _ of seg.segment(value)) n++;
    return n;
  }
  return [...value].length;
}

/** Count of non-overlapping matches, without mutating the shared regex state. */
function countMatches(value: string, re: RegExp): number {
  return (value.match(new RegExp(re.source, "g")) ?? []).length;
}

/**
 * Every rule `value` breaks as the single parameter at `paramIndex`. Empty
 * array = Meta will accept it. Order is stable: emptiness first (it makes the
 * rest moot), then newline, tab, spaces, length.
 */
export function validateOne(value: string, paramIndex = 0): WaParamViolation[] {
  const out: WaParamViolation[] = [];

  if (value.trim().length === 0) {
    return [{ issue: "empty", paramIndex, count: 0 }];
  }

  const newlines = countMatches(value, NEWLINE);
  if (newlines > 0) out.push({ issue: "newline", paramIndex, count: newlines });

  const tabs = countMatches(value, TAB);
  if (tabs > 0) out.push({ issue: "tab", paramIndex, count: tabs });

  const spaceRuns = countMatches(value, TOO_MANY_SPACES);
  if (spaceRuns > 0) {
    out.push({ issue: "consecutiveSpaces", paramIndex, count: spaceRuns });
  }

  const chars = characterCount(value);
  if (chars > MAX_BODY_CHARS) {
    out.push({ issue: "tooLong", paramIndex, count: chars });
  }

  return out;
}

/** Every rule broken across a whole bodyParams list, in parameter order. */
export function validateAll(params: string[]): WaParamViolation[] {
  return params.flatMap((p, i) => validateOne(p, i));
}

/** Length of the body Meta will assemble: template text plus every value. */
export function renderedLength(
  params: string[],
  staticBodyChars: number,
): number {
  return params.reduce((sum, p) => sum + characterCount(p), staticBodyChars);
}

/**
 * Every rule broken by a whole send — each parameter's own rules, plus the
 * rendered-body limit that no single parameter can reveal. This is the check
 * that catches the message which passes locally and then returns
 * "132005 Translated text is too long" from Meta.
 */
export function validateRendered(
  params: string[],
  staticBodyChars: number,
): WaParamViolation[] {
  const out = validateAll(params);
  const rendered = renderedLength(params, staticBodyChars);
  if (rendered > MAX_BODY_CHARS) {
    out.push({ issue: "renderedTooLong", paramIndex: WHOLE, count: rendered });
  }
  return out;
}

/**
 * Rewrites `value` into the nearest Meta-legal equivalent: every run of
 * new-lines and every tab collapses to ONE space, runs of more than four
 * spaces collapse to one, and the result is trimmed.
 *
 * Length is deliberately NOT truncated — silently cutting the tail off an
 * agent's announcement is worse than telling them to shorten it.
 */
export function sanitize(value: string): string {
  return value
    .replace(NEWLINE, " ")
    .replace(TAB, " ")
    .replace(TOO_MANY_SPACES, " ")
    .trim();
}

/**
 * A one-line reason for a refusal, in the same plain English the Edge
 * Functions already use. The APP maps issues to localized sentences; this is
 * the fallback for a caller that reaches the server without doing so.
 */
export function violationSummary(violations: WaParamViolation[]): string {
  return violations
    .map((v) => {
      switch (v.issue) {
        case "empty":
          return "the message is empty";
        case "newline":
          return `it contains ${v.count} line break(s)`;
        case "tab":
          return "it contains a tab character";
        case "consecutiveSpaces":
          return "it contains more than 4 consecutive spaces";
        case "tooLong":
          return `one value is ${v.count} characters (max ${MAX_BODY_CHARS})`;
        case "renderedTooLong":
          return `the whole message is ${v.count} characters (max ${MAX_BODY_CHARS})`;
      }
    })
    .join("; ");
}
