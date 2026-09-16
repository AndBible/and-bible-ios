import Foundation
import XCTest
import Vision

/**
 Release-only measurements of production reader launch, return, and destination navigation.

 Dedicated Release performance schemes select these methods. Fixture preparation occurs
 before measurement; detailed accessibility exports are disabled. The endpoint requires visible
 scripture and its module-derived source marker with usable geometry. XCTest wall time includes UI
 automation overhead and must not be presented as a pure app-thread or physical-frame measurement.
 */
extension AndBibleUITests {
    /**
     Measures real Calvin commentary scrolling between visible KJV endpoints.

     Fixture installation, launch, module switches, and visible source/body readiness remain outside
     the scrolling metric. Each module button is activated exactly once. Each measurement invocation
     swipes Calvin's large Genesis 1:1 entry; its count includes any XCTest warmup. Screenshots and
     OCR occur only before or after the measurement cycle.
     The attached route timings are diagnostic samples and carry no release budget.
     */
    func testPerformanceCalvinCommentaryScrollAndReturnToScripture() {
        let app = makeApp(
            fixtureScenario: "calvin-commentary-performance",
            enablesDetailedAccessibilityExports: false
        )
        app.launch()
        waitForVisiblePerformanceScripture(in: app)
        waitForVisiblePerformanceModuleSubtitle("King James Version (1769) with Strongs Numbers and Morphology  and CatchWords", in: app)

        let commentaryButton = app.otherElements["readerDocumentHeader"]
            .buttons["readerCommentaryToolbarButton"]
            .firstMatch
        XCTAssertTrue(
            waitForElementToBecomeHittable(commentaryButton, timeout: 10),
            "Expected one visible commentary toolbar action."
        )
        let commentarySwitchStarted = ProcessInfo.processInfo.systemUptime
        commentaryButton.tap()
        waitForVisiblePerformanceModuleSubtitle("Calvin's Collected Commentaries", in: app)
        waitForVisibleReaderText(containing: "BY JOHN CALVIN", in: app, timeout: 30)
        let commentaryReady = ProcessInfo.processInfo.systemUptime

        let commentaryReadyScreenshot = XCTAttachment(screenshot: app.screenshot())
        commentaryReadyScreenshot.name = "Calvin Genesis 1:1 visible before measured scroll"
        commentaryReadyScreenshot.lifetime = .keepAlways
        add(commentaryReadyScreenshot)

        let webView = app.webViews.firstMatch
        XCTAssertTrue(
            webView.exists && elementFrameIsUsable(webView.frame) && app.frame.contains(webView.frame),
            "Expected the real Calvin document in the visible reader WebView."
        )
        var scrollInvocationCount = 0
        let scrollOptions = XCTMeasureOptions()
        scrollOptions.iterationCount = 1
        measure(
            metrics: [
                XCTOSSignpostMetric.scrollingAndDecelerationMetric,
                XCTClockMetric(),
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app),
            ],
            options: scrollOptions
        ) {
            scrollInvocationCount += 1
            webView.swipeUp()
        }

        let scrolledScreenshot = XCTAttachment(screenshot: app.screenshot())
        scrolledScreenshot.name = "Calvin Genesis 1:1 after measured scroll"
        scrolledScreenshot.lifetime = .keepAlways
        add(scrolledScreenshot)

        let bibleButton = app.otherElements["readerDocumentHeader"]
            .buttons["readerBibleToolbarButton"]
            .firstMatch
        XCTAssertTrue(
            waitForElementToBecomeHittable(bibleButton, timeout: 10),
            "Expected one visible Bible toolbar action after the commentary scroll."
        )
        let bibleReturnStarted = ProcessInfo.processInfo.systemUptime
        bibleButton.tap()
        waitForVisiblePerformanceModuleSubtitle("King James Version (1769) with Strongs Numbers and Morphology  and CatchWords", in: app)
        waitForVisiblePerformanceScripture(in: app)
        let bibleReady = ProcessInfo.processInfo.systemUptime

