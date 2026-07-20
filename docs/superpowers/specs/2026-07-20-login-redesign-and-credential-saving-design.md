# Login Redesign + Credential Saving — Design

**Date:** 2026-07-20
**Branch:** feat/money-collection-settlement
**Status:** Approved (design), pending implementation plan

## Goal

Elevate the admin login screen to a "best-in-class" auth experience and add
native credential conveniences the app currently lacks:

1. **Research-informed visual polish** — keep the existing structure, level up
   execution (hierarchy, motion, inline errors, focus states).
2. **OS save & autofill** — let Android's Google Password Manager / iOS iCloud
   Keychain save and refill the number + password (the "store password in
   Google like some apps do" request).
3. **Biometric quick-unlock** — fingerprint / Face ID to sign back in after a
   logout without retyping.
4. **Show / hide password** toggle.
5. **Remember & prefill** the last-used phone number.

## Current state (as-built)

- Login is **phone + password for admins only** — not OTP.
  ([lib/screens/login_screen.dart](../../../lib/screens/login_screen.dart),
  [lib/controllers/auth_controller.dart](../../../lib/controllers/auth_controller.dart))
  - Step 1: enter phone → `AuthController.submitPhone()` → `AdminAuthService.findByPhone`.
  - Step 2: a registered number slides open `_PasswordStep` → `verifyAdminPassword()`
    → `AdminAuthService.signIn` (Supabase Auth via synthetic-email mapping).
  - Non-admin numbers are rejected.
- **No autofill wired up.** Neither `UgamInput` nor `UgamPhoneInput` sets
  `autofillHints`; there is no `AutofillGroup`.
  ([lib/design/components/ugam_input.dart](../../../lib/design/components/ugam_input.dart))
- Admin sessions **already persist** across restarts (SharedPreferences +
  Supabase session in `flutter_secure_storage`). So biometric matters *after an
  explicit logout* / reinstall / new device — that is the scenario we target.
- Errors surface as **toasts** (`AppSnackBar`), including a **temporary debug
  string that leaks the synthetic email** in `verifyAdminPassword` — to be removed.
- `MainActivity` extends `FlutterActivity`
  ([android/.../MainActivity.kt](../../../android/app/src/main/kotlin/com/occubitsolution/ugambooking/MainActivity.kt)).

## Design decisions (confirmed with user)

- **Biometric storage model:** store the admin password in hardware-backed
  secure storage (Android Keystore / iOS Keychain via `flutter_secure_storage`),
  written only when the user opts into biometric login, retrieved **only after a
  passing `local_auth` check**, never logged. Chosen over an "app-lock that never
  signs out" because it matches the sign-back-in-after-logout requirement and is
  durable (refresh tokens rotate / expire).
- **iOS autofill scope:** **Android-first.** Android password save/fill works in
  the app with no extra hosting. Full iCloud Keychain save on iOS additionally
  requires an *Associated Domains* entitlement + an `apple-app-site-association`
  file hosted on a web domain — deferred until a domain is available. iOS still
  gets show/hide + biometric + the keyboard "Passwords" bar now.

## Architecture & components

### A. Visual polish — `LoginScreen`

Structure unchanged: logo-halo → `UGAM` wordmark → tagline → phone → (reveal)
password → sticky CTA. Changes:

- Tighten the brand block to the cockpit-density tokens; strengthen the type
  hierarchy between wordmark / tagline / field labels using existing `UgamText`.
- Password field gains the eye toggle (see D) and, on a failed sign-in, an
  **inline field error** ("Incorrect password") instead of a toast.
- A **biometric unlock affordance** renders near the CTA *only when* a stored
  credential exists for the prefilled number (see C).
- Subtle focus + reveal motion via existing `UgamMotion` tokens.
- **Remove the debug email-leak** string in `verifyAdminPassword`; map
  `AuthException` to a clean inline message.

### B. OS save & autofill

- Wrap phone + password fields in a single `AutofillGroup` inside `LoginScreen`.
- `UgamInput` / `UgamPhoneInput` gain an optional `autofillHints` param
  (default `null`, so no other caller changes):
  - Phone → `[AutofillHints.username]` — pairs it with the password as a login
    credential. (`telephoneNumber` would make the OS treat it as a contact
    field, not a saved login.)
  - Password → `[AutofillHints.password]`.
- On **successful** sign-in only (inside `_loginAsAdmin`, before navigation),
  call `TextInput.finishAutofillContext()` → OS shows "Save password?". Call it
  exactly once per successful login to avoid repeated dialogs.
- The two-step reveal is compatible: phone is entered first, password mounts
  second (the recommended username-then-password order); both are mounted and
  filled when the context commits, so the pair saves correctly.

### C. Biometric quick-unlock

New unit: **`BiometricCredentialStore`** (`lib/services/biometric_credential_store.dart`)
— thin wrapper over `local_auth` + `flutter_secure_storage`.

- **What it does:** stores/retrieves a `{phone, password}` credential gated by a
  biometric check; reports whether biometrics are available and whether a
  credential is enrolled.
- **Interface:**
  - `Future<bool> isAvailable()` — `canCheckBiometrics || isDeviceSupported()`.
  - `Future<bool> hasCredential(String phone)`.
  - `Future<void> enroll(String phone, String password)` — writes to secure storage.
  - `Future<({String phone, String password})?> unlock(String phone)` — runs
    `authenticate(biometricOnly: true, ...)`; returns the credential on success,
    `null` on cancel/fail.
  - `Future<void> clear()` — purge (on disable / logout-if-disabled).
- **Depends on:** `local_auth`, `flutter_secure_storage`.

Flow, wired through `AuthController`:

1. After a successful password login, if `isAvailable()` and not already
   enrolled → offer "Enable fingerprint login?" (one-time prompt). On yes →
   `enroll(phone, password)`.
2. On the login screen, if `hasCredential(prefilledPhone)` → show
   **"Unlock with fingerprint / Face ID."** Tap → `unlock()` → on success replay
   `AdminAuthService.signIn` → `_loginAsAdmin`.
3. A **Settings toggle** ("Fingerprint login") reflects enrollment; turning it
   off calls `clear()`.

Platform setup (required for biometrics):

- Android: `MainActivity` → `FlutterFragmentActivity`; add
  `<uses-permission android:name="android.permission.USE_BIOMETRIC"/>`; confirm
  effective `minSdk >= 24` (local_auth requirement; firebase deps likely already
  raise it — verify).
- iOS: add `NSFaceIDUsageDescription` to `Info.plist`.

### D. Show / hide password

- `UgamInput` gains an optional built-in obscure toggle: when
  `obscureToggle: true`, render an eye suffix icon that flips `obscureText`.
  Default `false` → existing callers unchanged. The login password field opts in.

### E. Remember & prefill number

- Persist a new `last_phone` key that **survives logout** (separate from the
  session `auth_phone` cleared in `_clearSessionLocally`).
- On `LoginScreen` init, prefill `phoneController` from `last_phone`.
- Editing the number cancels any pending biometric offer / password step
  (existing `onChanged` already calls `cancelAdminPassword`).

## Data flow

```
open app (logged out)
  └─ prefill phone from last_phone
     ├─ hasCredential? → show "Unlock with biometric"
     │     └─ unlock() → signIn() → _loginAsAdmin → home
     └─ type password → verifyAdminPassword() → signIn()
           └─ _loginAsAdmin:
                ├─ finishAutofillContext()  → OS "Save password?"
                ├─ offer biometric enroll (first time)
                ├─ persist last_phone
                └─ navigate home
```

## Error handling

- Wrong password → inline field error on the password field (not a toast); clear
  it on next keystroke.
- Biometric cancel / lockout / no-hardware → silently fall back to the password
  field (never block the manual path).
- Autofill unavailable (older OS) → fields behave as plain inputs; no crash.
- Secure-storage read/write failure → treat as "no biometric credential"; manual
  login still works.

## Testing

Widget/unit tests (follow the `easy_localization` setUpAll load pattern noted in
project memory):

- Show/hide toggle flips obscurity.
- Phone prefill from `last_phone`.
- Inline error renders on `AuthException`, and the debug email string is gone.
- Biometric button visibility: shown iff `hasCredential` + available (mock the
  store); hidden otherwise.
- `autofillHints` present on both fields; both sit inside one `AutofillGroup`.
- `BiometricCredentialStore`: enroll → hasCredential true; clear → false;
  `unlock` returns credential on mocked success, `null` on failure.

## Dependencies

- **New:** `local_auth` (^2.x).
- **Reuse:** `flutter_secure_storage` (already present), `shared_preferences`.

## Out of scope

- Full iOS iCloud Keychain association (Associated Domains + AASA hosting).
- Any change to the passenger (non-admin) flow.
- OTP / passwordless auth.

## Risks / notes

- `finishAutofillContext()` must fire **only on success**, exactly once, or the
  save dialog nags. Guard it in `_loginAsAdmin`.
- Storing a reusable password at rest is acceptable here (hardware-backed +
  biometric-gated + purgeable) but is a deliberate posture — documented above.
- `FlutterFragmentActivity` swap can interact with other plugins; smoke-test
  push + image_picker after the change.
