export const meta = {
  name: 'wave2-money-redesign',
  description: 'Redesign the 6 money/finance screens onto the Ugam foundation (logic preserved), one agent per screen',
  phases: [
    { title: 'Redesign', detail: 'one agent per money screen — components + accent rationing' },
  ],
}

const ROOT = '/Users/zeelshiyani/WorkSpace/occubusbooking'

const FOUNDATION = `
AVAILABLE FOUNDATION (import via lib/design/ugam.dart — already built & analyzer-clean):
- UgamButton(kind: UgamButtonKind.{primary|tonal|ghost|neutral|danger|dangerTonal}) — 'tonal'
  is the canonical QUIET PRIMARY (accentFill bg + accent ink + hairline border).
- UgamCTA / UgamStickyCTA — the ONE solid-champagne sticky bottom action per screen.
- UgamCard.plain / .media with \`tone: UgamCardTone.{none|accent|good|warm|danger}\` — tinted
  attention/danger cards (use instead of hand-rolling Container(cardElev, colored border)).
- UgamAppBar(title, eyebrow?, subtitle?, actions:[UgamAppBarAction(...)]) — pushed-screen header.
  Use eyebrow for the section context (e.g. "FINANCE", "TOUR MONEY").
- UgamSearchField, UgamSelectorPills(items:[UgamSelectorItem(label, leadingColor?, count?)],
  currentIndex, onChanged) — TONAL active state. UgamTabPills for 2-segment toggles.
- UgamRequestRow / UgamReqChip / UgamStatTile / UgamEmpty / UgamSkeleton / UgamIconButton — existing.
- UgamDialog.confirm(...) / UgamSheet.show(...) — never raw showDialog/showModalBottomSheet.
- Formatters.formatMoneyInr(n) / formatMoneyInrCompact(n) / formatDateShort(d, locale:) — shared,
  localized; REPLACE every local _money()/_format() rupee helper and hardcoded English month array.
`

const LAW = `
THE ACCENT-RATIONING LAW (#1 priority):
At most ONE solid-champagne (c.accent FILL) focal element per screen — the bottom sticky CTA when
one exists. EVERY other "primary-ish" action is TONAL (UgamButton.tonal). Non-champagne tones
(good/warm/danger) use tone-colored ink, never c.onAccent. IMPORTANT for money screens: error/empty
states must NOT use solid gold.
`

const RULES = `
ABSOLUTE RULES (presentation redesign, NOT a rewrite):
1. PRESERVE LOGIC. Do not change controllers, GetX bindings, callbacks, navigation, money math, or
   business rules. Same taps do the same things.
2. CLICK-EFFICIENCY ITEMS THAT ADD BEHAVIOR (e.g. one-tap "Mark paid", default-period, default-view):
   only implement by REUSING an EXISTING controller method / existing state. If it would require new
   persistence or new business logic, DO the presentation parts and DEFER the behavior change with a
   note. Never invent money-mutation logic.
3. Keep all existing functionality reachable. Relocate/restyle, never delete features.
4. Localization: user-facing strings stay tr('ns.key'). NEW strings → return in newTranslationKeys
   (en/gu/hi); do NOT edit the JSON files yourself.
5. Edit ONLY your assigned screen file. No other screens, components, or JSON.
6. Use tokens (UgamSpacing/UgamRadius/UgamColors.of(context)/UgamText) — no magic numbers, raw hex,
   or inline TextStyle.
7. VERIFY: run \`flutter analyze <your file>\` and iterate until "No issues found!". Report honestly.
`

