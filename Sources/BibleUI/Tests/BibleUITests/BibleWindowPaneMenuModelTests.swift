// BibleWindowPaneMenuModelTests.swift -- Android parity tests for pane hamburger menus

import BibleCore
import XCTest
@testable import BibleUI

/**
 Regression tests for the Android-style per-window hamburger menu model.

 These tests deliberately exercise the pure menu snapshot rather than SwiftUI menu introspection.
 Failures mean the pane menu has drifted away from Android's `window_popup_menu.xml` and
 `SplitBibleArea.getItemOptions` ordering, visibility, or action semantics.
 */
final class BibleWindowPaneMenuModelTests: XCTestCase {
    /**
     Protects Android's normal-window top-level menu order.

     Android shows layout, text, configured AI, current-reference copy, typed clipboard navigation,
     live speech navigation, and Close in XML order for a normal visible non-maximized window. The
     old iOS flat rows and invented typed-reference dialog must not reappear in this model.
     */
    func testNormalWindowTopLevelMenuMatchesAndroidOrder() {
        let currentID = UUID()
        let otherID = UUID()
        let model = BibleWindowPaneMenuModel(snapshot: .fixture(
            windowID: currentID,
            isAIConfigured: true,
            copiedReferenceName: "John 3:16",
            speakReferenceName: "Romans 8:1",
            recentTextSettings: [.sectionTitles],
            allWindowsInPersistedOrder: [
                .fixture(id: currentID, position: 0, document: "KJV", reference: "Gen 1"),
                .fixture(id: otherID, position: 1, document: "ESV", reference: "Rom 1"),
            ],
            visibleWindows: [
                .fixture(id: currentID, position: 0, document: "KJV", reference: "Gen 1"),
                .fixture(id: otherID, position: 1, document: "ESV", reference: "Rom 1"),
            ]
        ))

        XCTAssertEqual(model.items.map(\.id), [
            "newWindow",
            "maximize",
            "minimize",
            "moveTo",
            "pin",
            "synchronize",
            "textOptions",
            "aiActions",
            "copyLink",
            "goToReference",
            "goToSpeak",
            "close",
        ])
    }

    /** Protects Android's non-Bible whole-page bookmark position ahead of text options. */
    func testGenericWindowInsertsWholePageBookmarkBeforeTextOptions() throws {
        let model = BibleWindowPaneMenuModel(snapshot: .fixture(
            canAddWholePageBookmark: true,
            recentTextSettings: [.sectionTitles]
        ))

        let ids = model.items.map(\.id)
        XCTAssertLessThan(
            try XCTUnwrap(ids.firstIndex(of: "addWholePageBookmark")),
            try XCTUnwrap(ids.firstIndex(of: "textOptions"))
        )
    }

    /** Protects Android's empty-history fallback as a late top-level All Text Options action. */
    func testEmptyRecentTextHistoryReplacesSubmenuWithTopLevelAllTextOptions() throws {
        let model = BibleWindowPaneMenuModel(snapshot: .fixture(
            copiedReferenceName: "John 3:16",
            speakReferenceName: "Romans 8:1",
            recentTextSettings: []
        ))

        XCTAssertFalse(model.items.contains { $0.id == "textOptions" })
        let allIndex = try XCTUnwrap(model.items.firstIndex { $0.id == "allTextOptions" })
        let speakIndex = try XCTUnwrap(model.items.firstIndex { $0.id == "goToSpeak" })
        let closeIndex = try XCTUnwrap(model.items.firstIndex { $0.id == "close" })
        XCTAssertGreaterThan(allIndex, speakIndex)
        XCTAssertLessThan(allIndex, closeIndex)
    }

    /** Protects Android's enum-name ordering and shared asset/action contract for recent settings. */
    func testRecentTextSettingsUseAndroidSortedRowsAndSharedActions() throws {
        let model = BibleWindowPaneMenuModel(snapshot: .fixture(
            sectionTitlesEnabled: false,
            verseNumbersEnabled: true,
            recentTextSettings: [.verseNumbers, .sectionTitles]
        ))

        let menu = try XCTUnwrap(model.items.first { $0.id == "textOptions" })
        XCTAssertEqual(
            Array(menu.children.prefix(2).map(\.id)),
            ["textSetting::SECTIONTITLES", "textSetting::VERSENUMBERS"]
        )
        XCTAssertEqual(menu.children[0].action, .editTextSetting(.sectionTitles))
        XCTAssertEqual(menu.children[0].iconAssetName, "SettingsIconSectionTitles")
        XCTAssertTrue(menu.children[0].isCheckable)
        XCTAssertFalse(menu.children[0].isChecked)
        XCTAssertTrue(menu.children[1].isChecked)
    }

