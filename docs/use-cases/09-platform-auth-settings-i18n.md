# 09 — Platform: Auth / Login, Setup, Settings, Notifications, Legal, Language, Roles

Cross-cutting use cases for the app's foundation surfaces: cold-start/splash routing, admin
login (phone + password), the admin-setup explainer, account/notification settings, theme,
language switch (en/gu/hi live re-render), legal documents, FCM push gating, logout, and the
admin-vs-customer role split.

**Key architecture facts (verified in code):**

- **Auth is admin-only.** `AuthController.submitPhone()` looks the phone up in the `admins`
  table. A registered number reveals a password step; an **unregistered number is rejected**
  with "number not registered" — it does NOT create a passenger session at login. The customer
  experience is the *default* app entry (`/customer-home`), reached without ever logging in.
- **Roles:** `UserRole { admin, handler, passenger }` exists in `lib/models/profile.dart`, but
  the auth layer only ever assigns `admin` (on login) or `passenger` (everyone else / logged
  out). There is **no handler login** — "handler" is a per-tour appointment, not an auth
  identity. So in this cross-cutting area, a handler authenticates as a customer/passenger.
- **Session persistence** (`SharedPreferences`): only an **admin** session is restored. Any
  non-admin or stale state is purged on boot, including a best-effort local Supabase sign-out
  so customer browse runs as `anon` (otherwise RLS hides other admins' public tours).
- **Splash routing waits on real auth state** (`auth.whenRestored`), then sends a logged-in
  admin to `/` (MainShell) and everyone else to `/customer-home`.
- **Locale** is persisted by easy_localization; default/fallback/start locale is **Gujarati
  (`gu`)**. Supported order in pickers: gu, en, hi. `LocaleController.setLocale` pushes the
  change through `context.setLocale` + `Get.updateLocale` + the reactive `currentLocale`.
- **Theme** is tri-state (system/light/dark), persisted; **dark is the default** for fresh
  installs.
- **Push** is admin-only and best-effort. Token register/unregister flows through
  `PushService`. Per-admin toggles live in Notifications settings and are mirrored to the
  `admins` row.

**Notable findings flagged to the assembler (see end of file):** a TEMP diagnostic that leaks
the synthetic admin email on a failed sign-in, and a push deep-link tab-index mismatch that
lands on the wrong tab.

---

### UC-09PLATFORMAUTHSETTINGSI18N-1: Cold start restores a logged-in admin to the admin home
- **Actor:** admin
- **Phase:** Cross-cutting (app launch)
- **Preconditions:** App previously logged in as admin (prefs `auth_phone`, `auth_role=admin`, `auth_name` present); device may be online or offline.
- **Steps:**
  1. Fully kill the app, then relaunch it.
  2. Observe the very first frame (pre-init bootstrap splash), then the branded `SplashScreen`.
  3. Wait for routing.
- **Expected:**
  - First frame shows the bootstrap splash (logo only, no text — localization not yet ready), then `SplashScreen` shows logo + `splash.brand_name` + `splash.tagline`.
  - Splash holds for a short minimum (~450 ms) AND until `auth.whenRestored` completes — it does NOT route on a fixed timer.
  - App lands on `/` (MainShell), Home (Dashboard) tab selected; admin name/initials appear in Settings.
  - If online and the Supabase session is valid, `currentAdmin` hydrates (push re-armed if `pushEnabled`, contacts/tours reloaded). If offline, the admin still lands on admin home (hydrates on next online action).
- **Edge cases:**
  - Slow cold start: must still land on admin home, NOT customer home (this was the "opens on a random screen" race the `whenRestored` completer fixes).
  - Supabase session lost but prefs still say admin: lands on admin home but `currentAdmin` is null until re-auth/online; screens reading `currentAdmin` (e.g. Account Details `_save`) show "no admin" guards.
  - Android Auto-Backup restore after reinstall: a lingering Supabase auth session is purged on boot if prefs are not a valid admin.
- **Screens/files:** `lib/main.dart`, `lib/screens/splash_screen.dart`, `lib/controllers/auth_controller.dart` (`_restoreSession`, `whenRestored`), `lib/app.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-2: Cold start with no admin session lands on customer home
- **Actor:** customer (passenger)
- **Phase:** Cross-cutting (app launch)
- **Preconditions:** Fresh install OR previously logged out OR non-admin/stale prefs.
- **Steps:**
  1. Launch the app on a device with no persisted admin session.
  2. Observe splash, then routing.
- **Expected:**
  - Splash shows, then app routes to `/customer-home` (`CustomerTourListScreen`) — the public "explore tours" experience.
  - On boot, any stale prefs (`auth_phone/role/name`) are removed and a best-effort `signOut(scope: local)` runs so browse is `anon` (so RLS does not hide other admins' public tours → no false "no tours").
  - No login screen is shown automatically; login is reachable only via the hidden long-press (see UC-3).
- **Edge cases:**
  - Prefs contain a phone but role is `passenger` (stale): treated as non-admin → purged, customer home.
  - Offline: local sign-out still works (`SignOutScope.local`, no network round-trip); still lands on customer home.
- **Screens/files:** `lib/screens/splash_screen.dart`, `lib/controllers/auth_controller.dart` (`_restoreSession`, `_purgeStaleAuthSession`), `lib/screens/customer_tour_list_screen.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-3: Admin reaches login via the hidden long-press entry
- **Actor:** admin
- **Phase:** Cross-cutting (auth entry)
- **Preconditions:** On `/customer-home` (explore tours). Login route is otherwise unlinked.
- **Steps:**
  1. On the customer explore-tours screen, long-press the "Explore" header title (`customer_tour_list.header_explore`).
  2. Feel the medium haptic; observe navigation to `/login`.
- **Expected:**
  - Login screen (`LoginScreen`) opens, pushed onto the stack (it can pop here, so a close `X` button appears top-left).
  - Brand block (logo on copper halo, "UGAM" wordmark, `login.tagline`), phone input (`login.phone_label`), terms (`login.terms`), and a primary CTA (`app.action.continue_`).
- **Edge cases:**
  - LoginScreen as ROOT (when it is the first route, e.g. legacy path): `Navigator.canPop` is false, so NO close button appears (user is not stranded vs. not given a dead "back").
  - Tapping anywhere outside a field dismisses the keyboard (iOS numeric keyboard has no Done key); the CTA sits above the keyboard via `UgamStickyCTA`.
- **Screens/files:** `lib/screens/customer_tour_list_screen.dart` (long-press → `AppRoutes.login`), `lib/screens/login_screen.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-4: Admin logs in successfully (phone → password two-step)
- **Actor:** admin
- **Phase:** Cross-cutting (auth)
- **Preconditions:** On `LoginScreen`; the entered phone is a registered admin in the `admins` table; correct password known; online.
- **Steps:**
  1. Enter the 10-digit admin phone in the phone field.
  2. Tap `Continue` (`app.action.continue_`) / submit the phone field.
  3. When the password step slides open, enter the admin password.
  4. Tap `Sign in` (`login.btn_sign_in`) / submit the password field.
- **Expected:**
  - After step 2: `submitPhone()` finds the admin, reveals the animated password sub-form with `login.password_label` / `login.password_hint`, and shows `login.signing_in_as` with the admin's name. CTA label flips to `login.btn_sign_in`.
  - After step 4: `verifyAdminPassword()` → Supabase Auth sign-in succeeds → `_loginAsAdmin` sets role=admin, persists session, reloads tours, ensures contacts, registers push if `pushEnabled`, and `Get.offAllNamed('/')` lands on MainShell (Home).
  - Loading spinner on the CTA during both async steps (`isLoading`).
- **Edge cases:**
  - Phone < 10 digits on Continue: inline error `errors.phone_invalid`; no lookup.
  - Editing the phone after the password step is open auto-cancels the password step (`cancelAdminPassword`), letting the user switch numbers without a dedicated button.
  - Empty password on Sign in: `errors.enter_admin_password`; no network call.
  - `pendingAdmin` somehow null at verify time: password step silently closes (guard).
- **Screens/files:** `lib/screens/login_screen.dart`, `lib/controllers/auth_controller.dart` (`submitPhone`, `verifyAdminPassword`, `_loginAsAdmin`), `lib/services/admin_auth_service.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-5: Non-admin phone is rejected at login (admin-only gate)
- **Actor:** customer (passenger) / would-be user
- **Phase:** Cross-cutting (auth, role gating)
- **Preconditions:** On `LoginScreen`; entered phone is NOT in the `admins` table.
- **Steps:**
  1. Enter a valid-length (10-digit) but non-admin phone.
  2. Tap `Continue`.
- **Expected:**
  - `submitPhone()` finds no admin → error snackbar `errors.number_not_registered` with title `errors.access_denied`.
  - The password step does NOT open; NO session is created; user remains on `LoginScreen` (and can close back to customer home).
  - There is no password-less passenger login — confirms the app is admin-login-only and customers never authenticate.
- **Edge cases:**
  - Network/lookup failure during `findByPhone`: error `errors.verify_phone` (with `{e}`) titled `errors.connection_error`; user can retry.
  - The same phone later promoted to admin in Supabase: must succeed on next attempt (no client cache of the negative result).
- **Screens/files:** `lib/screens/login_screen.dart`, `lib/controllers/auth_controller.dart` (`submitPhone`)

---

### UC-09PLATFORMAUTHSETTINGSI18N-6: Wrong password on sign-in surfaces an error
- **Actor:** admin
- **Phase:** Cross-cutting (auth)
- **Preconditions:** Registered admin phone entered, password step open; wrong password typed; online.
- **Steps:**
  1. Enter an incorrect password.
  2. Tap `Sign in`.
- **Expected:**
  - `verifyAdminPassword()` throws `AuthException`; an error snackbar appears titled `errors.sign_in_failed`.
  - User stays on the password step; can retry without re-entering the phone.
  - CTA spinner clears (`isLoading=false`) after the failure.
- **Edge cases:**
  - **KNOWN ISSUE (TEMP DIAGNOSTIC):** the error body appends `\n[debug] trying: <synthetic email>` — it leaks the synthetic email mapping to the end user. This is a hard-coded English `[debug]` string (not localized) and should be removed before release. See notable findings.
  - Non-Auth exception (connectivity): error `errors.sign_in` (with `{e}`) titled `errors.connection_error`.
  - Offline at sign-in: connection error; no session created.
- **Screens/files:** `lib/screens/login_screen.dart`, `lib/controllers/auth_controller.dart` (`verifyAdminPassword`)

---

### UC-09PLATFORMAUTHSETTINGSI18N-7: Admin-setup explainer — request access / contact support
- **Actor:** customer (prospective admin)
- **Phase:** Cross-cutting (onboarding)
- **Preconditions:** `AdminSetupScreen` reachable (route `/admin-setup`). Note: post-Supabase, admin accounts are provisioned via the Supabase dashboard, so this screen is a static explainer card (NOT a self-serve signup).
- **Steps:**
  1. Open the Admin Setup screen.
  2. Read `admin_setup.support_heading` / `admin_setup.support_body`.
  3. Tap the support email chip (or the `admin_setup.btn_contact_support` CTA) to open the mail app.
  4. Long-press the email chip to copy it instead.
- **Expected:**
  - Tapping the chip/CTA launches the device mail client with `mailto:support@ugambooking.com` and subject "Admin Access Request".
  - Long-press copies `support@ugambooking.com` to the clipboard and shows info snackbar `admin_setup.email_copied` (with `{email}`).
  - Back arrow returns to the previous screen.
- **Edge cases:**
  - No mail app / `launchUrl` returns false or throws: error snackbar `admin_setup.mail_unavailable_title` + `admin_setup.mail_unavailable_body` (with `{email}`) — user can still copy the address.
  - The support email is a hard-coded constant (`support@ugambooking.com`), not localized — only the surrounding copy is translated.
- **Screens/files:** `lib/screens/admin_setup_screen.dart`, `lib/utils/app_snackbar.dart`, `lib/routes/app_routes.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-8: Admin edits account details (name / business / read-only phone)
- **Actor:** admin
- **Phase:** Cross-cutting (settings)
- **Preconditions:** Logged in as admin; Settings tab open; online.
- **Steps:**
  1. Settings → Account details (`settings.account_details_title`).
  2. Edit the name, business name, and business email fields.
  3. Tap Save (`settings_pages.save`).
- **Expected:**
  - Fields prefill from `currentAdmin` (name falls back to `userName` if admin name empty); the **phone is shown read-only** in a locked row with a lock icon and `+91` prefix, plus hint `settings_pages.account.phone_hint` ("can't be changed from the app").
  - On save: `saveAdmin()` persists to the `admins` table, mirrors into `currentAdmin`/`userName` (so the Settings hero + initials update immediately via Obx), success snackbar `settings_pages.saved`, screen pops back.
- **Edge cases:**
  - Empty name on save: error `settings_pages.account.name_required`; not saved.
  - `currentAdmin` null (e.g. offline cold start without hydration): error `settings_pages.no_admin`.
  - Save throws (network): error `settings_pages.save_error`, unsaved edits remain on screen, screen does NOT pop.
- **Screens/files:** `lib/screens/account_details_screen.dart`, `lib/controllers/auth_controller.dart` (`saveAdmin`), `lib/widgets/settings_scaffold.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-9: Admin manages notification preferences + master push gate
- **Actor:** admin
- **Phase:** Cross-cutting (settings / notifications)
- **Preconditions:** Logged in as admin; Settings → Notifications open; online.
- **Steps:**
  1. Settings → Notifications (`settings.notifications_title`).
  2. Toggle the master Push switch (`settings_pages.notifications.push_label`).
  3. Toggle the dependent alerts: Booking requests, Payment reminders, Departure reminders.
  4. Tap Save.
- **Expected:**
  - Initial toggle values come from `currentAdmin` (all default true when fields are null).
  - When the master Push switch is OFF, the three dependent rows are disabled (not toggleable) and show inline hint `settings_pages.notifications.turn_on_hint` instead of their subtitle; the Switch is the only colour signal.
  - On save: `saveAdmin()` persists the four flags to the `admins` row; if push is ON → `PushService.register()` (prompts OS permission + stores FCM token); if OFF → `PushService.unregister()` (drops the token). Success snackbar `settings_pages.saved`, pops back.
- **Edge cases:**
  - `currentAdmin` null: error `settings_pages.no_admin`.
  - Turning push ON triggers the OS permission prompt; if the user denies it, registration quietly no-ops (no crash) — but the saved preference still says ON (server may still target a device with no token).
  - Save failure: error `settings_pages.save_error`; toggles remain; no pop.
  - Only `booking_request` push type is actually delivered today (payment/departure reminders are wired as preferences but not yet sent).
- **Screens/files:** `lib/screens/notifications_settings_screen.dart`, `lib/services/push_service.dart`, `lib/controllers/auth_controller.dart` (`saveAdmin`)

---

### UC-09PLATFORMAUTHSETTINGSI18N-10: Admin changes app theme (system / light / dark)
- **Actor:** admin
- **Phase:** Cross-cutting (settings / appearance)
- **Preconditions:** Logged in as admin; Settings tab open.
- **Steps:**
  1. In the Appearance section, tap one of the three theme segments: System / Light / Dark (`settings.theme_system`/`theme_light`/`theme_dark`).
- **Expected:**
  - The whole app re-themes immediately (`Get.changeThemeMode`); the segmented picker shows the new selection with a selection-click haptic.
  - Choice persists across restarts (`themeMode` in SharedPreferences); legacy `isDarkMode` bool kept in sync.
  - Fresh installs default to **Dark**.
- **Edge cases:**
  - System mode: app follows OS brightness; flipping the OS theme at runtime re-themes screens that read `MediaQuery`/`Theme.of`, though `isDarkMode`-only call sites may lag until next rebuild (documented limitation).
  - Legacy users with only the old `isDarkMode` bool stored are migrated to the matching tri-state on first load.
- **Screens/files:** `lib/screens/settings_screen.dart` (`_ThemeTriPicker`), `lib/controllers/theme_controller.dart`, `lib/app.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-11: Language switch re-renders the app live (en / gu / hi)
- **Actor:** admin or customer
- **Phase:** Cross-cutting (i18n)
- **Preconditions:** App running in any locale. Admin path: Settings → Language. Customer path: More → Language.
- **Steps:**
  1. Open the language picker (`language.pick_title`).
  2. Tap a language: ગુજરાતી (gu) / English (en) / हिंदी (hi).
- **Expected:**
  - Each option is labelled in its own script (so a user can find their language regardless of current display language); the active one shows the accent fill + checkmark radio.
  - On tap: `LocaleController.setLocale` runs `context.setLocale` + `Get.updateLocale` + updates `currentLocale`; the sheet closes and the entire app (incl. Material chrome: date pickers, tooltips) re-renders in the new language **without a restart**.
  - Choice persists across restarts (easy_localization SharedPreferences).
  - On the customer More screen, the Language row subtitle updates to the new active-language label on return.
- **Edge cases:**
  - Default/fallback/start locale is **Gujarati** (`gu`) — a first launch on an unsupported device locale shows Gujarati, not English.
  - Picker order is fixed: gu, en, hi.
  - Switching away from a language must not leave any hard-coded English fragment on the surfaces in this area — note the `[debug]` string in UC-6 is the one un-localized user-facing string found.
  - `LocaleController` is auto-registered if missing when the sheet opens.
- **Screens/files:** `lib/widgets/language_picker_sheet.dart`, `lib/controllers/locale_controller.dart`, `lib/config/i18n_config.dart`, `lib/screens/settings_screen.dart`, `lib/screens/customer_more_screen.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-12: Customer reads legal documents (About / Privacy / Terms)
- **Actor:** customer
- **Phase:** Cross-cutting (legal)
- **Preconditions:** On the customer "More" screen (opened from the explore-tours top bar). No account required.
- **Steps:**
  1. More → About (`customer_more.about`), or Privacy (`customer_more.privacy`), or Terms (`customer_more.terms`).
  2. Read the document; scroll long-form content.
  3. Back to return.
- **Expected:**
  - The chosen `LegalDoc` renders natively in the Ugam dark-first style (title, optional logo for About, meta line, and section/sub/paragraph/boxed-callout/bullet blocks) — not an embedded off-theme web page.
  - Each row opens with a selection haptic and a cupertino transition.
  - App bar back returns to More.
- **Edge cases:**
  - About shows the logo + centered header (`doc.showLogo`); Privacy/Terms are left-aligned with no logo.
  - Legal docs are only reachable from the CUSTOMER More screen — the admin Settings list does NOT expose About/Privacy/Terms (admin sees Account/Notifications/Language only). Note for testers: legal is a customer-surface, confirm it is intentionally absent from admin Settings.
  - The boxed-callout paragraph variant renders on a soft card surface.
- **Screens/files:** `lib/screens/customer_more_screen.dart`, `lib/screens/legal_document_screen.dart`, `lib/content/legal_content.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-13: Admin logs out (confirm → push unregister → splash → customer browse)
- **Actor:** admin
- **Phase:** Cross-cutting (auth / session end)
- **Preconditions:** Logged in as admin; Settings tab open.
- **Steps:**
  1. Settings → Log out danger row (`settings.logout`).
  2. Confirm in the destructive dialog (`settings.logout_confirm_message`).
- **Expected:**
  - A confirm dialog appears (destructive styling). On confirm:
    - `PushService.unregister()` runs FIRST (while the Supabase session is still live, since the delete RPC is scoped by `auth.uid()`), dropping this device's token.
    - `AdminAuthService.signOut()`, then local prefs/state cleared (`_clearSessionLocally`): role → passenger, name/phone cleared, `UserController.reset()`, tours re-scoped to public.
    - `Get.offAllNamed('/splash')` → splash → routes to `/customer-home` (now an anonymous viewer).
- **Edge cases:**
  - Cancel the dialog: nothing changes; stays logged in.
  - Offline logout: sign-out is best-effort; local state is still cleared so the user is logged out client-side and browses as anon (a lingering server session is purged on next boot).
  - After logout, re-opening the app routes to customer home (UC-2), confirming the session did not persist.
- **Screens/files:** `lib/screens/settings_screen.dart` (`_DangerRow`), `lib/controllers/auth_controller.dart` (`logout`, `_clearSessionLocally`), `lib/services/push_service.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-14: Admin-only surfaces are hidden from the customer (role gating)
- **Actor:** customer vs admin
- **Phase:** Cross-cutting (role gating)
- **Preconditions:** One device browsing as customer (no login), one logged in as admin.
- **Steps:**
  1. As customer, explore the app: confirm available surfaces.
  2. As admin, open the bottom dock and Settings.
- **Expected:**
  - **Customer** sees: explore tours, my-requests, find-my-seat, language, legal/about, support — and NO admin dock, NO Settings profile/finance, NO create-tour/seat-assignment/money. The only path to admin is the hidden long-press (UC-3).
  - **Admin** sees the 5-tab dock: Home, Tours, Charts, Requests (with live NEW-request badge), Settings (`main_shell.tab_*`). Settings exposes profile hero with `settings.admin_badge`, lifetime P&L card, Account/Notifications/Language, theme picker, and logout.
  - Push notifications are admin-only; a customer never registers an FCM token or receives booking alerts.
- **Edge cases:**
  - `UserRole.handler` exists in the enum but is never assigned at auth — a handler signs in as a customer/passenger and has no admin surfaces; their on-trip duties are granted per-tour, not via login. Tester note: do NOT expect a "handler login".
  - The Requests badge count (`pendingRequestCount`) is reactive and only meaningful for the admin who owns the tours.
- **Screens/files:** `lib/screens/main_shell.dart` (dock, `buildAdminDockItems`), `lib/controllers/auth_controller.dart` (`isAdmin`/`isPassenger`), `lib/models/profile.dart`, `lib/screens/customer_tour_list_screen.dart`

---

### UC-09PLATFORMAUTHSETTINGSI18N-15: Tapping a booking-request push notification deep-links into the app
- **Actor:** admin
- **Phase:** Cross-cutting (notifications / deep-link)
- **Preconditions:** Logged in as admin with push enabled and OS permission granted; a `booking_request`-typed push arrives (foreground, background, or app-killed).
- **Steps:**
  1. Receive a "new booking request" notification.
  2. Tap it (from tray when backgrounded/killed, or the heads-up banner on Android foreground).
- **Expected:**
  - The app comes to the foreground; if not already on `/` it navigates to MainShell, then selects a dock tab to show the booking request.
  - Android foreground: the message is drawn via local notifications (`booking_requests` channel) so it isn't silently dropped; iOS foreground banner is shown by the OS (no duplicate).
  - Cold launch from a tapped notification deep-links after first frame (`getInitialMessage`).
- **Edge cases:**
  - **KNOWN BUG (tab-index mismatch):** `PushService._requestsTabIndex = 2`, but in `main_shell.dart` `_adminPages` is `[Dashboard(0), Tours(1), Charts(2), Requests(3), Settings(4)]`. So the deep-link selects **Charts (index 2)**, NOT the Requests inbox (index 3). The PushService comment also describes a stale 4-tab layout that omits Charts. See notable findings.
  - Non-`booking_request` type: tap is ignored (no navigation).
  - Push permission denied or `pushEnabled=false`: no token is registered, so no alert/tap path at all.
  - All push titles/bodies originate server-side (send-push Edge Function) — they are NOT localized by the app's en/gu/hi assets.
- **Screens/files:** `lib/services/push_service.dart` (`_handleTapType`, `_onForegroundMessage`, `init`), `lib/screens/main_shell.dart` (`ShellController.switchTab`, `_adminPages`)

---

### UC-09PLATFORMAUTHSETTINGSI18N-16: Back/exit behavior in the admin shell (PopScope tab handling)
- **Actor:** admin
- **Phase:** Cross-cutting (navigation)
- **Preconditions:** Logged in as admin on MainShell.
- **Steps:**
  1. From Home (tab 0), press the system back gesture/button.
  2. Switch to another tab (e.g. Requests) and press back.
  3. Drill into a pushed screen within a tab, then press back.
- **Expected:**
  - On Home with nothing pushed: back exits the app (`canPop` true at root).
  - On a non-Home tab with nothing pushed: back returns to Home tab 0 (does not exit).
  - With a pushed inner screen: back pops that inner route first (per-tab nested Navigator), not the whole app.
  - Tabs are lazy-mounted: only visited tabs build/observe state (Home always mounted); revisiting a tab preserves its scroll/selection state.
- **Edge cases:**
  - Deep-link from push (UC-15) forces tab selection after the shell mounts (`addPostFrameCallback`), independent of the back stack.
  - Wide screens (tablet/web): shell body and dock are width-capped at 540 and centered.
- **Screens/files:** `lib/screens/main_shell.dart` (`PopScope`, `ShellController`, `_visitedTabs`)

---

## Cross-language string coverage notes

All namespaces referenced above (`login.*`, `admin_setup.*`, `splash.*`, `settings.*`,
`settings_pages.*`, `language.*`, `main_shell.*`, plus `errors.*`, `app.action.*`,
`customer_more.*`) were verified to have **full en/gu/hi parity** (no missing gu/hi keys) in
`assets/translations/{en,gu,hi}.json`. Any new string added on these screens must be added to
all three files.

**Strings that are NOT localized (verified):**
- The TEMP `[debug] trying: <email>` fragment appended to the failed-sign-in error
  (`auth_controller.dart` `verifyAdminPassword`) — English-only and user-facing.
- The support email constant `support@ugambooking.com` (`admin_setup_screen.dart`).
- Push notification titles/bodies (generated server-side by the send-push Edge Function).
