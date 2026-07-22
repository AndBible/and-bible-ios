import Foundation
import XCTest
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 App-host-free package coverage for Android `ChooseDocument` and reader module picker parity.

 These tests protect the BibleUI-owned picker filtering, pseudo-document, document-management, and
 full-screen chooser presentation contracts without booting the app. Failures indicate visual or
 behavioral drift from Android's document chooser, not app delegate or simulator lifecycle issues.
 */
final class BibleReaderModulePickerTests: XCTestCase {
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

        XCTAssertEqual(
            BibleReaderModulePicker.filteredModules(
                modules,
                selectedCategory: nil,
                selectedLanguage: "",
                searchText: ""
            ).map(\.name),
            ["KJV", "MHC", "StrongsHebrew", "BookA", "MapA"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredModules(
                modules,
                selectedCategory: .dictionary,
                selectedLanguage: "",
                searchText: ""
            ).map(\.name),
            ["StrongsHebrew"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredModules(
                modules,
                selectedCategory: nil,
                selectedLanguage: "en",
                searchText: ""
            ).map(\.name),
            ["KJV", "MHC", "MapA"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredModules(
                modules,
                selectedCategory: .bible,
                selectedLanguage: "he",
                searchText: ""
            ).map(\.name),
            []
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredModules(
                modules,
                selectedCategory: nil,
                selectedLanguage: "",
                searchText: "strong"
            ).map(\.name),
            ["StrongsHebrew"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.availableLanguages(from: modules),
            ["en", "fr", "he"]
        )
        let bibleOnlyModules = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en")
        ]
        XCTAssertTrue(
            BibleReaderModulePicker.shouldShowCategoryEmptyState(
                bibleOnlyModules,
                selectedCategory: .dictionary
            )
        )
        XCTAssertFalse(
            BibleReaderModulePicker.shouldShowCategoryEmptyState(
                bibleOnlyModules,
                selectedCategory: .bible
            )
        )
        XCTAssertFalse(
            BibleReaderModulePicker.shouldShowCategoryEmptyState(
                modules,
                selectedCategory: nil
            )
        )
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
                modules,
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
                modules,
                selectedFilter: .category(.commentary),
                selectedLanguage: "",
                searchText: ""
            ).map(\.id),
            ["module:MHC", "pseudo:compare", "pseudo:myNotes"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredRows(
                modules,
                selectedFilter: .category(.generalBook),
                selectedLanguage: "",
                searchText: ""
            ).map(\.id),
            ["module:BookA", "pseudo:studyPads"]
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredRows(
                modules,
                selectedFilter: .addons,
                selectedLanguage: "en",
                searchText: ""
            ).map(\.id),
            ["module:AddonFonts"]
        )
        XCTAssertTrue(
            BibleReaderModulePicker.filteredRows(
                modules,
                selectedFilter: .category(.bible),
                selectedLanguage: "",
                searchText: "notes"
            ).isEmpty
        )
        XCTAssertEqual(
            BibleReaderModulePicker.filteredRows(
                modules,
                selectedFilter: .all,
                selectedLanguage: "",
                searchText: "notes"
            ).map(\.id),
            ["pseudo:myNotes"]
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
     Guards Android `ChooseDocument` routes against regressing to the iOS sheet host.

     Android opens both the all-types chooser and category-scoped chooser as an app-owned
     full-screen activity. The iOS coordinator state is private, so this source-level contract
     checks the presentation boundary directly: document chooser routes must be filtered into a
     full-screen cover, the generic reader-modal sheet must receive only non-chooser routes, and
     the chooser view itself must not carry medium/large sheet detents.
     */
    func testBibleReaderDocumentChooserRoutesUseFullScreenCoverInsteadOfSheetDetents() throws {
        let readerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        )
        let pickerSource = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )

        XCTAssertTrue(readerSource.contains("var isDocumentChooserRoute: Bool"))
        XCTAssertTrue(readerSource.contains("case .modulePicker, .chooseDocument:"))
        XCTAssertTrue(readerSource.contains(".sheet(item: readerSheetModalBinding)"))
        XCTAssertTrue(readerSource.contains(".fullScreenCover(item: readerDocumentChooserModalBinding)"))
        XCTAssertFalse(readerSource.contains(".sheet(item: $activeReaderModal)"))
        XCTAssertFalse(pickerSource.contains(".presentationDetents([.medium, .large])"))
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

        XCTAssertTrue(pickerSource.contains("private var androidDocumentChooserScreen"))
        XCTAssertTrue(pickerSource.contains("private var androidTopAppBar"))
        XCTAssertTrue(pickerSource.contains("private func androidFilterBar(visibleDocumentCount: Int)"))
        XCTAssertTrue(pickerSource.contains("private func androidDocumentRow(_ row: DocumentChooserRow)"))
        XCTAssertTrue(pickerSource.contains("private func androidLanguageFilterMenu()"))
        XCTAssertTrue(pickerSource.contains("private func androidSearchFilterField()"))
        XCTAssertTrue(pickerSource.contains("private func androidDocumentTypeFilterMenu(visibleDocumentCount: Int)"))
        XCTAssertTrue(pickerSource.contains("private var androidChooserOverflowMenu"))
        XCTAssertTrue(pickerSource.contains("String(localized: \"document\", defaultValue: \"Document\")"))
        XCTAssertTrue(pickerSource.contains(".toolbar(.hidden, for: .navigationBar)"))
        XCTAssertFalse(pickerSource.contains("NavigationStack {\n            List {"))
        XCTAssertFalse(pickerSource.contains(".searchable(text: $searchText"))
        XCTAssertFalse(pickerSource.contains("Section(String(localized: \"document_filter_results"))
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
     Verifies locked-row selection is gated by real manager-level cipher verification.

     A failure means a locked document can be selected without a key, or the picker has regressed to
     the obsolete module-level setter that is not authoritative in libsword.
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

        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )
        let selectionSource = try BibleUITestSourceLocator.extractFunction(named: "select", from: source)
        let unlockSource = try BibleUITestSourceLocator.extractFunction(named: "attemptUnlock", from: source)

        XCTAssertTrue(selectionSource.contains("Self.requiresUnlock(module)"))
        XCTAssertTrue(selectionSource.contains("beginUnlock(module)"))
        XCTAssertTrue(unlockSource.contains("controller.swordManager?.unlockModule"))
        XCTAssertTrue(unlockSource.contains("controller.refreshInstalledModules()"))
        XCTAssertFalse(unlockSource.contains("setCipherKey"))
    }

