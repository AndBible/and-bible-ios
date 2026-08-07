# App Store metadata automation — design

Date: 2026-08-07
Status: approved, not yet implemented
Scope: App Store Connect **text** metadata for the iOS app, generated from source
and pushed with `fastlane deliver`. Screenshots are explicitly out of scope.

## Problem

`and-bible-ios` has an automated binary pipeline (`make testflight` →
`scripts/upload-testflight.sh`) but **no App Store listing automation at all**:
no `fastlane/`, no metadata tree, no localized store copy. The app is heading for
its first App Store release (`CFBundleShortVersionString = 1.0.0`, README carries
an App Store badge with no link yet), so every listing field would otherwise be
typed by hand into App Store Connect, in every locale, on every release.

Meanwhile the Android repo already carries a complete, translated store-copy
pipeline: `and-bible/play/` holds an English master (`playstore-description.yml`),
51 Transifex translations (`description-translations/*.yml`), shared constants,
Jinja2 templates and a renderer (`compile_description.py`). Those translations are
human-made and kept at 100 % coverage by the project's Transifex configuration.
Re-authoring the same prose for iOS would waste that work and immediately drift.

## Goals

1. Generate the complete App Store text metadata tree from source, for 34 locales.
2. Reuse the Android Transifex translations as the source of truth for prose,
   per ADR-0009 (Android is the authority for shared strings).
3. Make every iOS-specific divergence explicit, reviewable and localized.
4. Catch Apple's metadata rules (notably: no other-platform names) locally,
   before an upload is attempted.
5. Push with one command, reusing the existing App Store Connect API key handling.
6. Never touch screenshots — they are uploaded by hand for the first release.

## Non-goals

- Screenshot generation or upload (separate future spec).
- Pricing, territory availability, build-to-version assignment.
- Creating the App Store listing itself (done once in App Store Connect; this
  pipeline updates an existing listing).
- Submitting for review.
- Changing anything in `and-bible` (Android). This pipeline only reads it.

## Architecture

Three layers: an upstream source we only read, an iOS source we maintain, and a
generated tree we commit.

```
and-bible/play/                          ANDROID — source of truth for prose
  playstore-description.yml              English master, keyed
  description-translations/*.yml         51 Transifex translations
  constants.yml                          URLs, document/language counts
        │  read-only, at a pinned commit
        ▼
and-bible-ios/appstore/                  iOS SOURCE — maintained here
  description_template.txt               Jinja2, plain text, iOS feature selection
  ios_source.yml                         English: iOS key overrides + short fields
  ios_translations/<apple-locale>.yml    per-locale, same key shape as ios_source
  locales.yml                            Play→Apple map + platform substitutions
  app_info.yml                           categories, URLs, copyright
  release_notes.txt                      English, written to every locale
  review_information.yml                 public reviewer notes (no personal data)
  app_rating.json                        age-rating questionnaire answers
  android_source.lock                    and-bible commit SHA used for generation
        │  scripts/assemble_appstore_metadata.py
        ▼
and-bible-ios/fastlane/metadata/         GENERATED, committed
  <apple-locale>/
    name.txt subtitle.txt description.txt keywords.txt
    promotional_text.txt release_notes.txt
    support_url.txt marketing_url.txt privacy_url.txt
  copyright.txt primary_category.txt secondary_category.txt
  review_information/*.txt
```

`ios_source.yml` + `ios_translations/` deliberately mirror the Android
`playstore-description.yml` + `description-translations/` shape. If the iOS copy
is ever moved to Transifex as its own resource, the files are already in the
right form and the renderer needs no change.

### Merge order

Per locale, later layers win:

1. `constants.yml` (Android) — URLs, `total_documents`, `total_languages`
2. `playstore-description.yml` (Android English master)
3. `description-translations/<play-locale>.yml` (Android translation)
4. `ios_source.yml` (iOS English overrides)
5. `ios_translations/<apple-locale>.yml` (iOS translation of the overrides)

