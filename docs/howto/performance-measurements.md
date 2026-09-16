# Reader performance measurements

Use the `AndBiblePerformance` shared scheme for Release measurements with the production web bundle. It disables coverage and detailed accessibility exports. The regular `AndBible` correctness scheme excludes these repeated measurements.

The harness measures process launch, warm foreground return, and opening Search, Bookmarks and Settings from the reader drawer. Launch and return require actual visible Genesis text inside the reader WebView. Destination measurements keep one live app process and use the actual Back control outside each measured interval to return to visible scripture. These are warm destination workloads; process-launch measurements remain separate. Destination measurements start at one tap on the visible drawer action and end at an on-screen, hittable destination control. Search and Settings measure control availability. Bookmarks additionally requires on-screen Back and filter controls, a nonzero visible scroll viewport, and a visible row or explicit empty state. A partially clipped filter cannot satisfy Bookmarks readiness. Each method explicitly selects its prelaunch fixture: `search-indexed` for Search and `baseline` for the other four. No launch argument opens the measured destination. Fixture materialization, process termination and background transition occur outside each measured interval. XCTest discards a warmup iteration and records five measured iterations by default. Change `PERFORMANCE_ITERATIONS` in the performance scheme for longer runs.

## Workloads and acceptance

Performance acceptance concerns one person using the app on a phone: launching and returning to reading, scrolling real commentary and returning to Scripture, selecting chapters, switching panes, editing bookmarks or notes, reopening settings, and syncing a personal library. Use the reproducible ordinary baseline and observed personal-library configurations, and measure on older and newer supported phones. Record the actual library and pane configuration; synthetic row counts alone do not establish that a workload represents users. The harness above covers only part of these journeys.

NextCloud account setup edits one server address, username, password or folder preference at a time. Verify saved values on reopen, cancellation, invalid input and preservation of unrelated fields. It is not a bulk-save performance workload. Importing or restoring a personal library and applying its sync changes can legitimately affect multiple records; evaluate those operations separately from credential editing.

Large synthetic libraries are optional diagnostics for a specific suspected cost, such as reading all bookmarks when displaying one chapter. They are not routine acceptance gates or evidence of typical library size. In particular, the 10,000-bookmark fixture does not define a supported-use threshold or a mandatory performance target. Run a scale comparison when it can answer an identified question, and keep it out of the ordinary test loop otherwise. A diagnostic result can justify removing demonstrated unnecessary work; it does not by itself justify a new persistence architecture or additional abstractions.

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

For an optional scale diagnostic, set `PERFORMANCE_LIBRARY_SCALE=10`, `1000`, or `10000` in the wrapper's environment to use the corresponding controlled bookmark fixture. Omit it or use `small` for the ordinary baseline. The controlled fixtures each retain ten Genesis 1 bookmarks and distribute any remaining rows over Exodus 1–40; every fifth row has the same fixed-size note. All include the same indexed KJV. This varies unrelated bookmark count while keeping the visible chapter's required annotations fixed. The ordinary baseline has different visible annotation counts and must not be treated as the zero point of this controlled growth comparison. It does not vary module inventory, workspace count, or other document families. Compare each scale against its own unchanged-application baseline; report the diagnostic separately from ordinary-use acceptance.

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

## Measure a real commentary scroll locally

The opt-in `AndBibleCommentaryPerformance` scheme measures one real commentary workflow without adding the external module to the repository. Obtain `CalvinCommentaries.zip` from CrossWire's [module page](https://www.crosswire.org/sword/modules/ModInfo.jsp?modName=CalvinCommentaries) or [raw ZIP mirror](https://www.crosswire.org/ftpmirror/pub/sword/packages/rawzip/CalvinCommentaries.zip). Its configuration declares version 1.1 and `DistributionLicense=Public Domain`. The preparation script accepts only the reviewed 20,897,508-byte archive with SHA-256 `df66fc8c03537499ad006d069481d2c95b600887cdbd6ce75ec5d264b573192a`; it performs no download.

From a clean PR checkout, create a new composite SWORD fixture outside the source tree:

```bash
python3 scripts/prepare_calvin_commentary_fixture.py \
  --archive /absolute/path/to/CalvinCommentaries.zip \
  --output /tmp/andbible-calvin-sword \
  --record /tmp/andbible-calvin-sword.json
```

Build the fixture tool and the dedicated Release test products. Use a dedicated automation simulator because the fixture service stops the app and replaces its test data. Do not target a simulator used for manual review.

