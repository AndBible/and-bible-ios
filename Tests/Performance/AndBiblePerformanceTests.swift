import Foundation
import XCTest

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
    private func waitForVisiblePerformanceModuleSubtitle(
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
}
