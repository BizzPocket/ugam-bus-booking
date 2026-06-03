# Ugam Booking — Store Release Guide

Everything needed to ship to Google Play and the Apple App Store. Items marked
**🔑 YOU** require your secrets/accounts and can't be done in the repo.

## 1. App identifiers

| Field | Value |
|---|---|
| Android applicationId | `com.occubitsolution.ugambooking` |
| iOS bundle identifier | `com.occubitsolution.ugambooking` |
| App display name | Ugam Booking |
| Version (name + build) | `1.0.0` (+1) → Android versionCode `1`, iOS build `1` |
| Apple Team ID | `LZKBLPJ282` (already set in the Xcode project) |
| Backend | Supabase `rhyqjzulpvaeslbaymex.supabase.co` (publishable/anon key — safe to ship) |

Bump the version for every store upload by editing `version:` in `pubspec.yaml`
(e.g. `1.0.1+2`). Play rejects a re-used versionCode; App Store rejects a
re-used build number.

---

## 2. Google Play

### 2a. 🔑 YOU — create the upload keystore (one time, keep forever)
Losing this key means you can never update the app again. Store it + the
passwords in a password manager.

```bash
keytool -genkey -v \
  -keystore ~/ugam-upload-key.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias ugam-upload
```

Then create `android/key.properties` (already git-ignored — never commit it):

```properties
storePassword=<the store password you just set>
keyPassword=<the key password you just set>
keyAlias=ugam-upload
storeFile=/Users/zeelshiyani/ugam-upload-key.jks
```

### 2b. Build the upload artifact
```bash
flutter build appbundle --release
# → build/app/outputs/bundle/release/app-release.aab
```
With `key.properties` present this is signed with your upload key. Upload the
`.aab` in Play Console → Production (or Internal testing first).

> Enroll in **Play App Signing** (default) so Google manages the final signing
> key; your keystore above is just the *upload* key.

### 2c. 🔑 YOU — Play Data Safety form
Declare (the app collects, does **not** sell, does **not** track for ads):

| Data | Collected | Shared | Purpose | Optional? |
|---|---|---|---|---|
| Phone number | Yes | No | Account management, App functionality | Required |
| Name | Yes | No | App functionality | Required |
| Contacts | Yes | No | App functionality (match contacts to bookings) | Optional (permission) |
| Other (tour/passenger records) | Yes | No | App functionality | Required |

- Data encrypted in transit: **Yes** (HTTPS/TLS to Supabase).
- Users can request deletion: **Yes** — in-app account deletion exists
  (Settings → Delete account). Provide the deletion method + URL.

### 2d. 🔑 YOU — required listing items
- **Privacy policy URL** (see §4) — required because the app requests Contacts.
- Short description, full description, app category, contact email.
- Screenshots (phone, min 2), 512×512 icon, 1024×500 feature graphic.
- Content rating questionnaire.

---

## 3. Apple App Store

### 3a. 🔑 YOU — register + create the app (one time)
1. **developer.apple.com → Certificates, IDs & Profiles → Identifiers** → register
   App ID `com.occubitsolution.ugambooking` (enable no special capabilities).
2. **App Store Connect → My Apps → +** → New App, bundle ID
   `com.occubitsolution.ugambooking`, name "Ugam Booking", primary language.

### 3b. ⚠️ Xcode step — add the privacy manifest to the target
`ios/Runner/PrivacyInfo.xcprivacy` exists but must be a member of the **Runner**
target to ship:
1. Open `ios/Runner.xcworkspace` in Xcode.
2. Drag `PrivacyInfo.xcprivacy` into the **Runner** group (if not shown).
3. Select it → File Inspector → **Target Membership → check `Runner`**.

### 3c. Build + upload
✅ Already built and App-Store-signed: **`build/ios/ipa/Ugam Booking.ipa`** (22MB,
Team `LZKBLPJ282`). Rebuild any time with `flutter build ipa --release`.

> Upload only lands once the app record exists in App Store Connect (§3a).

Upload with either:
- **Transporter** app (Mac App Store) → drag the `.ipa` → Deliver, **or**
- `xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios \
     -u <apple-id> -p <app-specific-password>`, **or**
