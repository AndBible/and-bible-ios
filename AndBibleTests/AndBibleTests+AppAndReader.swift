import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import enum SwiftUI.ColorScheme
import struct SwiftUI.Text
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

extension AndBibleTests {
    func testBibleReaderSpeakMiniPlayerBuildsWithSpeakService() {
        let view = BibleReaderSpeakMiniPlayer(
            speakService: SpeakService(),
            currentReference: "Genesis 1",
            onShowControls: {}
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderSpeakMiniPlayer"))
    }

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

    /**
     Verifies the passage chooser uses its Android-style full-screen shell.

     Android presents book/chapter/verse selection as a full-screen dark chooser with its own
     toolbar, not as the narrow hamburger drawer. Failure means iOS is artificially preserving a
     platform-specific presentation that hides part of the picker behind the reader surface.
     */
    func testPassageChooserUsesFullScreenChooserShell() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readerViewURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )

        let source = try String(contentsOf: readerViewURL, encoding: .utf8)
        let overlayStart = try XCTUnwrap(source.range(of: "private var bookChooserDrawerOverlay"))
        let overlayEnd = try XCTUnwrap(source[overlayStart.lowerBound...].range(of: "private func dismissReaderNavigationDrawer"))
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
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let overlayURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Bible/ReaderPassageChooserOverlay.swift"
        )

        let source = try String(contentsOf: overlayURL, encoding: .utf8)

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
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readerViewURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )

        let source = try String(contentsOf: readerViewURL, encoding: .utf8)
        let occurrences = source.components(separatedBy: "workspaceName: activePassageChooserWorkspaceName").count - 1

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
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readerViewURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )

        let source = try String(contentsOf: readerViewURL, encoding: .utf8)
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
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readerViewURL = repoRoot.appendingPathComponent(
            "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )

        let source = try String(contentsOf: readerViewURL, encoding: .utf8)
        let contextOccurrences = source.components(separatedBy: "let progressContext = passageChooserProgressContext").count - 1
        let captureOccurrences = source.components(separatedBy: "passageChooserProgressContext = makePassageChooserProgressContext()").count - 1

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

    #if os(iOS)
    /**
     Keeps app-host coverage for the scene delegate bootstrap that package tests cannot exercise.

     `AndBibleApplicationDelegate.sceneConfiguration` is the remaining `+AppAndReader` test that
     depends on the app target rather than BibleUI package logic. A failure here means app launch
     would stop installing `AndBibleWindowSceneDelegate`, breaking the iPadOS windowing-control
     policy wiring even though the package-level policy tests still pass.
     */
    func testApplicationDelegateSceneConfigurationUsesWindowSceneDelegate() {
        let configuration = AndBibleApplicationDelegate.sceneConfiguration(
            sessionRole: UISceneSession.Role.windowApplication
        )

        XCTAssertEqual(
            ObjectIdentifier(configuration.delegateClass!),
            ObjectIdentifier(AndBibleWindowSceneDelegate.self)
        )
        XCTAssertNil(configuration.name)
    }

    func testColorARGBByteClampsIntermediatePickerComponents() {
        XCTAssertEqual(Color.clampedARGBByte(-0.25), 0)
        XCTAssertEqual(Color.clampedARGBByte(0.5), 128)
        XCTAssertEqual(Color.clampedARGBByte(1.2), 255)
        XCTAssertEqual(Color.clampedARGBByte(.nan), 0)
        XCTAssertEqual(Color.clampedARGBByte(.infinity), 0)
    }

    func testColorARGBIntClampsOutOfRangeComponents() {
        let color = Color(.sRGB, red: -0.25, green: 0.5, blue: 1.2, opacity: 1.0)
        XCTAssertEqual(color.argbInt, Int(Int32(bitPattern: 0xFF0080FF)))
    }
    #endif

}
