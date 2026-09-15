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

### Package and application-host tests

Run the package that owns the affected behavior. For example:

```bash
xcodebuild -project AndBible.xcodeproj -scheme BibleCoreTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`SwordKitTests`, `BibleViewTests`, and `BibleUITests` select the other package lanes.
`AndBibleUnitTests` selects the application scene/bootstrap contract.

### UI journeys

UI tests use the [build and fixture-wrapper workflow](docs/howto/building-and-testing.md#ui-journeys).
The wrapper installs the exact app product and owns fixture preparation on macOS before the test's
first app launch. Running a fixture-dependent UI test directly through Xcode or `xcodebuild test`
has no fixture service and fails with a setup message.

## Project Structure

```text
AndBible.xcodeproj              # Open this in Xcode
AndBible/                       # App target
Tests/AppHost/AndBibleTests/    # Application scene/bootstrap test
Tests/UI/AndBibleUITests/       # Actual UI journeys
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

Rebuild and atomically sync the production frontend fallback with
`scripts/manage_bibleview_bundle.py` before app validation when frontend assets changed. CI packages
its own verified Debug build, and release archives always package a fresh Production build.

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

### UI products or fixture setup fail

- Build into a dedicated derived-data directory and use the generated `.xctestrun` from that build.
- Follow the [UI fixture workflow](docs/howto/building-and-testing.md#ui-journeys); do not replace missing setup with an extra app launch or a guessed container.
- Search's journey requires its manifest-selected indexed fixture. Check the host service's concrete preparation error before changing a result assertion.
- Preserve the failed result bundle and compare source/product hashes before rebuilding. Deleting evidence or repeating a failed UI action does not establish correctness.

## Resources

- Full repo guidance: `CLAUDE.md`
- Android reference repository: https://github.com/andbible/and-bible
- Shared frontend code: `bibleview-js/`

## Development Workflow

1. Make the code change
2. Run repo guardrails
3. Run the narrowest relevant simulator or frontend validation
4. Commit with the repo commit-message format
