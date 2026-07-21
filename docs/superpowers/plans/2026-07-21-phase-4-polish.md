# Phase 4 — Low-severity polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Clear the 23 low-severity polish findings from the 2026-07-21 audit (§5) — i18n date/currency leaks, minor overflow, dead code, snackbar dedup, a handful of data/UX correctness nits, and the untested BusMoneySummary/TourFinance branches — without changing any shipped behavior a user relies on.

**Architecture:** Every fix is a localized edit inside an existing screen, model, controller, util, or the iOS privacy manifest. There is one new shared util (`MoneyInputFormatter`) and one new shared wrapper (`UgamMaxWidth`); everything else edits code that already exists. No data-model, RPC, or migration changes belong to this phase — those were Phases 1–3.

**Tech Stack:** Flutter, GetX, Supabase, easy_localization, flutter_test.

## Global Constraints
- Money formatting always formatMoneyInr (₹, en_IN).
- Every user-facing string via tr(); keys in en/gu/hi in sync.
- Widget tests calling plural() must Localization.load a locale in setUpAll.
- Do NOT restructure unrelated code.

## Cross-phase assumptions
- **Phase 2 converted `UgamInput` to a `TextFormField`** (per audit AL-1). Task 5 (AL-6) therefore adds an `inputFormatters` on the existing `UgamInput`; if Phase 2 also added a `validator` param, prefer a validator over the pre-save guard, but the pre-save guard below is valid either way.
- **Phase 3 owns the medium responsiveness items** (AS-4/H-4 tile scaling, AM-2/AM-3/AM-4 money loading/refresh/snapshot, AS-1/AS-2 leg counts). Phase 4 only touches the *low* responsiveness nits (C-2, C-3, AL-9, AL-10, AS-6, X-9). Do not re-do Phase 3 work.
- **H-3 (Phase 2)** may rewrite `_collectionKey` to be seat-agnostic. Task 11 (H-12) is a *comment* fix only — reconcile the doc comment with whatever the code says at execution time; do not change the key.
- **`Formatters.formatDateShort(date, {locale})` and `formatDateMedium` already exist** (lib/utils/formatters.dart:50-57) and are already used by tour_detail/finance/create_tour/edit_tour/dashboard. Task 1 routes the remaining hardcoded month arrays through them — no new helper needed.
- **`UgamPickerField` already ellipsizes** its value (lib/design/components/ugam_picker_field.dart:73-81, inside an `Expanded`). AL-10 is therefore a documented verification, not a code change.

---

### Task 1: i18n date/currency leaks + dead formatters (C-1, AL-5, AL-7, X-10, C-7)

**Files:** `lib/screens/customer_my_requests_screen.dart`, `lib/screens/tours_screen.dart`, `lib/screens/tour_detail_screen.dart`, `lib/utils/formatters.dart`, `lib/screens/customer_more_screen.dart`, `lib/screens/login_screen.dart`

