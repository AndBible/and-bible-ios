# Releasing a new version

End-to-end checklist for shipping an App Store update, from a release branch to
the "Release this version" button, including the release tag. It links to the
focused guides for the details of each tool:

- [TestFlight CLI upload](testflight-cli-upload.md) — `make testflight` and its
  one-time signing and API-key setup
- [App Store metadata](appstore-metadata.md) — listing text, translations and
  `make appstore-*`

Claude Code drives this checklist through the `release` skill
(`.claude/skills/release/SKILL.md`).

Only the person who owns the App Store Connect account submits releases. Other
contributors land fixes through pull requests.

## Rules that always apply

- **PR-only.** Never commit to `main`. Every release step that changes the
  repository goes through a branch and a pull request.
- **Never skip the version bump.** Once a version is approved, App Store Connect
  closes its pre-release train and TestFlight uploads for it fail with errors
  90062 and 90186. Each release needs a new `CFBundleShortVersionString`.
- **Commands marked (YubiKey) need the key inserted** and a PIN entry. The
  pinentry dialog does not take focus, so a command started without the key
  ready just sits until `gpg` reports `decryption failed: Timeout`. Run those
  commands in the foreground and keep the full output, because the fastlane
  update banner at the end of `make appstore-deliver` hides the result if you
  only look at the tail.

## 1. Decide the version

Semantic version `MAJOR.MINOR.PATCH`. A bug-fix release increments the last
number. There is no version tooling; the marketing version lives in one place,
and each version submitted for review gets a `v<version>` git tag (step 11).
`git tag -l 'v*'` shows what has been submitted.

## 2. Create the release branch

```bash
git checkout main && git pull
git checkout -b release/<version>        # e.g. release/1.0.2
```

## 3. Bump the marketing version

Edit `CFBundleShortVersionString` in `AndBible/Info.plist` by hand. Leave
`CFBundleVersion` alone: `make testflight` stamps a UTC `YYYY.MMDD.HHMMSS` build
number for the archive and restores the file afterwards, so the tree stays clean.

Commit it as `chore(release): bump marketing version to <version>`, using the
usual `Why / What Changed / Validation / Impact` body.

## 4. Write the "What's New" text

1. List the **user-visible** fixes since the last release
   (`git log --oneline <last-bump-commit>..main`). Leave out CI, test and
   internal refactors.
2. Rewrite `appstore/release_notes.txt` in English: one intro line and one
   bullet per fix. Do not mention other platforms by name (Android, Google Play):
   Apple rejects platform references, and `make appstore-validate` enforces it
   in every locale.
3. Translate it into the other 33 locales. See "Release notes" in the
   `appstore-copy` skill (`.claude/skills/appstore-copy/SKILL.md`); each file in
   `appstore/release_notes_translations/` needs the digest from
   `python3 scripts/appstore_release_notes.py --digest`.
4. Render and validate:

   ```bash
   make appstore-release-notes     # must report all 34 locales current
   make appstore-metadata
   make appstore-validate
   git diff --check
   ```

   `make appstore-metadata` rewrites `appstore/android_source.lock` when the
   local Android checkout is out of date. Revert that file
   (`git checkout appstore/android_source.lock`) unless you meant to move the pin.

Commit the text, translations and the regenerated `fastlane/metadata/` together
as `chore(appstore): write <version> What's New for all locales`.

## 5. Open the pull request

Push the branch and open a PR to `main`. CI must be green before it is merged.

## 6. Upload the build to TestFlight (YubiKey)

```bash
make testflight
```

This archives from the **current working tree**, so run it from the release
branch. It ends with `Upload succeeded` and `>> Done`. Afterwards
`git status` must be clean. A build with a new marketing version appears in App
Store Connect → TestFlight after a few minutes of processing; the internal
group receives it automatically.

Write down the build number (`>> Archiving (build …)` in the output) and the
commit it was archived from (`git rev-parse HEAD`). Step 11 tags that commit.

If the build changes after upload (more fixes land), merge them, re-run the
tests, and upload a new build with the same marketing version. Build numbers
are timestamps, so a re-upload always gets a fresh one.

## 7. Verify the build from TestFlight

Install the exact build on a device and exercise the paths touched by the
release plus the main reading, search, bookmark and sync flows. This is the
last point where backing out costs nothing.

## 8. Create the version in App Store Connect

App Store Connect → the app → **+ Version** → enter the new version number.
`deliver` writes into the editable version, so it must exist before step 9.

## 9. Merge the PR, then upload the listing text (YubiKey)

Merge the pull request first so `main` and the live listing carry the same
text.

```bash
make appstore-deliver
make appstore-precheck       # optional: Apple's own rules against the live listing
```

`deliver` writes text only; the Deliverfile sets `skip_binary_upload`,
`skip_screenshots` and `submit_for_review false`. It is not atomic — if a run
fails halfway, the listing is half-written, so fix the cause and run it again.
Confirm the result in App Store Connect rather than trusting the console
output. Never edit `fastlane/metadata/` by hand and never run
`download_metadata` without regenerating the tree afterwards, because it
overwrites the rendered files.

## 10. Select the build and submit for review

In App Store Connect, on the new version:

1. Choose the build processed in step 6.
2. Check that "What's New" is filled for the locales and that screenshots,
   age rating, export compliance and App Privacy are still complete. Screenshots
   are uploaded by hand and only need changing when the UI changed.
3. Choose **Manually release this version**.
4. Submit for review. Review typically takes 24–48 hours; there is no fast lane
   other than an Expedited Review request, which should be used sparingly.

## 11. Tag the submitted build

As soon as App Store Connect accepts the submission, tag the commit the
submitted build was archived from (step 6) with an annotated `v<version>` tag
that records the build number, and push the tag:

```bash
git tag -a v<version> <commit> -m "AndBible iOS <version> (build <build-number>)"
git push origin v<version>
```

Tags are pushed directly; they do not go through a pull request. If the release
branch was merged with a merge commit, the tagged commit is still part of
`main`'s history.

If review rejects the build, or you abandon it, and a different build is
submitted for the same version, move the tag to that build's commit:

```bash
git tag -d v<version> && git push origin :refs/tags/v<version>
```

then tag again as above. A version that is withdrawn without any build
shipping loses its tag.

## 12. Release

When the build reaches `Pending Developer Release`, install it from TestFlight
once more, then press **Release This Version**. Updates can use Phased Release
(7 days, pausable) if you want a staged roll-out.

If a serious bug shows up while waiting, abandon the build for free: fix it,
bump the marketing version again (step 3) and start over from step 6. Delete
the abandoned version's tag (step 11).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Upload fails with 90062 / 90186 | The marketing version is already approved or closed. Bump it (step 3). |
| `gpg: decryption failed: Timeout` | The YubiKey PIN prompt was not answered. Insert the key and re-run. |
| `make appstore-validate`: forbidden platform reference | A translation names another platform. Reword it without the name. |
| `make appstore-validate` reports drift | Run `make appstore-metadata` and commit the regenerated tree. |
| `deliver` rejects a name with "invalid whitespace" | A `U+202F` or `U+200B` slipped in; `normalize_whitespace` should fold it, so check the source text. |
| `deliver` writes to the wrong version | The new version was not created in App Store Connect first (step 8). |
