# App Store metadata

The App Store listing text for all 34 supported locales is generated from
source and uploaded with `fastlane deliver`. Screenshots are **not** part of
this pipeline — they are uploaded by hand, and `fastlane/Deliverfile` sets
`skip_screenshots true` so `deliver` never touches them.

## Where the text comes from

| Layer | Where | Who maintains it |
|---|---|---|
| Description prose, in many languages | the Android repo's `play/` (Transifex) | Android project translators |
| iOS overrides + subtitle/keywords/promotional text | `appstore/ios_source.yml` | here, English |
| Translations of the iOS-only layer | `appstore/ios_translations/*.yml` | the `appstore-copy` skill |
| Categories, URLs, copyright | `appstore/app_info.yml` | here |
| Release notes | `appstore/release_notes.txt` | here, English only (see below) |
| Reviewer notes (public) | `appstore/review_information.yml` | here |
| Reviewer contact details (personal data) | `appstore/review_information.local.yml`, gitignored | you, locally |
| The uploaded tree | `fastlane/metadata/` | **generated — never edit by hand** |

`appstore/locales.yml` maps each Play Store locale to its App Store Connect
equivalent (34 pairs) and carries the platform-name substitution rules (see
below). 17 Android translations have no App Store equivalent and are simply
absent from the map; `en-GB`/`en-AU`/`en-CA`/`es-MX`/`fr-CA` are deliberately
not generated because the App Store falls back to `en-US`/`es-ES`/`fr-FR` in
those storefronts.

## Commands

```bash
make appstore-metadata    # generate fastlane/metadata (Linux or macOS)
make appstore-validate    # drift + field limits + platform-name rule (offline)
make appstore-precheck    # Apple's own metadata rules (macOS, YubiKey)
make appstore-deliver     # upload the text metadata, live (macOS, YubiKey)
```

Generation and validation need nothing but Python (`PyYAML`, see
`scripts/requirements-appstore.txt`) and a checkout of the Android
repository. On a fresh machine that means network access at least once, to
clone that checkout (below) — after that, both targets run fully offline.
Only the two upload targets need macOS and an App Store Connect API key (see
`docs/howto/testflight-cli-upload.md` for the one-time key setup —
`deliver-appstore-metadata.sh` reuses the same `lib-asc-api-key.sh` decrypt
step and `~/.appstoreconnect/asc-api.env`).

### Getting the Android checkout

`scripts/appstore_metadata.py`'s `resolve_android_root` looks, in order:

1. `--android-root <path>`, if the calling command took one (`assemble_appstore_metadata.py`
   only; `find_stale.py` does not).
2. `$ANDBIBLE_ANDROID_ROOT`, if set.
3. `.and-bible-android/` at the repo root (gitignored — the documented local
   location; also used for Android-parity reference per the top-level
   `CLAUDE.md`).
4. `../and-bible` (a sibling checkout).

A candidate only counts if it actually contains `play/constants.yml` — an
empty or wrong directory does not silently shadow a real checkout. `CLAUDE.md`
forbids hard-coding a sibling path in committed config, which is why this
resolver exists instead of a single hardcoded location:

```bash
git clone https://github.com/AndBible/and-bible.git .and-bible-android
```

On a machine where you haven't done this yet, the very first
`make appstore-metadata` or `make appstore-validate` you run will fail with
exit code 2 and a "No Android store copy found" message. That's expected,
not a broken pipeline — run the clone above and re-run the command.

CI goes through this exact same resolver — there is no separate code path —
but it doesn't rely on any of the developer-local fallbacks above.
`.github/workflows/ios-ci.yml` sets `ANDBIBLE_ANDROID_ROOT: ../and-bible` at
the workflow level (so it wins as rung 2) and its `appstore-metadata` job
checks out precisely the commit pinned in `appstore/android_source.lock`
into that path before running the script. Same resolver, same code — CI just
controls which candidate exists and what it contains, so the render is
reproducible regardless of what a developer happens to have checked out
locally.

## Changing the copy

- **Shared prose** (any description bullet not overridden for iOS): change it
  in the Android project and let Transifex translate it. Then update your
  local Android checkout, run `make appstore-metadata` (this rewrites
  `appstore/android_source.lock` to the new Android commit — see below), and
  commit the regenerated `fastlane/metadata/` tree together with the lock
  file.
