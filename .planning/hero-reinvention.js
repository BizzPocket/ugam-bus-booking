export const meta = {
  name: 'hero-reinvention',
  description: 'Bold LAYOUT reinvention of the two flagship screens (Dashboard, Requests) — gold-on-black DNA, logic preserved',
  phases: [{ title: 'Reinvent', detail: 'one agent per flagship screen — dramatic layout, not a reskin' }],
}

const ROOT = '/Users/zeelshiyani/WorkSpace/occubusbooking'

const DNA = `
DESIGN DNA — "BOLD GOLD-ON-BLACK" (just updated; the accent is GOLD, not lime):
- True-black ground (c.bg #0A0A0A), pure-white ink (c.ink), champagne GOLD accent (c.accent).
- Type is HEAVY + TIGHT now: UgamText.display / titleXl / titleL are w800 with tight tracking;
  UgamText.numXl / numLg are heavy tabular hero numerals. Use BIG type for impact.
- Shapes are SHARP (card radius 16, stat/row 12). Cards read crisp, not soft.
- ACCENT-RATIONING LAW: at most ONE solid-gold (c.accent FILL) focal element per screen — usually the
  bottom sticky CTA or the single most important hero/action. Everything else "primary-ish" is TONAL
  (UgamButton.tonal / accentFill + accent ink + hairline border). Gold is precious — ration it hard.
`

const GOAL = `
THIS IS A LAYOUT REINVENTION, NOT A RESKIN. Restructure the screen's COMPOSITION for a bold, confident,
"transit-board / control-cockpit" feel:
- Oversized hero moment up top (the single most important number or status, in huge numXl/display type).
- Strong SECTION structure: uppercase gold eyebrows (UgamText.micro / UgamAppBar eyebrow) over each block.
- Denser, more deliberate information hierarchy; use asymmetry and scale contrast (huge numbers next to
  small labels). Avoid the flat "stack of equal cards" look.
- Make the primary action unmissable; demote everything else.
- It should look NOTICEABLY different and more striking than before — a user should feel "this was redesigned".
`

const RULES = `
ABSOLUTE RULES:
1. PRESERVE LOGIC. Do NOT change controllers, GetX bindings, callbacks, navigation targets, data
   derivation, or business rules. You are restructuring the PRESENTATION widget tree only — every data
   source and onTap must still call the same thing. Same features remain reachable.
2. Reuse Ugam components (UgamCard/.media + tone, UgamButton kinds, UgamCTA, UgamStatTile, UgamRequestRow,
   UgamReqChip, UgamSelectorPills, UgamIconButton, UgamEmpty, UgamAppBar eyebrow). You MAY add new PRIVATE
   layout widgets within this one file for the new composition. Do NOT edit other files or shared components.
3. Tokens only — UgamSpacing/UgamRadius/UgamColors.of(context)/UgamText. No magic numbers, raw hex, or
   inline TextStyle (except a deliberate hero-size copyWith(fontSize:) on a UgamText role IF no role is big
   enough — keep such cases to the ONE hero number).
4. Localization: keep tr('ns.key'); NEW strings → return in newTranslationKeys (en/gu/hi). Do NOT edit JSON.
5. VERIFY: run \`flutter analyze <your file>\` until "No issues found!". Report honestly.
`

const SCREENS = [
  {
    name: 'dashboard',
    file: 'lib/screens/dashboard_screen.dart',
    thesis: `Reinvent the admin home into a CONTROL BOARD. Ideas (adapt freely, keep logic):
      - A bold top band: greeting + date, then the week-revenue as a HUGE numXl/display hero number with a
        small "THIS WEEK" gold eyebrow and the seats-sold subline — make it the visual anchor.
      - Quick actions (Create / Requests / Assign) as bold, confident tiles or a strong action strip — ONE
        gold-filled primary (Create), the rest tonal. Reuse the existing shell.switchTab / nav callbacks.
      - Stats (active / today / waitlist) as a tight row of big tabular numerals with tiny labels
        (UgamStatTile or a denser custom strip) — scale contrast.
      - "Needs attention" + "Recent requests" as strong eyebrow'd sections; keep UgamRequestRow for recents.
      Keep the existing data helpers (_thisWeekRevenue, _needsAttention, _recentRequests, etc.) and the
      already-fixed quick-action tab indices. Make it feel like a cockpit, not a list.`,
  },
  {
    name: 'requests',
    file: 'lib/screens/requests_screen.dart',
    thesis: `Reinvent the Requests tab into a bold TRIAGE BOARD. Ideas (adapt freely, keep logic):
      - A strong header zone: big screen title + the active count as a heavy numeral; keep search/add/menu.
      - Promote the capacity banner into a bolder hero status bar (demand vs capacity) with big numbers and
        the fill bar — it's the agent's key signal.
      - Filter pills + sort stay (UgamTabPills / UgamSelectorPills), but bolder.
      - The passenger cards: sharpen + strengthen hierarchy (bigger name, clearer single primary action —
        "Confirm & seat" is already the primary; keep it), denser meta. Keep ALL existing card actions and
        callbacks (_confirm, _confirmAndSeat, bulk selection, etc.) and the bottom _AssignmentCTA as the one
        gold focal. Do not regress the Wave-1 work — build on it.
      Keep every controller call and the selection/bulk logic intact.`,
  },
]

const SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['screen', 'changed', 'summary', 'analyzeClean', 'newTranslationKeys', 'deferred'],
  properties: {
    screen: { type: 'string' }, changed: { type: 'boolean' }, summary: { type: 'string' },
    analyzeClean: { type: 'boolean' }, deferred: { type: 'array', items: { type: 'string' } },
    newTranslationKeys: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'en', 'gu', 'hi'],
        properties: { key: { type: 'string' }, en: { type: 'string' }, gu: { type: 'string' }, hi: { type: 'string' } },
      },
    },
  },
}

phase('Reinvent')
const results = await parallel(SCREENS.map((s) => () =>
  agent(
    `You are a world-class Flutter product designer doing a BOLD LAYOUT REINVENTION of ONE flagship screen
of a premium tour-bus app. Your file: ${ROOT}/${s.file}

READ FIRST (fully): your screen file, ${ROOT}/lib/design/ugam.dart, ${ROOT}/lib/design/tokens.dart,
${ROOT}/lib/design/text_styles.dart, ${ROOT}/lib/utils/formatters.dart.

${DNA}
${GOAL}

SCREEN-SPECIFIC THESIS:
${s.thesis}

${RULES}

Think hard about composition before editing. Then restructure the presentation, run
\`flutter analyze ${s.file}\` until clean, and return the structured result (honest analyzeClean + deferred).`,
    { label: `reinvent:${s.name}`, phase: 'Reinvent', schema: SCHEMA }
  )
)).then((r) => r.filter(Boolean))

return { screens: results }
