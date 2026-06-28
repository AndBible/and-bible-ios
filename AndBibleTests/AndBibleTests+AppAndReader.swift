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
    /**
     Guards the reader coordinator against regressing to the iOS sheet for the quick-menu path.

     The coordinator state is intentionally private, so this source-level test checks the routing
     contract at the function boundary: Android's `menuForDocs` equivalent must route the resolved
     quick-selector rows into the popup, the toolbar button must publish anchor geometry for an
     in-reader popup, and module actions must be disabled until the focused pane controller exists,
     including accessibility exposure. Row selection must also dismiss the popup before checking
     whether the captured controller still exists. Bible/commentary toolbar gestures must dispatch
     tap or long-press exclusively so Android's quick-menu and full-chooser paths cannot both fire
     for one press. A failure means the user-visible selector likely drifted back toward the old
     full-sheet behavior, can accept taps before the Android-equivalent document state is available,
     can leave a stale popup onscreen after pane teardown, or can fire both selector paths from one
     toolbar gesture.
     */
    func testBibleToolbarMenuRoutesThroughAnchoredQuickSelectorInsteadOfSheet() throws {
        let readerSource = try bibleUISource(named: "BibleReaderView.swift")
        let toolbarSource = try bibleUISource(named: "BibleReaderToolbarActions.swift")
        let menuActionSource = try extractFunction(
            named: "performBibleMenuAction",
            from: readerSource
        )
        let selectionSource = try extractFunction(
            named: "selectBibleQuickModule",
            from: readerSource
        )

        XCTAssertTrue(menuActionSource.contains("case .showPopup(let rows):"))
        XCTAssertTrue(menuActionSource.contains("presentBibleQuickSelector(controller, rows: rows)"))
        XCTAssertFalse(menuActionSource.contains("performBibleChooserAction()"))
        XCTAssertTrue(readerSource.contains("@State private var bibleQuickModuleSelectorRows"))
        XCTAssertTrue(readerSource.contains("@State private var bibleQuickModuleSelectorTargetWindowId"))
        XCTAssertTrue(readerSource.contains("bibleQuickModuleSelectorTargetWindowId = resolvedTargetWindowId"))
        XCTAssertTrue(readerSource.contains("bibleQuickModuleSelectorTargetWindowId = nil"))
        XCTAssertTrue(readerSource.contains("let rows = bibleQuickModuleSelectorRows"))
        XCTAssertTrue(readerSource.contains("let targetWindowId = bibleQuickModuleSelectorTargetWindowId"))
        XCTAssertTrue(readerSource.contains("selectBibleQuickModule(module, targetWindowId: targetWindowId)"))
        XCTAssertTrue(readerSource.contains("moduleActionsEnabled: controller != nil"))
        XCTAssertTrue(readerSource.contains("ReaderBibleToolbarButtonBoundsPreferenceKey"))
        XCTAssertTrue(
            toolbarSource.contains(
                ".anchorPreference(key: ReaderBibleToolbarButtonBoundsPreferenceKey.self"
            )
        )
        XCTAssertTrue(toolbarSource.contains(".disabled(!moduleActionsEnabled)"))
        XCTAssertFalse(toolbarSource.contains(".simultaneousGesture(LongPressGesture"))
        XCTAssertTrue(toolbarSource.contains("LongPressGesture().exclusively(before: TapGesture())"))
        XCTAssertFalse(readerSource.contains("suppressBibleTapAfterLongPress"))
        XCTAssertFalse(readerSource.contains("suppressCommentaryTapAfterLongPress"))
        XCTAssertEqual(toolbarSource.components(separatedBy: "moduleToolbarAction(").count - 1, 2)
        XCTAssertTrue(toolbarSource.contains(".accessibilityHidden(!moduleActionsEnabled)"))
        XCTAssertTrue(selectionSource.contains("let controller = controller(for: targetWindowId)"))
        let resolveIndex = try XCTUnwrap(selectionSource.range(of: "let controller = controller(for: targetWindowId)")?.lowerBound)
        let dismissIndex = try XCTUnwrap(selectionSource.range(of: "dismissBibleQuickSelector()")?.lowerBound)
        XCTAssertLessThan(resolveIndex, dismissIndex)
    }

    /**
     Guards the commentary toolbar quick-menu route against preserving the old iOS sheet.

     Android default commentary taps show an anchored `PopupMenu` with commentaries, general books,
     and dictionaries while the reader remains visible. Long press remains the full
     `ChooseDocument` activity path except for Android's `swap-menu` setting. The SwiftUI
     coordinator state is private, so this source-level contract checks the same boundary as the
     Bible quick-menu test: commentary tap must resolve rows, show the anchored popup, anchor from
     the commentary toolbar button, and route selections through category-specific current-document
     switch methods.
     */
    func testCommentaryToolbarMenuRoutesThroughAnchoredQuickSelectorInsteadOfSheet() throws {
        let readerSource = try bibleUISource(named: "BibleReaderView.swift")
        let toolbarSource = try bibleUISource(named: "BibleReaderToolbarActions.swift")
        let menuActionSource = try extractFunction(
            named: "performCommentaryMenuAction",
            from: readerSource
        )
        let selectionSource = try extractFunction(
            named: "selectCommentaryQuickModule",
            from: readerSource
        )

        XCTAssertTrue(menuActionSource.contains("BibleReaderQuickModuleSelectorPresentation.action("))
        XCTAssertTrue(menuActionSource.contains("commentaryQuickSelectorModules("))
        XCTAssertTrue(menuActionSource.contains("presentCommentaryQuickSelector(controller, rows: rows)"))
        XCTAssertFalse(menuActionSource.contains("performCommentaryChooserAction()"))
        XCTAssertTrue(readerSource.contains("performCommentaryMenuAction(controller, includeAuxiliaryDocuments: false)"))
        XCTAssertTrue(readerSource.contains("modules += controller.installedGeneralBookModules"))
        XCTAssertTrue(readerSource.contains("modules += controller.installedDictionaryModules"))
        XCTAssertTrue(readerSource.contains("controller.installedCommentaryModules.filter(\\.isUnlocked)"))
        XCTAssertTrue(readerSource.contains("@State private var commentaryQuickModuleSelectorRows"))
        XCTAssertTrue(readerSource.contains("@State private var commentaryQuickModuleSelectorTargetWindowId"))
        XCTAssertTrue(readerSource.contains("commentaryQuickModuleSelectorTargetWindowId = resolvedTargetWindowId"))
        XCTAssertTrue(readerSource.contains("commentaryQuickModuleSelectorTargetWindowId = nil"))
        XCTAssertTrue(readerSource.contains("commentaryQuickModuleSelectorOverlay(anchor: anchor)"))
        XCTAssertTrue(readerSource.contains("ReaderCommentaryToolbarButtonBoundsPreferenceKey"))
        XCTAssertTrue(
            toolbarSource.contains(
                ".anchorPreference(key: ReaderCommentaryToolbarButtonBoundsPreferenceKey.self"
            )
        )
        XCTAssertTrue(selectionSource.contains("case .commentary:"))
        XCTAssertTrue(selectionSource.contains("controller.switchCommentaryDocument(to: module.name)"))
        XCTAssertTrue(selectionSource.contains("case .dictionary:"))
        XCTAssertTrue(selectionSource.contains("controller.switchDictionaryDocument(to: module.name)"))
        XCTAssertTrue(selectionSource.contains("case .generalBook:"))
        XCTAssertTrue(selectionSource.contains("controller.switchGeneralBookDocument(to: module.name)"))
        XCTAssertTrue(selectionSource.contains("dismissCommentaryQuickSelector()"))
    }

    /**
     Verifies active-pane rendering stays owned by the Android/Vue active-window indicator.

     Android emits `set_active` into each web reader and draws corner markers inside `BibleView.vue`.
     A native SwiftUI border around the pane creates an extra full blue rectangle that Android does
     not draw, especially visible in multi-window dictionary layouts. The source assertion protects
     that boundary because the visual marker is intentionally split between native focus routing and
     web-rendered reader chrome.
     */
    func testReaderPaneDoesNotAddNativeAccentBorderForActiveWindow() throws {
        let paneSource = try bibleUISource(named: "BibleWindowPane.swift")
        let readerSource = try bibleUISource(named: "BibleReaderView.swift")
        let controllerSource = try bibleUISource(named: "BibleReaderController.swift")
        let coordinatorSource = try bibleUISource(named: "BibleReaderConfigurationCoordinator.swift")
        let paneViewSource = try extractFunction(named: "paneView", from: readerSource)

        XCTAssertFalse(paneSource.contains(".border(isFocused"))
        XCTAssertFalse(paneSource.contains("Color.accentColor"))
        XCTAssertFalse(paneViewSource.contains("isFocused:"))
        XCTAssertTrue(controllerSource.contains("activeWindowState()"))
        XCTAssertTrue(controllerSource.contains("set_active"))
        XCTAssertTrue(coordinatorSource.contains("hasActiveIndicator"))
    }

    /**
     Loads a Bible reader UI source file for source-level contract tests.

     Source assertions are used only where SwiftUI coordinator state is intentionally private and a
     pure behavior test cannot observe the routing boundary. The helper derives the path from the
     current test bundle so it works in local and CI checkouts without hard-coded absolute paths.
     */
    private func bibleUISource(named fileName: String) throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRoot = testsDirectory.deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("BibleUI")
            .appendingPathComponent("Sources")
            .appendingPathComponent("BibleUI")
            .appendingPathComponent("Bible")
            .appendingPathComponent(fileName)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    /**
     Extracts one Swift function body from a source file for a focused source-contract assertion.

     The scanner balances braces after the named function declaration instead of checking arbitrary
     file-wide fragments, which keeps the tests tied to the specific behavior boundary they protect.
     */
    private func extractFunction(named functionName: String, from source: String) throws -> String {
        guard let functionRange = source.range(of: "func \(functionName)") else {
            throw NSError(
                domain: "AndBibleTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Function \(functionName) not found"]
            )
        }
        guard let openingBrace = source[functionRange.lowerBound...].firstIndex(of: "{") else {
            throw NSError(
                domain: "AndBibleTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Function \(functionName) has no body"]
            )
        }

        var depth = 0
        var current = openingBrace
        while current < source.endIndex {
            let character = source[current]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[functionRange.lowerBound...current])
                }
            }
            current = source.index(after: current)
        }

        throw NSError(
            domain: "AndBibleTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Function \(functionName) body was not balanced"]
        )
    }

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
