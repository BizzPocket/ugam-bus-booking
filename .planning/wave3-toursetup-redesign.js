export const meta = {
  name: 'wave3-toursetup-redesign',
  description: 'Redesign the 7 tour-setup screens onto the Ugam foundation (logic preserved), one agent per screen',
  phases: [
    { title: 'Redesign', detail: 'one agent per tour-setup screen — components + accent rationing' },
  ],
}

const ROOT = '/Users/zeelshiyani/WorkSpace/occubusbooking'

const FOUNDATION = `
AVAILABLE FOUNDATION (import via lib/design/ugam.dart — built & analyzer-clean):
- UgamButton(kind: {primary|tonal|ghost|neutral|danger|dangerTonal}) — 'tonal' = quiet primary.
- UgamCTA / UgamStickyCTA — the ONE solid-champagne sticky bottom action per screen.
- UgamCard.plain/.media with tone: UgamCardTone.{none|accent|good|warm|danger}.
- UgamAppBar(title, eyebrow?, subtitle?, actions:[UgamAppBarAction(...)]).
- UgamInput — all filled text fields. UgamSearchField — search pills.
- UgamPickerField(value, icon, onTap, label?, placeholder?) — read-only tappable field that opens a
  picker; use it as the date/time picker TRIGGER (keep showDatePicker/showTimePicker as the picker).
- UgamExpander(title, child, subtitle?, icon?, initiallyExpanded?, trailing?) — collapsible card
  section (use for add-bus price bands / overrides).
- UgamSelectorPills / UgamTabPills, UgamReqChip, UgamStatTile, UgamEmpty, UgamIconButton.
- UgamDialog.confirm / UgamSheet.show — never raw showDialog/showModalBottomSheet.
- Formatters.formatMoneyInr(n) / formatMoneyInrCompact(n) / formatDateShort(d, locale:) /
  formatDateMedium(d, locale:) — replace local _money() and hardcoded English month arrays.
`

const LAW = `
ACCENT-RATIONING LAW: at most ONE solid-champagne (c.accent FILL) focal per screen — the bottom
sticky CTA when one exists. Every other primary-ish action is TONAL (UgamButton.tonal). Non-champagne
tones use tone-colored ink, never c.onAccent.
`

const RULES = `
ABSOLUTE RULES (presentation redesign, NOT a rewrite):
1. PRESERVE LOGIC. No changes to controllers, GetX, callbacks, navigation, validation, or business
   rules. Same taps do the same things.
2. BEHAVIOR-ADDING items (duplicate-bus defaults, auto-name groups, route-into-grid, default-view):
   implement ONLY by reusing an EXISTING controller method / existing state. If it needs new logic or
   persistence, DO the presentation parts and DEFER the behavior with a note. Never invent logic.
3. DO NOT extract shared files or edit any file other than your assigned screen. Other agents are
   editing sibling screens concurrently — cross-file refactors WILL collide. Migrate IN-PLACE only.
   (If two screens duplicate a widget, just migrate your own copy; note the dedup as future work.)
4. DO NOT invent components that don't exist. There is NO UgamSwitch — keep the Material Switch but
   theme it (activeColor/activeThumbColor: c.accent). Only use components listed in FOUNDATION.
5. Localization: user-facing strings stay tr('ns.key'). NEW strings → return in newTranslationKeys
   (en/gu/hi); do NOT edit JSON yourself.
6. Tokens only (UgamSpacing/UgamRadius/UgamColors.of(context)/UgamText) — no magic numbers, raw hex,
   inline TextStyle.
7. VERIFY: run \`flutter analyze <your file>\` until "No issues found!". Report honestly.
`