- **iOS-only text**: edit `appstore/ios_source.yml`, then run the
  `appstore-copy` skill to refresh the translations (it digests the English
  source into a `source_sha` that each translation file records, so an
  out-of-date translation is detected automatically), then `make
  appstore-metadata`.
- **Never edit `fastlane/metadata/` by hand.** The tool owns the *entire*
  directory, not just the `.txt` files it writes: `make appstore-validate`
  reports anything in that tree it did not render as `stale`, and a plain
  `make appstore-metadata` deletes it. This matters if you ever bootstrap the
  age-rating file (below) by running `fastlane deliver
  download_metadata` — that command writes into `fastlane/metadata/` too, and
  those files must be copied out before the next `make appstore-metadata` run
  or they are silently removed.

### The Android lock file and why it sometimes doesn't update

`appstore/android_source.lock` records the Android commit the committed
`fastlane/metadata/` tree was rendered from. A plain `make appstore-metadata`
run:

- **rewrites the lock** to your Android checkout's current `HEAD`, if that
  checkout is clean;
- **leaves the lock unchanged and prints a warning** if the Android checkout
  has uncommitted changes — the commit SHA would not actually describe what
  was just rendered, so writing it would be misleading.

`make appstore-validate` (`assemble_appstore_metadata.py --check`) checks the
tree against the lock but only *warns* on a mismatch locally — you can render
against an unpinned or ahead-of-lock checkout while iterating. CI runs the
same script with `--require-pinned`, which turns both a mismatch **and** a
missing/SHA-less lock file into a hard failure — a render that can't be tied
to a specific Android commit is not allowed to reach `main`.

## Release notes are English-only, and optional

Unlike every other locale field, "What's New" is rendered into `en-US` alone
(`RELEASE_NOTES_LOCALE` in `scripts/appstore_metadata.py`). It describes one
release and is rewritten for the next, so a translated copy would sit stale in
the other 33 locales long before a translator saw it; App Store Connect shows
the primary locale's text in any storefront whose localisation has none, so
English-only degrades cleanly rather than leaving a gap.

An **empty** `appstore/release_notes.txt` renders no `release_notes.txt`
anywhere at all, and `deliver` then leaves the field untouched. That is the
correct state for a first release — there is no previous version for "What's
New" to describe, and App Store Connect rejects release notes on an app's very
first version. It is also why the tree is 276 files rather than 310: 34 locales
× 8 fields, plus the three app-level files and the reviewer notes.

Before shipping an update, put the English text in `appstore/release_notes.txt`
and re-run `make appstore-metadata`; `en-US/release_notes.txt` reappears and no
other locale gains one.

## Why the description differs from Play's