```bash
swift build --product UITestFixtureTool
xcodebuild -project AndBible.xcodeproj -scheme AndBibleCommentaryPerformance \
  -configuration Release \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath /tmp/andbible-calvin-performance \
  -enableCodeCoverage NO -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Run exactly the commentary method through the existing fixture-service wrapper:

```bash
export UITEST_SIMULATOR_ID='SIMULATOR_UUID'
export UITEST_BUNDLE_ID='org.andbible.ios'
export UITEST_FIXTURE_TOOL_PATH="$(pwd)/.build/debug/UITestFixtureTool"
export UITEST_FIXTURE_MANIFEST_PATH="$(pwd)/Tests/UI/Fixtures/ui_test_fixture_manifest.json"
export UITEST_SWORD_FIXTURE_PATH='/tmp/andbible-calvin-sword'
python3 scripts/run_xcodebuild_with_test_selection.py \
  --project AndBible.xcodeproj \
  --scheme AndBibleCommentaryPerformance \
  --configuration Release \
  --destination "platform=iOS Simulator,id=${UITEST_SIMULATOR_ID}" \
  --derived-data-path /tmp/andbible-calvin-performance \
  --result-bundle-path /tmp/andbible-calvin-performance.xcresult \
  --test-selection-args='-only-testing:AndBibleUITests/AndBibleUITests/testPerformanceCalvinCommentaryScrollAndReturnToScripture' \
  --action test-without-building
```

The endpoint first requires the visible KJV module title and real Genesis title/body. One commentary-toolbar action must then reach the visible `Calvin's Collected Commentaries` title and the `BY JOHN CALVIN` text inside the WebView. After the measured scroll, one Bible-toolbar action must return to the same visible KJV title/body. Hidden diagnostic state cannot satisfy these checks, and the test retains screenshots immediately before and after scrolling.

Export the structured measurements and attachments:

```bash
xcrun xcresulttool get test-results metrics \
  --path /tmp/andbible-calvin-performance.xcresult --compact \
  > /tmp/andbible-calvin-performance-metrics.json
xcrun xcresulttool export attachments \
  --path /tmp/andbible-calvin-performance.xcresult \
  --output-path /tmp/andbible-calvin-performance-attachments
```

The test requests the public scrolling-and-deceleration metric together with clock, app CPU, and app memory. Record every returned metric identity, unit, and sample instead of assuming that the requested set produced data. The JSON attachment records how many times XCTest invoked the measurement closure, including any framework warmup. A passing functional route with absent scrolling data is not a successful scroll measurement. In the initial local runs, the scrolling export contained duration only (`com.apple.dt.XCTMetric_OSSignpost-Scroll_DraggingAndDeceleration.duration`), not frame-rate or hitch data. Do not interpret that duration as proof of smooth scrolling.

These are simulator observations without an acceptance budget. App CPU and memory do not cover the separate WebContent process, and scrolling metrics do not identify a main-thread stack. Use an Instruments Time Profiler or Animation Hitches trace of the same exact method when attribution is needed, and report traced timing separately because tracing changes the workload.

## What the measurements establish

Clock time includes XCTest action and accessibility observation overhead. “Process launch” terminates the app but does not purge OS filesystem caches. CPU and memory metrics cover the app process; they do not cover WebContent. A five-sample nearest-rank p95 is simply the observed maximum and cannot establish tail latency. Compare distributions across independent matched runs, not a single best iteration.

The initial simulator baselines use a small KJV library. It does not establish older-device usability, large-library scaling, frame hitches, persistence cost, or every navigation flow. Extend workloads with the existing fixture tool, keep seeding outside measurement, and observe the requested content and settled position. Use physical-device traces for UI-thread and WebContent attribution and sustained memory. The simulator fixture materialization helper is not a physical-device seeder.

Performance observations must remain passive. Do not disable production focus/animations, retry an intended action until it succeeds, or substitute hidden state tokens for a rendered endpoint. Correctness tests and deterministic work-count gates establish different contracts and remain required.

## Reader diagnostics

The native WebView bootstrap forwards warnings and errors by default. Ordinary console output remains available in WebKit without native argument serialization or bridge traffic. Set `ANDBIBLE_READER_VERBOSE_LOGGING=1` in the application launch environment for a diagnostic capture, then remove it for baseline/comparison runs. The existing user-selected Vue error box retains its own explicit diagnostics behavior.

Detailed accessibility exports also remain opt-in. Their providers must not build snapshots when exports are disabled. Neither diagnostic mechanism should be used as the measured endpoint.
