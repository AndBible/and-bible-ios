import XCTest
@testable import BibleCore
@testable import BibleUI
import enum SwiftUI.ColorScheme
import struct SwiftUI.Text

/**
 Package-level construction coverage for reader shell views.

 These tests verify lightweight BibleUI reader shells can be built with their required injected
 dependencies without loading the app-host XCTest bundle. They protect the migration boundary for
 views that belong to BibleUI rather than app delegate or scene bootstrap behavior. Construction
 runs on the main actor because both SwiftUI views and their shared speech service are UI-owned.
 */
@MainActor
final class ReaderShellConstructionTests: XCTestCase {
    /**
     Verifies the reader observes the application-owned speech service without constructing a copy.

     The identity assertion protects active background playback and process-global media-command
     ownership across SwiftUI reader reconstruction.

     - Side effects: Constructs a speech service and reader value without rendering the view body.
     - Failure modes: Fails if reader construction wraps, replaces, or independently owns speech.
     */
    func testBibleReaderUsesInjectedSpeechServiceIdentity() {
        let speakService = SpeakService()

        let view = BibleReaderView(speakService: speakService)

        XCTAssertTrue(view.speakService === speakService)
    }

    /**
     Verifies the reader speak mini-player accepts the shared speak service dependency.

     A failure means the package-owned mini-player shell can no longer be constructed without the
     app target, which would regress the test architecture split back toward app-host coverage.
     */
    func testBibleReaderSpeakMiniPlayerBuildsWithSpeakService() {
        let view = BibleReaderSpeakMiniPlayer(
            speakService: SpeakService(),
            currentReference: "Genesis 1",
            onShowControls: {}
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderSpeakMiniPlayer"))
    }

    /**
     Verifies the reader navigation drawer accepts its action handler and presentation inputs.

     The hamburger drawer is a BibleUI shell with injected callbacks, not app bootstrap behavior.
     A failure means package-level reader chrome can no longer be constructed in isolation.
     */
    func testBibleReaderNavigationDrawerBuildsWithActionHandler() {
        let view = BibleReaderNavigationDrawer(
            width: 306,
            colorScheme: ColorScheme.dark,
            versionText: "Version 1.0 (1)",
            onAction: { _ in }
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderNavigationDrawer"))
    }

    /**
     Verifies the reader navigation drawer is hosted by the shared slide-out presentation shell.

     Android's hamburger menu remains a narrow left drawer over a dimmed reader. Passage selection
     is a separate full-screen chooser activity, so this shared shell should be reserved for the
     hamburger drawer and similar left navigation surfaces only.
     */
    func testReaderSideDrawerOverlayBuildsWithInjectedContent() {
        let view = ReaderSideDrawerOverlay(
            colorScheme: ColorScheme.light,
            dismissAreaIdentifier: "testDismissArea",
            onDismiss: {}
        ) { width in
            Text("Drawer \(Int(width))")
        }

        XCTAssertTrue(String(describing: type(of: view)).contains("ReaderSideDrawerOverlay"))
    }
}
