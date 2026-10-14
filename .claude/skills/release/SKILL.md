---
name: release
description: Use when preparing or shipping a new App Store / TestFlight version of the app - "tehdään uusi release", "prepare 1.0.3", "bump the version", "upload to TestFlight", "make testflight", "make appstore-deliver", "submit for review", or any step between a release branch and pressing Release in App Store Connect.
---

# Shipping a release

The steps themselves live in `docs/howto/releasing.md`. Read it first and work
through it in order; this skill adds how to drive it as an agent. Do not
duplicate the steps here — if a step is wrong or missing, fix the howto.

## Before starting

1. Ask which version is being released if the request does not say. A bug-fix
   release bumps the last number; check `CFBundleShortVersionString` in
   `AndBible/Info.plist` and `git log --oneline --grep='bump marketing version'`
   so you do not reuse a version that was already shipped or approved.
2. Create a todo item per step of the howto, so the user can see where the
   release stands.

## Operating rules

- **The user's App Store Connect is the source of truth**, not your console
  output. For anything only visible there (build processed, version created,
  listing text live, review status) ask the user to confirm instead of
  assuming.
- **Ask before every YubiKey command** (`make testflight`,
  `make appstore-deliver`, `make appstore-precheck`) with AskUserQuestion, even
  if the key was used a minute ago. The PIN dialog does not take focus and an
  unanswered prompt fails with `gpg: decryption failed: Timeout`.
- **Run each YubiKey command once, with its full output in a log file**, then
  read the log:

  ```bash
  make appstore-deliver > <scratchpad>/deliver.log 2>&1; echo "exit=$?"
  ```

  `make appstore-deliver` ends with a long fastlane update banner, so `tail`
  shows nothing useful. Never re-run a live command just to see its result.
- **Things only the user does**: creating the version in App Store Connect,
  choosing the build, filling anything in the ASC UI, submitting for review and
  pressing Release. Tell them exactly what to click; do not ask for credentials.
- **Commits and PRs** follow the repository rules: a `release/<version>` branch,
  `<type>(<scope>): <summary>` subjects, the `Why / What Changed / Validation /
  Impact` body, and a PR to `main`. Never push to `main`.
- **What's New text** is user-visible fixes only, with no platform names
  (Android, Google Play). Show the English draft to the user before translating
  when the fixes are not obvious from the log. Translations follow the
  "Release notes" section of the `appstore-copy` skill.
- After `make appstore-metadata`, revert `appstore/android_source.lock` unless
  the user asked to move the Android pin.
- After `make testflight`, check that `git status` is clean (the build number
  stamp must have been restored).

## Finishing

When the user has submitted for review, summarise the state: version, build
number, PR, and which steps remain (verify from TestFlight, then Release). If
`.local/release-handover.md` exists, offer to update it.