Empty values are dropped before merging, matching `compile_description.py`, so a
translation that leaves a key blank falls back to English rather than emitting an
empty line. Values are Jinja-rendered against the merged variable set (Android's
renderer does this too — keys such as `paragraph_1_1` contain `{{ title }}`).

### Locale mapping

App Store Connect supports a fixed locale set that does not match Play's. 34 of
the 51 Android translations map:

| Play | Apple | Play | Apple | Play | Apple |
|---|---|---|---|---|---|
| ar | ar-SA | id | id | ro | ro |
| ca | ca | it-IT | it | ru-RU | ru |
| cs-CZ | cs | iw-IL | he | sk | sk |
| da-DK | da | ja-JP | ja | sv-SE | sv |
| de-DE | de-DE | ko-KR | ko | th | th |
| el-GR | el | ms-MY | ms | tr-TR | tr |
| en-US | en-US | nl-NL | nl-NL | uk | uk |
| es-ES | es-ES | no-NO | no | vi | vi |
| fi-FI | fi | pl-PL | pl | zh-CN | zh-Hans |
| fr-FR | fr-FR | pt-BR | pt-BR | zh-TW | zh-Hant |
| hi-IN | hi | pt-PT | pt-PT | | |
| hr | hr | | | | |
| hu-HU | hu | | | | |

Dropped — no App Store locale exists: `af bg bn-BD eo et fil kk lt my-MM ne-NP
sl sr sw ta-IN te-IN ur yue`.

Also not generated: `en-GB`, `en-AU`, `en-CA`, `es-MX`, `fr-CA`. The App Store
falls back to `en-US` / `es-ES` / `fr-FR` in those storefronts, so duplicating the
text would add five identical copies to maintain and nothing else. The map lives
in `locales.yml`, so adding them later is a data change.

## iOS divergences from the Android copy

The description is otherwise identical to Android's, by decision — no
iOS-specific marketing paragraph. Five keys need to change, for correctness or to
satisfy Apple.

### 1. The platform name

`paragraph_1_1` says "…offline Bible study app for Android…". App Store Review
Guideline 2.3.10 forbids other-platform names in metadata. The word occurs
**exactly once per translation file**, in 43 of the 51 translations, and is an
invariant proper noun in most languages (Finnish "Androidille" → "iOS:lle").

Handled by a post-render substitution driven by `locales.yml`:

```yaml
platform_substitutions:
  default:
    - { from: "Android", to: "iOS" }
  hu: [{ from: "Androidra", to: "iOS-ra" }]
  pl: [{ from: "Androida", to: "iOS-a" }]
  hr: [{ from: "Androidu", to: "iOS-u" }]
  sl: [{ from: "Androidu", to: "iOS-u" }]
```

Per-locale rules are applied before the default rule, so inflected forms get the
hyphenated spelling the language actually uses for an invariant foreign noun. The
substitution is applied to the **rendered** description, not to the source YAML,
so `and-bible` is never modified.

### 2–5. Key overrides in `ios_source.yml`

| Key | Why | iOS text (English source) |
|---|---|---|
| `feature_08` | Android's sync includes Google Drive; iOS deliberately does not (`RemoteSyncBackend` is `iCloud`/`nextCloud` only, `CLAUDE.md` "Google Drive is intentionally removed from the iOS sync surface") | Cross-device sync over iCloud or NextCloud/WebDAV: workspaces, bookmarks, notes and reading progress stay in sync |
| `feature_09` | "set reading goals" has no iOS counterpart; what exists is `ReadingPlanService` plus `ReadingProgressStore` (chapters read, active days, cycles) | Reading plans and progress tracking, plus verse memorization with Word Scramble, Word Order, Word Blur and Type It modes |
| `feature_11` | Apple review risk: the AI agent must be described as opt-in and bring-your-own-key | Optional AI study agent — off by default, and requires your own API key from a third-party provider. Explore your installed commentaries and dictionaries with AI assistance in your chosen language. A built-in permission system keeps you in full control of what the agent can do. |
| `feature_12` | The app ships with no preinstalled modules; a bare "works offline" claim overpromises | Works offline: once you have downloaded or imported your documents, no internet connection is needed |

