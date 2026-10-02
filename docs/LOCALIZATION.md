# Localisation

myKikau ships in English. Everything needed to add a language is in place; adding one needs no code changes.

## How it works

- `Resources/Localizable.xcstrings` is a String Catalog. Its keys are the English strings as they appear in the source.
- `scripts/build-app.sh` compiles the catalog into `<language>.lproj/Localizable.strings` inside the app bundle. macOS then picks the user's language automatically.
- SwiftUI text (`Text("…")`, `Button("…")`, `Label("…")`) and `String(localized: "…")` are looked up in that table at run time.

## Add a language

1. Open `Resources/Localizable.xcstrings` in Xcode (double-click it).
2. Click **+** at the bottom of the language list and choose the language.
3. Translate. Xcode shows progress per language and flags anything new or changed.
4. Add the language code to `CFBundleLocalizations` in `Sources/App/Info.plist` (create the array if it isn't there), so macOS lists it under the app's language options.
5. `./scripts/build-app.sh` and run the app with that language: `open build/myKikau.app --args -AppleLanguages "(fr)"`.

A translator without Xcode can work from an export instead: in Xcode, **Product → Export Localizations…** produces an `.xcloc` file per language that standard translation tools open.

## After changing text in the code

```bash
./scripts/extract-strings.sh
```

This recompiles with the Swift compiler's string extraction and merges the result into the catalog. Translations are kept; strings that disappeared are marked stale. Commit the catalog.

## What is not yet translatable

The catalog covers text written directly in views, plus screen names, category names, review-sheet group titles, scan phases and History labels. Still English-only until they are wrapped in `String(localized:)`:

- Sentences assembled in code — screen subtitles ("12 apps · 3.4 GB total"), result summaries, failure reasons, maintenance-task outcomes.
- Maintenance task names and descriptions (`MaintenanceCatalog`).
- Health-score words and explanations (`HealthScore`).
- Plurals built by appending "s". These need plural variants in the catalog (Xcode: right-click a string → **Vary by Plural**) rather than string concatenation.
- Numbers, sizes and dates already follow the user's locale.

When wrapping one of these, use `String(localized: "…")` with the interpolation inside the literal, then run the extraction script.
