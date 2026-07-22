import XCTest

/**
 Package-level source guards for reader-hosted passage chooser presentation.

 These tests protect Android parity for the reader passage chooser shell and progress snapshot
 wiring where the relevant SwiftUI state is private. They belong to BibleUI because they inspect
 reader presentation source, not app delegate or scene bootstrap behavior.
 */
final class ReaderPassageChooserSourceGuardTests: XCTestCase {
    /**
     Verifies the passage chooser uses its Android-style full-screen shell.

     Android presents book/chapter/verse selection as a full-screen dark chooser with its own
     toolbar, not as the narrow hamburger drawer. Failure means iOS is artificially preserving a
     platform-specific presentation that hides part of the picker behind the reader surface.
     */
    func testPassageChooserUsesFullScreenChooserShell() throws {
        let source = try bibleUISource(named: "BibleReaderView.swift")
        let overlayStart = try XCTUnwrap(source.range(of: "private var bookChooserDrawerOverlay"))
        let overlayEnd = try XCTUnwrap(
            source[overlayStart.lowerBound...].range(of: "private func dismissReaderNavigationDrawer")
        )
        let overlaySource = String(source[overlayStart.lowerBound..<overlayEnd.lowerBound])

        XCTAssertTrue(overlaySource.contains("ReaderPassageChooserOverlay"))
        XCTAssertFalse(overlaySource.contains("ReaderSideDrawerOverlay"))
        XCTAssertFalse(overlaySource.contains("onCancel: dismissBookChooser"))
    }

    /**
     Verifies the passage chooser overlay does not expose an unused cancellation API.

     Dismissal belongs to `BookChooserView` through its explicit back button callback. Keeping a dead
     `onCancel` parameter on the overlay makes the reader shell look like it handles cancellation
     while the value is never read, so future call sites can drift into false safety.
     */
    func testReaderPassageChooserOverlayDoesNotExposeDeadCancellationAPI() throws {
        let source = try bibleUISource(named: "ReaderPassageChooserOverlay.swift")

        XCTAssertFalse(source.contains("onCancel"))
    }

    /**
     Verifies all reader-hosted passage chooser entry points carry the active workspace title.

     Android appends `SharedActivityState.currentWorkspaceName` to the book chooser activity title.
     The SwiftUI chooser should receive the same workspace context from `BibleReaderView` wherever
     that chooser is hosted, rather than only for one visible entry point. Failure means a caller can
     drift back to an iOS-only title that hides the target workspace.
     */
    func testReaderPassageChooserCallSitesUseSharedWorkspaceTitleSource() throws {
        let source = try bibleUISource(named: "BibleReaderView.swift")
        let occurrences = source
            .components(separatedBy: "workspaceName: activePassageChooserWorkspaceName")
            .count - 1

        XCTAssertEqual(occurrences, 2)
    }

    /**
     Verifies the drawer-hosted passage chooser does not depend on native navigation bars.

     Android's chooser activity owns its visible app bar as chooser content. `BibleReaderView`
     hides native navigation chrome for the reader, so the reader-hosted chooser must not try to
     recover by forcing a nested SwiftUI navigation bar visible. Failure means the app can regress
     to a brittle host-level toolbar that disappears under the reader shell.
     */
    func testPassageChooserDrawerDoesNotDependOnNativeNavigationBarInsideReader() throws {
        let source = try bibleUISource(named: "BibleReaderView.swift")
        guard let drawerStart = source.range(of: "private var bookChooserDrawerContent"),
              let nextSection = source.range(
                of: "private var searchSheetContent",
                range: drawerStart.upperBound..<source.endIndex
              ) else {
            return XCTFail("Could not locate book chooser drawer content in BibleReaderView.swift")
        }

        let drawerSource = source[drawerStart.lowerBound..<nextSection.lowerBound]

        XCTAssertTrue(drawerSource.contains("BookChooserView("))
        XCTAssertFalse(drawerSource.contains(".toolbar(.visible, for: .navigationBar)"))
    }