    /**
     Verifies chooser backup candidates use Android's language-first deterministic order.

     A failure means the backup sheet can reorder between presentations or diverge from Android's
     installed-document selection list.
     */
    func testBibleReaderModulePickerSortsBackupCandidatesLikeAndroid() {
        let modules = [
            ModuleInfo(name: "ZZZ", description: "Beta", category: .bible, language: "fr"),
            ModuleInfo(name: "BBB", description: "Alpha", category: .bible, language: "en"),
            ModuleInfo(name: "AAA", description: "Alpha", category: .commentary, language: "en"),
        ]

        XCTAssertEqual(
            BibleReaderModulePicker.sortedBackupModules(modules).map(\.name),
            ["AAA", "BBB", "ZZZ"]
        )
    }

    /**
     Guards the chooser's Android backup and local-file installation routes end to end.

     Private SwiftUI presentation state is source-guarded here: both overflow rows must exist, module
     backup must use the shared `.abmd.zip` service, and local files must pass preflight before the
     policy-aware importer refreshes controller inventory.
     */
    func testBibleReaderModulePickerExposesBackupAndInstallZipWorkflows() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderModulePicker.swift"
        )

        XCTAssertTrue(source.contains("modulePickerBackupDocumentsButton"))
        XCTAssertTrue(source.contains("modulePickerInstallZipButton"))
        XCTAssertTrue(source.contains("AndroidModuleBackupExportSheet("))
        XCTAssertTrue(source.contains("AndroidModuleBackupService().exportArchive"))
        XCTAssertTrue(source.contains(".fileExporter("))
        XCTAssertTrue(source.contains(".fileImporter("))
        XCTAssertTrue(source.contains("service.preflightDocument(request)"))
        XCTAssertTrue(source.contains("moduleOverwritePolicy: overwritePolicy"))
        XCTAssertTrue(source.contains("controller.refreshInstalledModules()"))
    }

}
