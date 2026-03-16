# AndBible iOS - Quick Start Guide

## Opening the Project

### In Xcode (Recommended)

1. Open the project:
   ```bash
   open AndBible.xcodeproj
   ```
   Or double-click `AndBible.xcodeproj` in Finder.

2. Wait for Swift package resolution.
   - First open can take a bit while Xcode resolves packages.

3. Select a simulator.
   - `iPhone 17` is the current standard simulator target used in repo validation.

4. Build and run.
   - Press `Cmd+R`
   - First build is slower than incremental builds

## Command-Line Build and Test

### Build

```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### Test

```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

### Focused Test Run

```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test -only-testing:AndBibleUITests/AndBibleUITests/testExample
```

## Project Structure

```text
AndBible.xcodeproj              # Open this in Xcode
AndBible/                       # App target
AndBibleTests/                  # App/unit test bundle
AndBibleUITests/                # UI test bundle
Package.swift                   # Local Swift package
Sources/
  SwordKit/                     # libsword wrapper
  BibleCore/                    # Models, services, persistence
  BibleView/                    # WKWebView bridge + bundled frontend
  BibleUI/                      # SwiftUI screens and reader coordinator
bibleview-js/                   # Shared Vue.js frontend
```

## What to Expect

This repository is not a placeholder scaffold.

Current baseline:
- the app builds and runs through `AndBible.xcodeproj`
- real `libsword` is consumed through `libsword/libsword.xcframework`, which is built locally and in CI via `libsword/build-ios.sh`
- the repo has active unit and XCUITest coverage
- native SwiftUI flows exist for settings, sync, bookmarks, history, workspaces, reading plans, downloads, and search
- Bible content still uses the WKWebView/Vue.js hybrid path where appropriate

## Recommended Validation Baseline

Run these after code changes:

```bash
git diff --check
python3 scripts/check_repo_standards.py docblocks --all-files
```

Then run the most relevant simulator tests for the area you changed.

## Vue.js Frontend

If you changed `bibleview-js/`, run:

```bash
cd bibleview-js
npm install            # first-time setup
npm run test:ci
npm run lint
npm run type-check
npm run build-debug
```

Rebuild the frontend bundle before app validation when frontend assets changed.

## Troubleshooting

### Package resolution failed
- Check network connectivity for the initial package fetch
- If `libsword/libsword.xcframework` is missing, build it with:
  ```bash
  cd libsword
  ./build-ios.sh
  ```
- Try Xcode clean build folder
- Reopen Xcode if resolution gets stuck

### UI tests seem stale
- Use a clean run with a dedicated derived-data path:
  ```bash
  xcodebuild -project AndBible.xcodeproj -scheme AndBible \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -derivedDataPath .derivedData-local \
    clean test
  ```

### Search UI tests suddenly return zero results
- Inspect the UI test harness setup before changing Search assertions
- Direct-launch Search tests depend on:
  - a temporary SWORD root
  - a temporary Search index path
  - bundled modules being available in the harness

## Resources

- Full repo guidance: `CLAUDE.md`
- Android reference repository: https://github.com/andbible/and-bible
- Shared frontend code: `bibleview-js/`
- Google Drive OAuth setup notes: `docs/howto/google-drive-oauth-setup.md`

## Development Workflow

1. Make the code change
2. Run repo guardrails
3. Run the narrowest relevant simulator or frontend validation
4. Commit with the repo commit-message format