        let timingPayload: [String: Any] = [
            "commentary_switch_to_visible_body_seconds": commentaryReady - commentarySwitchStarted,
            "bible_return_to_visible_body_seconds": bibleReady - bibleReturnStarted,
            "module": "CalvinCommentaries",
            "scroll_invocation_count_including_warmup": scrollInvocationCount,
            "reference": "Gen.1.1",
            "scroll_metric": "XCTOSSignpostMetric.scrollingAndDecelerationMetric",
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: timingPayload, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Calvin commentary route timings"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("Could not encode commentary route timing evidence: \(error)")
        }
    }

    /**
     Records six bounded Calvin reading cycles in one application process for sustained-lag diagnosis.

     Each cycle begins on the visible seeded KJV body, activates Commentary once, performs three
     slow forward and three slow backward drags in Calvin's long Genesis 1:1 entry, and activates
     Bible once. Tap readiness is checked before each route clock; the timed route starts immediately
     before its single tap and ends after the visible module source marker is ready. A screenshot/OCR
     check then verifies the actual composited body outside that route clock and publishes its cost.
     The scroll duration includes XCTest gesture delivery;
     it is not a physical FPS, hitch, WebContent CPU, or cross-commentary-block measurement.

     This test deliberately has no performance budget and does not assert that later samples must
     be slower. It retains every cycle's monotonic and Unix timestamps before reporting endpoint
     failures, allowing an external RSS sampler to correlate early, middle, and late behavior.

     - Side effects: Launches one fixture-backed app process, performs at most twelve module taps
       and 36 vertical drags, runs bounded English OCR polling at body correctness boundaries,
       retains only each observer's final WebView screenshot, and adds one JSON timing attachment.
       It never relaunches or resets the app between cycles.
     - Failure modes: Retains the first failed cycle for a missing source, body, restored position,
       gesture surface, or OCR result, then stops before driving another cycle from invalid state.
       Fixture preparation and process launch failures remain outside the cycle clocks.
     */
    func testPerformanceSustainedCalvinCommentaryReadingAndScriptureReturn() {
        let kjvSubtitle = "King James Version (1769) with Strongs Numbers and Morphology  and CatchWords"
        let calvinSubtitle = "Calvin's Collected Commentaries"
        let cycleCount = 6
        let app = makeApp(
            fixtureScenario: "calvin-commentary-performance",
            enablesDetailedAccessibilityExports: false
        )
        app.launch()
        waitForVisiblePerformanceScripture(in: app)
        waitForVisiblePerformanceModuleSubtitle(kjvSubtitle, in: app)

        let sessionMonotonicStart = ProcessInfo.processInfo.systemUptime
        let sessionUnixStart = Date().timeIntervalSince1970
        var cycleRecords: [[String: Any]] = []
        var failedCycles: [Int] = []

        for cycle in 1...cycleCount {
            var phases: [[String: Any]] = []
            var observers: [[String: Any]] = []
            var cycleSucceeded = true

            let commentaryButton = app.otherElements["readerDocumentHeader"]
                .buttons["readerCommentaryToolbarButton"]
                .firstMatch
            let commentaryControlReady = waitForElementToBecomeHittable(commentaryButton, timeout: 10)
            let commentaryStartMonotonic = ProcessInfo.processInfo.systemUptime
            let commentaryStartUnix = Date().timeIntervalSince1970
            if commentaryControlReady {
                commentaryButton.tap()
            }
            let commentaryEndpointReady = commentaryControlReady && waitForVisiblePerformanceSource(
                subtitle: calvinSubtitle,
                in: app,
                timeout: 30
            )
            let commentaryEndMonotonic = ProcessInfo.processInfo.systemUptime
            let commentaryEndUnix = Date().timeIntervalSince1970
            phases.append(sustainedPhaseRecord(
                name: "commentary_tap_to_visible_source_marker",
                startMonotonic: commentaryStartMonotonic,
                endMonotonic: commentaryEndMonotonic,
                startUnix: commentaryStartUnix,
                endUnix: commentaryEndUnix,
                succeeded: commentaryEndpointReady
            ))
            cycleSucceeded = cycleSucceeded && commentaryEndpointReady
            if !commentaryEndpointReady {
                cycleRecords.append([
                    "cycle": cycle,
                    "sample_band": cycle == 1 ? "early" : (cycle == 3 ? "middle" : (cycle == 6 ? "late" : "intermediate")),
                    "succeeded": false,
                    "phases": phases,
                    "observers": observers,
                ])
                failedCycles.append(cycle)
                break
            }
            let commentaryReadyObservation = sustainedReaderObservation(
                expectedText: "BY JOHN CALVIN",
                attachmentName: "Sustained Calvin cycle \(cycle) body ready before scrolling",
                timeout: 20,
                routeTapStartMonotonic: commentaryStartMonotonic,
                in: app
            )
            observers.append(commentaryReadyObservation)
            cycleSucceeded = commentaryReadyObservation["succeeded"] as? Bool == true
            if !cycleSucceeded {
                cycleRecords.append([
                    "cycle": cycle,
                    "sample_band": cycle == 1 ? "early" : (cycle == 3 ? "middle" : (cycle == 6 ? "late" : "intermediate")),
                    "succeeded": false,
                    "phases": phases,
                    "observers": observers,
                ])
                failedCycles.append(cycle)
                break
            }

            let webView = app.webViews.firstMatch
            let scrollStartMonotonic = ProcessInfo.processInfo.systemUptime
            let scrollStartUnix = Date().timeIntervalSince1970
            var forwardGestureCount = 0
            var backwardGestureCount = 0
            let scrollSurfaceReady = webView.exists
                && elementFrameIsUsable(webView.frame)
                && app.frame.contains(webView.frame)
            if scrollSurfaceReady {
                for direction in ["forward", "forward", "forward", "backward", "backward", "backward"] {
                    let start = direction == "forward"
                        ? webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
                        : webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
                    let end = direction == "forward"
                        ? webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
                        : webView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
                    start.press(
                        forDuration: 0.05,
                        thenDragTo: end,
                        withVelocity: .slow,
                        thenHoldForDuration: 0.15
                    )
                    if direction == "forward" {
                        forwardGestureCount += 1
                    } else {
                        backwardGestureCount += 1
                    }
                }
            }
            let returnedToCalvinStart = scrollSurfaceReady && waitForVisiblePerformanceSource(
                subtitle: calvinSubtitle,
                in: app,
                timeout: 20
            )
            let scrollEndMonotonic = ProcessInfo.processInfo.systemUptime
            let scrollEndUnix = Date().timeIntervalSince1970
            phases.append(sustainedPhaseRecord(
                name: "bounded_forward_backward_scroll",
                startMonotonic: scrollStartMonotonic,
                endMonotonic: scrollEndMonotonic,
                startUnix: scrollStartUnix,
                endUnix: scrollEndUnix,
                succeeded: returnedToCalvinStart,
                details: [
                    "forward_gesture_count": forwardGestureCount,
                    "backward_gesture_count": backwardGestureCount,
                    "includes_xctest_gesture_delivery": true,
                ]
            ))
            cycleSucceeded = cycleSucceeded && returnedToCalvinStart
            let commentaryObservation = sustainedReaderObservation(
                expectedText: "BY JOHN CALVIN",
                attachmentName: "Sustained Calvin cycle \(cycle) after bounded scroll",
                timeout: 20,
                in: app
            )
            observers.append(commentaryObservation)
            cycleSucceeded = cycleSucceeded && (commentaryObservation["succeeded"] as? Bool == true)
            if !cycleSucceeded {
                cycleRecords.append([
                    "cycle": cycle,
                    "sample_band": cycle == 1 ? "early" : (cycle == 3 ? "middle" : (cycle == 6 ? "late" : "intermediate")),
                    "succeeded": false,
                    "phases": phases,
                    "observers": observers,
                ])
                failedCycles.append(cycle)
                break
            }

            let bibleButton = app.otherElements["readerDocumentHeader"]
                .buttons["readerBibleToolbarButton"]
                .firstMatch
            let bibleControlReady = waitForElementToBecomeHittable(bibleButton, timeout: 10)
            let bibleStartMonotonic = ProcessInfo.processInfo.systemUptime
            let bibleStartUnix = Date().timeIntervalSince1970
            if bibleControlReady {
                bibleButton.tap()
            }
            let bibleEndpointReady = bibleControlReady && waitForVisiblePerformanceSource(
                subtitle: kjvSubtitle,
                in: app,
                timeout: 30
            )
            let bibleEndMonotonic = ProcessInfo.processInfo.systemUptime
            let bibleEndUnix = Date().timeIntervalSince1970
            phases.append(sustainedPhaseRecord(
                name: "bible_tap_to_visible_source_marker",
                startMonotonic: bibleStartMonotonic,
                endMonotonic: bibleEndMonotonic,
                startUnix: bibleStartUnix,
                endUnix: bibleEndUnix,
                succeeded: bibleEndpointReady
            ))
            cycleSucceeded = cycleSucceeded && bibleEndpointReady
            // Recognize the passage even when verse 1's opening words are just above the viewport.
            // Exact scroll restoration is a separate contract from returning to readable Scripture.
            let bibleObservation = sustainedReaderObservation(
                expectedText: "Spirit of God moved upon the face of the waters",
                attachmentName: "Sustained Calvin cycle \(cycle) returned scripture",
                timeout: 20,
                routeTapStartMonotonic: bibleStartMonotonic,
                in: app
            )
            observers.append(bibleObservation)
            cycleSucceeded = cycleSucceeded && (bibleObservation["succeeded"] as? Bool == true)

            cycleRecords.append([
                "cycle": cycle,
                "sample_band": cycle == 1 ? "early" : (cycle == 3 ? "middle" : (cycle == 6 ? "late" : "intermediate")),
                "succeeded": cycleSucceeded,
                "phases": phases,
                "observers": observers,
            ])
            if !cycleSucceeded {
                failedCycles.append(cycle)
                break
            }
        }

        let payload: [String: Any] = [
            "schema_version": 1,
            "workload": "CalvinCommentaries1.1 Gen.1.1 bounded repeated reading",
            "planned_cycle_count": cycleCount,
            "executed_cycle_count": cycleRecords.count,
            "session_monotonic_start_seconds": sessionMonotonicStart,
            "session_monotonic_end_seconds": ProcessInfo.processInfo.systemUptime,
            "session_unix_start_seconds": sessionUnixStart,
            "session_unix_end_seconds": Date().timeIntervalSince1970,
            "cycles": cycleRecords,
            "failed_cycles": failedCycles,
            "interpretation": [
                "route_durations_include_xctest_action_and_accessibility_endpoint_observer_cost",
                "scroll_durations_include_xctest_gesture_delivery_cost",
                "ocr_and_screenshot_observer_costs_are_recorded_outside_phase_durations",
                "app_memory_metrics_would_exclude_the_WebContent_process",
                "no_physical_fps_or_cross_commentary_block_smoothness_claim",
                "no_performance_budget_or_monotonic_degradation_assertion",
            ],
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Sustained Calvin commentary cycle timings"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            XCTFail("Could not encode sustained commentary timing evidence: \(error)")
        }
        XCTAssertTrue(
            failedCycles.isEmpty,
            "Sustained commentary visible endpoint failures in cycles: \(failedCycles)"
        )
    }

    /**
     Measures a fresh process reaching the visible seeded KJV document.

     Each measured iteration terminates the preceding process before starting its clock. This is
     a process-cold launch; OS filesystem caches are not purged. CPU and memory cover the app process,
     so WebContent attribution still requires a device trace. Fails if scripture never becomes visible.
     */
    func testPerformanceProcessLaunchToVisibleReader() {
        let app = makeApp(fixtureScenario: readerPerformanceFixture(default: "baseline"), enablesDetailedAccessibilityExports: false)
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
            options: readerPerformanceOptions()
        ) {
            app.terminate()
            startMeasuring()
            app.launch()
            waitForVisiblePerformanceScripture(in: app)
            stopMeasuring()
        }
    }

    /**
     Measures foreground return to the already rendered KJV document with production focus and
     animations.

     Launch, initial render and background transition occur outside measurement. Each iteration
     activates once and passively awaits actual visible content; no hidden model token is an endpoint.
     */
    func testPerformanceWarmReturnToVisibleReader() {
        let app = makeApp(fixtureScenario: readerPerformanceFixture(default: "baseline"), enablesDetailedAccessibilityExports: false)
        app.launch()
        waitForVisiblePerformanceScripture(in: app)
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
            options: readerPerformanceOptions()
        ) {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
            startMeasuring()
            app.activate()
            waitForVisiblePerformanceScripture(in: app)
            stopMeasuring()
        }
    }

    /** Measures one drawer Search action reaching the visible, enabled criteria field. */
    func testPerformanceOpenSearchCriteria() {
        measureReaderDestination(
            actionIdentifier: "readerOpenSearchAction",
            fixtureScenario: "search-indexed",
            readyIdentifier: "searchQueryField",
            backIdentifier: "searchActivityAppBarBackButton"
        )
    }

    /** Measures one drawer Bookmarks action reaching usable list content and navigation chrome. */
    func testPerformanceOpenBookmarks() {
        measureReaderDestination(
            actionIdentifier: "readerOpenBookmarksAction",
            readyIdentifier: "bookmarkListLabelFilterButton",
            backIdentifier: "bookmarkListAppBarBackButton"
        )
    }

    /** Measures one drawer Settings action reaching the visible first application-preferences row. */
    func testPerformanceOpenSettings() {
        measureReaderDestination(
            actionIdentifier: "readerOpenSettingsAction",
            readyIdentifier: "settingsSwitch::navigate_to_verse_pref",
            backIdentifier: "settingsTopAppBarBackButton"
        )
    }

    /**
     Measures warm navigation in one live application process once the drawer is visibly open.

     Process launch, source render, drawer opening and row reveal are prerequisites outside the
     clock. Between samples the destination's real Back button returns to visible scripture.
     Keeping one process also keeps the app-scoped CPU/memory instruments attached to one lifetime;
     launch/return measurements own the separate process and foreground workloads.
     The destination is neither seeded nor activated by a launch argument. Each iteration
     performs its menu action once and passively observes an on-screen, hittable control. Bookmarks additionally requires a visible row or explicit empty state and usable Back chrome.
     Search measures criteria availability, not query results; mutation persistence is separate.
     Search runs require an indexed fixture prepared before launch.
     */
    private func measureReaderDestination(
        actionIdentifier: String,
        fixtureScenario: String = "baseline",
        readyIdentifier: String,
        backIdentifier: String
    ) {
        let app = makeApp(fixtureScenario: readerPerformanceFixture(default: fixtureScenario), enablesDetailedAccessibilityExports: false)
        app.launch()
        waitForVisiblePerformanceScripture(in: app)
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app)],
            options: readerPerformanceOptions()
        ) {
            waitForVisiblePerformanceScripture(in: app)
            guard let action = tryResolveReaderActionControl(actionIdentifier, in: app, timeout: 20),
                  waitForElementToBecomeHittable(action, timeout: 10) else {
                XCTFail("Expected the production drawer action '\(actionIdentifier)'")
                return
            }
            startMeasuring()
            action.tap()
            if actionIdentifier == "readerOpenBookmarksAction" {
                XCTAssertTrue(waitForUsableBookmarkList(in: app),
                              "Expected visible Bookmarks content and usable navigation chrome")
            } else {
                let control = app.descendants(matching: .any).matching(identifier: readyIdentifier).firstMatch
                let ready = NSPredicate { _, _ in
                    control.exists && self.elementFrameIsUsable(control.frame)
                        && app.frame.intersects(control.frame) && control.isHittable
                }
                XCTAssertEqual(XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30
                ), .completed, "Expected visible destination control '\(readyIdentifier)'")
            }
            stopMeasuring()
            let back = app.buttons[backIdentifier]
            guard waitForElementToBecomeHittable(back, timeout: 10) else {
                XCTContext.runActivity(named: "Unavailable destination Back control") { activity in
                    let screenshot = XCTAttachment(screenshot: app.screenshot())
                    screenshot.lifetime = .keepAlways
                    activity.add(screenshot)
                    let hierarchy = XCTAttachment(string: app.debugDescription)
                    hierarchy.lifetime = .keepAlways
                    activity.add(hierarchy)
                }
                XCTFail("Expected the production Back control '\(backIdentifier)'")
                return
            }
            back.tap()
            waitForVisiblePerformanceScripture(in: app)
        }
    }

    /**
     Selects only the prelaunch dataset for a controlled bookmark-growth workload.

     An absent or `small` value keeps each method's normal fixture; `10`, `1000` and `10000` each include
     the same indexed KJV and ten visible-chapter bookmarks. Invalid values fail the measurement.
     No preference here changes production interaction, navigation, or rendering behavior.
     */
    private func readerPerformanceFixture(default defaultScenario: String) -> String {
        switch ProcessInfo.processInfo.environment["PERFORMANCE_LIBRARY_SCALE"] ?? "small" {
        case "small": return defaultScenario
        case "10": return "performance-bookmarks-10"
        case "1000": return "performance-bookmarks-1000"
        case "10000": return "performance-bookmarks-10000"
        default:
            XCTFail("PERFORMANCE_LIBRARY_SCALE must be small, 10, 1000, or 10000")
            return defaultScenario
        }
    }

    /** Uses explicit measurement boundaries and a reproducible sample count from the runner. */
    private func readerPerformanceOptions() -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = max(3, Int(ProcessInfo.processInfo.environment["PERFORMANCE_ITERATIONS"] ?? "5") ?? 5)
        return options
    }

    /**
     Awaits rendered Genesis text inside an on-screen WebView without changing the UI.

     The fixture starts the real KJV module at Genesis 1. Its module-derived introductory title
     distinguishes accepted source publication from the controller's visible demo Genesis document.
     The existing visible scripture check remains part of the endpoint, and the exact title proves
     that scripture belongs to the accepted KJV source rather than the demo. Both require nonzero
     geometry; an offscreen accessibility node or native toolbar cannot satisfy the endpoint. A
     missing render fails after 30 seconds instead of contributing a successful timing sample.
     */
    private func waitForVisiblePerformanceScripture(in app: XCUIApplication) {
        let predicate = NSPredicate { _, _ in
            let webView = app.webViews.firstMatch
            guard webView.exists, self.elementFrameIsUsable(webView.frame) else { return false }
            let verse = webView.staticTexts.matching(
                NSPredicate(format: "label CONTAINS[c] %@", "In the beginning")
            ).firstMatch
            let sourceTitle = webView.staticTexts.matching(
                NSPredicate(format: "label == %@", "THE FIRST BOOK OF MOSES CALLED GENESIS")
            ).firstMatch
            guard verse.exists, self.elementFrameIsUsable(verse.frame),
                  sourceTitle.exists, self.elementFrameIsUsable(sourceTitle.frame) else { return false }
            return webView.frame.intersects(verse.frame) && app.frame.intersects(verse.frame)
                && webView.frame.intersects(sourceTitle.frame) && app.frame.intersects(sourceTitle.frame)
        }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed,
                       "Expected visible scripture from the seeded KJV source in the reader viewport")
    }

    /**
     Awaits one exact module subtitle inside the visible reader header without changing app state.

     This source marker complements WebView body verification so shared Genesis text cannot satisfy
     a commentary or Bible endpoint under the wrong installed module.
     */
    func waitForVisiblePerformanceModuleSubtitle(
        _ subtitle: String,
        in app: XCUIApplication
    ) {
        let header = app.otherElements["readerDocumentHeader"].firstMatch
        let source = header.staticTexts.matching(
            NSPredicate(format: "label == %@", subtitle)
        ).firstMatch
        let predicate = NSPredicate { _, _ in
            header.exists && self.elementFrameIsUsable(header.frame)
                && source.exists && self.elementFrameIsUsable(source.frame)
                && header.frame.intersects(source.frame) && app.frame.intersects(source.frame)
        }
        XCTAssertEqual(
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 30),
            .completed,
            "Expected visible reader module subtitle '\(subtitle)'."
        )
    }

    /**
     Passively awaits an actual visible reader source marker.

     - Parameters:
       - subtitle: Exact reader-header module subtitle required for source identity.
       - app: The running foreground application.
       - timeout: Maximum accessibility polling time in seconds.
     - Returns: `true` when the source is visible with usable on-screen geometry.
     - Side effects: Samples XCTest accessibility state; it does not mutate application state.
     - Failure modes: Returns `false` on timeout or unusable geometry. The separately timed OCR
       observer verifies composited body pixels because WebKit can split body text across AX nodes.
     */
    private func waitForVisiblePerformanceSource(
        subtitle: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        waitForUITestCondition("Visible performance source", timeout: timeout) {
            let header = app.otherElements["readerDocumentHeader"].firstMatch
            let source = header.staticTexts.matching(
                NSPredicate(format: "label == %@", subtitle)
            ).firstMatch
            guard header.exists, self.elementFrameIsUsable(header.frame),
                  source.exists, self.elementFrameIsUsable(source.frame) else { return false }
            return header.frame.intersects(source.frame) && app.frame.intersects(source.frame)
        }
    }

    /**
     Passively polls composited reader pixels and retains only the final screenshot.

     - Parameters:
       - expectedText: Known logical-position text expected in the composited reader pixels.
       - attachmentName: Stable diagnostic name for the retained screenshot.
       - timeout: Maximum screenshot/OCR polling time in seconds.
       - routeTapStartMonotonic: Optional route-tap timestamp used to report the explicitly
         observer-inclusive tap-to-body evidence beside, but not inside, the source-marker phase.
       - app: The running foreground application.
     - Returns: A JSON-compatible record with observer timestamps, duration, and OCR result.
     - Side effects: Repeatedly captures the visible WebView and performs English Vision OCR in the
       test runner until success or timeout; retains only the final screenshot as an attachment.
     - Failure modes: Returns `succeeded: false` for missing pixels, OCR errors, or absent text;
       the sustained test defers its XCTest failure until all cycle records are attached.
     */
    private func sustainedReaderObservation(
        expectedText: String,
        attachmentName: String,
        timeout: TimeInterval,
        routeTapStartMonotonic: TimeInterval? = nil,
        in app: XCUIApplication
    ) -> [String: Any] {
        let startMonotonic = ProcessInfo.processInfo.systemUptime
        let startUnix = Date().timeIntervalSince1970
        let webView = app.webViews.firstMatch
        var succeeded = false
        var recognizedText = ""
        var lastScreenshot: XCUIScreenshot?
        succeeded = waitForUITestCondition("Visible reader OCR body: \(expectedText)", timeout: timeout) {
            guard webView.exists, self.elementFrameIsUsable(webView.frame),
                  app.frame.intersects(webView.frame) else { return false }
            let screenshot = webView.screenshot()
            lastScreenshot = screenshot
            guard let pixels = screenshot.image.cgImage else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            do {
                try VNImageRequestHandler(cgImage: pixels, options: [:]).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                recognizedText = lines.joined(separator: " ")
                return self.visibleReaderOCRLines(lines, contain: expectedText)
            } catch {
                recognizedText = "OCR error: \(error.localizedDescription)"
                return false
            }
        }
        if let screenshot = lastScreenshot {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = attachmentName
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let endMonotonic = ProcessInfo.processInfo.systemUptime
        let endUnix = Date().timeIntervalSince1970
        var record: [String: Any] = [
            "name": attachmentName,
            "expected_text": expectedText,
            "recognized_text": recognizedText,
            "succeeded": succeeded,
            "monotonic_start_seconds": startMonotonic,
            "monotonic_end_seconds": endMonotonic,
            "duration_seconds": endMonotonic - startMonotonic,
            "unix_start_seconds": startUnix,
            "unix_end_seconds": endUnix,
        ]
        if let routeTapStartMonotonic {
            record["tap_to_visible_body_observer_inclusive_seconds"] = endMonotonic - routeTapStartMonotonic
        }
        return record
    }

    /**
     Builds one JSON-compatible phase record from monotonic and wall-clock observations.

     - Parameters:
       - name: Stable phase identity.
       - startMonotonic: `systemUptime` sampled immediately before the phase action.
       - endMonotonic: `systemUptime` sampled after the visible endpoint or timeout.
       - startUnix: Unix timestamp sampled beside `startMonotonic` for external correlation.
       - endUnix: Unix timestamp sampled beside `endMonotonic` for external correlation.
       - succeeded: Whether the phase reached its declared visible endpoint.
       - details: Optional JSON-compatible phase metadata.
     - Returns: A record containing raw timestamps and monotonic duration.
     - Side effects: None.
     - Failure modes: Does not validate clock ordering; the caller records observed values exactly.
     */
    private func sustainedPhaseRecord(
        name: String,
        startMonotonic: TimeInterval,
        endMonotonic: TimeInterval,
        startUnix: TimeInterval,
        endUnix: TimeInterval,
        succeeded: Bool,
        details: [String: Any] = [:]
    ) -> [String: Any] {
        [
            "name": name,
            "succeeded": succeeded,
            "monotonic_start_seconds": startMonotonic,
            "monotonic_end_seconds": endMonotonic,
            "duration_seconds": endMonotonic - startMonotonic,
            "unix_start_seconds": startUnix,
            "unix_end_seconds": endUnix,
            "details": details,
        ]
    }

}