    /** Protects Android Study Pad's three shared export commands and their XML order. */
    func testStudyPadWindowShowsHTMLArchiveAndCSVExportsInAndroidOrder() {
        let model = BibleWindowPaneMenuModel(snapshot: .fixture(
            canCopyLink: false,
            canExportHTML: true,
            canExportStudyPad: true,
            canExportStudyPadCSV: true
        ))

        let exportIDs = model.items.map(\.id).filter { $0.hasPrefix("export") }
        XCTAssertEqual(exportIDs, ["exportHTML", "exportStudyPad", "exportStudyPadCSV"])
        XCTAssertEqual(
            model.items.first(where: { $0.id == "exportHTML" })?.action,
            .exportHTML
        )
        XCTAssertEqual(
            model.items.first(where: { $0.id == "exportStudyPad" })?.action,
            .exportStudyPad
        )
        XCTAssertEqual(
            model.items.first(where: { $0.id == "exportStudyPadCSV" })?.action,
            .exportStudyPadCSV
        )
    }

    /**
     Protects Android's links-window-specific row set.

     Links windows expose Change to normal window and hide normal-window-only creation, pinning, and
     movement rows. This keeps iOS from preserving its older generic pane menu for links panes.
     */
    func testLinksWindowShowsChangeToNormalAndHidesNormalWindowRows() {
        let currentID = UUID()
        let model = BibleWindowPaneMenuModel(snapshot: .fixture(
            windowID: currentID,
            isLinksWindow: true,
            allWindowsInPersistedOrder: [
                .fixture(id: currentID, position: 0, document: "KJV", reference: "Gen 1"),
                .fixture(id: UUID(), position: 1, document: "ESV", reference: "Rom 1"),
            ]
        ))

        XCTAssertTrue(model.items.contains { $0.id == "changeToNormal" })
        XCTAssertFalse(model.items.contains { $0.id == "newWindow" })
        XCTAssertFalse(model.items.contains { $0.id == "moveTo" })
        XCTAssertFalse(model.items.contains { $0.id == "pin" })
    }

    /**
     Protects Android's synchronization submenu behavior.

     A synchronized window shows Disable synchronize, then Group 1 through Group 6 except the
     currently selected group. Group selection is one-based in the UI and zero-based in the action.
     */
    func testSynchronizedWindowSubmenuShowsDisableAndSkipsCurrentGroup() throws {
        let model = BibleWindowPaneMenuModel(snapshot: .fixture(
            isSynchronized: true,
            syncGroup: 2
        ))

        let syncMenu = try XCTUnwrap(model.items.first { $0.id == "synchronize" })
        XCTAssertEqual(syncMenu.children.map(\.id), [
            "disableSync",
            "syncGroup::0",
            "syncGroup::1",
            "syncGroup::3",
            "syncGroup::4",
            "syncGroup::5",
        ])
        XCTAssertEqual(syncMenu.children.compactMap(\.action), [
            .disableSync,
            .selectSyncGroup(0),
            .selectSyncGroup(1),
            .selectSyncGroup(3),
            .selectSyncGroup(4),
            .selectSyncGroup(5),
        ])
    }

    /**
     Protects Android's same-pin-bucket Move to submenu semantics.

     Android builds move targets from all windows in the same pin-mode bucket and uses the filtered
     bucket index as the action argument. It does not expose relative Move Up/Move Down commands.
     */
    func testMoveToSubmenuUsesAbsolutePositionsInSamePinBucket() throws {
        let firstID = UUID()
        let currentID = UUID()
        let lastID = UUID()
        let hiddenDifferentPinID = UUID()
        let model = BibleWindowPaneMenuModel(snapshot: .fixture(
            windowID: currentID,
            isPinned: false,
            allWindowsInPersistedOrder: [
                .fixture(id: firstID, position: 0, document: "KJV", reference: "Gen 1", isPinned: false),
                .fixture(id: currentID, position: 1, document: "ESV", reference: "Rom 1", isPinned: false),
                .fixture(id: hiddenDifferentPinID, position: 2, document: "NASB", reference: "Ps 1", isPinned: true),
                .fixture(id: lastID, position: 3, document: "NET", reference: "John 1", isPinned: false),
            ]
        ))

        let moveMenu = try XCTUnwrap(model.items.first { $0.id == "moveTo" })
        XCTAssertEqual(moveMenu.children.map(\.action), [
            .moveToPosition(0),
            .moveToPosition(2),
        ])
        XCTAssertEqual(moveMenu.children.map(\.title), [
            "Position 1 (KJV:Gen 1)",
            "Position 3 (NET:John 1)",
        ])
    }

    /**
     Protects Android checkable menu-row state as distinct from checked state.

     Android XML marks `pinMode` checkable even when the row is unchecked, and dynamic text-display
     preference rows are checkable booleans. The iOS renderer needs that metadata so it can draw an
     empty checkbox instead of treating `false` as a plain action row.
     */
    func testCheckableRowsExposeUncheckedStateForCustomRenderer() throws {
        let model = BibleWindowPaneMenuModel(snapshot: .fixture(
            isPinned: false,
            sectionTitlesEnabled: false,
            verseNumbersEnabled: true,
            recentTextSettings: [.sectionTitles, .verseNumbers]
        ))

        let pin = try XCTUnwrap(model.items.first { $0.id == "pin" })
        XCTAssertTrue(pin.isCheckable)
        XCTAssertFalse(pin.isChecked)

        let textOptions = try XCTUnwrap(model.items.first { $0.id == "textOptions" })
        let sectionTitles = try XCTUnwrap(
            textOptions.children.first { $0.id == "textSetting::SECTIONTITLES" }
        )
        let verseNumbers = try XCTUnwrap(
            textOptions.children.first { $0.id == "textSetting::VERSENUMBERS" }
        )
        XCTAssertTrue(sectionTitles.isCheckable)
        XCTAssertFalse(sectionTitles.isChecked)
        XCTAssertTrue(verseNumbers.isCheckable)
        XCTAssertTrue(verseNumbers.isChecked)
    }

