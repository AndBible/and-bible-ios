import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 App-host-free package coverage for Android `ChooseDocument` and reader module picker parity.

 These tests protect the BibleUI-owned picker filtering, pseudo-document, document-management, and
 full-screen chooser presentation contracts without booting the app. Behavioral access regressions
 use isolated temporary SWORD trees removed by inherited teardown or local `defer` cleanup.
 Failures indicate visual or behavioral drift from Android's document chooser, not app delegate or
 simulator lifecycle issues.
 */
final class BibleReaderModulePickerTests: BibleUISwordFixtureTestCase {
    /**
     Wraps lightweight test metadata in the exact presentation contract consumed by production.

     - Parameter modules: Immutable module fixtures whose initials also serve as abbreviations.
     - Returns: Installed-book presentations preserving fixture order and metadata.
     - Side effects: None.
     - Failure modes: None; every supplied module maps to exactly one presentation.
     */
    private func installedBooks(
        _ modules: [ModuleInfo]
    ) -> [BibleReaderInstalledBookPresentation] {
        modules.map {
            BibleReaderInstalledBookPresentation(info: $0, abbreviation: $0.name)
        }
    }

    func testBibleReaderModulePickerBuildsForBibleCategory() {
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        let view = BibleReaderModulePicker(
            controller: controller,
            category: .bible,
            onDismiss: {},
            onOpenDownloads: {},
            onOpenDictionaryBrowser: {},
            onOpenGeneralBookBrowser: {},
            onOpenMapBrowser: {}
        )

        XCTAssertTrue(String(describing: type(of: view)).contains("BibleReaderModulePicker"))
    }

    /**
     Verifies installed document filtering follows Android category, language, and search rules.

     Android `ChooseDocument` omits unsupported document categories from the normal picker, applies
     type and language filters together, and exposes a category-empty state only when the selected
     type has no visible rows. A failure means iOS can show Android-hidden modules or hide
     Android-visible modules.
     */
    func testBibleReaderModulePickerFiltersAndroidChooserCategoriesAndSearch() {
        let modules = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en"),
            ModuleInfo(name: "MHC", description: "Matthew Henry", category: .commentary, language: "en"),
            ModuleInfo(name: "StrongsHebrew", description: "Strong's Hebrew", category: .dictionary, language: "he"),
            ModuleInfo(name: "BookA", description: "General reference book", category: .generalBook, language: "fr"),
            ModuleInfo(name: "MapA", description: "Bible maps", category: .map, language: "en"),
            ModuleInfo(name: "Devotion", description: "Daily devotional", category: .dailyDevotion, language: "en")
        ]

        func filteredModules(
            category: DocumentCategory?,
            language: String = "",
            searchText: String = ""
        ) -> [ModuleInfo] {
            BibleReaderModulePicker.filteredRows(
                installedBooks: installedBooks(modules),
                selectedFilter: category.map(BibleReaderModulePicker.DocumentTypeFilter.category)
                    ?? .all,
                selectedLanguage: language,
                searchText: searchText
            ).compactMap { row in
                guard case .module(let module) = row else { return nil }
                return module.info
            }
        }

