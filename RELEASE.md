# Ugam Booking — Store Release Runbook

Everything needed to ship **Ugam Booking** to the Google Play Store and Apple
App Store. Steps marked **🧑 YOU** require your accounts/machine; everything else
is already wired in this repo.

- **App name (stores):** Ugam Booking
- **Android applicationId / iOS bundle id:** `com.occubitsolution.tourpro`
- **Version:** `1.0.0+1` (versionName `1.0.0`, build/versionCode `1`) — set in [pubspec.yaml](pubspec.yaml)
- **Backend:** Supabase (publishable key shipped in client; security enforced by RLS)

> **Distribution change:** the old in-app GitHub-APK auto-updater was **removed**
> (it violates Google Play policy). Updates now ship only through the stores.
> Do not re-add APK self-install.

---

## 0. Prerequisites (🧑 YOU)

- **Google Play Developer account** — one-time $25, https://play.google.com/console
- **Apple Developer account** — $99/yr, https://developer.apple.com
- **Tooling:** Flutter SDK, Xcode (for iOS) on macOS, CocoaPods.
- Verify the toolchain: `flutter doctor`

---

## 1. One-time setup

### 1a. Run the account-deletion SQL (🧑 YOU — required for Play)
In the Supabase SQL editor for the **production** project, run:
- [docs/superpowers/specs/2026-05-25-account-deletion.sql](docs/superpowers/specs/2026-05-25-account-deletion.sql)

This creates the `delete_my_account()` RPC behind **Settings → Delete Account**.
Without it, the in-app delete button will error.

### 1b. Android upload keystore (🧑 YOU — required for Play)
Generate an upload key (keep the `.jks` and passwords safe and **off** git):
```bash
keytool -genkey -v -keystore ~/ugam-upload-keystore.jks \
    -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```
Then copy the template and fill it in:
```bash
cp android/key.properties.example android/key.properties
```
Edit `android/key.properties` with your passwords, `keyAlias=upload`, and the
absolute `storeFile` path. **`key.properties` and `*.jks` are already
git-ignored** — never commit them. The Gradle config in
[android/app/build.gradle.kts](android/app/build.gradle.kts) automatically uses
this key for release builds (and falls back to the debug key when the file is
absent, so CI/fresh clones still build).

> Enroll in **Play App Signing** when you create the app in Play Console (let
> Google manage the app signing key; your `.jks` is just the *upload* key).

### 1c. iOS signing (🧑 YOU — required for App Store)
1. In the Apple Developer portal, register the App ID `com.occubitsolution.tourpro`.
2. Open `ios/Runner.xcworkspace` in Xcode → **Runner → Signing & Capabilities**
   → select your **Team** and enable **Automatically manage signing**.
3. Create the app record in **App Store Connect** (same bundle id).

---

## 2. Pre-build checklist (already done in this repo ✅)

- ✅ In-app APK updater removed; `REQUEST_INSTALL_PACKAGES` + APK queries stripped.
- ✅ Android release signing wired to `key.properties`.
- ✅ `targetSdk = 35` pinned.
- ✅ iOS + Android locked to **portrait**; iPad supported (universal).
- ✅ App name "Ugam Booking" consistent across platforms.
- ✅ In-app **account deletion** (admin) + Supabase RPC + SQL.
- ✅ Launcher icons regenerated; store icons in [store_assets/](store_assets/).
- ✅ Privacy policy + data-safety answers drafted in [docs/legal/](docs/legal/).

Bump the version for every release in [pubspec.yaml](pubspec.yaml) (`version:`),
e.g. `1.0.1+2`. versionCode (the `+N`) must increase on every Play upload.

---

## 3. Build

```bash
flutter clean && flutter pub get

# Android — App Bundle for Play (requires android/key.properties)
flutter build appbundle --release
#  → build/app/outputs/bundle/release/app-release.aab

# iOS — archive (requires Xcode signing from step 1c)
flutter build ipa --release
#  → build/ios/ipa/*.ipa   (or open Runner.xcworkspace → Product ▸ Archive)
```

---

## 4. Store listing assets (🧑 YOU)

| Asset | Play | App Store |
|---|---|---|
| App icon | 512×512 → [store_assets/play_store_icon_512.png](store_assets/play_store_icon_512.png) | from build (1024 in asset catalog) |
| Feature graphic | 1024×500 (**create** a banner) | — |
| Phone screenshots | 2–8, min 1080px | 6.7" + 6.5" iPhone (+ 12.9" iPad, since iPad is supported) |
| Short / full description | yes | subtitle + description |
| **Privacy policy URL** | required | required |
| Category | e.g. Business / Travel | Business |
| Content rating / Age | fill questionnaire | fill questionnaire |

- Host [docs/legal/PRIVACY_POLICY.md](docs/legal/PRIVACY_POLICY.md) at a public
  URL and paste it into both listings (fill the `[BRACKETED]` placeholders first).
- Fill the privacy forms using [docs/legal/STORE_DATA_SAFETY.md](docs/legal/STORE_DATA_SAFETY.md).
- Take portrait screenshots on a simulator/device:
  `flutter run --release` → capture key screens (Dashboard, Tours, Requests,
  Assign, Settings). For iPad screenshots, run on an iPad simulator.

---

## 5. Submit

**Google Play (🧑 YOU)**
1. Play Console → Create app → enroll in **Play App Signing**.
2. Internal testing track → upload `app-release.aab`.
3. Complete: Data safety, Content rating, Target audience, Privacy policy,
   App access (provide **test agent credentials** so reviewers can log in —
   admin accounts are dashboard-provisioned, so create a demo admin and share
   its phone+password in the review notes).
4. Promote to Production → submit for review.

**App Store (🧑 YOU)**
1. Upload the build via Xcode Organizer or `xcrun altool`/Transporter.
2. In App Store Connect: fill App Privacy, screenshots, description, age rating.
3. **App Review notes:** provide demo admin phone+password (no in-app sign-up,
   so reviewers need credentials to see the agent features).
4. Submit for review.

---

## 6. After launch

- Ship updates by bumping `version:` in pubspec and re-uploading through the
  stores. No sideloading, no in-app APK install.
- If you add analytics/crash reporting/ads/payments later, **update both
  privacy disclosures** before the next submission.
