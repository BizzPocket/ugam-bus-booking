export const meta = {
  name: 'ui-rewrite-batch',
  description: 'Finish the interrupted UI rewrite in small resilient batches (idempotent, file-isolated)',
  phases: [
    { title: 'Rewrite', detail: 'this batch of screen agents' },
    { title: 'Verify', detail: 'flutter analyze' },
  ],
}

const ROOT = '/Users/zeelshiyani/WorkSpace/occubusbooking'
const BATCH = 3

const SCHEMA = {
  type: 'object',
  properties: {
    filesChanged: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    alreadyComplete: { type: 'boolean', description: 'true if the file already contained all intended changes from the prior interrupted run and you applied nothing new' },
    selfAnalyze: { type: 'string' },
    entryPointsPreserved: { type: 'boolean' },
    neededI18nKeys: {
      type: 'array',
      items: {
        type: 'object',
        properties: { key: { type: 'string' }, en: { type: 'string' }, context: { type: 'string' } },
        required: ['key', 'en'],
      },
    },
    risks: { type: 'array', items: { type: 'string' } },
  },
  required: ['filesChanged', 'summary', 'selfAnalyze', 'entryPointsPreserved'],
}

const COMMON = `
You are FINISHING an interrupted UI rewrite in a Flutter + GetX app at ${ROOT} (graphite + champagne theme; tokens in lib/design/tokens.dart: UgamColors.of(context) -> c.bg/card/cardElev/border/ink/ink2/ink3/accent/accentFill/warm/warmFill/good/danger; UgamSpacing/Radius/Text).

CRITICAL — IDEMPOTENCY: A prior run was interrupted, so your assigned file(s) may ALREADY contain SOME of the changes below. READ the current state FIRST. Apply ONLY what is missing. Do NOT duplicate, double-apply, or revert changes that are already correctly in place. If everything is already done, change nothing and set alreadyComplete=true.

KEYSTONE ALREADY DONE (do not redo, just rely on it):
- UgamBusBackdrop (lib/design/components/ugam_bus_backdrop.dart) is now a graphite tile + faint champagne bus motif and accepts an OPTIONAL named param \`String? label\` (renders a champagne route monogram, e.g. label: 'S→M'). You MAY pass label where you have from/to city text. Do NOT edit that component.
- UgamLogo (lib/components/ugam_logo.dart) is now a tokenized champagne monogram. If your file still does Image.asset('assets/icon/ugam_logo.png'), replace it with the UgamLogo widget. Do NOT edit that component.

ABSOLUTE RULES:
1. Edit ONLY your assigned file(s). Read anything for context.
2. NEVER edit assets/translations/*.json. For any NEW user-facing string, use tr('your.key') AND report it in neededI18nKeys. Reuse existing keys where possible.
3. Do NOT create new files or extract shared widgets (deferred). In-file changes only.
4. Preserve class names, constructor signatures, route names, and ALL business/navigation logic. Visual/UX only.
5. Use shared components (UgamAppBar, UgamButton/UgamCTA, UgamStickyCTA, UgamDialog/UgamSheet, UgamCard, UgamEmpty, UgamIconButton, UgamTabPills). Honor the ACCENT-RATIONING LAW (one champagne signal per view; never warm/brown outside the c.warm token).
6. When done: cd ${ROOT} && flutter analyze <your files> 2>&1 | tail -30 ; fix errors you introduced; report in selfAnalyze.
Return the structured object.
`

