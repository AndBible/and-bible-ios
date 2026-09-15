import Foundation
import XCTest
@testable import BibleUI
@testable import SwordKit

/**
 Package-level coverage for Android quick document selector presentation parity.

 These tests cover BibleUI-owned quick-selector sorting, labeling, exact identity, and popup
 threshold without app bootstrap or SWORD fixtures. Controller document-switch side effects live in
 `BibleReaderDocumentSwitchControllerTests` so pure presentation failures stay separate from SWORD
 fixture failures.
 */
final class BibleReaderQuickModuleSelectorTests: XCTestCase {
    /** The shared toolbar row model sorts and retains exact installed/EPUB/My Documents targets. */
    func testQuickDocumentRowsIncludeAuthorizedLocalGeneralBooks() {
        let installed = ModuleInfo(
            name: "DICT",
            description: "Dictionary",
            category: .dictionary,
            language: "en"
        )
        let selections: [BibleReaderQuickModuleSelectorPresentation.Selection] = [
            .myDocument(
                id: UUID(),
                initials: "MYDOC",
                name: "My document",
                language: "fi"
            ),
            .epub(
                identifier: "epub-id",
                generationIdentifier: "generation-id",
                initials: "Epub-Book",
                title: "A book",
                language: "en"
            ),
            .installed(installed),
        ]

        let rows = BibleReaderQuickModuleSelectorPresentation.rows(
            for: selections,
            activeModuleName: "Epub-Book"
        )

        XCTAssertEqual(rows.map(\.title), ["A book (en)", "DICT (en)", "MYDOC (fi)"])
        XCTAssertEqual(rows.map(\.selection.name), ["Epub-Book", "DICT", "MYDOC"])
        XCTAssertEqual(rows.map(\.isEnabled), [false, true, true])
    }

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

