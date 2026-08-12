# WhatsApp messaging that explains itself

**Date:** 2026-08-10
**Branch:** `feat/money-collection-settlement`
**Status:** approved, implementing

## The problem

Three WhatsApp flows carry the tour lifecycle:

| Stage | Template | Payload |
|---|---|---|
| Pre-lock greeting | `seat_allocation` | `{{1}}` name, `{{2}}` tour title |
| After-lock details | `seat_allotment` | IMAGE header (highlighted seat chart) + 7 body vars |
| Per-bus announcement | `bus_msg` | `{{1}}` free text typed by agent or handler |

All three refuse messages the agent believes are fine, accept messages Meta then
refuses, and report every failure as the same opaque English sentence appended to
a Gujarati snackbar. Six concrete defects, verified against Meta's current docs:

**D1 — the length budget measures the wrong thing.** Meta's 1024-character limit
applies to the *rendered* body: approved static text plus substituted values.
`WaTemplateParams.validateOne` checks a single parameter against 1024 in
isolation. For `bus_msg` the static greeting and closing blessing are invisible
to the validator, so text that passes the composer still returns `132005`.
`seat_allotment` has seven parameters and no aggregate check at all.

**D2 — `132000` is overloaded and only one meaning is handled.** Meta returns it
both for "Param text cannot have new-line/tab characters or more than 4
consecutive spaces" *and* for a parameter-count mismatch between the request and
the approved template. The two need opposite fixes — edit the text, versus
reconcile the app's variable contract with Meta — and today they are
indistinguishable to the reader.

**D3 — no error-code mapping exists.** `firstWaError` appends Meta's raw English
to the snackbar. `132001` (not approved in `gu`), `132015` (paused for quality),
`131053` (media rejected), `133010`, `131026` all read identically: unexplained
and unactionable.

**D4 — emoji and formatting characters are half-handled.** Counting `runes`
fixed the UTF-16 double-count that once rejected a legal 600-character message,
but a ZWJ sequence such as a family emoji is still seven runes. Separately,
nothing guards `*`, `_`, `~` and `` ` `` in a parameter, so a typed message can
arrive bold, italic or struck-through by accident.

**D5 — seat-flow parameters are never validated.** `_buildAllocationMessage`
passes `tour.title`, `bus.customerLabel`, `boardingPoint` and `handlerContact`
straight into `bodyParams`; `_orDash` only trims. A boarding point stored with a
line break in it fails *that one passenger* with `132000` while the rest of the
bus succeeds — a strong candidate for the standing "some passengers don't get
the msg" report.

**D6 — the handler path is unguarded on both sides.**
`sendBusMessageAsHandler` forwards `message` verbatim, and `bus-message`
performs no sanitizing server-side, unlike the admin path which sanitizes in
`sendBusMessage`.

Also corrected in passing: the `seatAllocationTemplate` docstring in
`whatsapp_cloud_config.dart` contradicts itself, claiming "5 BODY vars" directly
above an enumeration of `{{1}}`–`{{7}}`.

## Decisions taken

| Question | Decision |
|---|---|
| How does the app learn what the templates contain? | Fetch live from Meta's `message_templates` endpoint |
| What does a refusal look like? | Richer inline dialog with cause + resolution and Retry failed — not a new screen |
| Document headers | Out of scope; bus messages never carry a document |
| `*` `_` `~` `` ` `` | Warn with a live "arrives as" preview; sender decides |
| Where do the rules live? | Client *and* server, from one shared rule set |

## Architecture

### 1 · Template catalog

New Edge Function `wa-templates` calls
`GET /{WABA_ID}/message_templates?fields=name,language,status,category,components`
and returns one normalized row per template:

```
{ name, language, status, category,
  headerFormat,        // NONE | TEXT | IMAGE | DOCUMENT | VIDEO | LOCATION
  headerVarCount,
  bodyStaticChars,     // approved body with every {{n}} removed
  bodyVarCount }
```

`bodyStaticChars` is the quantity D1 needs: the free-text budget is
`1024 - bodyStaticChars`.

Dart consumes this through `WaTemplateCatalog`, cached via the existing
`cached_remote_document.dart` ETag mechanism with a 6-hour TTL.

**Fail-soft is mandatory.** This requires only a token carrying
`whatsapp_business_management` scope. The WABA id is NOT a new secret: it is
derived server-side from `WHATSAPP_PHONE_NUMBER_ID` (a phone number belongs to
exactly one business account), falling back to the token's own granular scopes,
and `WHATSAPP_WABA_ID` remains available as an override for a multi-business
token. See `supabase/functions/_shared/waba_id.ts`. If the scope is absent the
fetch 403s, the catalog falls back to conservative constants
(`1024 - 224` headroom), and every flow keeps working. No send path may block on
catalog availability.

### 2 · Rule engine — one rule set, two languages

`lib/services/wa_template_params.dart` and a new
`supabase/functions/_shared/wa_rules.ts` implement identical rules, pinned
together by identical test vectors.

Addition to `WaParamIssue`:

- `renderedTooLong` — `bodyStaticChars + Σ(param lengths) > 1024` (D1)

