# Phase 1 — Rebrand to Ugam Booking

**Date:** 2026-05-02
**Status:** Approved design, ready for implementation plan.
**Parent:** `2026-05-02-ugam-booking-roadmap.md`

## Goal

Replace the current `TourPro` brand identity with **Ugam Booking** — a religiously-appropriate identity for an Ugam Foj community tour agent. No behavior changes in this phase; only identity surfaces (logo, name, colors, splash, icons).

## Branding direction

Subtle community identity. The Ugam Foj sun symbol and `ઉગમ` Gujarati script appear on splash, login, and launcher icon. Inside-the-app working screens (tours list, seat assignment, etc.) stay clean and functional with gold/saffron used only as an accent — not a full warm wash that could fight the readability of an admin doing real seat-assignment work.

## Logo specification

A reusable Flutter `UgamLogo` widget (CustomPaint, vector) composing:

- **12 gold rays** alternating long/short, radiating from the top-center of a horizon line. Color: `0xFFFFC107` (bright gold).
- **Gold half-disc** below the horizon line. Color: `0xFFFFB300` (deeper amber).
- **`ઉગમ`** Gujarati script centered over the disc, in deep red `0xFFB91C1C`. Font: `NotoSansGujarati`.
- **Bus silhouette** in deep red `0xFF991B1B`, compact, sitting just inside the bottom of the disc.

The CustomPaint widget renders sharp at any size. Launcher PNGs are generated from this widget at build time via `flutter_launcher_icons` reading a single source PNG `assets/icon/ugam_logo.png`. The source PNG is rendered once from the Flutter widget at 1024×1024 (one-off operation; checked in).

## Color palette change

Only the brand tokens change. Functional status colors (success/danger/warning/info) stay the same — they're functional, not brand.

| Token | Old (blue) | New (gold/saffron) |
|---|---|---|
| `brand` | `#1746A2` | `#D97706` (saffron 600) |
| `brandDark` | `#0B1120` | `#7C2D12` (deep red-brown) |
| `brandLight` | `#EFF6FF` | `#FFF7ED` (cream) |
| `brandAccent` | `#4A9FD8` | `#FFC107` (gold) |

Theme gradients (`brandGradient`, `darkGradient`) recomputed using the new tokens. Card surfaces, text colors, and borders stay neutral — the warm color appears only in buttons, icons, focus rings, and the splash background.

## Splash screen redesign

Replace the current pill-with-compass icon and `TourPro` wordmark with:

- `UgamLogo` widget at 180×180, fade-in animation kept as today
- Wordmark: **Ugam Booking** — Inter 700, 34px, white on dark background
- Tagline: **ઉગમ ફોજ બસ બુકિંગ** — Noto Sans Gujarati 400, 14px, 67% opacity white (Inter does not include Gujarati glyphs; italic dropped because Gujarati script does not have a true italic form)
- Decorative ellipses and divider lines kept; recolored to use `brand` (now gold) at low alpha so they read as warm-on-dark instead of blue-on-dark

## Files touched

| File | Change |
|---|---|
| `lib/app.dart` | `title: 'TourPro'` → `'Ugam Booking'` |
| `lib/config/theme.dart` | Update brand color tokens; update `brandGradient` |
| `lib/screens/splash_screen.dart` | Replace pill+compass icon with `UgamLogo`; replace wordmark text; update tagline |
| `lib/screens/login_screen.dart` | Replace `TourPro` header text with `Ugam Booking` |
| `lib/screens/settings_screen.dart` | Replace `TourPro v1.0.0` with `Ugam Booking v1.0.0` |
| `lib/components/ugam_logo.dart` | **NEW.** CustomPaint widget rendering the sun + bus + Gujarati script logo |
| `android/app/src/main/AndroidManifest.xml` | `android:label="TourPro"` → `"Ugam Booking"` |
| `ios/Runner/Info.plist` | `CFBundleName` and `CFBundleDisplayName` → `Ugam Booking` |
| `pubspec.yaml` | Add `flutter_launcher_icons` dev dependency; add `flutter_launcher_icons` config block; add Noto Sans Gujarati via `google_fonts` (already a dep, no new pubspec change for the font itself) |
| `assets/icon/ugam_logo.png` | **NEW.** 1024×1024 PNG rendered once from `UgamLogo` widget; source for launcher icon generation |
| `android/app/src/main/res/mipmap-*/ic_launcher.png` | Regenerated via `flutter pub run flutter_launcher_icons` |
| `ios/Runner/Assets.xcassets/AppIcon.appiconset/*` | Regenerated via `flutter pub run flutter_launcher_icons` |

## Out of scope for Phase 1

- No changes to `AuthController`, `AppwriteService`, or any controller/service business logic.
- No changes to tour, booking, passenger, or seat models.
- No changes to the tour lifecycle screens (broadcast, requests, assign, notify, ticket) beyond the color-token cascade automatically picking up the new accent.
- No rename of the Flutter package `occubusbooking` (would force every `import 'package:occubusbooking/...'` to be rewritten with no user-visible benefit).

## Verification

Manual verification on Android emulator after implementation:

1. Splash shows the new sun + bus logo, "Ugam Booking" wordmark, Gujarati tagline. No blue colors on the splash.
2. After splash, login screen header reads "Ugam Booking".
3. Home screen application bar / drawer / titlebar reads "Ugam Booking" where applicable.
4. Settings → About line reads "Ugam Booking v1.0.0".
5. Phone home screen launcher: app icon is the gold sun + red bus mark, label reads "Ugam Booking".
6. Buttons and focus highlights throughout the app render in the new gold/saffron, not blue.
7. `flutter analyze` still returns 0 issues.

## Risks and notes

- **Gujarati font availability.** `google_fonts` package downloads `Noto Sans Gujarati` at runtime; offline first launch could show a fallback glyph briefly. Acceptable for now; can be embedded as a static font later if it becomes a problem.
- **Launcher icon adaptive shape.** Android adaptive icons require foreground + background layers; the simplest path is to ship the gold logo as foreground over a cream `#FFF7ED` background. `flutter_launcher_icons` handles this when configured.
- **iOS launcher icon corners.** iOS auto-rounds; the logo must be centered with a small inset so the half-disc isn't clipped. The 1024×1024 source PNG should leave ~10% padding.
