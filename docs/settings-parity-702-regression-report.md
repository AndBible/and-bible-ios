# SETPAR-702 Regression Report

Date: 2026-03-10

## Scope

Regression verification for settings parity work and CI/guardrail integration, using local simulator test execution and localization guardrail execution.

## Environment

- Repo: `and-bible-ios`
- Xcode scheme test target: `AndBibleTests.xctest` enabled (`AndBible.xcodeproj/xcshareddata/xcschemes/AndBible.xcscheme:26-54`)
- Simulator destination used: `platform=iOS Simulator,name=iPhone 17,OS=26.2`

## Executed Checks

### 1. SETPAR-603 localization guardrails (snapshot fallback path)

Command:

```bash
python3 scripts/check_settings_localization_guardrails.py --android-root /tmp/does-not-exist
```

Result: `PASS` (exit code `0`)

Observed output:

- `tree mismatches: 0`
- `ios_gap count: 0`
- `android source: snapshot:.../docs/settings-localization-android-baseline.json`
- `keys checked: 58`
- `locales checked: 44`

Evidence:

- `scripts/check_settings_localization_guardrails.py`
- `docs/settings-localization-android-baseline.json`
- `docs/settings-localization-guardrail-baseline.json`

### 2. Xcode simulator unit test run (explicit result bundle)

Command:

```bash
mkdir -p .artifacts && \
xcodebuild \
  -project AndBible.xcodeproj \
  -scheme AndBible \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' \
  -derivedDataPath .derivedData \
  -resultBundlePath .artifacts/AndBibleTests-20260310.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Result: `PASS` (`** TEST SUCCEEDED **`)

Observed test summary:

- `Executed 4 tests, with 0 failures (0 unexpected)`
- Test bundle: `AndBibleTests`
  - `testActionPreferencesUseActionShape`
  - `testAppPreferenceRegistryHasDefinitionForAllKeys`
  - `testCriticalPreferenceDefaultsMatchParityContract`
  - `testCSVSetEncodingAndDecodingRoundTrip`

Result bundle (generated during the run, not committed to git):

- `.artifacts/AndBibleTests-20260310.xcresult`

## CI Workflow Regression Verification

The CI workflow now includes the expected improvements and still runs guardrails + simulator tests:

- Job-level derived data / result bundle paths: `.github/workflows/ios-ci.yml:33-35`
- SwiftPM cache restore step: `.github/workflows/ios-ci.yml:40-49`
- Simulator test invocation with `-derivedDataPath` and `-resultBundlePath`: `.github/workflows/ios-ci.yml:147-158`
- `.xcresult` artifact upload: `.github/workflows/ios-ci.yml:160-167`

## Non-blocking Observations From Test Logs

- Simulator/runtime noise was observed (for example CoreSimulator/ExtensionKit and duplicate-class warnings from test-host loading). These warnings did not fail build/test execution in this run.

## Outcome

- Regression suite status for this pass: `PASS`
- Guardrails status for this pass: `PASS`
- Verified outputs are consistent with current parity baseline docs and tests.

## Follow-up Inputs

See `docs/settings-parity-701-verification-matrix.md` for current functional parity status by key. Current remaining items are only documented platform divergences.
