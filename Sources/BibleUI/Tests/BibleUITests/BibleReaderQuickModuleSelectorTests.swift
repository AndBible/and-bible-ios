import Foundation
import XCTest
@testable import BibleUI
@testable import SwordKit
import enum SwiftUI.ColorScheme

/**
 Package-level coverage for Android quick document selector presentation parity.

 These tests cover BibleUI-owned quick-selector sorting, labeling, popup threshold, and renderer
 structure without app bootstrap or SWORD fixtures. Controller document-switch side effects live in
 `BibleReaderDocumentSwitchControllerTests` so pure presentation failures stay separate from SWORD
 fixture failures.
 */
final class BibleReaderQuickModuleSelectorTests: XCTestCase {
    /**
     Protects Android `MainBibleActivity.menuForDocs` parity for the Bible toolbar quick menu.

     Android sorts quick-menu entries by language code and then book abbreviation, renders labels as
     abbreviation plus language code in parentheses, and disables the current document instead of
     re-selecting it. This test uses the pure presentation contract so future UI refactors cannot
     accidentally restore the old iOS full-sheet semantics or sort by localized description.
     */
    func testBibleQuickModuleSelectorRowsMirrorAndroidOrderingLabelsAndDisabledCurrentDocument() {
        let modules = [
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en"),
            ModuleInfo(name: "FinRK", description: "Finnish Revised Version", category: .bible, language: "fi"),
            ModuleInfo(name: "AB", description: "Another Bible", category: .bible, language: "en")
        ]

        let rows = BibleReaderQuickModuleSelectorPresentation.rows(
            for: modules,
            activeModuleName: "WEB"
        )

        XCTAssertEqual(rows.map(\.module.name), ["AB", "WEB", "FinRK"])
        XCTAssertEqual(rows.map(\.title), ["AB (en)", "WEB (en)", "FinRK (fi)"])
        XCTAssertEqual(rows.map(\.isEnabled), [true, false, true])
    }

    /**
     Protects the quick-selector row equality contract used by presentation tests.

     Row equality should cover only visible and behavior-significant fields: selected module name,
     rendered title, and enabled state. Metadata such as description, category, or language is
     normalized into the title before rendering and should not make tests fail when behavior is
     unchanged.
     */
    func testBibleQuickModuleSelectorRowEqualityIgnoresNonVisibleModuleMetadata() {
        let lhs = BibleReaderQuickModuleSelectorPresentation.Row(
            module: ModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en"
            ),
            title: "KJV (en)",
            isEnabled: true
        )
        let rhs = BibleReaderQuickModuleSelectorPresentation.Row(
            module: ModuleInfo(
                name: "KJV",
                description: "Different catalog description",
                category: .commentary,
                language: "fi"
            ),
            title: "KJV (en)",
            isEnabled: true
        )