- Xcode → Product → Archive → Distribute App → App Store Connect.

App-specific password: appleid.apple.com → Sign-In & Security → App-Specific Passwords.

### 3d. 🔑 YOU — App Privacy (App Store Connect)
Mirror §2c: Phone Number, Name, Contacts, "Other User Content" — all *Linked to
user*, *Not used for tracking*, purpose *App Functionality*. Export compliance is
pre-answered in `Info.plist` (`ITSAppUsesNonExemptEncryption = false`).

---

## 4. Privacy policy (🔑 YOU — host this at a public URL, e.g. devam.org/privacy)

Draft (review with the org before publishing):

> **Ugam Booking — Privacy Policy**
> Ugam Booking helps tour-booking agents of Ugam Foj / DEVAM manage bus yatra
> trips. We collect the phone number and name you sign in with, the tour and
> passenger details you enter, and — only with your permission — your device
> contacts, which are matched locally to incoming bookings so you can see who
> booked. Data is stored on our backend (Supabase) and transmitted over
> encrypted HTTPS. We do not sell your data, show third-party ads, or track you
> across other apps or websites. You can delete your account and all associated
> data from Settings → Delete account, or by contacting <support email>.
> Contact: <email> · DEVAM — Bhedapipaliya Dham · devam.org

---

## 5. Permission justifications (for store review)
- **Contacts (READ_CONTACTS / NSContactsUsageDescription):** matches the agent's
  saved contacts to incoming booking requests so they recognize who booked.
  Optional — the app works if denied.
- **Internet / Network state:** sync tours, passengers, and bookings with the
  Supabase backend; detect offline to queue writes.

## 6. Hardening already applied in the repo
- targetSdk 35; HTTPS-only network security config (no cleartext).
- R8 minification + resource shrinking on Android release (`proguard-rules.pro`).
- iOS export-compliance key + `PrivacyInfo.xcprivacy`.
- Debug boot instrumentation removed; release builds verified to compile.

---

## 7. App Store Connect — Version Information (ready to paste)

> Paste each block into the matching field on the App Store Connect "Version
> Information" page. Promotional Text + Description can be edited any time
> without resubmitting a binary.

### Promotional Text (170 chars max)
```
Run group bus yatras end-to-end — manage tours, seats, requests, and passengers from one screen. Built for community tour-booking agents who work over WhatsApp.
```

### Description (4,000 chars max)
```
Ugam Booking is a focused tour-management app for community booking agents who plan and run group bus yatras. It replaces the spreadsheet + WhatsApp + paper-list workflow with a single screen that holds every tour from first inquiry to the day the bus rolls out.

WHAT YOU CAN DO
• Create and publish tours with route, date, bus type, price, and seat layout.
• Take customer booking requests directly in-app, or capture them from WhatsApp.
• Assign passengers to specific seats on visual bus layouts — single, double, sleeper, and sofa rows — with ladies-seat and shared-pair handling built in.
• Track payment status per passenger and per tour at a glance.
• Send tour updates, departure notes, and confirmations to riders through WhatsApp deep links — no message-blasting required.
• Match incoming booking requests to your saved contacts so you instantly recognise who is on the line.
• Works offline: requests, edits, and seat assignments queue locally and sync automatically when you are back online.

FOR COMMUNITY AGENTS
Built for the Ugam Foj / DEVAM satsangi community's tour coordinators, but useful for any small-to-mid operator running scheduled group buses.

LANGUAGES
English, ગુજરાતી (Gujarati), and हिन्दी (Hindi) — pick your language in Settings.

PRIVACY & CONTROL
Your data lives in your account, encrypted in transit. Contacts are read on-device only when you grant permission, used only to match phone numbers to names — never uploaded, never shared. Delete your account and all associated data any time from Settings.
```

### Keywords (100 chars max, comma-separated, no spaces around commas)
```
bus,tour,yatra,booking,travel,seat,passenger,trip,agent,whatsapp,gujarati,fleet,group travel
```
*(92 chars; swap any term as needed.)*