    /**
     Protects Android-compatible copy-link URL construction.

     The pane menu should copy a `read.andbible.org` URL with the OSIS reference and module initials,
     including the optional ordinal when one is available. Human display strings are not equivalent.
     */
    func testCopyLinkURLUsesAndroidReadAndBibleSemantics() throws {
        let url = try XCTUnwrap(AndBibleReferenceURLBuilder.urlString(
            osisRef: "Gen.1.1",
            documentInitials: "KJV",
            ordinal: 42
        ))

        XCTAssertEqual(url, "https://read.andbible.org/Gen.1.1?document=KJV&ordinal=42")
    }

    /**
     Protects Android's configured-only window AI action visibility.

     Android exposes `llmActionsSubMenu` for a visible pane only after AI configuration exists.
     The row must route as a dialog action and must not appear for an unconfigured installation.
     */
    func testAIActionsRequireConfiguredAIAndVisibleWindow() {
        let configured = BibleWindowPaneMenuModel(snapshot: .fixture(isAIConfigured: true))
        let unconfigured = BibleWindowPaneMenuModel(snapshot: .fixture(isAIConfigured: false))

        XCTAssertEqual(
            configured.items.first(where: { $0.id == "aiActions" })?.action,
            .openAIActions
        )
        XCTAssertFalse(unconfigured.items.contains { $0.id == "aiActions" })
    }
}

private extension BibleWindowPaneMenuSnapshot {
    static func fixture(
        windowID: UUID = UUID(),
        isLinksWindow: Bool = false,
        isPinned: Bool = false,
        isSynchronized: Bool = false,
        syncGroup: Int = 0,
        isMaximized: Bool = false,
        sectionTitlesEnabled: Bool = true,
        verseNumbersEnabled: Bool = true,
        isAIConfigured: Bool = false,
        canCopyLink: Bool = true,
        canAddWholePageBookmark: Bool = false,
        canExportHTML: Bool = false,
        canExportStudyPad: Bool = false,
        canExportStudyPadCSV: Bool = false,
        copiedReferenceName: String? = nil,
        speakReferenceName: String? = nil,
        recentTextSettings: [AndroidTextDisplaySettingType] = [],
        allWindowsInPersistedOrder: [BibleWindowPaneMenuWindowSummary] = [
            .fixture(position: 0, document: "KJV", reference: "Gen 1"),
            .fixture(position: 1, document: "ESV", reference: "Rom 1"),
        ],
        visibleWindows: [BibleWindowPaneMenuWindowSummary]? = nil
    ) -> BibleWindowPaneMenuSnapshot {
        var displaySettings = TextDisplaySettings.appDefaults
        displaySettings.showSectionTitles = sectionTitlesEnabled
        displaySettings.showVerseNumbers = verseNumbersEnabled
        return BibleWindowPaneMenuSnapshot(
            windowID: windowID,
            isLinksWindow: isLinksWindow,
            isPinned: isPinned,
            isSynchronized: isSynchronized,
            syncGroup: syncGroup,
            isVisible: true,
            isMaximized: isMaximized,
            canMinimize: true,
            canClose: true,
            canSync: true,
            canCopyLink: canCopyLink,
            canAddWholePageBookmark: canAddWholePageBookmark,
            canExportHTML: canExportHTML,
            canExportStudyPad: canExportStudyPad,
            canExportStudyPadCSV: canExportStudyPadCSV,
            copiedReferenceName: copiedReferenceName,
            speakReferenceName: speakReferenceName,
            recentTextSettings: recentTextSettings.sorted { $0.rawValue < $1.rawValue },
            resolvedTextDisplaySettings: displaySettings,
            isBibleShown: true,
            isMyNotesShown: false,
            moduleHasRedLetterWords: true,
            autoPinEnabled: false,
            moduleHasStrongs: true,
            sectionTitlesEnabled: sectionTitlesEnabled,
            verseNumbersEnabled: verseNumbersEnabled,
            isAIConfigured: isAIConfigured,
            allWindowsInPersistedOrder: allWindowsInPersistedOrder,
            visibleWindows: visibleWindows ?? allWindowsInPersistedOrder
        )
    }
}

private extension BibleWindowPaneMenuWindowSummary {
    static func fixture(
        id: UUID = UUID(),
        position: Int,
        document: String,
        reference: String,
        isPinned: Bool = false
    ) -> BibleWindowPaneMenuWindowSummary {
        BibleWindowPaneMenuWindowSummary(
            id: id,
            position: position,
            documentAbbreviation: document,
            referenceName: reference,
            isPinned: isPinned
        )
    }
}
