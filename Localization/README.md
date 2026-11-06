# Simplified Chinese localization

`zh-Hans.lproj/Localizable.strings` is the single source of truth for Simplified Chinese. Edit that file directly. Historical translation fragments and scan reports are migration artifacts, not build inputs; their translations are folded into the canonical table. The remaining worklists are review aids for candidate strings and are not translation sources.

## Translation rules

- Keep each English key identical to the source text. Missing entries fall back to English.
- Keep every format placeholder in the value. Placeholder order may change with positional forms such as `%1$@` and `%2$@`.
- Preserve literal percent signs as `%%` when they appear in a format string.
- Keep product names, controller button names, protocol identifiers, and diagnostic codes as written unless the interface already has an established Chinese equivalent.
- Review strings in the UI context. The scanner reports candidates and can include logs, identifiers, test text, and pieces of concatenated strings.

## Checks and build

Run `python3 Localization/validate_strings.py` to check table syntax, duplicate keys, and placeholder counts. Run `python3 Localization/extract_strings.py` and `python3 Localization/scan_all.py` to refresh review lists under `.build/localization/`; those lists are generated aids, not translation sources.

Build a local debug preview with `CHIAKI_BUILD_ONLY=1 make app`. This builds the app's native core without running the core test suite. The app is assembled at `.build/chiaki-ng.app`; the packaging script places this table in `Contents/Resources/zh-Hans.lproj/Localizable.strings` and declares English and Simplified Chinese as supported localizations. Open that app to review the Chinese interface. Release packaging uses the same app assembly script.

## Design notes

The custom `chiakiLocalized(_:)` bridge handles dynamic Swift `String` values that SwiftUI cannot resolve as literal `LocalizedStringKey`s. The table remains in the main app bundle because the runtime lookup uses `Bundle.main`. Keep the bridge imports available in modules that display those dynamic strings, and ensure new app packaging paths carry the `.lproj` directory into the main bundle.