### Support URL  *(🔑 must exist as a public page before review)*
```
https://devam.org
```
*Verified 2026-05-28: only the **root** `https://devam.org` returns 200 — every
subpath (`/support`, `/contact`, `/privacy`, `/about`, etc.) currently returns
404. So use the root for now. Before the next update, host a real `/support`
page on devam.org listing an email + WhatsApp number, and switch the URL here.
Apple rejects `mailto:` URLs and 404 pages.*

### Marketing URL  *(optional)*
```
https://devam.org
```

### Version
```
1.0
```
Matches `MARKETING_VERSION = 1.0` in the Xcode project and `1.0.0` in
`pubspec.yaml`. Bump both together for the next submission.

### Copyright (200 chars max)
```
© 2026 Occubit Solution
```
*(Default to Occubit Solution because the bundle ID prefix `com.occubitsolution.*`
implies that's the developer-account holder. Replace with the exact legal name
on the Apple Developer enrolment if different — Apple cross-checks this.)*

### Routing App Coverage File
**Leave blank.** Only for transportation apps that provide Apple Maps directions
via `MKDirections`. Not applicable.

---

## 8. App Store Connect — App Review Information

> ⚠️ **CRITICAL**: the admin login is reached by a hidden long-press on the
> "Explore tours" title. The Notes field below tells the reviewer exactly how
> to find it — without this, Apple rejects under Guideline 2.1 (App
> Completeness) because the reviewer can't reach the admin features.

### Before submitting — create a demo admin in Supabase
Do NOT share the real production agent's credentials. Create a dedicated
review account:
- A real phone+password admin in Supabase (e.g. phone `9000000001`).
- Seed it with 2–3 sample tours + a few sample booking requests so the
  reviewer has something to interact with.
- Keep the password simple but unique (don't reuse anything you actually use).

### Sign-In Information
- ✅ **Sign-in required** (the admin shell is gated)
- User name: `<demo admin 10-digit phone, no +91>` e.g. `9000000001`
- Password: `<the password you set in Supabase for the demo account>`

### Contact Information
Your own real first/last name, phone, and email. Apple may email this address
if they have questions during review — use a mailbox you actually check.

### Notes (paste verbatim)
```
HOW THE APP IS STRUCTURED

Ugam Booking has two modes in the same binary:

1. CUSTOMER MODE (default — no login)
   On launch, the splash routes anonymous users straight to "Explore tours."
   Customers browse upcoming tours, view details, and submit booking requests
   without creating an account. This is the path most users take.

2. ADMIN MODE (login required — for the single tour-booking agent)
   Admin login is intentionally hidden from customers to keep the public flow
   clean. Exactly one agent per organisation uses this side.

>>> HOW TO REACH THE ADMIN LOGIN <<<
On the "Explore tours" screen (the first screen after splash), LONG-PRESS
the "Explore tours" title in the top bar. This opens the login screen.
Sign in with the phone + password provided above.

WHAT TO TEST AS ADMIN
After login you land in the admin shell with five tabs (dashboard, tours,
requests, seat assignment, notify). The demo account has sample tours and
requests pre-loaded so you can verify create / edit / seat-assign / mark-paid
flows end-to-end.

PERMISSIONS
• Contacts (NSContactsUsageDescription): requested only when you open the
  Requests tab. Used on-device to match incoming phone numbers to saved
  contact names. App works fully if you deny.

WHATSAPP DEEP LINKS
The app declares LSApplicationQueriesSchemes "whatsapp" to deep-link share
tour details to WhatsApp. WhatsApp does not need to be installed; if absent,
the share opens the system sheet instead.

LANGUAGES
Default Gujarati. Switch via Settings → Language (English / ગુજરાતી / हिन्दी).

ACCOUNT DELETION
Settings → Delete account removes the account and all associated data
(complies with App Store Guideline 5.1.1(v)).
```

### Attachment
Optional — skip unless you want to include a short screen-recording
demonstrating the long-press gesture. Not required if the Notes are clear.

### App Store Version Release
For this **first release**, pick **"Manually release this version"** — once
Apple approves, you click "Release" yourself when you're ready to announce.
For future updates, "Automatically release" is fine.
