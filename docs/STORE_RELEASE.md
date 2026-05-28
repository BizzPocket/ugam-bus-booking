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
