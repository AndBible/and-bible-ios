# Building And Testing

This project should be built and tested with `xcodebuild` against a simulator. Do not use `swift build` for app validation.

## Prerequisites

- Xcode installed
- An available iOS simulator runtime
- Working directory: repo root (`and-bible-ios/`)

## Discover Destinations

List valid build destinations:

```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBible -showdestinations
```

List available simulators directly:

```bash
xcrun simctl list devices available
```

## Run The Test Suite

Use `xcodebuild test` and target a simulator.

```bash
xcodebuild \
  -project AndBible.xcodeproj \
  -scheme AndBible \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .derivedData \
  -resultBundlePath .artifacts/AndBibleTests.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Notes:
- `CODE_SIGNING_ALLOWED=NO` keeps CLI simulator runs simple.
- `.derivedData/` and `.artifacts/` are local build artifacts and should not be committed.
- Current maintained regression coverage includes the Strong's `H02022` find-all flow in `AndBibleTests/AndBibleTests.swift`.

## Build The App For Simulator

If you only need a build artifact:

```bash
xcodebuild \
  -project AndBible.xcodeproj \
  -scheme AndBible \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .derivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Install And Launch In Simulator

After a successful simulator build:

```bash
xcrun simctl install booted .derivedData/Build/Products/Debug-iphonesimulator/AndBible.app
xcrun simctl launch booted org.andbible.ios
```

If no simulator is booted, boot one first:

```bash
xcrun simctl boot 'iPhone 17'
open -a Simulator
```

## When To Use Xcode.app

Use Xcode.app when you need:
- visual debugging
- SwiftUI previews
- breakpoint-heavy debugging in the app target
- signing/profile troubleshooting

Use `xcodebuild` when you need:
- repeatable local validation
- CI parity
- scripted simulator runs
- fast verification of a branch before commit

## Related Docs

- For live Google Drive sign-in setup, see `docs/howto/google-drive-oauth-setup.md`.

## Vue.js Bundle Notes

The native app hosts a packaged web bundle through `BibleWebView`.

Relevant loader path:
- `Sources/BibleView/Sources/BibleView/BibleWebView.swift:279-301`

If the packaged bundle is missing, the app falls back to a placeholder page instead of the real client.

## Common Failures

### "bundle not found" in BibleView

Check that the packaged web resources exist under:
- `Sources/BibleView/Sources/BibleView/Resources`

### Simulator tests fail because of stale state

Delete local artifacts and rerun:

```bash
rm -rf .derivedData .artifacts
```

Only do this for local cleanup. Do not remove tracked files.

### Wrong tool for validation

If you are validating the app target or simulator behavior, the command should be `xcodebuild`, not `swift build`.