**Formatting is deliberately NOT a `WaParamIssue`.** The design first placed it
there; that was wrong. Meta accepts `*`, `_`, `~` and `` ` `` without
complaint, so a message carrying them is perfectly sendable and must never be
blocked — putting it in the refusal enum would have made a legal message
un-sendable. It lives instead in `lib/services/wa_formatting.dart` as an
advisory: `parse()` for the preview, `marksIn()` for detection, `toPlain()` for
the sender who did not mean it. Only *paired* marks count, because only paired
marks format.

Changes to existing behaviour:

- Counting moves from `runes.length` to grapheme clusters —
  `value.characters.length` in Dart, `Intl.Segmenter` in TypeScript — so a ZWJ
  emoji costs 1. `characters` becomes an explicit pubspec dependency.
- `sanitize()` keeps its present contract (newlines, tabs and 5+ space runs
  collapse to one space; length is never truncated).
- A new `plainText()` neutralizes paired formatting marks. It is **not** part of
  `sanitize()` — it runs only when the sender taps "Make it plain text", because
  deliberate emphasis is legitimate.
- `sanitize()` is applied to **every** parameter including the seat-flow ones
  (D5), in `_buildAllocationMessage` and both `seat_allocation` senders.

Only paired marks count as formatting. A lone asterisk in `10*20` never renders
as bold and must not be flagged.

### 3 · Error mapping

`quick-action` and `bus-message` currently surface only `data.error.message`.
Both change to return `{ code, subcode, message }`, and `WaRecipientResult`
gains `code`.

New `lib/utils/wa_error.dart` — `WaError.explain(code, message)` returning a
localized `(cause, resolution)` pair in en/gu/hi:

| Code | Cause | Resolution |
|---|---|---|
| 132000 *newline variant* | Line break or tab in the message | Tap Fix automatically |
| 132000 *count variant* | Template changed in Meta | App and template disagree — needs a developer |
| 132001 | Template not approved in Gujarati | Check status in Meta Manager |
| 132005 | Too long once the greeting is added | Shorten by N characters |
| 132007 | Content violates WhatsApp policy | Template needs rewording |
| 132012 | Parameter format mismatch | Header or variable shape differs from the approved template |
| 132015 | Paused for low quality | Edit and resubmit the template |
| 132016 | Permanently disabled | A new template must be created |
| 131008 / 131009 | Malformed request | Developer-side defect |
| 131026 | Not a WhatsApp number | Call this passenger |
| 131047 | Outside the 24-hour window | Send as a template instead |
| 131053 | Media rejected | Chart was N MB; the limit is 5 MB |
| 133010 | Sender number not registered | Setup problem, not this message |

The 132000 split keys off the message text (`new-line` versus
`number of parameters`). Unmapped codes still display Meta's raw text, so no
failure becomes *less* informative than it is today.

### 4 · Composer and result dialog

`BusMessageComposerField` gains:

- a live **"arrives as"** preview with WhatsApp formatting actually rendered,
- a remaining-character count driven by the real budget from the catalog,
- **Make it plain text** alongside the existing **Fix automatically**.

The result dialog stays inline (per the decision above) but groups recipients by
cause, shows each cause's resolution, and offers **Retry failed** — which
re-sends only the failed recipients via the `onlyPassengerIds` parameter
`sendSeatAllocations` already accepts.

**Preflight:** before a batch, consult the catalog. A template that is paused,
disabled, or absent in `gu` produces one clear message *before* two hundred
sends fail one at a time.

### 5 · Media validation

Scoped to the seat-chart image, the only media actually sent. Before upload in
`_buildAllocationMessage`: `image/png` or `image/jpeg`, and ≤ 5 MB. An
over-size chart reports its actual size rather than surfacing a bare `131053`.
Meta's document limits are recorded as constants for correctness with no UI —
documents are out of scope, and the existing unused `headerDocumentUrl` path is
left untouched rather than removed.

### 6 · Testing

- Shared vectors executed against both the Dart and TypeScript rule sets, so
  they cannot drift.
- Table test over every mapped error code.
- Widget test for the composer preview and both fix actions.
- Regression test for D5: a boarding point containing a line break must not
  reach `bodyParams` unsanitized.
- The existing `wa_template_params_test.dart` cases must continue to pass
  unchanged, including the real 28 Jul 2026 announcement.

## Assumptions and risks

**Meta does not document how it counts characters.** Grapheme clusters are the
best available reading and strictly better than the current rune count, but the
server remains ground truth. This is why §3 matters more than §2: the mapping
makes any residual mismatch explainable.

**The budget is only exact once the catalog fetch works.** Until the token's
`whatsapp_business_management` scope is confirmed, the fallback headroom
applies — correct, but slightly stricter than necessary. No secret needs
setting; the account id resolves itself.

**Deployment order.** The Dart changes are safe to ship before the Edge
Functions redeploy; error codes simply stay unmapped until the server returns
them. `wa-templates` may be deployed last.

## Out of scope

- Document or image attachments on bus announcements.
- Persisting send outcomes to the database for later audit.
- Removing the unused `headerDocumentUrl` / `headerDocumentFilename` path.