    /**
     Verifies reader-hosted passage choosers store progress snapshots once per presentation.

     Reading and memorization snapshots decode persisted store payloads. The chooser progress
     closures run for many grid cells, and `BibleReaderView` can re-render while a chooser is open.
     The reader should therefore store a captured context at presentation time instead of rebuilding
     it from computed properties during unrelated renders.
     */
    func testReaderPassageChooserProgressProvidersCaptureSnapshotsOnce() throws {
        let source = try bibleUISource(named: "BibleReaderView.swift")
        let contextOccurrences = source
            .components(separatedBy: "let progressContext = passageChooserProgressContext")
            .count - 1
        let captureOccurrences = source
            .components(separatedBy: "passageChooserProgressContext = makePassageChooserProgressContext()")
            .count - 1

        XCTAssertTrue(source.contains("@State private var passageChooserProgressContext = PassageChooserProgressContext.empty"))
        XCTAssertTrue(source.contains("private func makePassageChooserProgressContext() -> PassageChooserProgressContext"))
        XCTAssertFalse(source.contains("private var passageChooserProgressContext: PassageChooserProgressContext"))
        XCTAssertEqual(contextOccurrences, 2)
        XCTAssertEqual(captureOccurrences, 2)
        XCTAssertTrue(source.contains("passageChooserProgressContext = .empty"))
        XCTAssertFalse(source.contains("passageBookProgress(for: book)"))
        XCTAssertFalse(source.contains("passageChapterProgress(for: book, chapter: chapter)"))
        XCTAssertFalse(source.contains("passageVerseProgress(for: book, chapter: chapter, verse: verse)"))
    }

    /**
     Verifies the web-modal chooser returns JSword short verse names and generation-bound dismissal.

     Android's `refChooserDialog` always enables verse navigation and always responds, including
     cancellation. The production SwiftUI wiring must therefore request a verse, format Android's
     exact short `Verse.name`, and bind explicit and interactive dismissal to the presented request
     generation.
     */
    func testBridgeReferenceChooserReturnsExactVerseAndCompletesDismissal() throws {
        let source = try bibleUISource(named: "BibleReaderView.swift")
        let chooserStart = try XCTUnwrap(source.range(of: "private func refChooserSheetContent("))
        let chooserEnd = try XCTUnwrap(
            source.range(
                of: "private var keyboardShortcutSurface",
                range: chooserStart.upperBound..<source.endIndex
            )
        )
        let chooserSource = source[chooserStart.lowerBound..<chooserEnd.lowerBound]

        XCTAssertTrue(chooserSource.contains("navigateToVerse: true"))
        XCTAssertTrue(chooserSource.contains("completeReferenceChooser(with: nil, for: generation)"))
        XCTAssertTrue(chooserSource.contains("{ book, chapter, verse in"))
        XCTAssertTrue(
            chooserSource.contains(
                "BibleReaderReferenceChooserResultFormatter.verseName("
            )
        )
        XCTAssertTrue(chooserSource.contains("completeReferenceChooser(with: verseName, for: generation)"))
        XCTAssertFalse(chooserSource.contains("\"\\(osisId).\\(chapter).\\(verse)\""))
        XCTAssertTrue(source.contains(".sheet(item: $refChooserPresentation) { generation in"))
        XCTAssertTrue(source.contains("handleReferenceChooserDismissal(for: generation)"))
        XCTAssertTrue(
            source.contains("refChooserPresentation = refChooserRequest.replace(with: completion)")
        )
    }

    /**
     Loads a Bible reader UI source file for package-level passage chooser source guards.

     The shared locator keeps these tests independent from the app-host bundle and avoids
     hard-coded absolute paths while still asserting source contracts that are not directly
     observable through public SwiftUI state.
     */
    private func bibleUISource(named fileName: String) throws -> String {
        try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/\(fileName)"
        )
    }
}