- [ ] **C-1** — `customer_my_requests_screen.dart`: the static `_formatDate` (lines 728-744) hardcodes an English `months` array. Change its signature to `static String _formatDate(DateTime d, String locale)` and replace the body with:
  ```dart
  return Formatters.formatDateShort(d, locale: locale).toUpperCase();
  ```
  Update the single call site (line 538, inside `_RequestRow.build(BuildContext context)`) to `_formatDate(entry.tourDepartureDate, context.locale.languageCode)`. Confirm `Formatters` is imported (grep the file's imports; add `import '../utils/formatters.dart';` if absent).
- [ ] **AL-5** — `tours_screen.dart`: same edit. `_formatDate` (lines 566-582) → `static String _formatDate(DateTime d, String locale) => Formatters.formatDateShort(d, locale: locale).toUpperCase();`. Call site is line 437 inside `build(BuildContext context)` → `_formatDate(tour.departureDate, context.locale.languageCode)`.
- [ ] **AL-7** — `tour_detail_screen.dart:1562`: replace `const UgamReqChip(label: 'AC')` with `UgamReqChip(label: tr('manage_buses.tag_ac'))` (existing key, value "AC" in en/gu/hi — verified present in all three). Drop `const` since `tr()` is not const.
- [ ] **X-10** — `formatters.dart`: delete the two dead, wrong-locale/currency formatters — `formatDateTime` (lines 4-8, pinned `en_US`) and `formatCurrency` (lines 15-17, `$` symbol). Both are defined-only (grep confirms zero call sites). `formatSeatDetails` (lines 10-13) is also dead and hardcodes an English `'No seats'`; delete it too. Keep `formatMoneyInr`, `formatMoneyInrCompact`, `formatDateShort`, `formatDateMedium`. Remove the now-unused `intl` import only if nothing else in the file uses it (`DateFormat`/`NumberFormat` still do — keep it).
- [ ] **C-7 (decision: KEEP hardcoded, document)** — the brand wordmarks `'UGAM'` (`login_screen.dart:106`) and `'Ugam Foj'` (`customer_more_screen.dart:170`) are proper-noun brand marks, identical across all locales; routing them through `tr()` adds three duplicate keys with no localization value. Leave the literals in place and add a one-line comment above each: `// Brand wordmark — intentionally not localized (same in en/gu/hi).` No behavior change.
- [ ] **Verify:** `flutter analyze` clean. Light manual check: switch app locale to `gu`, open My Requests and the tours list — the date pills render Gujarati month names (e.g. `12 જૂન`) instead of `JUN`. Run `flutter test test/` to confirm nothing referenced the deleted formatters.
- [ ] **Commit:** `polish(i18n): localized date pills, reuse AC key, drop dead formatters (C-1/AL-5/AL-7/X-10/C-7)`

---

### Task 2: Customer overflow polish (C-2, C-3)

**Files:** `lib/screens/login_screen.dart`, `lib/screens/customer_tour_list_screen.dart`

- [ ] **C-2** — `login_screen.dart:186-198`: the biometric-unlock `Row` has an unconstrained `Text`. Wrap the label in `Flexible` so a long translation ellipsizes instead of overflowing:
  ```dart
  Flexible(
    child: Text(
      tr('login.unlock_biometric'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: UgamText.bodyStrong.copyWith(color: c.accent),
    ),
  ),
  ```
- [ ] **C-3** — `customer_tour_list_screen.dart:685-702`: the price `Text` in the route/price `Row` has `maxLines: 1` + ellipsis but is NOT flex-constrained, so the ellipsis can never fire and the price segment overflows under large text scale (the route beside it is already `Flexible`, lines 664-674). Wrap the price `Text` (the whole `Text(tr('customer_tour_list.price_per_seat', ...))`) in `Flexible( child: ... )`. Leave the `·` separator and spacing as-is.
- [ ] **Verify:** manual — set OS font scale to max (Android Display size / iOS Larger Text) on a 360dp-wide device profile; the login biometric row and a long-route tour card both clip cleanly with `…`, no yellow overflow stripes.
- [ ] **Commit:** `polish(responsive): flex-constrain biometric label + tour price segment (C-2/C-3)`

---

### Task 3: Customer data/UX correctness (C-4, C-5, C-6)

**Files:** `lib/screens/account_details_screen.dart`, `lib/screens/add_return_ticket_sheet.dart`, `lib/screens/customer_tour_list_screen.dart`

- [ ] **C-4** — `account_details_screen.dart:131`: `'+91 ${_authCtrl.userPhone.value}'` prints a bare `+91 ` when the phone is empty. Guard it:
  ```dart
  final phone = _authCtrl.userPhone.value.trim();
  ... Text(phone.isEmpty ? '—' : '+91 $phone', ...)
  ```
  (Country code stays `+91` — the app is India-only; the bug is the empty case, not the prefix.) Compute `phone` at the top of the enclosing `build`/method so the `Obx`/reactive read still occurs.
- [ ] **C-5** — `add_return_ticket_sheet.dart:26-32`: `show(...)` fires `onAdded` on ANY dismiss because `.then((_) => onAdded?.call())` runs on every sheet close, including cancel. Gate it on a success result:
  - In `_submit` (line 66) change `Get.back();` → `Get.back(result: true);`.
  - In `show` change the tail to `.then((result) { if (result == true) onAdded?.call(); });`.
  Confirm no other pop path in the sheet returns `true`.
- [ ] **C-6** — `customer_tour_list_screen.dart:63`: the "My bookings" badge counts cancelled/rejected future requests. `CustomerRequestEntry` exposes `isCancelled` (status `rejected`/`cancelled`, customer_requests_store.dart:127). Change the filter to exclude them:
  ```dart
  setState(() => _myRequestCount =
      entries.where((e) => !e.isPast && !e.isCancelled).length);
  ```
- [ ] **Verify (TDD-light):** C-5 and C-6 are real behavior changes — add/extend a widget or unit test. For C-6, a pure list-filter assertion is enough: build a fixture list with one live-active, one live-cancelled, one past entry and assert the count is 1. For C-5, if a sheet test is heavy, document a manual check: open the return-ticket sheet, dismiss without submitting → the caller's refresh does NOT fire; submit successfully → it does.
- [ ] **Commit:** `fix(customer): empty-phone guard, success-only onAdded, exclude cancelled from badge (C-4/C-5/C-6)`

---

### Task 4: Admin form/pickup responsiveness (AL-9, AL-10)

**Files:** `lib/screens/pickup_locations_screen.dart`; (verify-only) `lib/screens/create_tour_screen.dart`, `lib/screens/edit_tour_screen.dart`

- [ ] **AL-9** — `pickup_locations_screen.dart:223-256`: the add-row `Row` gives the code field a fixed `SizedBox(width: 80)` and packs a non-flex `UgamButton` after the `Expanded` name field, crowding the name on ~360dp phones / large text. Tighten the code field and let the button shrink:
  - Reduce the code `SizedBox` width from `80` to `64` (a 6-char uppercase code still fits at normal scale).
  - The name field stays `Expanded`. This is the minimal, reviewable change; do NOT restructure into a Wrap.
- [ ] **AL-10 (documented verification — no code change)** — `create_tour_screen.dart:326-387` and `edit_tour_screen.dart:509-570` place localized `Formatters.formatDateMedium` values into `UgamPickerField`s inside flex `Expanded` cells. `UgamPickerField` already renders its value in an `Expanded > Text(maxLines: 1, overflow: TextOverflow.ellipsis)` (ugam_picker_field.dart:72-82), so long localized dates ellipsize safely. Record in the commit body: "AL-10 verified: UgamPickerField ellipsizes; no change." Optionally add a manual check at gu locale + max font scale confirming no overflow.
- [ ] **Verify:** manual — pickup add-row on a 360dp profile at large text: name field remains usable, add button and code field visible.
- [ ] **Commit:** `polish(responsive): tighten pickup add-row; verify picker ellipsis (AL-9/AL-10)`

---

### Task 5: Admin tour-lifecycle data/UX (AL-6, AL-8, AL-11, AL-12)

**Files:** `lib/screens/edit_tour_screen.dart`, `lib/screens/manage_buses_screen.dart`, `lib/screens/tour_groups_screen.dart`, `lib/screens/dashboard_screen.dart`

- [ ] **AL-6** — `edit_tour_screen.dart`: the price field (`UgamInput` at 579-583, `keyboardType: TextInputType.number`) still accepts `"12.3.4"`/junk, which `double.tryParse(_priceCtrl.text) ?? 0` (line 200) silently turns into 0. Add a digits-only formatter so only whole-rupee input is possible (display already uses `toStringAsFixed(0)`):
  ```dart
  UgamInput(
    label: tr('create_tour.label.price_per_seat'),
    controller: _priceCtrl,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
  )
  ```
  Add `import 'package:flutter/services.dart';` if absent. With digits-only input, `double.tryParse` at line 200 always succeeds (or empty → 0, which is the existing intended "free" case). If Phase 2 added a `validator` param to `UgamInput`, additionally reject an empty price with `tr('edit_tour.error_invalid_price')` (add that key to en/gu/hi) — otherwise the formatter alone closes the "parses junk to 0" bug.
- [ ] **AL-8** — double error snackbar + raw `$e`. Root cause confirmed: `TourController._write` (tour_controller.dart:2867-2890) shows its `failure:` snackbar AND `rethrow`s, so callers that also catch fire a second one.
  - `manage_buses_screen.dart:182-183`: `removeBus` passes `failure: tr('errors.remove_bus')`, so it already surfaced a localized error before rethrowing. Change the catch to stop the raw-`$e` double: `} catch (_) { /* _write already surfaced errors.remove_bus */ }`. Keep the success snackbar at line 181.
  - `edit_tour_screen.dart:324-325`: the price-sheet copy loop calls `ctrl.updateBus` (also `_write`, `failure: tr('errors.update_bus')`), so the local `AppSnackBar.error(tr('edit_tour.price_sheet.copy_failed'))` is the redundant second snackbar. Change to `} catch (_) { /* updateBus (_write) already surfaced the error */ }`, keeping the `finally { _saving = false }`. The now-unused key `edit_tour.price_sheet.copy_failed` may stay (harmless) or be removed from all three locales.
- [ ] **AL-11** — `tour_groups_screen.dart:150-170`: `createGroup` then a `for` loop of `setPassengerGroup` has only `try/finally` (resets `_creating`) — a mid-loop failure leaves the group created with some members unassigned and no user feedback (the exception propagates uncaught). Add a `catch` that surfaces the partial state instead of failing silently:
  ```dart
  } catch (_) {
    if (mounted) AppSnackBar.error(tr('tour_groups.snack_create_failed'));
  } finally {
    if (mounted) setState(() => _creating = false);
  }
  ```
  Add key `tour_groups.snack_create_failed` (en/gu/hi). Full transactional rollback (deleting the half-built group) is out of scope for Phase 4 — note that in the commit body; the user can retry, and `createGroup` is idempotent per member via `setPassengerGroup`.
- [ ] **AL-12** — `dashboard_screen.dart:338-347`: `_recentRequests` folds every `t.passengers` row, so "Recent requests" lists all riders, not new/pending ones. `Passenger` exposes `isConfirmed` (passenger.dart:46) and `isCancelled` (passenger.dart:85). Filter to actionable new requests:
  ```dart
  for (final p in t.passengers) {
    if (p.isConfirmed || p.isCancelled) continue;
    entries.add(RecentEntry(tour: t, passenger: p));
  }
  ```
  Keep the existing `createdAt` sort + `take(5)`.
- [ ] **Verify:** `flutter analyze` clean. AL-12 is a real behavior change — assert the filter with a small fixture (confirmed + cancelled excluded, pending kept). AL-6/AL-8/AL-11 verify manually: enter `"1.2.3"` in edit-tour price (blocked at keystroke); delete a bus while offline → exactly ONE localized error snackbar; force a group-create failure → a localized error toast (not a silent hang).
- [ ] **Commit:** `fix(admin): price formatter, dedup delete/copy snackbars, group-fail toast, pending-only recent (AL-6/AL-8/AL-11/AL-12)`

---

### Task 6: Tablet max-width clamp for the customer flow (X-9)

**Files:** new `lib/design/components/ugam_max_width.dart` (or add to an existing layout file), `lib/screens/customer_tour_list_screen.dart`, plus the other top-level customer screens listed below.

The admin shell clamps its body to 540 (`main_shell.dart:79,147,175`); the customer flow (pushed screens, no shell) sprawls edge-to-edge on tablets/foldables.

- [ ] Add a shared wrapper mirroring the admin clamp constant:
  ```dart
  class UgamMaxWidth extends StatelessWidget {
    static const double kCustomerMaxWidth = 540;
    final Widget child;
    const UgamMaxWidth({super.key, required this.child});
    @override
    Widget build(BuildContext context) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kCustomerMaxWidth),
        child: child,
      ),
    );
  }
  ```
  Export it from the design barrel (`lib/design/ugam.dart`) alongside the other components.
- [ ] Wrap the body content of the customer-facing top-level screens in `UgamMaxWidth`. Start with `customer_tour_list_screen.dart` (the primary sprawl surface — wrap the content inside `_refreshable`/the scaffold body, not the scroll physics). Then apply to the other pushed customer screens: `customer_my_requests_screen.dart`, `customer_more_screen.dart`, `account_details_screen.dart`. Wrap at the `UgamScaffold` body level so the app bar/background still fill the width but content centers.
- [ ] **Verify:** manual — run in a wide window / tablet emulator; customer home + my-requests + more + account all center at ≤540 with symmetric side gutters, matching the admin shell. Phone widths (<540) are unchanged.
- [ ] **Commit:** `polish(responsive): clamp customer flow to 540 like admin shell (X-9)`

---

### Task 7: Overview/charts loading-state flash (AS-5)

**Files:** `lib/screens/tour_overview_screen.dart`, `lib/screens/charts_screen.dart`

`TourController` has `isLoading` (tour_controller.dart:37) but no `loadedOnce`, so gate the empty/not-found flash on `isLoading` alone.

- [ ] **tour_overview_screen.dart:142-149**: before returning the `tour_overview.tour_not_found` center, show a skeleton while the first fetch is in flight:
  ```dart
  final tour = _ctrl.getTour(widget.tourId);
  if (tour == null) {
    if (_ctrl.isLoading.value) return const UgamSkeleton();
    return Center(child: Text(tr('tour_overview.tour_not_found'), ...));
  }
  ```
  Use the project's existing skeleton widget (`UgamSkeleton` per audit §10; confirm the exact constructor by grepping an existing use, e.g. in finance_screen/`_Loading`).
- [ ] **charts_screen.dart:136-180**: the empty state (`eligible.isEmpty` → `UgamEmpty`) flashes before the first fetch. Gate: `if (eligible.isEmpty) { if (tourCtrl.isLoading.value) return _skeletonWithHeader(); ... existing UgamEmpty ... }`. Keep the `_Header` above the skeleton so the screen chrome doesn't pop.
- [ ] **Verify:** manual — cold-start into a tour overview / charts on a throttled connection; a skeleton shows during the fetch instead of a "not found"/empty flash, then resolves to real data.
- [ ] **Commit:** `fix(admin): skeleton-gate overview/charts first fetch (AS-5)`

---

### Task 8: Seat-assignment & chart-export hardening (AS-6, AS-7, AS-8)

**Files:** `lib/screens/tour_seat_assignment_screen.dart`, `lib/services/seat_chart_pdf.dart`

- [ ] **AS-6** — `tour_seat_assignment_screen.dart`: the seat-chart scroll view reserves a fixed `_kCollapsedDockHeight = 244` at the bottom (line 104, used at 2099-2100), so under large OS text the taller dock hides the legend. Make the reserve text-scale-aware at the padding site (line 2099):
  ```dart
  _kCollapsedDockHeight *
      MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.6) +
      MediaQuery.of(context).padding.bottom,
  ```
  This keeps normal-scale layout identical and grows the reserve up to 1.6× so the legend always clears the dock. The deeper dock re-layout (moving the legend above the fold) is out of scope — note that.
- [ ] **AS-7** — `tour_seat_assignment_screen.dart:1319-1320`: the drop-rejected `tooSmall` toast force-unwraps `_tour!` and `_selectedBus(_tour!)!` inside `namedArgs`, which throws if either is null when the toast fires. Guard with locals resolved earlier in the method:
  ```dart
  final t = _tour;
  final bus = t == null ? null : _selectedBus(t);
  final dragName = (t != null && bus != null) ? (_dragLabelFor(t, bus, fromCell) ?? '') : '';
  ...
  namedArgs: {'name': dragName},
  ```
  Apply the same nil-safe pattern anywhere in this `switch` that force-unwraps `_tour!`/`_selectedBus(_tour!)!` for a toast.
- [ ] **AS-8** — `seat_chart_pdf.dart:126-150`: `buildTourChartPdf` `continue`s past every layout-less bus, so if NO bus has a layout it returns a zero-page `doc.save()` that gets shared as a blank PDF. Track whether any page was added and refuse to emit a blank doc:
  ```dart
  var pageCount = 0;
  for (final bus in buses) {
    final layout = bus.layout;
    if (layout == null) continue;
    ...
    doc.addPage(...);
    pageCount++;
  }
  if (pageCount == 0) {
    throw StateError('no_layouts'); // caller shows a localized warning
  }
  return doc.save();
  ```
  In the caller `_downloadChart` (tour_seat_assignment_screen.dart:1928-1934) the existing `try/catch` already shows `tr('chart.error')` — additionally short-circuit BEFORE generating with a clearer message: at the top of `_downloadChart`, if `!tour.buses.any((b) => b.layout != null)` show `AppSnackBar.warning(tr('chart.no_layouts'))` and return. Add key `chart.no_layouts` (en/gu/hi). Mirror the guard defensively in `shareTourChartA4` is unnecessary once `_downloadChart` gates and `buildTourChartPdf` throws.
- [ ] **Verify:** AS-8 is a real behavior change — unit test `buildTourChartPdf` throws `StateError` when every bus has `layout == null`, and returns non-empty bytes when at least one bus has a layout (reuse existing seat_chart_pdf test fixtures if present; otherwise a minimal Tour with one laid-out bus). AS-6/AS-7 verify manually: max font scale — legend scrolls fully clear of the dock; trigger a too-small drop rejection with no bus selected → localized toast, no crash.
- [ ] **Commit:** `fix(seats): scale dock reserve, nil-safe drop toast, block blank chart PDF (AS-6/AS-7/AS-8)`

---

### Task 9: Money-board labeling + finance refresh feedback (AM-7, AM-8, AM-9, CALC-6 revenue-label alignment)

**Files:** `lib/screens/tour_money_board_screen.dart`, `lib/screens/finance_screen.dart`, `lib/controllers/finance_controller.dart`, translations.

The money board shows a **billed** net headline (`summary.totalNetBilled`, line 209) and a **cash** net capsule (`summary.totalNet`, line 655) both labeled generically "net"; the finance row shows **cash** net (`tf.net`) + a "revenue" subline that is cash-collected, while the board it opens shows **billed** net — no cross-labeling (AM-7, AM-8). The finance controller's `revenue` is cash (received − refunded, finance_controller.dart:67-70), diverging from the P&L "revenue" which is billed (CALC-6 label note).

- [ ] **AM-7** — disambiguate the two board figures:
  - Hero (`_PnlEntryCard`, tour_money_board_screen.dart:209): ensure its caption reads billed — set its label to `tr('tour_money_board.net_billed')`.
  - Capsule (line 654): change `tr('tour_money_board.net')` → `tr('tour_money_board.net_cash')`.
  - Add keys `tour_money_board.net_billed` (en: "NET (BILLED)") and `tour_money_board.net_cash` (en: "NET (CASH)") to en/gu/hi; the existing `tour_money_board.net` may stay if referenced elsewhere, else remove from all three.
- [ ] **AM-8 + CALC-6 revenue label** — `finance_screen.dart:548`: the row subline `tr('finance.row_revenue_value', namedArgs: {'n': _inr(tf.revenue)})` presents a cash figure under a "revenue" label while its net (`tf.net`, line 542) is cash and the board it opens is billed. Relabel the subline to make the basis explicit — add/adjust a key so it reads "collected" rather than ambiguous "revenue" (e.g. `finance.row_collected_value` → "{n} collected"), and keep `tf.net` labeled as the trip's cash net. This aligns the "revenue" semantics: finance screen = CASH/collected; money board hero = BILLED. Update en/gu/hi.
- [ ] **AM-9** — `finance_controller.dart` load (`catch` at lines 120-125): on a refresh failure AFTER the first success, `loadFailed` is set but the screen's error branch is gated `loadFailed && !loadedOnce` (finance_screen.dart:89), so a failed pull-to-refresh is completely silent. Surface it: inside the `catch`, when already loaded, warn instead of silently keeping stale data:
  ```dart
  } catch (e, st) {
    dev.log('finance load failed: $e\n$st', name: 'FinanceController');
    loadFailed.value = true;
    if (loadedOnce.value) {
      AppSnackBar.warning(tr('errors.refresh_showing_saved')); // existing key
    }
  }
  ```
  Reuse the existing `errors.refresh_showing_saved` key (already used by TourController, tour_controller.dart:415). Add the `AppSnackBar`/`easy_localization` imports to the controller if not present.
- [ ] **Verify:** `flutter analyze` clean; visual check that the money board now reads "NET (BILLED)" up top and "NET (CASH)" in the capsule, and the finance row subline reads "collected". AM-9: force a reload failure after first load (throw in a test double or offline) → a warning snackbar appears rather than silence.
- [ ] **Commit:** `fix(money): label billed vs cash net, collected revenue, surface refresh failures (AM-7/AM-8/AM-9)`

---

### Task 10: Notify driver-phone affordance (AM-10)

**Files:** `lib/screens/notify_screen.dart`

`_BusInfo.driverPhone` is resolved (line 685) and plumbed into `_HeroSummaryCard` but never rendered — the driver `_InfoCell` (lines 919-926 shows `handler`; the driver name is at 911-916) is a dead affordance.

- [ ] Make the driver `_InfoCell` (label `notify.info_driver`, value `busInfo.driverName`, lines 911-916) tap-to-dial when a phone is present. Wrap it so a non-null `busInfo.driverPhone` becomes actionable, reusing the app's `PhoneDialer` (used in tour_detail_screen.dart:1550):
  ```dart
  Expanded(
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: busInfo.driverPhone == null
          ? null
          : () => PhoneDialer.call(busInfo.driverPhone!),
      child: _InfoCell(
        c: c,
        icon: busInfo.driverPhone == null ? Icons.badge_outlined : Icons.call_rounded,
        label: tr('notify.info_driver'),
        value: busInfo.driverName,
      ),
    ),
  ),
  ```
  Import `PhoneDialer` from wherever tour_detail imports it. If wiring a tap is deemed too much, the alternative is to remove the unused `driverPhone` field entirely — but rendering it is the better close since the operator often needs to call the driver from this screen.
- [ ] **Verify:** manual — open Lock & Notify for a tour whose bus has a driver phone; tapping the driver cell opens the dialer. A bus with no driver phone shows the plain (non-tappable) cell.
- [ ] **Commit:** `fix(notify): tap-to-call driver from hero card (AM-10)`

---

### Task 11: Handler polish & docs (H-9, H-10, H-11, H-12)

**Files:** new `lib/utils/money_input_formatter.dart`, `lib/screens/handler_bus_chart_screen.dart`

- [ ] **H-9** — the collect fields (received/returned at 1931-1943, plus the expense/income amount fields at ~2381 and ~2732) use `FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))`, which permits multi-dot input like `"1.2.3"` → `double.tryParse` returns null → silently 0. Add a shared single-decimal formatter and use it on all three money fields:
  ```dart
  // lib/utils/money_input_formatter.dart
  import 'package:flutter/services.dart';
  class MoneyInputFormatter extends TextInputFormatter {
    static final _re = RegExp(r'^\d*(\.\d{0,2})?$');
    @override
    TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
        _re.hasMatch(newValue.text) ? newValue : oldValue;
  }
  ```
  Replace each field's `inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]` with `inputFormatters: [MoneyInputFormatter()]` at lines 1931-1943, ~2381, ~2732. A second dot / third decimal can no longer be typed, so no silent-zero parse.
- [ ] **H-10** — `handler_bus_chart_screen.dart:599-609`: the bus-broadcast partial-failure warning shows counts but not WHO failed. `WaSendResult.results` is a `List<WaRecipientResult>` each with `.ok` (whatsapp_cloud_service.dart:182-191). Enrich the `else if (result.anySent)` branch to list the failed recipients so the operator can follow up manually — append the failed names/numbers to the warning body (or open a short read-back sheet built from `result.results.where((r) => !r.ok)`). A true "resend to failed" is out of scope: the `bus-message` edge function loads phones server-side by bus and has no failed-subset target, so a partial resend isn't supported — say so in the commit body. Add any new key (e.g. `bus_message.partial_failed_list`) to en/gu/hi if you render a list.
- [ ] **H-11** — empty-seat tap feedback. Grid tiles pass `onTapBooked: null` for empty seats (line 1005-1007), and `_onSeatTapped` early-returns on `occupants.isEmpty` after a haptic (line 312-313). Decide and document: for the handler view an empty seat has nothing to collect, so a silent no-op is intentional. Make that explicit rather than a mystery dead gesture — either (a) leave the tiles non-tappable and add a one-line comment at 1005-1007 (`// Empty seats are non-actionable in the handler view — no collect target.`), or (b) if a tap DOES reach `_onSeatTapped` for empty seats, replace the bare `return` at line 313 with a brief neutral toast `AppSnackBar.info(tr('handler_chart.seat_empty'))` (add key to en/gu/hi) then `return`. Verify which path is live first; prefer (a) if empty tiles are truly non-tappable.
- [ ] **H-12 (docs only)** — `handler_bus_chart_screen.dart:73-74` comment says the collection cache is keyed by `'"$passengerId|$busId"'`, but `_collectionKey` (lines 96-97) appends `|$seatId`. Reconcile the comment with whatever the code says AT EXECUTION TIME (Phase 2's H-3 may have dropped `seatId`): if the key still includes `seatId`, fix the comment to `'"$passengerId|$busId|$seatId"'`; if H-3 removed it, the comment already matches — leave it. No behavior change.
- [ ] **Verify:** H-9 is a real behavior change — unit test `MoneyInputFormatter` (rejects `"1.2.3"`, `"1.234"`, `".."`; accepts `"12"`, `"12.5"`, `"12.50"`, `""`). H-10/H-11/H-12 verify manually / by reading the diff.
- [ ] **Commit:** `fix(handler): single-decimal money input, list failed broadcasts, empty-seat clarity, doc drift (H-9/H-10/H-11/H-12)`

---

### Task 12: Collection shortfall epsilon (CALC-3)

**Files:** `lib/screens/collection_screen.dart`

Raw `< 0` comparisons skip the shared ±0.005 money epsilon (`Collection.kMoneyEpsilon`, collection.dart:49), so dust-negative balances show a "Mark paid ₹0".

- [ ] **collection_screen.dart:105** (`_passesFilter`, "To collect" case): replace `return col == null || col.balance < 0;` with the epsilon-aware form using the line's due:
  ```dart
  case 2: // To collect
    return col == null
        ? line.due > Collection.kMoneyEpsilon
        : col.isShortfall;
  ```
  (`_SeatCollectionLine.due` exists, collection_screen.dart:430; `Collection.isShortfall => balance < -kMoneyEpsilon`.)
- [ ] **collection_screen.dart:624**: replace `final isShortfall = balance < 0;` with `final isShortfall = col?.isShortfall ?? (due > Collection.kMoneyEpsilon);`. Leave the `balance`/`shortfall` locals above (used for display) unchanged.
- [ ] Confirm `Collection` is imported in collection_screen.dart (it uses `col`, so it is; `Collection.kMoneyEpsilon` is a static const on the same type).
- [ ] **Verify:** unit/widget assertion or manual — a rider whose balance is `-0.004` (dust) is no longer in the "To collect" filter and does not show a "Mark paid ₹0" chip; a rider owing ≥ ₹0.01 still does.
- [ ] **Commit:** `fix(money): epsilon-aware shortfall in collection filter/row (CALC-3)`

---

### Task 13: Controller state contract + iOS privacy prune (X-12, X-11)

**Files:** `lib/controllers/inbox_controller.dart`, `lib/controllers/pickup_controller.dart`, `lib/screens/pickup_locations_screen.dart`, `ios/Runner/PrivacyInfo.xcprivacy`

- [ ] **X-12 (PickupController)** — it has `loadedOnce` but no `isLoading`/error flag, so pickup_locations_screen can't render the shared error/retry state. Add fields matching the repo convention (finance_controller uses `isLoading`/`loadedOnce`/`loadFailed`):
  ```dart
  final RxBool isLoading = false.obs;
  final RxBool loadFailed = false.obs;
  ```
  In `refresh()` (pickup_controller.dart:57-76) set `isLoading.value = true; loadFailed.value = false;` at the top; on `catch` set `loadFailed.value = true;`; in `finally` set `isLoading.value = false;` (keep `loadedOnce.value = true;`).
- [ ] **X-12 (InboxController)** — it has `loading` but no error flag. Add `final RxBool loadFailed = false.obs;`; in the stream `onError` (inbox_controller.dart:47-51) set `loadFailed.value = true;` and in the data callback (line 42-46) set `loadFailed.value = false;` on a successful emit. (Realtime reconnects, so this is a soft flag.)
- [ ] Wire the shared error/retry state into `pickup_locations_screen.dart`'s list gate (around line 261, the `!loadedOnce && all.isEmpty` skeleton branch): add `if (_ctrl.loadFailed.value && _ctrl.all.isEmpty) return UgamEmpty.error(onRetry: _ctrl.refresh);` (use the project's `UgamEmpty.error` shape — grep an existing use for the exact params). InboxScreen wiring is optional this phase; adding the flag unblocks it.
- [ ] **X-11** — `ios/Runner/PrivacyInfo.xcprivacy:66-74`: remove the stale `NSPrivacyAccessedAPICategoryFileTimestamp` dict (reason `C617.1`) — it cited sqflite/path_provider, which were removed. Delete lines 66-74 (the whole second `<dict>`), leaving the `NSPrivacyAccessedAPICategoryUserDefaults` entry for shared_preferences. Keep the surrounding `<array>`/`<dict>`/`<plist>` well-formed.
- [ ] **Verify:** `flutter analyze` clean; pickup screen shows a retry state when its fetch fails (simulate offline). `plutil -lint ios/Runner/PrivacyInfo.xcprivacy` (or a plist parse) confirms valid XML after the deletion.
- [ ] **Commit:** `chore(state,ios): add loading/error flags to inbox+pickup controllers, prune stale privacy reason (X-12/X-11)`

---

### Task 14: Untested-branch coverage — money_summary + tour_finance (CALC-6)

**Files:** `test/models/money_summary_test.dart` (extend), new `test/models/tour_finance_test.dart`. No production code changes; CALC-5 is an accepted trade-off (see below).

- [ ] **CALC-6a (BusMoneySummary seated-uncollected branch, money_summary.dart:103-117)** — extend `test/models/money_summary_test.dart` with cases for `BusMoneySummary.compute` when `dueForSeat` is supplied:
  - A passenger seated on the bus with NO collection row adds their full seat fare to `toCollectTotal` (via `dueForSeat`), across multiple assigned seats on that bus.
  - A passenger who HAS any collection row on the bus is skipped (seat-agnostic) — no double count on top of the recorded shortfall.
  - When `dueForSeat` is null, `toCollectTotal` equals the recorded-shortfall sum alone.
  Write these RED-first against the real `BusMoneySummary.compute` signature (busId, collections, expenses, handovers, incomes, busRent, revenueBilled, passengers, dueForSeat).
- [ ] **CALC-6b (TourFinance / FinanceTotals folds, tour_finance.dart)** — create `test/models/tour_finance_test.dart`:
  - `TourFinance.net == revenue + income - expenses`; `isProfit == net >= 0` (including the boundary net == 0).
  - `TourFinance.from(tour, revenue, expenses, income:)` maps `date = returnDate ?? departureDate`, `isCompleted`, `passengers`, `buses` correctly.
  - `FinanceTotals.from([...])` sums revenue/expenses/income across rows, picks `best`/`worst` by `net`, sets `tourCount`, and `avgNet == net / tourCount`; `FinanceTotals.from([])` returns `FinanceTotals.empty`.
  These are pure value objects — no Localization/GetX setup needed.
- [ ] **CALC-6c (revenue label semantics)** — the actual label alignment ships in Task 9 (AM-8). Here, add a short assertion/comment locking the intent: `TourFinance.revenue` is CASH collected (received − refunded), distinct from the money board's BILLED revenue. A doc comment already states this (tour_finance.dart:6-11); reference it in the test file header so a future edit doesn't silently re-conflate them.
- [ ] **CALC-5 (accepted, no code change)** — per-seat rounding can let two half-payers of a shared double exceed the whole-double price by ₹1 on odd prices (bus_details.dart:561). This is a documented trade-off (audit §5). Do NOT change code; add a one-line note in the tour_finance/money test file (or a code comment at bus_details.dart:561 if none exists) recording that this ±₹1 is accepted so it isn't "fixed" into a regression later.
- [ ] **Verify:** `flutter test test/models/money_summary_test.dart test/models/tour_finance_test.dart` — all green. Run the full suite once (`flutter test`) to confirm no collateral breakage.
- [ ] **Commit:** `test(money): cover seated-uncollected + TourFinance/FinanceTotals folds; note CALC-5 trade-off (CALC-6)`

---

## Done criteria
- `flutter analyze` clean (no new info/warns beyond the pre-existing 6).
- `flutter test` green.
- All 23 §5 low findings addressed: fixed (C-1/2/3/4/5/6/7, AL-5/6/7/8/9/11/12, AS-5/6/7/8, H-9/10/11/12, AM-7/8/9/10, CALC-3, X-9/10/11/12), verified-no-change (AL-10), or documented-accepted (CALC-5). CALC-6 branches now covered by tests.
- Every new user-facing string added to en/gu/hi in sync.