const SCREENS = [
  {
    name: 'add_bus',
    file: 'lib/screens/add_bus_screen.dart',
    thesis: `De-gold Step 3 so only one focal champagne element remains (sticky CTA). Replace the local
      _Field/_Label with UgamInput. Wrap the price bands + overrides collapsible sections in
      UgamExpander. Convert the _WizardHeader to UgamAppBar (or UgamIconButton back). Keep Material
      Switches but theme them activeColor: c.accent. Replace local rupee helpers with Formatters.
      "Duplicate bus / remember last bus defaults" — only if you can prefill from existing state cheaply;
      otherwise DEFER. The redundant "1/3" step counter can be dropped if it doesn't drive logic.`,
  },
  {
    name: 'create_tour',
    file: 'lib/screens/create_tour_screen.dart',
    thesis: `Replace the back/header with UgamAppBar. Migrate the Material date/time picker triggers to
      UgamPickerField (keep showDatePicker/showTimePicker as the actual pickers, wired to the same
      state). Normalize section labels (uppercase eyebrow style). Convert _PreviewPill preview chips to
      UgamReqChip. Strip inline fontSize overrides. Do NOT extract shared form widgets — migrate in place.`,
  },
  {
    name: 'edit_tour',
    file: 'lib/screens/edit_tour_screen.dart',
    thesis: `Header → UgamAppBar with a danger (delete) UgamAppBarAction. _CancelChangesPill →
      UgamButton(kind: ghost/neutral). Price-sheet bus rows + _ApplyPriceSheetCard → UgamCard. Date/time
      triggers → UgamPickerField. Do NOT extract the create/edit shared widgets (note the dedup as future
      work) — migrate this screen's own copies in place.`,
  },
  {
    name: 'manage_buses',
    file: 'lib/screens/manage_buses_screen.dart',
    thesis: `Localize the hardcoded month array via Formatters.formatDateShort/Medium(locale:
      context.locale.languageCode). _TopBar → UgamAppBar. _BusListItem → UgamCard.media. More-button →
      UgamIconButton (≥44). Drop the redundant kebab "View status" only if its action is reachable
      elsewhere (it taps into bus status). LinearProgressIndicator fill → keep but token its radius.`,
  },
  {
    name: 'bus_status',
    file: 'lib/screens/bus_status_screen.dart',
    thesis: `Move the title + subtitle into UgamAppBar(eyebrow/subtitle). not-found / no-layout →
      UgamEmpty. quick-call + _CircleAction → UgamIconButton. _OutlinedPill → UgamButton. _DriverHeroCard
      → UgamCard.media. Avoid the fixed 130px label width that clips gu/hi — let it flex.`,
  },
  {
    name: 'tour_groups',
    file: 'lib/screens/tour_groups_screen.dart',
    thesis: `_Header → UgamAppBar. Pin the roster search as UgamSearchField. New-group / _AddMemberButton
      (color-only) → UgamButton.tonal. _NoPassengers / _NoSearchResults → UgamEmpty. group/member
      remove icons → UgamIconButton (≥44). _SuggestionCard surface → UgamCard, its apply button → tonal.
      "Auto-name groups 'Group N'" — only if you can pass a default label to the EXISTING add-group
      method; otherwise DEFER. Do NOT change group/priority logic.`,
  },
  {
    name: 'seating_exceptions',
    file: 'lib/screens/seating_exceptions_screen.dart',
    thesis: `_Header → UgamAppBar. The alert _ExceptionCard → UgamCard(tone: warm/danger). _AllClear →
      UgamEmpty (good tone). _WaitlistAction → UgamButton. "Route a not-yet-placed tap into the seat grid
      pre-selected" — only if an EXISTING route/arg supports preselecting that passenger; otherwise keep
      the current behavior and DEFER. Token the magic spacing/radii.`,
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
          key: { type: 'string' }, en: { type: 'string' }, gu: { type: 'string' }, hi: { type: 'string' },
        },
      },
    },
  },
}

phase('Redesign')
const results = await parallel(SCREENS.map((s) => () =>
  agent(
    `You are a senior Flutter UI engineer redesigning ONE tour-setup screen of a premium
graphite+champagne tour-bus app onto the established Ugam design system. Your file: ${ROOT}/${s.file}

READ FIRST: your screen file (fully), ${ROOT}/lib/design/ugam.dart, ${ROOT}/lib/design/tokens.dart,
${ROOT}/lib/utils/formatters.dart. Skim ${ROOT}/.planning/REDESIGN_ROADMAP.md.

REDESIGN THESIS:
${s.thesis}

${FOUNDATION}
${LAW}
${RULES}

Understand the existing widget tree and logic before editing. Make presentation changes, then run
\`flutter analyze ${s.file}\` and fix until clean. Return the structured result (honest analyzeClean +
deferred).`,
    { label: `redesign:${s.name}`, phase: 'Redesign', schema: SCHEMA }
  )
)).then((r) => r.filter(Boolean))

return { screens: results }
