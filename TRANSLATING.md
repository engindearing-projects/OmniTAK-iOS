# Translating OmniTAK

Thanks for helping bring OmniTAK to more languages. Translations are
community-driven and very welcome. You do **not** need to be a developer to
contribute one.

## The language file

Everything translatable lives in one plain-text file per language:

```
OmniTAKMobile/Resources/<code>.lproj/Localizable.strings
```

The **source (master) file is English**:

- View: https://github.com/engindearing-projects/OmniTAK-iOS/blob/main/OmniTAKMobile/Resources/en.lproj/Localizable.strings
- Raw (right-click → Save As): https://raw.githubusercontent.com/engindearing-projects/OmniTAK-iOS/main/OmniTAKMobile/Resources/en.lproj/Localizable.strings

That English file is your template. Translate the right-hand side of each line.

### Currently shipping

| Code | Language |
|------|----------|
| `en` | English (source) |
| `uk` | Українська (Ukrainian) |
| `pl` | Polski (Polish) |
| `de` | Deutsch (German) |
| `fr` | Français (French) |
| `es` | Español (Spanish) |

**Coverage:** the onboarding flow, the Quick Start guide, and the full Settings
screen are localized today. Other screens fall back to English until later
passes extend coverage, so a finished translation of this file localizes those
areas immediately.

## How to translate

1. Download the English file (raw link above).
2. Save it as `Localizable.strings` inside a folder named for your
   [ISO language code](https://en.wikipedia.org/wiki/List_of_ISO_639_language_codes),
   e.g. `zh-Hant.lproj/` (Traditional Chinese), `it.lproj/` (Italian),
   `ja.lproj/` (Japanese).
3. Translate **only the value** in each line — the text on the right inside the
   second pair of quotes:

   ```
   "settings.callsign" = "Callsign";
                          ^^^^^^^^  translate this part only
   ```

### Rules (so the file loads correctly)

- **Keep the key unchanged** — the part before the `=` (`"settings.callsign"`).
- **Keep every line ending in `;`** and keep the surrounding quotes.
- **Keep placeholders exactly as-is:** `%d` (a number) and `%@` (a word) get
  filled in at runtime, e.g. `"%d points"` → `"%d 點"`. Don't translate or
  remove them.
- **Leave technical proper nouns untranslated:** TAK, ATAK, MGRS, UTM, BNG,
  OSGB36, TLS/SSL, QR, FAA Remote ID, MIL-STD, Bluetooth, DJI/Skydio/Autel.
- Save as **UTF-8**.
- The `/* ... */` lines are comments for context — you can leave them in English.

## How to submit

Whichever is easiest for you:

- **Email it back** — attach your finished `Localizable.strings` (mention the
  language) to a reply, or send it to the address you used for TestFlight
  feedback. We'll wire it in and credit you in the release notes.
- **Open a pull request** — drop your `<code>.lproj/Localizable.strings` into
  `OmniTAKMobile/Resources/` and open a PR against `main`.

You don't have to translate all 100-odd lines at once. A partial file is fine —
anything you leave in English just falls back to English.

## For maintainers: enabling a finished translation

1. Add the `<code>.lproj/Localizable.strings` file under
   `OmniTAKMobile/Resources/`.
2. In `OmniTAKMobile/Core/Localization/LocalizationManager.swift`, add a case to
   the `Language` enum plus its `displayName` (endonym) and `flag` emoji.
3. Add the code to `LANGS` in `scripts/sync-localization-pbxproj.rb` and run
   `ruby scripts/sync-localization-pbxproj.rb` to register the variant group in
   the Xcode project.

The picker and runtime switching pick it up automatically after that.