        XCTAssertEqual(
            filteredModules(category: nil).map(\.name),
            ["KJV", "MHC", "StrongsHebrew", "BookA", "MapA"]
        )
        XCTAssertEqual(
            filteredModules(category: .dictionary).map(\.name),
            ["StrongsHebrew"]
        )
        XCTAssertEqual(
            filteredModules(category: nil, language: "en").map(\.name),
            ["KJV", "MHC", "MapA"]
        )
        XCTAssertEqual(
            filteredModules(category: .bible, language: "he").map(\.name),
            []
        )
        XCTAssertEqual(
            filteredModules(category: nil, searchText: "strong").map(\.name),
            ["StrongsHebrew"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.availableLanguages(
                from: BibleReaderModulePicker.allRows(installedBooks: installedBooks(modules))
            ),
            ["en", "fr", "he"]
        )
        let bibleOnlyModules = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en")
        ]
        XCTAssertTrue(
            BibleReaderModulePicker.shouldShowFilterEmptyState(
                BibleReaderModulePicker.allRows(installedBooks: installedBooks(bibleOnlyModules)),
                selectedFilter: .category(.dictionary)
            )
        )
        XCTAssertFalse(
            BibleReaderModulePicker.shouldShowFilterEmptyState(
                BibleReaderModulePicker.allRows(installedBooks: installedBooks(bibleOnlyModules)),
                selectedFilter: .category(.bible)
            )
        )
        XCTAssertFalse(
            BibleReaderModulePicker.shouldShowFilterEmptyState(
                BibleReaderModulePicker.allRows(installedBooks: installedBooks(modules)),
                selectedFilter: .all
            )
        )
    }

    /**
     Preserves Java-distinct composed/decomposed module rows through rendering identity.

     - Setup: Supplies two installed rows with visually equivalent initials and different UTF-16
       spellings.
     - Expected: Each Java-distinct row has a distinct SwiftUI identity and retains its exact token.
     - Failure meaning: Swift canonical String equality is still collapsing or misrouting an
       installed book that Android exposes as a separate registry identity.
     - Side effects: None.
     */
    func testPickerKeepsCanonicalEquivalentJavaModuleIdentitiesSeparatelySelectable() throws {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf16), Array(decomposed.utf16))
        let composedModule = ModuleInfo(
            name: composed,
            description: "Composed",
            category: .bible,
            language: "fr"
        )
        let decomposedModule = ModuleInfo(
            name: decomposed,
            description: "Decomposed",
            category: .bible,
            language: "fr"
        )

        let distinct = [
            composedModule,
            decomposedModule,
        ]
        let rows = BibleReaderModulePicker.allRows(installedBooks: installedBooks(distinct))
            .filter { row in
                if case .module = row { return true }
                return false
            }

        XCTAssertEqual(distinct.count, 2)
        XCTAssertNotEqual(try XCTUnwrap(rows.first).id, try XCTUnwrap(rows.last).id)
        XCTAssertTrue(SwordJavaStringIdentity.equals(try XCTUnwrap(rows.first?.moduleInfo).name, composed))
        XCTAssertTrue(SwordJavaStringIdentity.equals(try XCTUnwrap(rows.last?.moduleInfo).name, decomposed))
    }

    /**
     Guards Android `ChooseDocument` document-type parity beyond normal installed SWORD rows.

     Android's chooser includes visible `FakeBookFactory` pseudo-documents, hides add-ons from
     "All types", and exposes add-ons only through the Add-ons document-type filter. The language
     filter also preserves AND_BIBLE rows, matching `DocumentSelectionBase.filterDocuments`.
     */
    func testBibleReaderModulePickerRowsIncludeAndroidPseudoDocumentsAndAddonFilter() {
        let modules = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en"),
            ModuleInfo(name: "MHC", description: "Matthew Henry", category: .commentary, language: "en"),
            ModuleInfo(name: "BookA", description: "General reference book", category: .generalBook, language: "fr"),
            ModuleInfo(name: "AddonFonts", description: "Font package", category: .addon, language: "zz"),
            ModuleInfo(name: "Devotion", description: "Daily devotional", category: .dailyDevotion, language: "en")
        ]

        XCTAssertEqual(
            BibleReaderModulePicker.filteredRows(
                installedBooks: installedBooks(modules),
                selectedFilter: .all,
                selectedLanguage: "",
                searchText: ""
            ).map(\.id),
            [
                "module:KJV",
                "module:MHC",
                "module:BookA",
                "pseudo:compare",
                "pseudo:myNotes",
                "pseudo:studyPads"
            ]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredRows(
                installedBooks: installedBooks(modules),
                selectedFilter: .category(.commentary),
                selectedLanguage: "",
                searchText: ""
            ).map(\.id),
            ["module:MHC", "pseudo:compare", "pseudo:myNotes"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredRows(
                installedBooks: installedBooks(modules),
                selectedFilter: .category(.generalBook),
                selectedLanguage: "",
                searchText: ""
            ).map(\.id),
            ["module:BookA", "pseudo:studyPads"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredRows(
                installedBooks: installedBooks(modules),
                selectedFilter: .addons,
                selectedLanguage: "en",
                searchText: ""
            ).map(\.id),
            ["module:AddonFonts"]
        )
        XCTAssertTrue(
            BibleReaderModulePicker.filteredRows(
                installedBooks: installedBooks(modules),
                selectedFilter: .category(.bible),
                selectedLanguage: "",
                searchText: "notes"
            ).isEmpty
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredRows(
                installedBooks: installedBooks(modules),
                selectedFilter: .all,
                selectedLanguage: "",
                searchText: "notes"
            ).map(\.id),
            ["pseudo:myNotes"]
        )
    }

    /**
     Verifies the picker add-on tab consumes the shared Android-admitted add-on projection.

     - Setup: Writes four payload-backed compatible add-ons, including two comparator-distinct books
       with the same initials and abbreviations opposing initials order, plus future and malformed
       configs under one temporary manager root.
     - Expected: Picker inventory contains every compatible JSword row, gives duplicates distinct
       SwiftUI identities, and uses Android's abbreviation ordering rather than initials ordering.
     - Side effects: Creates, reads, and removes one isolated SWORD config tree.
     - Failure meaning: The picker can expose add-ons that prompt/feature execution correctly rejects.
     */
    func testPickerAddonInventoryUsesSharedAndroidAdmission() throws {
        let swordFixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = swordFixtureURL.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: swordFixtureURL) }
        let definitions = [
            (file: "z-alpha.conf", initials: "ZZZADDON", description: "Alpha row", abbreviation: "Alpha", minimum: "1115"),
            (file: "b-duplicate.conf", initials: "DUPADDON", description: "Duplicate beta", abbreviation: "Beta", minimum: "1115"),
            (file: "c-duplicate.conf", initials: "DUPADDON", description: "Duplicate gamma", abbreviation: "Gamma", minimum: "1115"),
            (file: "a-zulu.conf", initials: "AAAADDON", description: "Zulu row", abbreviation: "Zulu", minimum: "1115"),
            (file: "future.conf", initials: "FUTURE", description: "Future", abbreviation: "Future", minimum: "1116"),
            (file: "malformed.conf", initials: "MALFORMED", description: "Malformed", abbreviation: "Malformed", minimum: "later"),
        ]
        for definition in definitions {
            let payloadDirectory = swordFixtureURL.appendingPathComponent(
                "addons/\(definition.file)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: payloadDirectory,
                withIntermediateDirectories: true
            )
            try """
            [\(definition.initials)]
            Description=\(definition.description)
            Abbreviation=\(definition.abbreviation)
            Category=And Bible
            ModDrv=RawGenBook
            DataPath=./addons/\(definition.file)
            AndBibleMinimumVersion=\(definition.minimum)
            """.write(
                to: configDirectory.appendingPathComponent(definition.file),
                atomically: true,
                encoding: .utf8
            )
        }
        let manager = try XCTUnwrap(SwordManager(modulePath: swordFixtureURL.path))
        let addons = BibleReaderModulePicker.selectableAddonModules(from: manager)

        XCTAssertEqual(
            addons.map(\.moduleInfo.name),
            ["ZZZADDON", "DUPADDON", "DUPADDON", "AAAADDON"]
        )
        let rows = BibleReaderModulePicker.filteredRows(
            installedBooks: [],
            admittedAddons: addons,
            selectedFilter: .addons,
            selectedLanguage: "",
            searchText: ""
        )
        XCTAssertEqual(
            rows.compactMap(\.moduleInfo).map(\.description),
            ["Alpha row", "Duplicate beta", "Duplicate gamma", "Zulu row"]
        )
        XCTAssertEqual(rows.map(\.primaryTitle), ["Alpha", "Beta", "Gamma", "Zulu"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 4)
        XCTAssertEqual(Set(rows.map(\.moduleAccessibilityIdentifier)).count, 4)
        XCTAssertEqual(Set(addons.map(\.removalTarget)).count, 4)
        let deletionTargets = rows.compactMap { row -> SwordInstalledAddonRemovalTarget? in
            guard let selection = BibleReaderModulePicker.deletionSelection(for: row),
                  case .addon(let addon) = selection else {
                return nil
            }
            return addon.removalTarget
        }
        XCTAssertEqual(deletionTargets, addons.map(\.removalTarget))
    }

    /**
     Guards the picker delete action against collapsing an admitted add-on back to initials.

     - Setup: Reads the production picker after the behavior-level row-selection oracle above and
       extracts its exact add-on uninstall function.
     - Expected result: The app bar captures immutable deletion identity before clearing contextual
       state, and repository deletion receives the opaque target rather than the module-name API.
     - Side effects: Reads one source-controlled Swift file without mutation.
     - Failure meaning: Duplicate-initial or configless Android add-on rows can render distinctly but
       invoke an ordinary uninstall path that rejects or removes a different installed Book.
     */
    func testAddonContextDeleteRetainsOpaqueInstalledOwner() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )
        let uninstallSource = try BibleUITestSourceLocator.extractFunction(
            named: "uninstallInstalledAddon",
            from: source
        )

        XCTAssertTrue(source.contains("@State private var pendingAddonUninstall"))
        XCTAssertTrue(
            source.contains(
                "let contextualDeletion = contextualRow.flatMap(Self.deletionSelection)"
            )
        )
        XCTAssertTrue(source.contains("case .addon(let addon):"))
        XCTAssertTrue(source.contains("pendingAddonUninstall = addon"))
        XCTAssertFalse(source.contains("if let contextualAddon"))
        XCTAssertTrue(uninstallSource.contains("repository.uninstallAddon(addon.removalTarget)"))
        XCTAssertFalse(uninstallSource.contains("repository.uninstallModule(named:"))
    }

    /**
     Verifies ordinary installed books retain Android abbreviation rendering and locale sorting.

     - Setup: Supplies Turkish-I abbreviations whose locale-lowercase order opposes initials, plus
       two equal-lowercase abbreviations in a deliberate input order.
     - Expected: Primary labels use abbreviations, Turkish lowercase controls ordering, and equal
       keys remain stable instead of falling back to initials.
     - Side effects: None; projects immutable in-memory installed metadata.
     - Failure meaning: Non-add-on chooser rows diverge from Android `DocumentSelectionBase` and
       `DocumentItemAdapter` even though add-on rows appear correct.
     */
    func testInstalledBookRowsRenderAndSortByAndroidAbbreviation() {
        /**
         Builds one Turkish-language installed presentation for deterministic row sorting.

         - Parameters:
           - initials: Exact installed module identity.
           - abbreviation: Android primary label and locale-lowercase sort input.
         - Returns: Immutable Bible-row presentation.
         - Side effects: None.
         - Failure modes: None.
         */
        func book(
            _ initials: String,
            _ abbreviation: String
        ) -> BibleReaderInstalledBookPresentation {
            BibleReaderInstalledBookPresentation(
                info: ModuleInfo(
                    name: initials,
                    description: "\(initials) name",
                    category: .bible,
                    language: "tr"
                ),
                abbreviation: abbreviation
            )
        }
        let rows = BibleReaderModulePicker.filteredRows(
            installedBooks: [
                book("AAA", "I"),
                book("DDD", "SAME"),
                book("CCC", "same"),
                book("ZZZ", "İ"),
            ],
            selectedFilter: .category(.bible),
            selectedLanguage: "",
            searchText: ""
        )

        XCTAssertEqual(rows.map(\.primaryTitle), ["İ", "SAME", "same", "I"])
        XCTAssertEqual(rows.compactMap(\.moduleInfo).map(\.name), ["ZZZ", "DDD", "CCC", "AAA"])
    }

    /**
     Protects the picker boundary that consumes Android's combined installed-book ownership result.

     The resolver separately proves exact-initials, exact-full-name, and case-insensitive TreeSet
     lookup across native, SQLite, EPUB, and My Documents registrations. This test supplies the
     possible ownership outcomes for several installed EPUB files and verifies the chooser retains
     only packages that resolve back to their own immutable library identifier. A failure means a
     rejected or shadowed EPUB can still be advertised/selectable, or the picker reordered valid
     EPUBs. The pure projection performs no filesystem, database, simulator, or async work.
     */
    func testBibleReaderModulePickerOmitsEpubsRejectedByCombinedRegistryOwnership() {
        let admittedFirst = EpubInfo(
            identifier: "epub-admitted-first",
            initials: "EPUBFirst",
            sourceFileName: "first.epub",
            title: "First EPUB",
            description: "First EPUB",
            author: "",
            language: "en"
        )
        let installedCollision = EpubInfo(
            identifier: "epub-installed-collision",
            initials: "NativeExact",
            sourceFileName: "native-collision.epub",
            title: "Installed collision",
            description: "Installed collision",
            author: "",
            language: "en"
        )
        let localCollision = EpubInfo(
            identifier: "epub-local-collision",
            initials: "my document name",
            sourceFileName: "local-collision.epub",
            title: "Local collision",
            description: "Local collision",
            author: "",
            language: "en"
        )
        let admittedLast = EpubInfo(
            identifier: "epub-admitted-last",
            initials: "EPUBLast",
            sourceFileName: "last.epub",
            title: "Last EPUB",
            description: "Last EPUB",
            author: "",
            language: "fr"
        )

        let admitted = BibleReaderModulePicker.admittedEpubs(
            from: [admittedFirst, installedCollision, localCollision, admittedLast],
            resolvedOwnerIdentifier: { epub in
                switch epub.identifier {
                case admittedFirst.identifier:
                    return admittedFirst.identifier
                case installedCollision.identifier:
                    return nil
                case localCollision.identifier:
                    return admittedFirst.identifier
                case admittedLast.identifier:
                    return admittedLast.identifier
                default:
                    return nil
                }
            }
        )

        XCTAssertEqual(admitted.map(\.identifier), [admittedFirst.identifier, admittedLast.identifier])
        XCTAssertEqual(
            BibleReaderModulePicker.allRows(installedBooks: [], epubs: admitted).compactMap { row in
                guard case .epub(let epub) = row else { return nil }
                return epub.identifier
            },
            [admittedFirst.identifier, admittedLast.identifier]
        )
    }

    /**
     Verifies the picker exposes Android document management actions including functional unlock.

     Android shows About, Delete, and Delete Index for installed documents. iOS must reuse the real
     module management services for those actions and expose Unlock only for encrypted rows now that
     the picker routes cipher keys through `SwordManager`.
     */
    func testBibleReaderModulePickerRowActionsUseAndroidDocumentManagementContract() {
        let plainModule = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en"
        )
        let lockedModule = ModuleInfo(
            name: "LOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            isEncrypted: true,
            isUnlocked: false
        )

        XCTAssertEqual(
            BibleReaderModulePicker.rowActions(
                for: plainModule,
                installedModules: [plainModule, lockedModule]
            ),
            [.about, .uninstall, .deleteIndex]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.rowActions(
                for: lockedModule,
                installedModules: [plainModule, lockedModule]
            ),
            [.about, .uninstall, .deleteIndex, .unlock]
        )
    }

    /**
     Verifies the installed-document picker hides removal for the final Bible.

     - Setup: Supplies one Bible as the selected row and the complete installed inventory.
     - Expected result: The picker retains About and Delete Index without exposing Uninstall.
     - Failure meaning: The picker can present a destructive action that Android and the shared
       repository invariant intentionally suppress.
     - Side effects: None.
     */
    func testBibleReaderModulePickerHidesUninstallForFinalInstalledBible() {
        let onlyBible = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en"
        )

        XCTAssertEqual(
            BibleReaderModulePicker.rowActions(
                for: onlyBible,
                installedModules: [onlyBible]
            ),
            [.about, .deleteIndex]
        )
    }

    /**
     Verifies Android document-type enum mapping stays scoped to chooser-visible categories.

     The full chooser supports Bible, commentary, dictionary, general book, and map categories while
     excluding daily devotions, EPUB, glossary, and unknown types from direct document-category
     selection.
     */
    func testBibleReaderModulePickerMapsAndroidDocumentTypeCategories() {
        XCTAssertEqual(BibleReaderModulePicker.initialCategoryFilter(for: .bible), .bible)
        XCTAssertEqual(BibleReaderModulePicker.initialCategoryFilter(for: .commentary), .commentary)
        XCTAssertEqual(BibleReaderModulePicker.initialCategoryFilter(for: .dictionary), .dictionary)
        XCTAssertEqual(BibleReaderModulePicker.initialCategoryFilter(for: .generalBook), .generalBook)
        XCTAssertEqual(BibleReaderModulePicker.initialCategoryFilter(for: .map), .map)
        XCTAssertNil(BibleReaderModulePicker.initialCategoryFilter(for: .epub))
        XCTAssertNil(BibleReaderModulePicker.initialCategoryFilter(for: .dailyDevotion))

        XCTAssertEqual(BibleReaderModulePicker.documentCategory(for: .bible), .bible)
        XCTAssertEqual(BibleReaderModulePicker.documentCategory(for: .commentary), .commentary)
        XCTAssertEqual(BibleReaderModulePicker.documentCategory(for: .dictionary), .dictionary)
        XCTAssertEqual(BibleReaderModulePicker.documentCategory(for: .generalBook), .generalBook)
        XCTAssertEqual(BibleReaderModulePicker.documentCategory(for: .map), .map)
        XCTAssertNil(BibleReaderModulePicker.documentCategory(for: .dailyDevotion))
        XCTAssertNil(BibleReaderModulePicker.documentCategory(for: .glossary))
        XCTAssertNil(BibleReaderModulePicker.documentCategory(for: .unknown))
    }

    /**
     Guards Android current-document parity for full module-picker map selections.

     Android routes map rows through `setCurrentDocument(book)` just like other document rows. The
     full iOS picker must therefore call the controller's map document switch instead of splitting
     map module and category updates across separate mutations.
     */
    func testBibleReaderModulePickerRoutesMapsThroughDocumentSwitch() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )
        let selectionSource = try BibleUITestSourceLocator.extractFunction(
            named: "selectUnlockedModule",
            from: source
        )

        XCTAssertTrue(selectionSource.contains("case .map:"))
        XCTAssertTrue(selectionSource.contains("controller.switchMapDocument(to: module.name)"))
        XCTAssertFalse(selectionSource.contains("controller.switchMapModule(to: module.name)"))
        XCTAssertFalse(selectionSource.contains("controller.switchCategory(to: .map)"))
    }

    /**
     Guards Android `FakeBookFactory.pseudoDocuments` routing for the full document chooser.

     Android exposes My Notes, Journal/StudyPads, and Compare from `ChooseDocument`; it does not
     expose the hidden Memorize document or the transient Multi document from that picker path.
     */
    func testBibleReaderModulePickerPseudoDocumentsRouteThroughAndroidEquivalents() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )

        XCTAssertTrue(source.contains("case .myNotes:"))
        XCTAssertTrue(source.contains("controller.loadMyNotesDocument()"))
        XCTAssertTrue(source.contains("case .studyPads:"))
        XCTAssertTrue(source.contains("dismissAndPresentAuxiliaryBrowser(onOpenStudyPadSelector)"))
        XCTAssertTrue(source.contains("case .compare:"))
        XCTAssertTrue(source.contains("controller.loadCompareDocument()"))
        XCTAssertFalse(source.contains("loadMultiReferenceDocument"))
        XCTAssertFalse(source.contains("loadMemorizeDocument"))
    }

    /**
     Guards Android `ChooseDocument` routes against regressing to a dialog-sized presentation host.

     Android opens both the all-types chooser and category-scoped chooser as an app-owned
     full-screen activity. The iOS coordinator state is private, so this source-level contract
     checks the presentation boundary directly: both chooser routes must use the same reader-stack
     destination host as Downloads, and neither route may return to an overlay, native sheet, or
     full-screen cover.
     */
    func testBibleReaderDocumentChooserRoutesUseAppOwnedOverlayInsteadOfNativePresentation() throws {
        let readerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )
        let pickerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )
        let chooserDestinationSource = try BibleUITestSourceLocator.extractFunction(
            named: "documentChooserDestinationContent",
            from: readerSource
        )

        XCTAssertTrue(readerSource.contains("case modulePicker"))
        XCTAssertTrue(readerSource.contains("case chooseDocument"))
        XCTAssertTrue(readerSource.contains("case .modulePicker:"))
        XCTAssertTrue(readerSource.contains("case .chooseDocument:"))
        XCTAssertTrue(readerSource.contains("documentChooserDestinationContent("))
        XCTAssertTrue(readerSource.contains("presentReaderDestination(.modulePicker"))
        XCTAssertTrue(readerSource.contains("presentReaderDestination(.chooseDocument"))
        XCTAssertFalse(readerSource.contains("if let modal = activeReaderModal"))
        XCTAssertFalse(readerSource.contains("readerModalContent("))
        XCTAssertFalse(readerSource.contains("readerSheetModalBinding"))
        XCTAssertFalse(readerSource.contains("readerDocumentChooserModalBinding"))
        XCTAssertFalse(readerSource.contains(".fullScreenCover(item: $refChooserPresentation)"))
        XCTAssertFalse(pickerSource.contains(".presentationDetents([.medium, .large])"))
        XCTAssertTrue(chooserDestinationSource.contains("BibleReaderModulePicker("))
        XCTAssertTrue(chooserDestinationSource.contains("surfacePalette: readerThemeSurfacePalette"))
        XCTAssertFalse(chooserDestinationSource.contains("ReaderAppOwnedOverlay"))
        XCTAssertFalse(chooserDestinationSource.contains(".sheet("))
        XCTAssertFalse(chooserDestinationSource.contains(".fullScreenCover("))
    }

    /**
     Guards Android `DocumentSelectionBase` visual parity for the full document chooser.

     Android renders `ChooseDocument` with an app-owned toolbar, inline language/search/type filters,
     a visible document count, and `document_list_item` rows. iOS must not regress to a native
     `NavigationStack`/`List`/`.searchable` sheet because that preserves iOS chrome instead of the
     shared AndBible document-management surface.
     */
    func testBibleReaderDocumentChooserUsesAndroidDocumentSelectionLayout() throws {
        let pickerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )
        let sharedSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Shared/AndroidDocumentSelectionControls.swift"
        )

        XCTAssertTrue(pickerSource.contains("private var androidDocumentChooserScreen"))
        XCTAssertTrue(pickerSource.contains("AndroidDocumentSelectionActivityScreen("))
        XCTAssertTrue(pickerSource.contains("private var androidTopAppBar"))
        XCTAssertTrue(pickerSource.contains("private func androidFilterBar(visibleDocumentCount: Int)"))
        XCTAssertTrue(pickerSource.contains("private func androidDocumentRow(_ row: DocumentChooserRow)"))
        XCTAssertTrue(pickerSource.contains("AndroidDocumentSelectionFilterBar("))
        XCTAssertTrue(pickerSource.contains("AndroidDocumentSelectionFilterBar.localizedResultCount"))
        XCTAssertFalse(pickerSource.contains("private func androidLanguageFilterMenu()"))
        XCTAssertTrue(pickerSource.contains("private var androidChooserOverflowMenu"))
        XCTAssertTrue(pickerSource.contains("String(localized: \"document\", defaultValue: \"Document\")"))
        XCTAssertTrue(sharedSource.contains("AndroidActivitySurface(palette: surfacePalette)"))
        XCTAssertFalse(sharedSource.contains(".toolbar(.hidden, for: .navigationBar)"))
        XCTAssertFalse(pickerSource.contains("NavigationStack {\n            List {"))
        XCTAssertFalse(pickerSource.contains(".searchable(text: $searchText"))
        XCTAssertFalse(pickerSource.contains("Section(String(localized: \"document_filter_results"))
    }

    /**
     Locks the reported chooser regression to Android's full activity structure shared with Downloads.

     The regression presented Choose Document as a large-type, history-like constrained modal even
     though Android's `ChooseDocument` and `DownloadActivity` inherit the same
     `DocumentSelectionBase` screen. This guard requires both iOS routes to reuse the same app-owned
     activity host, top bar, filter strip, icon column, contextual action bar, palette ownership, and
     16/14sp row typography. Native menus, context menus, swipe actions, sheets, and local color
     facsimiles are forbidden inside either document-selection activity.
     */
    func testDocumentChooserAndDownloadsShareFullAndroidDocumentSelectionStructure() throws {
        let pickerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )
        let downloadsSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift"
        )
        let sharedSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Shared/AndroidDocumentSelectionControls.swift"
        )
        let rowPresentationSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserRowActionPresentation.swift"
        )
        let activityMarkerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Shared/AndroidActivityAccessibilityMarker.swift"
        )

        for source in [pickerSource, downloadsSource] {
            XCTAssertTrue(source.contains("AndroidDocumentSelectionActivityScreen("))
            XCTAssertTrue(source.contains("AndroidActivityTopAppBar("))
            XCTAssertTrue(source.contains("AndroidDocumentSelectionFilterBar("))
            XCTAssertTrue(source.contains("AndroidDocumentListLeadingColumn("))
            XCTAssertTrue(source.contains("AndroidDocumentContextActionBar("))
            XCTAssertTrue(source.contains("AndroidActivityAccessibilityMarker("))
            XCTAssertTrue(source.contains("ReaderThemeSurfacePalette"))
            XCTAssertTrue(source.contains(".font(.system(size: 16, weight: .regular))"))
            XCTAssertTrue(source.contains(".font(.system(size: 14, weight: .regular))"))

            for forbidden in [
                "Menu {",
                ".contextMenu",
                ".swipeActions",
                ".sheet(",
                ".presentationDetents",
                "Image(systemName:",
                "DocumentChooserPalette",
            ] {
                XCTAssertFalse(source.contains(forbidden), "Unexpected native/invented document UI: \(forbidden)")
            }
        }

        XCTAssertTrue(sharedSource.contains("struct AndroidDocumentSelectionActivityScreen"))
        XCTAssertTrue(sharedSource.contains("AndroidActivitySurface(palette: surfacePalette)"))
        XCTAssertTrue(sharedSource.contains("VStack(spacing: 0)"))
        XCTAssertTrue(sharedSource.contains("maxHeight: .infinity"))
        XCTAssertFalse(sharedSource.contains("surfacePalette.backgroundColor.ignoresSafeArea()"))
        XCTAssertFalse(sharedSource.contains(".navigationBarBackButtonHidden(true)"))
        XCTAssertFalse(sharedSource.contains(".toolbar(.hidden, for: .navigationBar)"))
        XCTAssertTrue(sharedSource.contains(".frame(height: 55)"))
        XCTAssertTrue(sharedSource.contains("localized: \"document_filter_results\""))
        XCTAssertTrue(sharedSource.contains("defaultValue: \"%d documents\""))
        XCTAssertTrue(sharedSource.contains("AndroidResourcePalette.grey600"))
        XCTAssertTrue(sharedSource.contains("AndroidResourcePalette.yellow600"))
        XCTAssertTrue(activityMarkerSource.contains("struct AndroidActivityAccessibilityMarker"))
        XCTAssertTrue(activityMarkerSource.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(activityMarkerSource.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(downloadsSource.contains("ModuleBrowserStatusSlotPresentation(status: status)"))
        XCTAssertTrue(rowPresentationSource.contains("DocumentInstalledStatus"))
        XCTAssertTrue(rowPresentationSource.contains("DocumentDownloadingStatus"))
        XCTAssertTrue(rowPresentationSource.contains("DocumentUpdateStatus"))
        XCTAssertTrue(rowPresentationSource.contains("DocumentErrorStatus"))
        XCTAssertTrue(rowPresentationSource.contains("AndroidResourcePalette.documentUpgradeAmber"))

        let backup = try XCTUnwrap(pickerSource.range(of: "modulePickerBackupDocumentsButton"))
        let downloads = try XCTUnwrap(pickerSource.range(of: "modulePickerDownloadsButton"))
        let install = try XCTUnwrap(pickerSource.range(of: "modulePickerInstallZipButton"))
        XCTAssertLessThan(backup.lowerBound, downloads.lowerBound)
        XCTAssertLessThan(downloads.lowerBound, install.lowerBound)
    }

    /**
     Guards imported EPUB management against returning to a parallel native iOS library.

     - Setup: Reads the Choose Document, reader-route, and immutable EPUB adapter sources.
     - Expected result: EPUBs use the same long-press context bar and About/Delete/Delete Index
       ordering as Android General Book rows; deletion is durable and Delete Index publishes and
       adopts an index-free generation without removing the document.
     - Failure meaning: EPUB management has drifted into an iOS-only route, invented row actions,
       or a mutable in-place index operation that can invalidate an active reader.
     - Side effects: None; this is a structural ownership and lifecycle contract.
     */
    func testImportedEpubRowsReuseAndroidDocumentContextManagement() throws {
        let pickerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )
        let readerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )
        let epubReaderSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleCore/Sources/BibleCore/Formats/EpubReader.swift"
        )
        let generationSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleCore/Sources/BibleCore/Formats/EpubReaderGeneration.swift"
        )

        XCTAssertFalse(readerSource.contains("case epubLibrary"))
        XCTAssertFalse(readerSource.contains("EpubLibraryView("))
        XCTAssertTrue(readerSource.contains("onDeleteEpub: reconcileDeletedEpubAcrossReaderPanes"))
        XCTAssertTrue(pickerSource.contains("case .epub(let epub):"))
        XCTAssertTrue(pickerSource.contains("onLongPress: { beginContextualEpubSelection(epub) }"))
        XCTAssertTrue(pickerSource.contains("private var contextualEpubActions"))
        XCTAssertTrue(pickerSource.contains("[.about, .uninstall, .deleteIndex]"))
        XCTAssertTrue(pickerSource.contains("ModuleBrowserModuleDetails(epub: contextualEpub)"))
        XCTAssertTrue(pickerSource.contains("EpubLibraryDeletionState"))
        XCTAssertTrue(pickerSource.contains("EpubReader.deleteSearchIndex(identifier: identifier)"))
        XCTAssertTrue(pickerSource.contains("controller.adoptRebuiltEpubReader(replacementReader)"))
        XCTAssertTrue(pickerSource.contains("Text(epub.initials)"))
        XCTAssertTrue(pickerSource.contains("Text(epub.title)"))
        XCTAssertFalse(pickerSource.contains("Text(epub.author)"))
        XCTAssertTrue(epubReaderSource.contains("public static func deleteSearchIndex"))
        XCTAssertTrue(generationSource.contains("includesSearchIndex: false"))
        XCTAssertTrue(generationSource.contains("try clearSearchIndex(at: stagingIndex)"))
    }

    /**
     Guards reader document-picker About against preserving the shared iOS sheet route.

     Android's `DocumentSelectionBase` row menu invokes `CommonUtils.showAbout(...)` and keeps the user
     inside the chooser while a dialog is visible. The iOS picker must therefore use the same shared
     module details dialog presenter as Downloads instead of wrapping `ModuleBrowserModuleDetailsView`
     in a `NavigationStack` sheet or synthesizing Downloads-only metadata for installed documents.
     */
    func testBibleReaderModulePickerAboutUsesSharedAndroidDialogInsteadOfSheet() throws {
        let pickerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )

        XCTAssertTrue(pickerSource.contains(".moduleBrowserModuleDetailsDialog("))
        XCTAssertTrue(pickerSource.contains("ModuleBrowserModuleDetails(installedModule: module)"))
        XCTAssertFalse(pickerSource.contains(".sheet(item: $selectedModuleDetails)"))
        XCTAssertFalse(pickerSource.contains("NavigationStack {\n                ModuleBrowserModuleDetailsView"))
        XCTAssertFalse(pickerSource.contains("sourceName: String(localized: \"installed\""))
    }

    /**
     Verifies the inclusive full chooser retains locked rows and gates selection through real
     manager-level cipher verification.

     - Setup: Compares locked and unlocked Bible metadata, then inspects the private SwiftUI routing
       boundary that consumes the shared switch outcome.
     - Expected result: Both rows remain in the full chooser; all Bible rows reach the controller's
       fresh preflight before prompting through `SwordManager`, and only a successful switch
       dismisses the picker. A stale locked row already unlocked elsewhere does not prompt twice.
     - Failure meaning: A locked document can disappear from the unlock-capable chooser, render
       without a key, recurse on stale metadata, or dismiss without changing the reader.
     - Side effects: Reads package source only; no module store or reader state is mutated.
     */
    func testBibleReaderModulePickerGatesLockedSelectionThroughSwordManager() throws {
        let locked = ModuleInfo(
            name: "LOCKED",
            description: "Locked Bible",
            category: .bible,
            language: "en",
            isEncrypted: true,
            isUnlocked: false
        )
        let unlocked = ModuleInfo(
            name: "OPEN",
            description: "Open Bible",
            category: .bible,
            language: "en",
            isEncrypted: true,
            isUnlocked: true
        )

        XCTAssertTrue(BibleReaderModulePicker.requiresUnlock(locked))
        XCTAssertFalse(BibleReaderModulePicker.requiresUnlock(unlocked))
        XCTAssertEqual(
            BibleReaderModulePicker.filteredRows(
                installedBooks: installedBooks([locked, unlocked]),
                selectedFilter: .category(.bible),
                selectedLanguage: "",
                searchText: ""
            ).compactMap(\.moduleInfo).map(\.name),
            ["LOCKED", "OPEN"]
        )

        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )
        let selectionSource = try BibleUITestSourceLocator.extractFunction(named: "select", from: source)
        let unlockedSelectionSource = try BibleUITestSourceLocator.extractFunction(
            named: "selectUnlockedModule",
            from: source
        )
        let beginUnlockSource = try BibleUITestSourceLocator.extractFunction(
            named: "beginUnlock",
            from: source
        )
        let unlockSource = try BibleUITestSourceLocator.extractFunction(named: "attemptUnlock", from: source)

        XCTAssertTrue(selectionSource.contains("if module.category == .bible"))
        XCTAssertTrue(selectionSource.contains("Self.requiresUnlock(module)"))
        XCTAssertTrue(selectionSource.contains("beginUnlock(module)"))
        XCTAssertTrue(unlockedSelectionSource.contains("switch controller.switchBibleDocument"))
        XCTAssertTrue(unlockedSelectionSource.contains("case .switched:"))
        XCTAssertTrue(unlockedSelectionSource.contains("case .requiresUnlock:"))
        XCTAssertTrue(
            unlockedSelectionSource.contains(
                "beginUnlock(module, authoritativeAccessState: true)"
            )
        )
        XCTAssertTrue(beginUnlockSource.contains("authoritativeAccessState || Self.requiresUnlock(module)"))
        XCTAssertTrue(unlockSource.contains("controller.swordManager?.unlockModule"))
        XCTAssertTrue(unlockSource.contains("controller.refreshInstalledModules()"))
        XCTAssertFalse(unlockSource.contains("setCipherKey"))
    }

    /**
     Verifies a commentary row that becomes locked after chooser construction enters the existing
     authoritative unlock flow without dismissing or partially changing the pane.

     - Setup: Supplies stale row metadata that still reports an encrypted commentary readable while
       the manager's fresh installed inventory reports the same module locked, then routes selection
       through the production picker handler against a ready KJV pane.
     - Expected result: The typed switch fails closed, the fresh access check requests unlock for the
       selected commentary, dismissal is not invoked, and controller, `PageManager`, persistence,
       and bridge output remain unchanged.
     - Failure meaning: A stale commentary row can close the picker without opening the passphrase
       flow, or can mutate the visible pane before authorization succeeds.
     - Side effects: Writes one isolated temporary SWORD commentary fixture and removes it through
       inherited teardown; all reader callbacks are in-memory and synchronous.
     */
    @MainActor
    func testStaleRelockedCommentarySelectionBeginsUnlockWithoutDismissOrPaneMutation() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(named: "LockedComm", in: modulePath)
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/lockedcomm.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertEqual(manager.moduleAccessState(named: "LockedComm"), .locked)
        let staleReadableRow = ModuleInfo(
            name: "LockedComm",
            description: "Stale readable commentary row",
            category: .commentary,
            language: "en",
            isEncrypted: true,
            isUnlocked: true
        )
        XCTAssertFalse(BibleReaderModulePicker.requiresUnlock(staleReadableRow))

        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(
            id: window.id,
            currentCategoryName: DocumentCategory.bible.pageManagerKey
        )
        pageManager.bibleDocument = "KJV"
        pageManager.commentaryDocument = "BaselineComm"
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)

        let baselineBible = controller.activeModuleName
        let baselineCommentary = controller.activeCommentaryModuleName
        let baselineCategory = controller.currentCategory
        let baselineBibleDocument = pageManager.bibleDocument
        let baselineCommentaryDocument = pageManager.commentaryDocument
        let baselineCategoryName = pageManager.currentCategoryName
        let baselineScriptCount = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }
        var dismissCount = 0
        var unlockModule: ModuleInfo?

        BibleReaderModulePicker.handleCommentarySelection(
            staleReadableRow,
            controller: controller,
            onDismiss: { dismissCount += 1 },
            onBeginAuthoritativeUnlock: { unlockModule = $0 }
        )

        XCTAssertEqual(unlockModule?.name, "LockedComm")
        XCTAssertEqual(dismissCount, 0)
        XCTAssertEqual(controller.activeModuleName, baselineBible)
        XCTAssertEqual(controller.activeCommentaryModuleName, baselineCommentary)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(pageManager.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(pageManager.commentaryDocument, baselineCommentaryDocument)
        XCTAssertEqual(pageManager.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(recordedScripts().count, baselineScriptCount)
    }

    /**
     Verifies failed commentary selection cannot open an unlock prompt for a freshly locked module
     whose canonical installed category is not commentary.

     - Setup: Supplies stale picker metadata claiming a locked dictionary identity is an unlocked
       commentary while the manager's current canonical row reports `.dictionary` and `.locked`.
     - Expected result: The production picker handler neither dismisses nor requests commentary
       unlock, and controller, `PageManager`, persistence, and bridge state remain unchanged.
     - Failure meaning: Replaced or stale wrong-category inventory can route users into a misleading
       commentary passphrase flow even though the requested document can never activate there.
     - Side effects: Writes one isolated temporary SWORD dictionary fixture and removes it through
       inherited teardown; all reader callbacks are in-memory and synchronous.
     */
    @MainActor
    func testLockedWrongCategoryCommentarySelectionRetainsPickerWithoutUnlock() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawDictionaryModule(named: "LockedDict", in: modulePath)
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/lockeddict.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertEqual(manager.moduleAccessState(named: "LockedDict"), .locked)
        XCTAssertEqual(
            manager.installedModules().first { $0.name == "LockedDict" }?.category,
            .dictionary
        )
        let staleCommentaryRow = ModuleInfo(
            name: "LockedDict",
            description: "Stale commentary projection of a dictionary",
            category: .commentary,
            language: "en",
            isEncrypted: true,
            isUnlocked: true
        )

        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(
            id: window.id,
            currentCategoryName: DocumentCategory.bible.pageManagerKey
        )
        pageManager.bibleDocument = "KJV"
        pageManager.commentaryDocument = "BaselineComm"
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)

        let baselineBible = controller.activeModuleName
        let baselineCommentary = controller.activeCommentaryModuleName
        let baselineCategory = controller.currentCategory
        let baselineBibleDocument = pageManager.bibleDocument
        let baselineCommentaryDocument = pageManager.commentaryDocument
        let baselineCategoryName = pageManager.currentCategoryName
        let baselineScriptCount = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }
        var dismissCount = 0
        var unlockModule: ModuleInfo?

        BibleReaderModulePicker.handleCommentarySelection(
            staleCommentaryRow,
            controller: controller,
            onDismiss: { dismissCount += 1 },
            onBeginAuthoritativeUnlock: { unlockModule = $0 }
        )

        XCTAssertNil(unlockModule)
        XCTAssertEqual(dismissCount, 0)
        XCTAssertEqual(controller.activeModuleName, baselineBible)
        XCTAssertEqual(controller.activeCommentaryModuleName, baselineCommentary)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(pageManager.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(pageManager.commentaryDocument, baselineCommentaryDocument)
        XCTAssertEqual(pageManager.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(recordedScripts().count, baselineScriptCount)
    }

    /**
     Verifies chooser backup candidates use Android's localized language-name order.

     Equal-language modules include a canonically equivalent Java-distinct pair and intentionally
     reverse description/initials order. German, English, and French codes prove sorting follows
     localized names rather than raw codes. A failure means the backup sheet applies iOS
     tie-breakers or code order instead of Android's `Language.getName()` order before
     position-filtered selection.
     */
    func testBibleReaderModulePickerSortsBackupCandidatesLikeAndroid() {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        let modules = [
            ModuleInfo(name: "ZZZ", description: "Beta", category: .bible, language: "fr"),
            ModuleInfo(name: "BBB", description: "Alpha", category: .bible, language: "en"),
            ModuleInfo(name: composed, description: "Zulu", category: .bible, language: "en"),
            ModuleInfo(name: decomposed, description: "Alpha", category: .bible, language: "en"),
            ModuleInfo(name: "AAA", description: "Alpha", category: .commentary, language: "en"),
            ModuleInfo(name: "DDD", description: "German", category: .bible, language: "de"),
        ]
        let languageNames = [
            "de": "German",
            "en": "English",
            "fr": "French",
        ]

        XCTAssertEqual(
            BibleReaderModulePicker.sortedBackupModules(
                modules,
                languageName: { languageNames[$0] ?? $0 }
            ).map { Array($0.name.utf16) },
            ["BBB", composed, decomposed, "AAA", "ZZZ", "DDD"].map { Array($0.utf16) }
        )
    }

    /**
     Guards the chooser's Android backup and local-file installation routes end to end.

     Private SwiftUI presentation state is source-guarded here: both overflow rows must exist, module
     backup must use the shared `.abmd.zip` service, and local files must pass preflight before the
     policy-aware importer refreshes controller inventory. Both preflight and final import must
     create the registry-aware service with the pane's native registry and SwiftData context so a
     delayed overwrite decision cannot install an EPUB that Android's current combined registry
     rejects. A failure indicates route drift; this test performs no file or database writes.
     */
    func testBibleReaderModulePickerExposesBackupAndInstallZipWorkflows() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )

        XCTAssertTrue(source.contains("modulePickerBackupDocumentsButton"))
        XCTAssertTrue(source.contains("modulePickerInstallZipButton"))
        XCTAssertTrue(source.contains("AndroidModuleBackupExportSheet("))
        XCTAssertTrue(source.contains("AndroidModuleBackupService().exportArchiveFile("))
        XCTAssertTrue(source.contains("orderedModuleNames: moduleNames"))
        XCTAssertFalse(source.contains("Set(moduleNames)"))
        XCTAssertTrue(source.contains(".fileExporter("))
        XCTAssertTrue(source.contains(".fileImporter("))
        XCTAssertTrue(source.contains("service.preflightDocument(request)"))
        XCTAssertTrue(source.contains("moduleOverwritePolicy: overwritePolicy"))
        XCTAssertEqual(
            source.components(separatedBy: "ExternalDocumentImportService.androidRegistryAware(").count - 1,
            2
        )
        XCTAssertTrue(source.contains("modelContext: modelContext"))
        XCTAssertTrue(source.contains("swordManager: controller.swordManager"))
        XCTAssertTrue(source.contains("controller.refreshInstalledModules()"))
    }

}
