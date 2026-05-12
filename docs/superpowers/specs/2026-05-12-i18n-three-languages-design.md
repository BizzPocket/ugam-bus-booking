# i18n: Gujarati / English / Hindi

**Date:** 2026-05-12
**Status:** Spec — approved by user, pending implementation plan

## Summary

Add three-language support to the OccuBus Booking Flutter app using `easy_localization`. Gujarati is the primary language and the default for new installs that don't have a saved preference. English and Hindi are full alternates. All ~305 user-facing strings across the ~20 screens and shared widgets are translated. The user (native Gujarati speaker) proofreads the AI-generated Gujarati strings; Hindi is shipped from the AI pass without manual review at first and corrected as issues are reported.

## Constraints and context

- 20 screen files under `lib/screens/` and several reusable widgets contain inline string literals.
- ~305 unique user-facing English strings today; no existing localization framework.
- `intl: ^0.20.2` already in `pubspec.yaml` (date formatting use only).
- 2 admins, 200–300 customers/month. Translation maintenance burden must stay low.
- Gujarati script is `gu` ISO 639-1; Hindi `hi`; English `en`. All three use the same writing direction (LTR), no RTL handling needed.

## Architecture

```
assets/translations/
  en.json     ← English (source of truth for keys)
  gu.json     ← Gujarati (default / primary)
  hi.json     ← Hindi

lib/
  config/i18n_config.dart   ← supported locales, fallback, key constants
  controllers/locale_controller.dart  ← GetX controller for current locale
  screens/settings_screen.dart  ← gets a "Language / ભાષા" row that opens a picker
  widgets/language_picker_sheet.dart  ← bottom sheet with 3 radio options
```

`easy_localization` handles:
- Loading JSON from `assets/translations/` at app boot.
- Persisting the selected locale to `SharedPreferences` (built in).
- The `.tr()` extension on `String` for key lookup.
- Plural/gender forms via `.plural()` if needed later (none today).
- `EasyLocalization` widget wraps `MyApp` so locale switches rebuild the tree.

`LocaleController` is a thin GetX wrapper around `context.setLocale(...)` so the rest of the app can stay test-friendly and decoupled from BuildContext for locale changes from non-widget code.

## Key naming convention

Dot-separated, screen-scoped, snake_case. Examples:

- `app.title`
- `app.action.cancel` / `app.action.save` / `app.action.delete`
- `app.error.network` / `app.error.unknown`
- `login.phone_label`
- `login.password_label`
- `login.submit`
- `dashboard.greeting` (with positional placeholder: `'Hello, {}'`)
- `tour.status.draft` / `tour.status.live` / `tour.status.completed`
- `booking_request.submitted_message`
- `settings.language`

Shared action verbs ("Cancel", "Save", "Add", "Delete") live under `app.action.*` to avoid duplication across screens.

## Translation source

For each English string the LLM generates Gujarati and Hindi during implementation. The user, who speaks Gujarati natively, proofreads the resulting `gu.json` in one pass after extraction is complete. Hindi is shipped as-is initially. Both files are version-controlled, so any later corrections are easy `Edit`s in source.

## Default locale and persistence

- On first launch with no saved preference, the app reads the device locale via `EasyLocalization.startLocale`. If it's `gu`, `en`, or `hi`, use it. Otherwise default to `gu` (Gujarati) per the user's primary-language requirement.
- After the user picks a language in Settings, `easy_localization` saves it to SharedPreferences and uses it on every subsequent launch.

## Out of scope (deferred)

- Right-to-left languages — none of `en`/`gu`/`hi` are RTL.
- Pluralization rules per locale (no plural-sensitive strings in the app today).
- Locale-specific date/time formats — `intl` already handles these via `DateFormat`'s locale arg; we'll thread the active locale into the small number of date format calls during the extraction pass.
- Translation memory or external translation management — JSON files in git is enough at this scale.
- Server-side localized strings (e.g. error messages from Supabase) — those stay English; the app maps known status enums to localized labels client-side.

## Risks and trade-offs

- **AI-generated translations can be subtly off**, especially for domain terms like "seat layout", "passenger handler", "request line". Gujarati proofreading by the user catches these for the primary language; Hindi will likely need a pass eventually but is acceptable as a starting point.
- **Adding a new string post-launch** requires editing all three JSON files. Mitigated by a CI lint (deferred) that flags missing keys; for now, the dev workflow is "add to en.json, run an LLM pass to fill gu/hi" — a 30-second loop.
- **Asset bundle size** grows by ~80–100 KB total (three JSON files of ~25–30 KB each at full coverage). Trivial.
- **Hot reload** with `easy_localization` works but locale-switch sometimes needs a full restart; documented in `easy_localization`'s README.

## Acceptance criteria

- App boots in Gujarati on a fresh install (no saved preference).
- Settings screen has a "Language / ભાષા" row that opens a picker with three options.
- Switching language reloads the UI immediately (no app restart needed).
- Every previously-hardcoded English string in `lib/screens/` and shared `lib/widgets/` resolves through `.tr()`.
- Selected locale persists across app launches.
- `flutter analyze` clean; `flutter test` green.
