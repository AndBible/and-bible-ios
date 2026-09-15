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

## Package and application-host tests

Select the package that owns the behavior: `SwordKitTests`, `BibleCoreTests`,
`BibleViewTests`, or `BibleUITests`. These simulator lanes do not require the application host.

```bash
xcodebuild -project AndBible.xcodeproj -scheme BibleCoreTests \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .derivedData-core \
  -resultBundlePath .artifacts/BibleCoreTests.xcresult \
  CODE_SIGNING_ALLOWED=NO test
```

Use `AndBibleUnitTests` for the actual application scene/bootstrap contract. Select affected
contracts from dependency and behavior analysis; one package or one passing count does not establish
whole-app coverage. CI's execution wrapper also reconciles the selected and reported identities.

## UI journeys

The UI runner submits fixture requests to a macOS service owned by the repository wrapper.
The wrapper installs the exact app product, confirms the preceding process has stopped, obtains its
actual container, and prepares the selected fixture before the first app launch. A direct Xcode UI
run has no fixture service and fails before preparation. No discovery launch is needed.

The Downloads installation journey also uses this service as a byte-level dependency. The service
builds a valid deterministic SWORD package, holds its loopback transfer for an observed cancellation
or an explicit release, and reports the partial and completed byte counts. The app streams the held
prefix through a URLSession protocol so the visible row must show nonzero progress before release.
It opts into that protocol
only for the synthetic `uitest-download.invalid` fixture source. Installation still runs through
the production repository download delegate, progress, cancellation, ZIP validation, staged
publication, module reload, and persisted install marker; the old app-side held-install loop is not
part of the contract.

Choose a dedicated simulator UUID from `simctl list devices available`, then build once:

```bash
export UITEST_SIMULATOR_ID='SIMULATOR_UUID'
export UITEST_BUNDLE_ID='org.andbible.ios'
export UITEST_FIXTURE_TOOL_PATH="$(pwd)/.build/debug/UITestFixtureTool"
export UITEST_FIXTURE_MANIFEST_PATH="$(pwd)/Tests/UI/Fixtures/ui_test_fixture_manifest.json"
export UITEST_SWORD_FIXTURE_PATH="$(pwd)/Sources/BibleUI/Tests/BibleUITests/Fixtures/sword"
swift build --product UITestFixtureTool
xcodebuild -project AndBible.xcodeproj -scheme AndBible \
  -configuration Debug -destination "platform=iOS Simulator,id=${UITEST_SIMULATOR_ID}" \
  -derivedDataPath .derivedData-ui CODE_SIGNING_ALLOWED=NO build-for-testing
```

Run the real Search journey from those products:

```bash
python3 scripts/run_xcodebuild_with_test_selection.py \
  --project AndBible.xcodeproj --scheme AndBible --configuration Debug \
  --destination "platform=iOS Simulator,id=${UITEST_SIMULATOR_ID}" \
  --derived-data-path .derivedData-ui \
  --result-bundle-path .artifacts/SearchJourney.xcresult \
  --test-selection-args='-only-testing:AndBibleUITests/AndBibleUITests/testSearchMenuEntryTypingAndResultNavigation' \
  --action test-without-building
```

The dedicated directory must contain one `.xctestrun`; pass `--xctestrun-path` when selecting a
specific artifact from several products. Use a new result-bundle path for each run. For a restored
CI artifact, use the verified fixture tool, manifest and SWORD paths returned by its importer.
The same wrapper owns preparation and exact execution reconciliation in both cases.

See [UI sharding](ui-test-sharding.md) for full selections, product reuse, fixture isolation and
execution-cost evidence. See [performance measurements](performance-measurements.md) for the separate
Release scheme and measurement boundaries.

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

- For the current UI shard model, runtime interpretation, and guardrails, see
  `docs/howto/ui-test-sharding.md`.

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

Keep the failed result bundle and inspect the reported setup or behavior failure. Use a fresh,
dedicated derived-data directory when product provenance is uncertain. UI fixture reset belongs to
the wrapper service; it must not mutate a guessed container or run over a live app process.

### Wrong tool for validation

If you are validating the app target or simulator behavior, the command should be `xcodebuild`, not `swift build`.