The exact English wording above is the starting point; it is authored in
`ios_source.yml` and may be refined during implementation. What is fixed is the
**set of keys that diverge** and the reason for each.

These overrides are translated into all 34 locales (see "Translation workflow"),
so a non-English listing is not left with English bullets in a translated list.

### Short fields with no Android counterpart

`subtitle` (30), `keywords` (100) and `promotional_text` (170) do not exist in
the Play source at all. Android's `subtitle_1` is translated but exceeds 30
characters in 22 of the 34 locales, so it cannot simply be reused. All three are
authored in `ios_source.yml` in English and translated per locale.

`name.txt` comes from the translated Android `title` ("AndBible: Bible Study",
21 chars in English) and is length-checked at 30.

## Generator

- `scripts/lib/appstore_metadata.py` — pure module: loading, merging, rendering,
  locale mapping, substitutions, validation. No I/O side effects beyond reading
  the paths it is given; this is what the tests exercise.
- `scripts/assemble_appstore_metadata.py` — thin CLI.
  - default: write the whole `fastlane/metadata/` tree
  - `--check`: render in memory, compare against the committed tree, exit 1 on
    drift, write nothing
  - `--android-root PATH`: override. Resolution order is the flag, then
    `ANDBIBLE_ANDROID_ROOT` (which `ios-ci.yml` already sets), then the
    gitignored `.and-bible-android/` that `CLAUDE.md` documents as the local
    reference location, then `../and-bible` (the fallback
    `scripts/ensure_android_reference_checkout.sh` already uses). A candidate
    counts only if it actually contains `play/constants.yml`, so an empty
    directory cannot shadow a real checkout. `CLAUDE.md` forbids hard-coding a
    sibling path, which is why this is a resolver and not a constant.

The script **reads** the Android checkout and never mutates it. In particular it
does not invoke `scripts/ensure_android_reference_checkout.sh`, which detaches
HEAD and refuses a dirty tree — appropriate for CI, destructive for a developer's
sibling working copy.

### Validation

Failures are errors, not warnings — a bad listing is worse than a failed build.

| Check | Limit / rule |
|---|---|
| `name` | ≤ 30 characters |
| `subtitle` | ≤ 30 characters |
| `keywords` | ≤ 100 characters |
| `promotional_text` | ≤ 170 characters |
| `description` | ≤ 4000 characters |
| `release_notes` | ≤ 4000 characters |
| Platform words | no `android`, `google play`, `play store` (case-insensitive) in any rendered field |
| Unresolved template | no `{{`, `}}` left in output |
| Key coverage | every key the template references resolves; no unknown keys in `ios_translations/*.yml` |

Locale coverage is reported, not enforced: a mapped locale with no
`ios_translations` file falls back to the English `ios_source.yml` values and the
generator prints the list of such locales. Enforcing it would make the tree
ungeneratable until all 34 translations exist, which is exactly the state the
pipeline has to be built in. The `appstore-copy` skill closes the gap.

**Lengths are counted in characters, not bytes.** The Telugu description is 9933
bytes but roughly 3300 characters; a byte-based check would reject valid copy.

### Pinning the Android source

`appstore/android_source.lock` holds the `and-bible` commit SHA the committed
metadata was generated from.

CI checks out exactly that SHA, so `--check` there is a true drift test. Locally
a developer's sibling `and-bible` checkout will often sit on some other commit —
a superrepo submodule branch, say. Requiring the SHA would make
`appstore-validate` unrunnable for them, so the generator does **not** enforce it:
it compares the checkout's HEAD against the lock and, on a mismatch, prints the
two SHAs and names this as the likely cause of any drift it then reports. Passing
`--require-pinned` turns the mismatch into an error; CI passes it.

Refreshing the Android source is its own reviewable commit: bump the lock,
regenerate, and the diff shows exactly which locales changed.