        XCTAssertEqual(lhs, rhs)
    }

    /**
     Protects long quick-selector lists from becoming unscrollable off-screen stacks.

     Users can install dozens of Bible modules. Android renders those entries through a popup menu
     that can scroll; the SwiftUI parity renderer must likewise be backed by a scroll container so
     all available modules can be reached without falling back to the full iOS sheet.
     */
    func testBibleQuickModuleSelectorUsesScrollContainerForLongInstalledModuleLists() throws {
        let rows = (0..<60).map { index in
            BibleReaderQuickModuleSelectorPresentation.Row(
                module: ModuleInfo(
                    name: String(format: "MOD%02d", index),
                    description: "Module \(index)",
                    category: .bible,
                    language: "en"
                ),
                title: String(format: "MOD%02d (en)", index),
                isEnabled: true
            )
        }
        let view = BibleReaderQuickModuleSelector(
            rows: rows,
            colorScheme: .light,
            onSelect: { _ in }
        )

        XCTAssertTrue(String(describing: type(of: view.body)).contains("ScrollView"))
        let selectorSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderQuickModuleSelector.swift"
        )
        XCTAssertTrue(selectorSource.contains("LazyVStack(alignment: .leading, spacing: 0)"))
        XCTAssertTrue(selectorSource.contains("AndroidPopupMenuSurface("))
        XCTAssertTrue(selectorSource.contains("AndroidPopupMenuRow("))
        XCTAssertTrue(selectorSource.contains("isEnabled: row.isEnabled"))
        XCTAssertTrue(selectorSource.contains("surfacePalette: ReaderThemeSurfacePalette = .standard"))
        XCTAssertFalse(selectorSource.contains("Color(red:"))
        XCTAssertFalse(selectorSource.contains("systemBackground"))
        XCTAssertFalse(selectorSource.contains("menuBackground"))
        XCTAssertFalse(selectorSource.contains("            VStack(alignment: .leading, spacing: 0)"))
    }

    /**
     Protects Android's exactly-two-document shortcut in `menuForDocs`.

     When only two Bible modules are available, Android switches directly to the other document and
     does not show a popup. The iOS toolbar action must keep that shortcut while replacing only the
     three-or-more path with the compact quick selector.
     */
    func testBibleQuickModuleSelectorActionMirrorsAndroidTwoDocumentShortcut() {
        let modules = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en"),
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en")
        ]

        let action = BibleReaderQuickModuleSelectorPresentation.action(
            for: modules,
            activeModuleName: "KJV"
        )

        guard case .switchDirectly(let row) = action else {
            XCTFail("Expected Android's exactly-two-module shortcut to select the alternate Bible.")
            return
        }
        XCTAssertEqual(row.module.name, "WEB")
        XCTAssertEqual(row.module.category, .bible)
    }

    /**
     Protects Android's popup threshold in `menuForDocs`.

     Three or more Bible modules must show the compact anchored quick selector, not the full
     document picker sheet. The sorted rows are part of the action payload so the UI layer cannot
     accidentally diverge from Android ordering while still showing a popup.
     */
    func testBibleQuickModuleSelectorActionShowsPopupForMoreThanTwoModules() {
        let modules = [
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en"),
            ModuleInfo(name: "FinRK", description: "Finnish Revised Version", category: .bible, language: "fi"),
            ModuleInfo(name: "AB", description: "Another Bible", category: .bible, language: "en")
        ]

        let action = BibleReaderQuickModuleSelectorPresentation.action(
            for: modules,
            activeModuleName: "WEB"
        )

        XCTAssertEqual(
            action,
            .showPopup([
                BibleReaderQuickModuleSelectorPresentation.Row(
                    module: modules[2],
                    title: "AB (en)",
                    isEnabled: true
                ),
                BibleReaderQuickModuleSelectorPresentation.Row(
                    module: modules[0],
                    title: "WEB (en)",
                    isEnabled: false
                ),
                BibleReaderQuickModuleSelectorPresentation.Row(
                    module: modules[1],
                    title: "FinRK (fi)",
                    isEnabled: true
                )
            ])
        )
    }

    /**
     Protects Android's non-two-document popup rule for single available Bible modules.

     Android only special-cases exactly two documents. With one available Bible it still shows the
     popup, and if the current document is not that Bible then the row remains enabled so the toolbar
     can switch from commentary or another category back to Bible mode.
     */
    func testBibleQuickModuleSelectorActionShowsPopupForSingleModuleWhenBibleIsNotCurrentDocument() {
        let modules = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en")
        ]

        let action = BibleReaderQuickModuleSelectorPresentation.action(
            for: modules,
            activeModuleName: nil
        )

        XCTAssertEqual(
            action,
            .showPopup([
                BibleReaderQuickModuleSelectorPresentation.Row(
                    module: modules[0],
                    title: "KJV (en)",
                    isEnabled: true
                )
            ])
        )
    }

    /**
     Protects Android `MainBibleActivity.commentaryClick` candidate and row semantics.

     The Android default commentary toolbar tap calls `menuForDocs` with unlocked commentaries plus
     general books plus dictionaries, then `menuForDocs` sorts by language code and abbreviation and
     renders compact `initials (language)` rows. This test keeps that category mix in the shared
     quick-selector presentation contract so iOS cannot regress to the full commentary-only chooser
     sheet or sort by localized descriptions.
     */
    func testCommentaryQuickModuleSelectorRowsIncludeAndroidDocumentCategories() {
        let commentary = ModuleInfo(
            name: "MHC",
            description: "Matthew Henry",
            category: .commentary,
            language: "en"
        )
        let dictionary = ModuleInfo(
            name: "BDBT",
            description: "Brown Driver Briggs",
            category: .dictionary,
            language: "en"
        )
        let generalBook = ModuleInfo(
            name: "Pilgrim",
            description: "Pilgrim's Progress",
            category: .generalBook,
            language: "en"
        )
        let finnishCommentary = ModuleInfo(
            name: "FinComm",
            description: "Finnish Commentary",
            category: .commentary,
            language: "fi"
        )

        let rows = BibleReaderQuickModuleSelectorPresentation.rows(
            for: [generalBook, finnishCommentary, commentary, dictionary],
            activeModuleName: "BDBT"
        )

        XCTAssertEqual(rows.map(\.module.category), [.dictionary, .commentary, .generalBook, .commentary])
        XCTAssertEqual(rows.map(\.title), ["BDBT (en)", "MHC (en)", "Pilgrim (en)", "FinComm (fi)"])
        XCTAssertEqual(rows.map(\.isEnabled), [false, true, true, true])
    }

}
