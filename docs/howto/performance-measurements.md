# Reader performance measurements

Use the `AndBiblePerformance` shared scheme for Release measurements with the production web bundle. It disables coverage and detailed accessibility exports. The regular `AndBible` correctness scheme excludes these repeated measurements.

The harness measures process launch, warm foreground return, and opening Search, Bookmarks and Settings from the reader drawer. Launch and return require actual visible Genesis text inside the reader WebView. Destination measurements keep one live app process and use the actual Back control outside each measured interval to return to visible scripture. These are warm destination workloads; process-launch measurements remain separate. Destination measurements start at one tap on the visible drawer action and end at an on-screen, hittable destination control. Search and Settings measure control availability. Bookmarks additionally requires on-screen Back and filter controls, a nonzero visible scroll viewport, and a visible row or explicit empty state. A partially clipped filter cannot satisfy Bookmarks readiness. Each method explicitly selects its prelaunch fixture: `search-indexed` for Search and `baseline` for the other four. No launch argument opens the measured destination. Fixture materialization, process termination and background transition occur outside each measured interval. XCTest discards a warmup iteration and records five measured iterations by default. Change `PERFORMANCE_ITERATIONS` in the performance scheme for longer runs.

## Reproduce a simulator run

Use one simulator at a time and avoid concurrent builds or tests during measurement. Build the existing fixture tool before running:

```bash
swift build --product UITestFixtureTool
```

Build test products through the checked-in project. Replace the simulator identifier and choose fresh artifact paths:

```bash
xcodebuild -project AndBible.xcodeproj -scheme AndBiblePerformance \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath /tmp/andbible-performance \
  -resultBundlePath /tmp/andbible-performance-build.xcresult \
  -enableCodeCoverage NO -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Run through the repository wrapper, which owns the macOS fixture service and reconciles the final xcresult with the requested test identities. Supply explicit verified fixture inputs; replace all placeholder paths below:

```bash
export UITEST_SIMULATOR_ID='SIMULATOR_UUID'
export UITEST_BUNDLE_ID='org.andbible.ios'
export UITEST_FIXTURE_TOOL_PATH='/absolute/path/to/UITestFixtureTool'
export UITEST_FIXTURE_MANIFEST_PATH='/absolute/path/to/ui_test_fixture_manifest.json'
export UITEST_SWORD_FIXTURE_PATH='/absolute/path/to/sword'
python3 scripts/run_xcodebuild_with_test_selection.py \
  --project AndBible.xcodeproj --scheme AndBiblePerformance --configuration Release \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --derived-data-path /tmp/andbible-performance \
  --result-bundle-path /tmp/andbible-performance-run.xcresult \
  --test-source Tests/Performance/AndBiblePerformanceTests.swift \
  --test-target AndBibleUITests --test-case-class AndBibleUITests \
  --test-selection-args='-only-testing:AndBibleUITests/AndBibleUITests/testPerformanceProcessLaunchToVisibleReader
-only-testing:AndBibleUITests/AndBibleUITests/testPerformanceWarmReturnToVisibleReader' \
  --action test-without-building
```

Use a dedicated derived-data directory with a single `.xctestrun`, or supply the intended `--xctestrun-path` explicitly. Do not reuse products built from another revision or configuration without recording that provenance. The simulator runner submits prepare/stop requests to the wrapper. Only the macOS owner resolves the installed container and invokes the explicit fixture tool; there is no container-discovery app launch or producer-checkout fallback. A direct manual Xcode UI run has no host service and fails before preparation.

Set `PERFORMANCE_LIBRARY_SCALE=10`, `1000`, or `10000` in the wrapper's environment to use the corresponding controlled bookmark fixture. Omit it or use `small` for the ordinary baseline. The controlled fixtures each retain ten Genesis 1 bookmarks and distribute any remaining rows over Exodus 1–40; every fifth row has the same fixed-size note. All include the same indexed KJV. This varies unrelated bookmark count while keeping the visible chapter's required annotations fixed. The ordinary baseline has different visible annotation counts and must not be treated as the zero point of this controlled growth comparison. It does not vary module inventory, workspace count, or other document families. A different scale needs its own unchanged-application baseline and budgets before comparison.

The current controlled fixtures contain directly seeded bookmarks and notes, with no user labels or established sync-journal metadata. Their initial launch includes default-label creation and initial journal reconciliation. The process-launch method seeds once: its discarded warmup performs that first launch, and the five measured processes reuse the same persistent library. Destination and return methods complete an initial launch before timing. Record whether that initialization finished; a failure at first readiness supplies no initialized-library timing budget. A separate first-time initialization measurement must not be mixed into the repeated-launch samples.

When using a restored CI artifact or an external fixture binary, provide its verified `UITEST_FIXTURE_MANIFEST_PATH` and `UITEST_SWORD_FIXTURE_PATH` along with `UITEST_FIXTURE_TOOL_PATH`. An explicitly supplied missing source directory fails fixture preparation; it must not fall back to a producer checkout.

Export measurements rather than parsing human-readable test logs:

```bash
xcrun xcresulttool get test-results metrics \
  --path /tmp/andbible-performance-run.xcresult > /tmp/andbible-performance-metrics.json
xcrun xcresulttool export metrics \
  --path /tmp/andbible-performance-run.xcresult \
  --output-path /tmp/andbible-performance-metrics
```

Record source revision and dirty diff, Xcode/build settings, runtime/device/host, fixture scenario, fixture tool hash, installed module hashes, production resource hashes, sample counts and raw result bundle with the report. Keep measurements and changing budgets in CI artifacts or the owning work item. Set matched-run budgets before evaluating optimized results.

## What the measurements establish

Clock time includes XCTest action and accessibility observation overhead. “Process launch” terminates the app but does not purge OS filesystem caches. CPU and memory metrics cover the app process; they do not cover WebContent. A five-sample nearest-rank p95 is simply the observed maximum and cannot establish tail latency. Compare distributions across independent matched runs, not a single best iteration.

The initial simulator baselines use a small KJV library. It does not establish older-device usability, large-library scaling, frame hitches, persistence cost, or every navigation flow. Extend workloads with the existing fixture tool, keep seeding outside measurement, and observe the requested content and settled position. Use physical-device traces for UI-thread and WebContent attribution and sustained memory. The simulator fixture materialization helper is not a physical-device seeder.

Performance observations must remain passive. Do not disable production focus/animations, retry an intended action until it succeeds, or substitute hidden state tokens for a rendered endpoint. Correctness tests and deterministic work-count gates establish different contracts and remain required.

## Reader diagnostics

The native WebView bootstrap forwards warnings and errors by default. Ordinary console output remains available in WebKit without native argument serialization or bridge traffic. Set `ANDBIBLE_READER_VERBOSE_LOGGING=1` in the application launch environment for a diagnostic capture, then remove it for baseline/comparison runs. The existing user-selected Vue error box retains its own explicit diagnostics behavior.

Detailed accessibility exports also remain opt-in. Their providers must not build snapshots when exports are disabled. Neither diagnostic mechanism should be used as the measured endpoint.
