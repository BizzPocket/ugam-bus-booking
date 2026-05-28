# Launch Checklist — live by 29 May 2026 afternoon

Two parallel tracks. iOS = your public "download" path. Android = WhatsApp APK (Play Store public is blocked by Google's 14-day closed-test rule and cannot make the 29th).

---

## TRACK A — iOS App Store (primary)

### 1. Host the privacy policy  ⬜  (YOU)
Upload `docs/publishing/privacy-policy.html` to devam.org so it resolves at a public URL,
e.g. `https://devam.org/ugam-booking-privacy`. You'll paste this URL in App Store Connect.

### 2. Create the app record in App Store Connect  ⬜  (YOU)
https://appstoreconnect.apple.com → My Apps → ➕ → New App
- Platform: iOS
- Name: **Ugam Booking**
- Primary language: English
- Bundle ID: **com.occubitsolution.ugambooking**  (select from list — it's registered to team LZKBLPJ282)
- SKU: `ugam-booking-001` (any unique string)

### 3. Fill the version page  ⬜  (YOU)
Use `APP_STORE_LISTING.md` for: subtitle, description, keywords, promo text, support URL, category, "What's New".

### 4. Upload screenshots  ⬜  (ME → then YOU upload)
6.9" iPhone screenshots are being generated into `docs/publishing/screenshots/`.
Upload them under App Store Connect → the 6.9" Display size. (6.9" set also covers smaller sizes.)

### 5. Privacy + Age Rating + Export  ⬜  (YOU)
Use `APP_PRIVACY_AND_REVIEW.md` for exact answers. (Export is pre-answered in the build.)

### 6. Upload the build (.ipa)  ⬜  (YOU, easiest path)
Binary is ready: **`build/ios/ipa/Ugam Booking.ipa`** (v1.0.0 build 1).
- Download **Transporter** from the Mac App Store.
- Sign in with your Apple ID, drag the .ipa in, click **Deliver**.
- Wait ~5–15 min for it to finish processing in App Store Connect, then select it as the build for this version.

### 7. App Review notes + Submit  ⬜  (YOU)
- Sign-in required: **No**. Paste the reviewer note from `APP_PRIVACY_AND_REVIEW.md`.
- Click **Submit for Review**. Set "Automatically release this version" so it goes live the moment it's approved.

### 8. Request Expedited Review  ⬜  (YOU)
https://developer.apple.com/contact/app-store/?topic=expedite — cite the 29 May departure.

> **Submit today (27th) to be safe.** Expedited review typically lands in hours; normal is ~24h.

---

## TRACK B — Android via WhatsApp (guaranteed, do anytime)

Signed APK ready: **`build/app/outputs/flutter-apk/app-release.apk`** (57 MB).

1. Send the .apk file into your WhatsApp group / to customers.
2. Each user taps the file → Android asks to "allow install from this source" → Allow → Install.
3. Done — works on any Android phone, no Play Store, no review, no testers.

> Public Google Play listing is NOT possible by the 29th (Google forces a 14-day
> closed test with 12 testers for new personal accounts). If you want it on Play
> later, we can start that 14-day clock via Internal Testing in parallel.

---

## Keystore — KEEP THIS SAFE  🔐
The Android release key lives at `android/upload-keystore.jks`
(credentials in `android/key.properties`, both git-ignored).
**Back up both files** somewhere safe. If you ever move to Google Play, you'll need this
exact key, and it cannot be recovered if lost.
