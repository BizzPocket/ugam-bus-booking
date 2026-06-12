export const meta = {
  name: 'wave4-customer-redesign',
  description: 'Redesign the 5 customer-funnel screens onto the Ugam foundation (logic preserved), one agent per screen',
  phases: [{ title: 'Redesign', detail: 'one agent per customer screen' }],
}

const ROOT = '/Users/zeelshiyani/WorkSpace/occubusbooking'

const FOUNDATION = `
AVAILABLE FOUNDATION (import via lib/design/ugam.dart — built & analyzer-clean):
- UgamButton(kind: {primary|tonal|ghost|neutral|danger|dangerTonal}) — 'tonal' = quiet primary.
- UgamCTA / UgamStickyCTA — the ONE solid-champagne sticky bottom action per screen.
- UgamCard.plain/.media with tone: UgamCardTone.{none|accent|good|warm|danger}.
- UgamAppBar(title, eyebrow?, subtitle?, actions:[UgamAppBarAction(icon,onTap,tooltip?,active?)]).
- UgamInput / UgamSearchField. UgamSelectorPills / UgamTabPills. UgamReqChip / UgamStatTile / UgamEmpty
  / UgamSkeleton / UgamIconButton.
- UgamDialog.confirm / UgamSheet.show. AppSnackBar.success/error/info for toasts.
- Formatters.formatMoneyInr(n) / formatMoneyInrCompact(n) / formatDateShort(d, locale:) /
  formatDateMedium(d, locale:) — replace local _money() + hardcoded English month arrays.
`

const LAW = `
ACCENT-RATIONING LAW: at most ONE solid-champagne (c.accent FILL) focal per screen — the bottom sticky
CTA when one exists. Every other primary-ish action (Book, Edit, Contact, per-row pills) is TONAL
(UgamButton.tonal). Non-champagne tones use tone-colored ink, never c.onAccent. This customer funnel is
the WORST accent over-user in the app — be aggressive about de-golding repeated/per-row actions.
`

const RULES = `
ABSOLUTE RULES (presentation redesign, NOT a rewrite):
1. PRESERVE LOGIC. No changes to controllers, GetX, callbacks, navigation, validation, business rules.
2. BEHAVIOR-ADDING items (price line, success toast, seed seat counts, fix dead row-tap): implement
   ONLY by reusing EXISTING data/methods (e.g. an existing price field on the model, an existing detail
   route, AppSnackBar after an existing share call). If it needs new data/logic, DEFER with a note.
3. DO NOT extract shared files or create new shared components (no TourMiniCard, no UgamListRow). Other
   agents edit sibling screens concurrently — migrate your widgets IN PLACE (e.g. _MoreRow/_TourRow →
   UgamCard.plain/.media inline). Note any dedup as future work.
4. DO NOT add dependencies or edit pubspec. If a fix needs a new package (e.g. package_info for real
   app version), DEFER it and keep the current value via a tr key/constant.
5. Localization: user-facing strings stay tr('ns.key'); NEW strings → return in newTranslationKeys
   (en/gu/hi). Replace hardcoded English month arrays with Formatters.*Date*(locale: context.locale.languageCode).
6. Edit ONLY your assigned screen file. Tokens only — no magic numbers, raw hex, inline TextStyle.
7. VERIFY: run \`flutter analyze <your file>\` until "No issues found!". Report honestly.
`

const SCREENS = [
  {
    name: 'customer_my_requests',
    file: 'lib/screens/customer_my_requests_screen.dart',
    thesis: `This is the worst gold over-user — demote the Edit-request and Handler-chart color-only
      buttons to UgamButton.tonal. Fix the HARDCODED English month array in _formatDate via
      Formatters.formatDateShort/Medium(locale: context.locale.languageCode). _TopBar (back + refresh
      circles, raw spinner) → UgamAppBar + UgamAppBarAction (drop the manual refresh button IF pull-to-
      refresh already exists; else keep it as an AppBarAction). Fix the dead/no-op row tap by pointing it
      at the EXISTING detail route (defer if no such route). Cards → UgamCard. Navigator.push(MaterialPageRoute)
      → Get.to(transition: Transition.cupertino).`,
  },
  {
    name: 'customer_tour_list',
    file: 'lib/screens/customer_tour_list_screen.dart',
    thesis: `_SearchField → UgamSearchField. _IconCircle action/badge buttons → UgamIconButton /
      UgamAppBarAction. _BookPill (color-only) and the full-state 30px circle → UgamButton.tonal /
      UgamIconButton. _TourRow surface → UgamCard.media. _GroupHeader count badge → UgamReqChip. Localize
      dates via Formatters. Do NOT create a shared TourMiniCard — migrate _TourRow in place. Normalize the
      title font (sibling screens use 24).`,
  },
  {
    name: 'customer_tour_detail',
    file: 'lib/screens/customer_tour_detail_screen.dart',
    thesis: `Color(0x14000000) shadow → UgamCard.plain(elev:true). _ChromeCircle (+ Colors.white at call
      site) → UgamIconButton. About / _ContactOrganiserButton / _BusCard / _TimelineRow / _InfoCard
      surfaces → UgamCard. Add a visible price line ONLY if the tour model already exposes a price field
      (reuse it); else DEFER. Add an AppSnackBar.success toast AFTER the existing share action. Let the
      _InfoCard fixed 90px label flex (clips gu/hi). Collapsing the Schedule tab into About is a structural
      change — DEFER it unless purely presentational.`,
  },
  {
    name: 'customer_booking_request',
    file: 'lib/screens/customer_booking_request_screen.dart',
    thesis: `_TopBar back → UgamAppBar. _TourPreviewCard surface → UgamCard. Localize _formatDate months
      via Formatters (drop any .toUpperCase() on non-Latin months). Strip inline fontSize overrides; token
      the magic paddings. Do NOT create a shared TourMiniCard. "Seed initial seat counts into first render"
      — only if existing form state supports a default; else DEFER.`,
  },
  {
    name: 'customer_more',
    file: 'lib/screens/customer_more_screen.dart',
    thesis: `_TopBar → UgamAppBar. _MoreRow → UgamCard.plain(onTap) IN PLACE (do NOT create a UgamListRow
      component). _BrandHero magic dims → tokens. Localize the 'Ugam Foj' brand literal via a tr key/
      constant. Real app version from package_info → DEFER (no new dependency); keep the current version
      string via its existing constant/tr key.`,
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

phase('Redesign')
const results = await parallel(SCREENS.map((s) => () =>
  agent(
    `You are a senior Flutter UI engineer redesigning ONE customer-facing screen of a premium
graphite+champagne tour-bus app onto the Ugam design system. Your file: ${ROOT}/${s.file}

READ FIRST: your screen file (fully), ${ROOT}/lib/design/ugam.dart, ${ROOT}/lib/design/tokens.dart,
${ROOT}/lib/utils/formatters.dart.

REDESIGN THESIS:
${s.thesis}

${FOUNDATION}
${LAW}
${RULES}

Understand the widget tree and logic before editing. Make presentation changes, then run
\`flutter analyze ${s.file}\` until clean. Return the structured result (honest analyzeClean + deferred).`,
    { label: `redesign:${s.name}`, phase: 'Redesign', schema: SCHEMA }
  )
)).then((r) => r.filter(Boolean))

return { screens: results }