const SCREENS = [
  {
    name: 'collection',
    file: 'lib/screens/collection_screen.dart',
    thesis: `Add a one-tap "Mark paid (₹due)" affordance on collection rows ONLY IF an existing
      controller method records a full payment for a passenger (reuse it with the row's due amount);
      if no such method exists cleanly, DEFER with a note. Migrate the balance banner to
      UgamCard(tone: accent/good), the no-match state to UgamEmpty, _StatusChip to UgamReqChip, and
      the local _money() to Formatters.formatMoneyInr. Pin the summary + filters above the scroll.`,
  },
  {
    name: 'bus_money',
    file: 'lib/screens/bus_money_screen.dart',
    thesis: `Demote the mid-page Collect/Add actions to UgamButton.tonal, enlarge the small delete
      icons to UgamIconButton (≥44px), migrate category chips to UgamTabPills/UgamSelectorPills, the
      empty lines to UgamEmpty, and local _money() to Formatters.formatMoneyInr. The destructive
      delete-confirm is ALREADY added — keep it intact.`,
  },
  {
    name: 'tour_money_board',
    file: 'lib/screens/tour_money_board_screen.dart',
    thesis: `Replace the hand-rolled _Header with UgamAppBar(eyebrow: "TOUR MONEY"). Migrate the
      attention ring (nested Container around a card) to UgamCard(tone: warm/danger), _CollectButton
      to UgamButton.tonal, _Empty to UgamEmpty, local _money() to Formatters. Fix the "sm+2"/SizedBox(2)
      arithmetic with tokens. Do NOT misuse UgamStickyCTA for the info capsule.`,
  },
  {
    name: 'finance',
    file: 'lib/screens/finance_screen.dart',
    thesis: `Default the period selector to "this month" using EXISTING state (just set the initial
      selected value; no new persistence). Migrate _Header to UgamAppBar(eyebrow: "FINANCE"),
      _StatTriple to UgamStatTile, _Empty/_ErrorState to UgamEmpty (NO solid gold in error), _Loading
      to UgamSkeleton, local _money() to Formatters. Strip inline fontSize overrides on UgamText;
      route the literal 18 radius to UgamRadius.stat.`,
  },
  {
    name: 'charts',
    file: 'lib/screens/charts_screen.dart',
    thesis: `Migrate the _TourPills + _BusPills selector strips to UgamSelectorPills (tonal active).
      The decorative trailing circle and the call-action circle become UgamIconButton (give the
      decorative one a real onTap or remove it). _EditSeatsLink to UgamButton(kind: ghost). Clean up
      fontSize tuning. LEAVE the chart/seat-grid rendering and data logic completely untouched.`,
  },
  {
    name: 'handler_bus_chart',
    file: 'lib/screens/handler_bus_chart_screen.dart',
    thesis: `Default to the List view IF the view-mode is held in existing state you can set initially
      (else DEFER). Migrate _ViewToggle to UgamTabPills, the spinner loading to UgamSkeleton, the
      _TopBar circles to UgamIconButton, _CollectSheet Call to UgamButton, local _money() to
      Formatters. Localize the hardcoded 'GO'/'RET' and ' ½' literals (return tr keys). Apply accent
      rationing to roster/category chips. Leave the seat-grid + handover logic untouched.`,
  },
]

const SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['screen', 'changed', 'summary', 'analyzeClean', 'newTranslationKeys', 'deferred'],
  properties: {
    screen: { type: 'string' },
    changed: { type: 'boolean' },
    summary: { type: 'string' },
    analyzeClean: { type: 'boolean' },
    deferred: { type: 'array', items: { type: 'string' } },
    newTranslationKeys: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'en', 'gu', 'hi'],
        properties: {
          key: { type: 'string' },
          en: { type: 'string' }, gu: { type: 'string' }, hi: { type: 'string' },
        },
      },
    },
  },
}

phase('Redesign')
const results = await parallel(SCREENS.map((s) => () =>
  agent(
    `You are a senior Flutter UI engineer redesigning ONE money/finance screen of a premium
graphite+champagne tour-bus app onto the established Ugam design system. Your file: ${ROOT}/${s.file}

READ FIRST: your screen file (fully), ${ROOT}/lib/design/ugam.dart, ${ROOT}/lib/design/tokens.dart,
${ROOT}/lib/utils/formatters.dart, and skim ${ROOT}/.planning/REDESIGN_ROADMAP.md.

REDESIGN THESIS:
${s.thesis}

${FOUNDATION}
${LAW}
${RULES}

Understand the existing widget tree AND its money logic before editing. Make the presentation
changes, then run \`flutter analyze ${s.file}\` and fix until clean. Return the structured result
(be honest about analyzeClean and deferred).`,
    { label: `redesign:${s.name}`, phase: 'Redesign', schema: SCHEMA }
  )
)).then((r) => r.filter(Boolean))

return { screens: results }