const AGENTS = {
  dashboard: {
    files: [`${ROOT}/lib/screens/dashboard_screen.dart`],
    task: `Dashboard. (1) ACCENT RATIONING: keep champagne ONLY on the _RevenueHero number; demote the greeting avatar, the 'Create' quick-action tile, the no-trips 'New' pill, and accent-toned attention CTAs to neutral c.cardElev/c.ink. (2) LOCALIZE hardcoded English via tr() + report keys: 'Needs attention', 'Recent requests', 'See all', and quick-action labels 'Create'/'Tours'/'Assign'/'Notify'. (3) _TodayHeroCard is dead-gated by _showTodayTrip=false and wired to the (now graphite) UgamBusBackdrop; re-enable it as a clean graphite hero (you may pass a route-initials label) so it matches the loading shimmer, OR keep gated but remove the shimmer/real-state mismatch. (4) Normalize drifting card radii toward UgamRadius where trivial. Keep shell.switchTab logic.`,
  },
  tours: {
    files: [`${ROOT}/lib/screens/tours_screen.dart`],
    task: `Tours tab. (1) Pass route-initials label: to the 88px UgamBusBackdrop thumbnail (from from/to cities); verify the black date chip reads over graphite, switch to a c.cardElev/c.ink chip if not. (2) Make the per-row LinearProgressIndicator NEUTRAL (track c.border, fill c.ink3) instead of c.accent on every row. (3) Replace hand-rolled _TopBar/_IconCircle/'Create' pill with UgamAppBar + UgamIconButton + UgamCTA; rebuild _TourRow on UgamCard.plain. (4) Convert the per-row action button to UgamButton/UgamCTA. Keep navigation + past-tours search.`,
  },
  'requests-charts': {
    files: [`${ROOT}/lib/screens/requests_screen.dart`, `${ROOT}/lib/screens/charts_screen.dart`],
    task: `REQUESTS: (1) per-card phone icon -> c.ink2 (not accent); keep champagne only for the sticky Seats CTA + the single bulk-Confirm. (2) disabled add-passenger circle: use a proper disabled token, not c.accent@40%. (3) hand-rolled _TopBar/_CircleBtn -> UgamAppBar + UgamIconButton. (4) make _CapacityBanner collapsible or merge with filter pills so cards appear sooner. CHARTS: (1) UgamAppBar header. (2) _Tally fill bar NEUTRAL. (3) trim _Tally to count+bar OR count+%, not all three. Preserve seat-grid + selection/bulk logic.`,
  },
  'settings-group': {
    files: [
      `${ROOT}/lib/screens/settings_screen.dart`,
      `${ROOT}/lib/screens/notifications_settings_screen.dart`,
      `${ROOT}/lib/screens/account_details_screen.dart`,
      `${ROOT}/lib/screens/payment_settings_screen.dart`,
      `${ROOT}/lib/screens/whatsapp_settings_screen.dart`,
    ],
    task: `SETTINGS: replace hardcoded 'Ugam Booking v1.0.0' with tr() key (report) or a version constant; normalize section-label casing (all .toUpperCase()); optionally fold settings-row icon tones to neutral (accent on Finance card only). NOTIFICATIONS_SETTINGS: single neutral/ink icon tile per row (drop the 4-color palette) so the Switch is the only colored signal; theme the Switch to champagne inline; replace Opacity(0.45) disabled wash with an inline 'Turn on Notifications…' note (tr()+report); swap hardcoded BorderRadius.circular(20) for a UgamRadius token. ACCOUNT/PAYMENT/WHATSAPP: leave as-is (optional lightweight section labels only).`,
  },
  'notify-legal': {
    files: [`${ROOT}/lib/screens/notify_screen.dart`, `${ROOT}/lib/screens/legal_document_screen.dart`],
    task: `NOTIFY: (1) hand-rolled _TopBar -> UgamAppBar (search/reset as actions; keep the conditional back already present). (2) localize the two raw English snackbars (no-seated-passengers; the appended raw-exception text -> generic localized failure) via tr()+report. (3) replace the hand-rolled month array + 24h formatter in _HeroSummaryCard with intl/easy_localization. (4) unify tour-selector chips with UgamTabPills. Keep lock/broadcast + bottomNavigationBar CTA. LEGAL: it now uses UgamLogo (already swapped) — good; (1) hand-rolled _TopBar -> UgamAppBar; (2) ration accent: keep ONE champagne signal (the underline rule), demote section titles to strong c.ink and bullet dots to c.ink3.`,
  },
  'tour-forms': {
    files: [`${ROOT}/lib/screens/create_tour_screen.dart`, `${ROOT}/lib/screens/edit_tour_screen.dart`],
    task: `CREATE_TOUR: feed the already-picked local image (_broadcastImage via _BroadcastImagePicker, Image.file) into the _TourPreviewCard cover when present (Image.file BoxFit.cover, rounded); fall back to the graphite UgamBusBackdrop (pass a route-initials label) when none. EDIT_TOUR: leave preview on graphite UgamBusBackdrop with a route-initials label. BOTH: keep each screen's own preview-pill impl (do NOT extract); optional lightweight form sections. Preserve all form/validation/save logic.`,
  },
  'tour-workspace': {
    files: [
      `${ROOT}/lib/screens/tour_detail_screen.dart`,
      `${ROOT}/lib/screens/tour_overview_screen.dart`,
      `${ROOT}/lib/screens/tour_seat_assignment_screen.dart`,
    ],
    task: `Large files — be conservative, preserve all logic. TOUR_DETAIL: pass a route-initials label to the 320px hero UgamBusBackdrop and ensure the scrim keeps white chrome legible; ACCENT-RATION the Overview tab (make _TourTools tiles neutral c.cardElev/c.ink2; only the single next action / sticky CTA carries gold); dedupe the Seats entry that appears in Next-Action + sticky CTA + tools grid (keep at most two). TOUR_OVERVIEW: collapse simultaneous warm _CapacityBanner + warm _DecisionChip into one attention surface; _BannerAction -> UgamButton (warm tonal). SEAT_ASSIGNMENT: decompress the cramped bottom third — keep ONE passenger switcher (prefer _PendingDock; remove the _PassengerCard inline all-passenger chip picker); make the _PendingDock +N overflow open a full list/sheet; enlarge 28px avatars; bump 8px handler-badge text; swap raw Material IconButton (~line 2165) for UgamIconButton.`,
  },
  'bus-money': {
    files: [
      `${ROOT}/lib/screens/manage_buses_screen.dart`,
      `${ROOT}/lib/screens/bus_status_screen.dart`,
      `${ROOT}/lib/screens/bus_money_screen.dart`,
      `${ROOT}/lib/screens/collection_screen.dart`,
      `${ROOT}/lib/screens/tour_money_board_screen.dart`,
      `${ROOT}/lib/screens/handler_bus_chart_screen.dart`,
    ],
    task: `Mostly polished — focus on named fixes; preserve money/collection logic + route names. MANAGE_BUSES: tighten card density (driver+departure into one meta line; seat-progress bar the single secondary signal). BUS_STATUS: its below-app-bar body is a FIXED non-scrolling Column that overflows on small phones — make the lower content scrollable OR move the two money buttons (Collect / Bus money) into app-bar overflow / a sheet; reduce _BottomActions to one-two primaries. MONEY CARDS (bus_money, tour_money_board, collection): establish HIERARCHY — lead with the ONE action number (outstanding handover / to-collect) as a larger tabular figure, demote the rest. HANDLER_BUS_CHART: hand-rolled _TopBar -> UgamAppBar; hand-rolled _BusPills -> the UgamTabPills/selector already used on that screen; bespoke accent add-expense chip -> tonal UgamButton. In-file only.`,
  },
  customer: {
    files: [
      `${ROOT}/lib/screens/customer_tour_list_screen.dart`,
      `${ROOT}/lib/screens/customer_tour_detail_screen.dart`,
      `${ROOT}/lib/screens/customer_booking_request_screen.dart`,
      `${ROOT}/lib/screens/customer_my_requests_screen.dart`,
      `${ROOT}/lib/screens/customer_more_screen.dart`,
    ],
    task: `Customer flow. customer_more already uses UgamLogo (swapped) — good. (1) pass route-initials label: to every UgamBusBackdrop (list rows, 320px detail hero, _BusCard, booking preview, my-requests rows) from from/to cities; verify black date/scrim pills read over graphite (switch to c.cardElev chips if not). (2) ADD PRICE (real gap): per-seat price on each tour-list row; price on the detail hero/summary card (pricePerSeat is in scope); estimated total (seats x pricePerSeat) near the booking-form submit CTA; report any new label keys. (3) ACCENT-RATION customer_my_requests rows: Edit pill -> outline/ghost, handler-chart button -> neutral; remove the duplicate status signal (StatusDot vs footer chip — keep one). (4) localize the hardcoded month array in customer_my_requests _formatDate via tr('app.month.short.*') (reuse sibling keys). Preserve booking/nav + hidden long-press login.`,
  },
  entry: {
    files: [
      `${ROOT}/lib/screens/login_screen.dart`,
      `${ROOT}/lib/screens/admin_setup_screen.dart`,
      `${ROOT}/lib/screens/splash_screen.dart`,
    ],
    task: `LOGIN: replace the 200px UgamBusBackdrop hero with the UgamLogo monogram + a clean graphite headline block (drop the fake hero); demote the dev 'Ping'/network-check OutlinedButton behind a long-press/debug gate; replace the hand-rolled _sendPing dialog with UgamDialog/UgamSheet; tidy dead _kKeepServices + unused imports. Keep auth logic + the back affordance. ADMIN_SETUP: replace the 120px UgamBusBackdrop banner with a clean tokenized header (champagne support-agent icon larger on c.cardElev); make the email chip launch mailto / copy. Keep UgamAppBar + CTA. SPLASH: it uses UgamLogo (now a monogram) — verify nothing else is warm and the 450ms/fade logic is untouched (likely no change).`,
  },
}