    /** Java-distinct installed initials remain separate row identities and current-row states. */
    func testBibleQuickModuleSelectorKeepsCanonicallyEquivalentInstalledInitialsDistinct() throws {
        let composed = "CAF\u{00E9}"
        let decomposed = "CAFE\u{0301}"
        let rows = BibleReaderQuickModuleSelectorPresentation.rows(
            for: [
                ModuleInfo(name: composed, description: "Composed", category: .bible, language: "en"),
                ModuleInfo(name: decomposed, description: "Decomposed", category: .bible, language: "en"),
            ],
            activeModuleName: composed
        )

        let composedRow = try XCTUnwrap(rows.first {
            $0.selection.name.utf16.elementsEqual(composed.utf16)
        })
        let decomposedRow = try XCTUnwrap(rows.first {
            $0.selection.name.utf16.elementsEqual(decomposed.utf16)
        })

        XCTAssertTrue(rows[0].selection.name.utf16.elementsEqual(decomposed.utf16))
        XCTAssertTrue(rows[1].selection.name.utf16.elementsEqual(composed.utf16))
        XCTAssertNotEqual(composedRow.id, decomposedRow.id)
        XCTAssertFalse(composedRow.isEnabled)
        XCTAssertTrue(decomposedRow.isEnabled)
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

    /** The two-document shortcut selects the Java-distinct alternate for equivalent spellings. */
    func testBibleQuickModuleSelectorActionUsesExactEnabledRowForCanonicalEquivalentInitials() {
        let composed = "CAF\u{00E9}"
        let decomposed = "CAFE\u{0301}"
        let action = BibleReaderQuickModuleSelectorPresentation.action(
            for: [
                ModuleInfo(name: composed, description: "Composed", category: .bible, language: "en"),
                ModuleInfo(name: decomposed, description: "Decomposed", category: .bible, language: "en"),
            ],
            activeModuleName: composed
        )

        guard case .switchDirectly(let row) = action else {
            return XCTFail("Expected the exact alternate row for Android's two-document shortcut.")
        }
        XCTAssertTrue(row.selection.name.utf16.elementsEqual(decomposed.utf16))
        XCTAssertTrue(row.isEnabled)
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

    /**
     Protects Android's inclusive retained-Bible suggestion without a readable fallback.

     - Setup: Supplies a readable KJV row and a locked retained row in one installed snapshot.
     - Expected result: The exact locked row is returned; missing or non-Bible retained identities
       return nil instead of selecting KJV.
     - Failure meaning: A non-Bible toolbar action can silently activate an unrelated readable Bible.
     - Side effects: None.
     */
    func testSuggestedBibleSelectionPreservesExactInstalledRetainedIdentityWithoutFallback() {
        let readable = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en"
        )
        let locked = ModuleInfo(
            name: "UITESTLOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            isEncrypted: true,
            isUnlocked: false
        )
        let commentary = ModuleInfo(
            name: "COMMENTARY",
            description: "Commentary",
            category: .commentary,
            language: "en"
        )

        XCTAssertEqual(
            BibleReaderSuggestedBibleSelectionPolicy.module(
                retainedModuleName: locked.name,
                installedModules: [readable, locked, commentary]
            )?.name,
            locked.name
        )
        XCTAssertNil(BibleReaderSuggestedBibleSelectionPolicy.module(
            retainedModuleName: "MISSING",
            installedModules: [readable, locked]
        ))
        XCTAssertNil(BibleReaderSuggestedBibleSelectionPolicy.module(
            retainedModuleName: commentary.name,
            installedModules: [readable, commentary]
        ))
        XCTAssertNil(BibleReaderSuggestedBibleSelectionPolicy.module(
            retainedModuleName: nil,
            installedModules: [readable]
        ))
    }

    /**
     Protects Java-exact UTF-16 identity at the suggested-Bible selection boundary.

     - Setup: Supplies canonically equivalent composed and decomposed module names.
     - Expected result: The retained decomposed UTF-16 sequence selects only the decomposed row.
     - Failure meaning: Swift normalization or case folding can redirect a retained module target.
     - Side effects: None.
     */
    func testSuggestedBibleSelectionUsesExactUTF16ModuleIdentity() throws {
        let composed = "Caf\u{00E9}Bible"
        let decomposed = "Cafe\u{0301}Bible"
        XCTAssertNotEqual(Array(composed.utf16), Array(decomposed.utf16))
        let modules = [
            ModuleInfo(name: composed, description: "Composed", category: .bible, language: "fr"),
            ModuleInfo(name: decomposed, description: "Decomposed", category: .bible, language: "fr"),
        ]

        let selected = try XCTUnwrap(BibleReaderSuggestedBibleSelectionPolicy.module(
            retainedModuleName: decomposed,
            installedModules: modules
        ))

        XCTAssertEqual(Array(selected.name.utf16), Array(decomposed.utf16))
        XCTAssertNotEqual(Array(selected.name.utf16), Array(composed.utf16))
    }

    /**
     Covers the pure identity predicate used by the suggested-Bible credential owner boundary.

     - Setup: Captures one window, controller object, exact module, and shared credential session.
     - Expected result: Only the unchanged tuple authorizes; replacing the window/controller,
       retained target, session target, or session identity returns false.
     - Failure meaning: The policy admits a stale identity tuple. Callback wiring and the absence of
       manager mutation still require focused integration coverage.
     - Side effects: None; this policy-only test does not invoke a controller or manager.
     */
    func testSuggestedBibleUnlockAuthorizationPredicateRejectsEveryStaleIdentityInput() {
        let windowID = UUID()
        let controller = NSObject()
        let replacementController = NSObject()
        let module = ModuleInfo(
            name: "UITESTLOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            isEncrypted: true,
            isUnlocked: false
        )
        let session = ModuleUnlockSession(module: module)
        let replacementSession = ModuleUnlockSession(module: module)
        let authorization = BibleReaderSuggestedBibleUnlockAuthorization(
            windowID: windowID,
            controllerID: ObjectIdentifier(controller),
            moduleIdentity: SwordJavaExactStringIdentity(module.name),
            sessionID: session.id
        )
        let authorizes: (UUID?, ObjectIdentifier?, String?, String, ModuleUnlockSession.ID) -> Bool = {
            authorization.authorizes(
                activeWindowID: $0,
                registeredControllerID: $1,
                retainedModuleName: $2,
                sessionModuleName: $3,
                presentedSessionID: $4
            )
        }

        XCTAssertTrue(authorizes(
            windowID,
            ObjectIdentifier(controller),
            module.name,
            module.name,
            session.id
        ))
        XCTAssertFalse(authorizes(
            UUID(), ObjectIdentifier(controller), module.name, module.name, session.id
        ))
        XCTAssertFalse(authorizes(
            windowID, ObjectIdentifier(replacementController), module.name, module.name, session.id
        ))
        XCTAssertFalse(authorizes(
            windowID, ObjectIdentifier(controller), "KJV", module.name, session.id
        ))
        XCTAssertFalse(authorizes(
            windowID, ObjectIdentifier(controller), module.name, "KJV", session.id
        ))
        XCTAssertFalse(authorizes(
            windowID,
            ObjectIdentifier(controller),
            module.name,
            module.name,
            replacementSession.id
        ))
    }

}