Four keys are overridden in `appstore/ios_source.yml`, each with the reason in
a comment: sync backends (no Google Drive on iOS), reading plans instead of
"reading goals", the AI agent's opt-in and bring-your-own-key framing, and the
subtitle/keywords/promotional text fields (which have no Play Store
equivalent at all). One further difference is mechanical: App Store Review
Guideline 2.3.10 forbids naming other platforms, so `appstore/locales.yml`
rewrites "Android" to "iOS" in the rendered text, with per-locale
substitution rules for the languages that inflect it (e.g. Polish "Androida"
→ "iOS-a", not the default rule's ungrammatical "iOSa").

`scripts/appstore_metadata.py`'s validator also rejects the literal words
"android", "google play" and "play store" (case-insensitively) in **every**
rendered field — not just `description`. It applies equally to `subtitle`,
`keywords`, `promotional_text` and the rest, as a backstop against a
substitution rule missing a locale.

## Writing Japanese/Chinese translations: the CJK space guard

`appstore/ios_translations/ja.yml`, `zh-Hans.yml` and `zh-Hant.yml` write
almost every value as a single flow-scalar line rather than YAML's folded
`>` block style. This is not a style preference — the validator
(`find_cjk_adjacent_spaces`) rejects **any space with a CJK character on both
sides**, anywhere in a rendered field.

The reason is a YAML implementation detail: a folded scalar (`key: >`) turns
every internal line break into a single space. That's invisible and correct
in space-delimited languages, since it lands exactly where a word space
belongs — but Japanese and Chinese don't put spaces between words at all, so
a wrapped line becomes a stray space in the middle of a sentence, and nobody
proofreading the rendered text would spot it unless they know to look. A
space next to a Latin character (e.g. "…借助 AI 探索…", the recommended
Chinese convention at a Latin/CJK boundary) is unaffected — the guard only
fires when *both* neighbours are CJK. `zh-Hans.yml` and `zh-Hant.yml` do use
`>` for `feature_11`, but only because the wrapped line happens to break at a
Latin-character boundary; if you edit that value, either keep the line break
at a non-CJK boundary or flatten it back to one line. When in doubt, write
the whole value on one line.

## Reviewer contact details

`appstore/review_information.yml` holds only the notes — public information.
The contact details are personal data and must never be committed to this
public repository. There is no environment-variable fallback for them: put
them in `appstore/review_information.local.yml` (gitignored via
`appstore/*.local.yml`):

```yaml
first_name: "..."
last_name: "..."
phone_number: "+358..."
email_address: "..."
```

When the file is absent, those fields are simply omitted from the rendered
tree and `deliver` leaves whatever App Store Connect already has.

## Age rating

`appstore/app_rating.json` does not exist in this repository yet, and cannot
be created from anywhere but a live App Store Connect listing — its key set
is defined by the installed fastlane version, so it must not be hand-written.
Bootstrap it once, on macOS, after the app record exists in App Store Connect
(see the first-release checklist):

```bash
fastlane deliver download_metadata --api_key_path "$ASC_KEY_JSON"
cp fastlane/metadata/app_rating_config.json appstore/app_rating.json
```

`download_metadata` writes into `fastlane/metadata/`, which this pipeline
otherwise owns entirely — copy the file out to `appstore/` (as above) *before*
running `make appstore-metadata` again, or it is deleted as stale.

Then add to `fastlane/Deliverfile`:

```ruby
app_rating_config_path "./appstore/app_rating.json"
```

and commit both the config path change and `appstore/app_rating.json`.

## Verifying without uploading anything

```bash
python3 -m unittest discover -s scripts -p 'test_*.py'    # scripts/ test suite
make appstore-validate                                     # drift + rules
python3 .claude/skills/appstore-copy/find_stale.py          # missing/stale locales
grep -ril 'android' fastlane/metadata/ || echo "clean"       # no leaked platform refs
```

All four are safe to run repeatedly and touch nothing outside `fastlane/metadata/`
(and only `make appstore-metadata`, not `--validate`/`--check`, writes there).

## First release checklist

1. Create the app record in App Store Connect (bundle ID `org.andbible.ios`),
   set pricing and territories. `deliver` updates an existing record; it does
   not create one.
2. Confirm `https://andbible.org/privacy.html` is live — App Store Connect
   requires the privacy URL, and it's already set in `appstore/app_info.yml`.
3. `make appstore-validate`
4. `make appstore-deliver` — reads this carefully: it prints the number of
   locales and the app-level files it's about to overwrite, then uploads
   immediately. There is no dry-run mode and `fastlane/Deliverfile` sets
   `force true`, which skips `deliver`'s interactive HTML-preview
   confirmation. Read the printed summary before running it, not after.
   `appstore/release_notes.txt` is empty for the 1.0 submission, so no
   `release_notes` field is uploaded at all — see "Release notes are
   English-only, and optional" above for why that avoids App Store Connect's
   rejection of release notes on a first version.
5. `make appstore-precheck` — Apple's own metadata rules against the live
   listing, run **after** step 4, not before: `precheck` inspects whatever
   App Store Connect currently holds, so running it before the new text is
   uploaded would only tell you about the *old* listing. It's meaningful
   here, once the new text is live and before you submit for review.
6. Upload screenshots by hand (this pipeline deliberately never touches
   them).
7. Bootstrap and commit the age rating (`appstore/app_rating.json`, above) —
   App Store Connect requires it before a submission can go out, and it can
   only be created once the app record from step 1 exists.
8. Attach the build (`docs/howto/testflight-cli-upload.md`) and submit for
   review.