const BATCHES = {
  1: ['dashboard', 'tours', 'requests-charts'],
  2: ['settings-group', 'notify-legal', 'tour-forms'],
  3: ['tour-workspace', 'bus-money', 'customer', 'entry'],
}

const keys = BATCHES[BATCH] || []
log(`Batch ${BATCH}: ${keys.join(', ')}`)

phase('Rewrite')
const fixResults = await parallel(keys.map((k) => () =>
  agent(
    `${COMMON}\n\nYOUR ASSIGNED FILES (edit ONLY these):\n${AGENTS[k].files.map((f) => '  - ' + f).join('\n')}\n\nTASK:\n${AGENTS[k].task}`,
    { label: `rw:${k}`, phase: 'Rewrite', schema: SCHEMA }
  ).then((r) => ({ key: k, ...r }))
))

phase('Verify')
const verify = await agent(
  `Run: cd ${ROOT} && flutter analyze lib 2>&1 | tail -60. Report clean(bool, true iff zero errors), errors[](verbatim), warnings[](edit-caused).`,
  {
    label: 'verify:analyze',
    phase: 'Verify',
    schema: {
      type: 'object',
      properties: { clean: { type: 'boolean' }, errors: { type: 'array', items: { type: 'string' } }, warnings: { type: 'array', items: { type: 'string' } } },
      required: ['clean', 'errors'],
    },
  }
)

return { batch: BATCH, fixes: fixResults.filter(Boolean), verify }