## Publishing pipeline

`scripts/lib/asc-api-key.sh` is extracted from `upload-testflight.sh` — the
RAM-disk mount, GPG/YubiKey decryption, permission tightening and eject-on-exit
trap, unchanged in behaviour. It exposes both artefacts callers need: the `.p8`
file (xcodebuild) and a `asc_api_key.json` (`{key_id, issuer_id, key,
in_house:false}`, mode 600) for fastlane's `--api_key_path`. `upload-testflight.sh`
is refactored to use it, so there is one implementation of the key handling.

- `fastlane/Appfile` — `app_identifier "org.andbible.ios"`
- `fastlane/Deliverfile` — `metadata_path "./fastlane/metadata"`,
  `skip_binary_upload true`, `skip_screenshots true`, `submit_for_review false`,
  `force true`, `precheck_include_in_app_purchases false`
- `scripts/deliver-appstore-metadata.sh` — key setup, then `fastlane deliver`

**`skip_screenshots true` is load-bearing.** Screenshots are uploaded by hand;
deliver must not delete or reorder them. (AndroidMidiRecorder sets
`overwrite_screenshots true` because it generates them — the opposite situation.)

No `Fastfile`: as in AndroidMidiRecorder, the `Deliverfile` plus CLI flags cover
everything, and a Fastfile would add a Ruby layer with nothing to do.

### Make targets

| Target | Runs on | Does |
|---|---|---|
| `appstore-metadata` | Linux or macOS | generate the tree |
| `appstore-validate` | Linux or macOS | `--check` + all validations; **offline, no YubiKey, no network** |
| `appstore-precheck` | macOS | `fastlane precheck` — Apple's own metadata rules against the live listing |
| `appstore-deliver` | macOS | upload text metadata |

Generation and validation are deliberately runnable in the Linux dev container;
only the two targets that talk to App Store Connect need macOS and the YubiKey.

`fastlane precheck` independently checks for other-platform mentions, so it
double-covers the local platform-word guard — with the local guard giving the
answer in a second instead of after a round trip to Apple.

## Translation workflow

The 34 `ios_translations/<apple-locale>.yml` files are produced by per-locale
LLM sub-agents, following the pattern established by AndroidMidiRecorder's
`translate-strings` skill. A new skill `.claude/skills/appstore-copy/` in this
repo:

1. reads `ios_source.yml`, computes its content hash
2. reports locales whose translation is missing, or whose recorded
   `source_sha` no longer matches — that is, whose English source has changed
3. dispatches one sub-agent per stale locale, giving it the English source, the
   corresponding Android translation (for terminology and register), and the
   App Store character limits as hard constraints
4. the agent writes `ios_translations/<locale>.yml` including the current
   `source_sha`
5. `make appstore-validate` confirms every file fits its limits

Each translation file records `source_sha` so staleness is detectable rather than
assumed. Marketing copy is translated idiomatically, not literally; the character
limits are constraints the agent must satisfy, not truncation applied afterwards.

This is LLM-authored text in an upstream project whose UI strings come from
Transifex. It is confined to iOS-only App Store fields that have no Transifex
resource, and the files are shaped so they can be handed to Transifex later
without touching the renderer.

## App-level metadata

`appstore/app_info.yml`:

- `primary_category: REFERENCE`, `secondary_category: BOOKS` — AndBible is
  primarily a study tool (search, commentaries, Strong's, cross-references);
  Reference describes it more accurately than Books and is less crowded.
- `copyright: 2026 Tuomas Airaksinen, Jared Murrell and the AndBible contributors`
  — the iOS app's own authorship, which differs from the Android app's.
- `marketing_url: https://andbible.org`
- `support_url: https://github.com/AndBible/and-bible/wiki/Support`
- `privacy_url: https://andbible.org/privacy.html`

These three URLs must be live before the first upload; the privacy URL in
particular is mandatory in App Store Connect and currently appears only in
`README.md`, not in the app.

`appstore/release_notes.txt` holds English release notes, written verbatim into
every locale's `release_notes.txt`. Release notes are not translated — by
decision, since they change every release and their value does not justify 34
translation runs.

## App Review Information

`appstore/review_information.yml` carries only the **notes** — public information
that genuinely helps a reviewer, and the part worth versioning:

- The app ships with no Bible texts. First launch prompts the reviewer to
  download a module from a SWORD repository or import a file; without that the
  reader is empty by design.
- Discrete mode (`Settings → Discrete mode`) replaces the launcher icon with a
  calculator and gates entry behind a PIN. It exists so users in countries where
  possessing religious material is dangerous can keep the app inconspicuous. It
  hides nothing from the reviewer: it is documented in the app's own settings and
  every feature remains reachable. It is not encryption and is not marketed as
  security.
- The AI study agent is off by default, requires the user's own API key from a
  third-party provider, stores that key only in the device Keychain, and gates
  every tool call behind a permission prompt.
- The ATS exceptions (`crosswire.org`, `ebible.org`, `ibtrussia.org`,
  `stepbible.org`, `github.io`) exist because several SWORD module repositories
  are still HTTP-only. They are download endpoints, not user-data endpoints.

Reviewer **contact details** (name, phone, email) are personal data and must not
be committed to a public repository. They come from a gitignored
`appstore/review_information.local.yml`, overlaid on the public notes at load
time; `appstore/*.local.yml` is added to `.gitignore`. When the file is absent
the generator omits those fields entirely and deliver leaves whatever App Store
Connect already holds. One mechanism, not two — no environment-variable
alternative.

`appstore/app_rating.json` holds the age-rating questionnaire answers in
deliver's `app_rating_config_path` format, so the rating is versioned and
reviewable rather than clicked once in a web form.

## Testing

`scripts/test_appstore_metadata.py`, following the repo's existing
`scripts/test_*.py` convention, covering:

- rendering a locale end to end from small fixtures
- merge precedence: iOS translation beats iOS source beats Android translation
  beats Android master beats constants
- blank values in a translation falling back to English rather than emitting
  empty lines
- the Play→Apple locale map, including that unmapped Play locales are dropped and
  that no unmapped Apple locale is emitted
- platform substitution: the default rule, a per-locale inflected rule, and the
  guard firing when a platform word survives
- every length limit, at the boundary, counted in characters — with a
  multi-byte-script case that passes on characters and would fail on bytes
- `--check` reporting drift and writing nothing
- the `android_source.lock` mismatch error

CI: a new job in `.github/workflows/ios-ci.yml` that checks out the Android repo
at the SHA in `android_source.lock` and runs the unit tests plus
`assemble_appstore_metadata.py --check`. It needs no macOS runner and no
credentials.

## Documentation

`docs/howto/appstore-metadata.md`, alongside the existing
`docs/howto/testflight-cli-upload.md`: the four Make targets, what runs where,
how to change copy (edit the Android source for shared prose, `ios_source.yml`
for iOS-only text), how to refresh translations, and how to bump
`android_source.lock`. `CLAUDE.md` gets a short section pointing at it.

## Risks and open items

- **`shop.andbible.org` in-app link.** `BibleReaderView.swift`, `HelpView.swift`
  and `AndroidTextDisplayHelpDialog.swift` link to an external shop. That is a
  Guideline 3.1.1 risk (external purchase link). It is an app change, out of
  scope here, but it should be resolved before the first submission.
- **Privacy policy URL** must be live at `https://andbible.org/privacy.html`
  before the first upload, and should also be linked from the app's settings.
- **The listing must exist in App Store Connect first.** `deliver` updates an
  existing app record; creating it and setting bundle ID, pricing and territories
  is a one-time manual step.
- **Substitution quality in inflecting languages** is verifiable by reading the
  four affected locales' output. The exception table is data, so adding a case is
  a one-line change.
- Apple may change locale support or field limits; both live in
  `locales.yml` and the validator, not scattered through the code.
