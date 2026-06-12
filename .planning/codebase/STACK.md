# Technology Stack

**Analysis Date:** 2026-06-06

---

## Languages

**Primary:**
- Dart 3.x — all application code under `lib/`

**Secondary:**
- TypeScript — Supabase Edge Function at `supabase/functions/whatsapp-send/index.ts` (Deno runtime)
- Kotlin — Android shell at `android/app/src/main/kotlin/com/occubitsolution/ugambooking/MainActivity.kt`
- SQL — Schema migrations under `supabase/migrations/` and `database.sql`

---

## Runtime

**Environment:**
- Flutter stable channel (no pinned version in workflow — uses latest stable via `subosito/flutter-action@v2`)
- Dart SDK constraint: `^3.10.3` (declared in `pubspec.yaml` line 22)
- Deno (version unspecified) for the Edge Function — runs on Supabase's managed Deno runtime

**Package Manager:**
- `flutter pub` (Dart pub)
- Lockfile: `pubspec.lock` present and committed

---

## Frameworks

**Core:**
- Flutter (stable) — cross-platform UI framework, portrait-only orientation locked in `lib/main.dart`
- GetX `4.7.3` (declared `^4.6.6`) — state management, DI, routing, reactive values

**Localization:**
- easy_localization `3.0.8` (declared `^3.0.7`) — JSON translation files at `assets/translations/` (Gujarati/English/Hindi)
- Locale config: `lib/config/i18n_config.dart` — fallback locale is Gujarati (`gu`)

**Testing:**
- `flutter_test` (Flutter SDK bundled) — unit + widget tests under `test/`
- `flutter_lints` `6.0.0` — lint rules via `analysis_options.yaml` (extends `flutter_lints/flutter.yaml`)

**Build/Dev:**
- `flutter_launcher_icons` `0.14.4` — generates launcher icons from `assets/icon/ugam_logo.png`
- Android Gradle Plugin (AGP) `8.11.1` — declared in `android/settings.gradle.kts`
- Kotlin `2.2.20` — declared in `android/settings.gradle.kts`
- Java 17 — `compileOptions` in `android/app/build.gradle.kts`
- GitHub Actions CI: `.github/workflows/release.yml` — builds APK on `v*` tag push

---

## Key Dependencies

### State Management & Routing
| Package | Resolved | pubspec constraint | Purpose |
|---------|----------|--------------------|---------|
| `get` | 4.7.3 | `^4.6.6` | GetX: state (Obx/Rx), DI (Get.put/find), navigation |

### Backend / Auth
| Package | Resolved | pubspec constraint | Purpose |
|---------|----------|--------------------|---------|
| `supabase_flutter` | 2.12.4 | `^2.8.0` | Supabase client: DB, Auth, Realtime, Storage, Edge Functions |
| `flutter_secure_storage` | 9.2.4 | `^9.2.2` | Stores Supabase session refresh token in iOS Keychain / Android Keystore |
| `crypto` | 3.0.7 | `^3.0.6` | SHA-256 password hashing for admin credentials |

### Networking / Platform
| Package | Resolved | pubspec constraint | Purpose |
|---------|----------|--------------------|---------|
| `url_launcher` | 6.3.2 | `^6.3.1` | Opens `wa.me/` deep links for free WhatsApp handoff |
| `connectivity_plus` | 6.1.5 | `^6.1.4` | Online/offline detection for fail-fast write guard |

### Contacts
| Package | Resolved | pubspec constraint | Purpose |
|---------|----------|--------------------|---------|
| `flutter_contacts` | 2.1.0 | `^2.1.0` | Reads device address book for booking-request enrichment |

### PDF & Sharing
| Package | Resolved | pubspec constraint | Purpose |
|---------|----------|--------------------|---------|
| `pdf` | 3.12.0 | `^3.12.0` | Generates A4 seat-chart PDFs in `lib/services/seat_chart_pdf.dart` |
| `printing` | 5.14.3 | `^5.14.3` | Rasterises PDF pages to PNG (for WhatsApp image share); `Printing.sharePdf` |
| `share_plus` | 12.0.2 | `^12.0.2` | Native share sheet |

### Media
| Package | Resolved | pubspec constraint | Purpose |
|---------|----------|--------------------|---------|
| `image_picker` | 1.2.2 | `^1.1.2` | Selects tour broadcast hero image from gallery/camera |

### i18n / Fonts
| Package | Resolved | pubspec constraint | Purpose |
|---------|----------|--------------------|---------|
| `intl` | 0.20.2 | `^0.20.2` | Date formatting in PDFs and message builders |
| `google_fonts` | 8.0.2 | `^8.0.2` | Included but **runtime fetching is disabled** (`GoogleFonts.config.allowRuntimeFetching = false` in `lib/main.dart`); Inter is bundled as `assets/fonts/Inter-Variable.ttf` |

### Utilities
| Package | Resolved | pubspec constraint | Purpose |
|---------|----------|--------------------|---------|
| `uuid` | 4.5.3 | `^4.5.1` | Client-side UUID generation for entity IDs |
| `shared_preferences` | 2.5.5 | `^2.5.3` | Theme preference persistence |

### Dev / Tooling
| Package | Resolved | pubspec constraint | Purpose |
|---------|----------|--------------------|---------|
| `flutter_lints` | 6.0.0 | `^6.0.0` | Lint rule set |
| `flutter_launcher_icons` | 0.14.4 | `^0.14.4` | Generates iOS/Android launcher icons |

---

## Dependency Risk Flags

**`app_links` (transitive, 7.0.0)** — pulled in as a transitive dependency of `supabase_flutter`. Not declared directly in `pubspec.yaml` but appears in `pubspec.lock`. If supabase_flutter's deep-link handling is not needed for this app (no OAuth redirects via app schemes), it is an invisible transitive that touches iOS scene lifecycle. The iOS `Info.plist` uses `UISceneDelegate` + `FlutterSceneDelegate` specifically to guard against this (`project_ios_scene_lifecycle.md` memory note confirms the risk is known).

**`sqflite_darwin` (transitive, in macOS Pods)** — `sqflite` appears as a transitive dependency via `supabase_flutter` on macOS, even though the offline SQLite cache (`OfflineDatabase`) was deleted (evidenced by the deleted `lib/services/offline_database.dart` in git status and the stub stubs in `lib/services/sync_service.dart`). The transitive pull is harmless on macOS but confirms the project no longer uses SQLite directly.

**`google_fonts` (8.0.2)** — package is present but only used for its font-data API (PDF fonts via `PdfGoogleFonts` in `lib/services/seat_chart_pdf.dart`). Runtime HTTP fetching is explicitly disabled in `lib/main.dart`. The package downloads Noto Sans fonts on first PDF generation (network-cached). Low risk; known and deliberate.

**`printing` (5.14.3)** — uses `Printing.raster()` to convert PDF pages to PNG for WhatsApp image send. Rasterisation calls into the native PDFKit (iOS) / Android PDF renderer; not a pure-Dart operation.

---

## Configuration

**Environment / Secrets:**
- No `.env` file exists. No `--dart-define` injection used.
- Supabase URL and anon key are **hardcoded in source** at `lib/config/supabase_config.dart`. This is intentional for a public anon key (Supabase anon keys are safe to ship), but worth noting for any key rotation.
- WhatsApp token and phone-number-id are **never in the app** — they live as Supabase Edge Function secrets (`WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`) set via `supabase secrets set`.
- Android release keystore: loaded from `android/key.properties` (git-ignored). CI builds fall back to debug signing.

**Build:**
- `android/app/build.gradle.kts` — Kotlin DSL; targetSdk pinned to 35; minSdk delegates to `flutter.minSdkVersion` (21 per `flutter_launcher_icons.min_sdk_android` in `pubspec.yaml`)
- `analysis_options.yaml` — includes `flutter_lints/flutter.yaml`, no custom rules added
- iOS release build via `scripts/build_ios_release.sh` — runs `flutter clean` before `flutter build ipa` to prevent simulator-slice contamination in `objective_c.framework`

---

## Platform Targets

**Primary:**
- Android (min SDK 21 / Android 5.0, target SDK 35) — deployed via GitHub Actions APK release
- iOS (portrait-only, scene-delegate lifecycle via `UISceneDelegate` + `FlutterSceneDelegate` in `ios/Runner/Info.plist`)

**Secondary / Desktop:**
- macOS — Pods directory and macOS Runner present; not an active deployment target
- Windows — `windows/` scaffold present; not an active deployment target
- Web — `web/` scaffold present; not an active deployment target

---

## Localization Setup

- Three locales: Gujarati (`gu`, default/fallback), English (`en`), Hindi (`hi`)
- Translation files: `assets/translations/gu.json`, `en.json`, `hi.json`
- Config centralised in `lib/config/i18n_config.dart`
- `easy_localization` wraps the app at `lib/main.dart` once `EasyLocalization.ensureInitialized()` completes (run in parallel with Supabase init)
- Locale selector in settings: `lib/controllers/locale_controller.dart`

---

## Notable Native / Plugin Setup

**iOS Scene Lifecycle:**
- `Info.plist` declares `UISceneDelegate` with `FlutterSceneDelegate` class — required because `flutter_contacts`, `flutter_secure_storage`, and `url_launcher` would crash at launch on iOS 13+ without scene-aware plugin registration. Documented in project memory `project_ios_scene_lifecycle.md`.

**Android Manifest:**
- `android:allowBackup="false"` — intentionally disabled to prevent stale SQLite data from being restored by Android Auto Backup (legacy SQLite cache was removed)
- `<queries>` block declares `com.whatsapp` and `com.whatsapp.w4b` package visibility + `wa.me` scheme, required for `url_launcher` to detect WhatsApp on Android 11+
- Permissions: `INTERNET`, `ACCESS_NETWORK_STATE`, `READ_CONTACTS`

**PDF Font Network Call:**
- `lib/services/seat_chart_pdf.dart` calls `PdfGoogleFonts.notoSansRegular()` on first PDF generation. This triggers a one-time download from `fonts.gstatic.com` (cached to disk afterwards). Gracefully degrades to built-in Latin font if network is unavailable.

---

*Stack analysis: 2026-06-06*
