// ReaderSwordCoordinatorTests.swift -- Reader SWORD setup coverage

import XCTest
import BibleCore
@testable import BibleUI
@testable import SwordKit

/**
 Package-level tests for `BibleReaderSwordCoordinator` setup behavior.

 The suite uses isolated temporary SWORD fixtures so the coordinator can exercise real
 `SwordManager` discovery without the app host, simulator application install, or shared
 `AndBibleTests` superclass. Failures mean the reader's Android-parity module selection or global
 SWORD option contract has drifted.
 */
final class ReaderSwordCoordinatorTests: BibleUISwordFixtureTestCase {
    /**
     Protects the extracted SWORD setup boundary for installed-module catalog and active-module
     resolution.

     The coordinator configures SWORD, splits installed modules by Android document category,
     chooses active module handles, and builds the active Bible book list. This test defines that
     collaborator contract: requested modules must be resolved through the shared `SwordManager`,
     commentaries keep the existing first-installed fallback, optional auxiliary modules remain
     explicit, and Bible books must come from the active module instead of a static fallback while a
     SWORD Bible is installed. A failure means the reader's module inventory or versification source
     no longer matches the app-hosted behavior this test replaced.
     */
    func testBuildsCatalogSelectionsAndBookList() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        try seedBibleAliasModule(named: "WEB", description: "World English Bible", in: modulePath)
        try seedEmptyRawCommentaryModule(named: "UITestComm", in: modulePath)
        try seedEmptyRawDictionaryModule(named: "UITestDict", in: modulePath)
        try seedEmptyRawGeneralBookModule(named: "UITestGB", in: modulePath)
        try seedEmptyRawMapModule(named: "UITestMap", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let state = BibleReaderSwordCoordinator().configure(
            manager: manager,
            selection: BibleReaderSwordSelection(
                activeModuleName: "WEB",
                activeCommentaryModuleName: nil,
                activeDictionaryModuleName: "UITestDict",
                activeGeneralBookModuleName: "UITestGB",
                activeMapModuleName: "UITestMap"
            ),
            displaySettings: .appDefaults
        )

        XCTAssertEqual(Set(state.installedBibleModules.map(\.name)), Set(["KJV", "WEB"]))
        XCTAssertEqual(state.installedCommentaryModules.map(\.name), ["UITestComm"])
        XCTAssertEqual(state.installedDictionaryModules.map(\.name), ["UITestDict"])
        XCTAssertEqual(state.installedGeneralBookModules.map(\.name), ["UITestGB"])
        XCTAssertEqual(state.installedMapModules.map(\.name), ["UITestMap"])
        XCTAssertEqual(state.activeModuleName, "WEB")
        XCTAssertEqual(state.activeModule?.info.name, "WEB")
        XCTAssertEqual(state.activeCommentaryModuleName, "UITestComm")
        XCTAssertEqual(state.activeDictionaryModuleName, "UITestDict")
        XCTAssertEqual(state.activeGeneralBookModuleName, "UITestGB")
        XCTAssertEqual(state.activeMapModuleName, "UITestMap")
        XCTAssertEqual(state.moduleBookList.count, 66)
        XCTAssertEqual(state.moduleBookList.first?.osisId, "Gen")
    }

    /**
     Protects the SWORD global option mapping used by reader rendering.

     Android applies reader display settings through JSword filters; iOS mirrors those options with
     SWORD global options. The coordinator must keep the always-on heading/red-letter base
     configuration and the setting-driven morphology, footnote, and cross-reference toggles
     together so future controller refactors cannot silently stop applying display changes to the
     SWORD manager. Android's Strong's mode `0` is hidden links, not disabled Strong's data, so the
     SWORD layer must keep lemma output enabled while Vue decides whether to draw the underline.
     */
    func testAppliesBaseAndDisplayGlobalOptions() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        var settings = TextDisplaySettings()
        settings.strongsMode = 1
        settings.showMorphology = true
        settings.showFootNotes = true
        settings.showXrefs = true

        _ = BibleReaderSwordCoordinator().configure(
            manager: manager,
            selection: BibleReaderSwordSelection(
                activeModuleName: "KJV",
                activeCommentaryModuleName: nil,
                activeDictionaryModuleName: nil,
                activeGeneralBookModuleName: nil,
                activeMapModuleName: nil
            ),
            displaySettings: settings
        )

        XCTAssertTrue(manager.isGlobalOptionEnabled(.headings))
        XCTAssertTrue(manager.isGlobalOptionEnabled(.redLetterWords))
        XCTAssertTrue(manager.isGlobalOptionEnabled(.strongsNumbers))
        XCTAssertTrue(manager.isGlobalOptionEnabled(.morphology))
        XCTAssertTrue(manager.isGlobalOptionEnabled(.footnotes))
        XCTAssertTrue(manager.isGlobalOptionEnabled(.crossReferences))

        settings.strongsMode = 0
        settings.showMorphology = false
        settings.showFootNotes = false
        settings.showXrefs = false
        BibleReaderSwordCoordinator().applyDisplayOptions(to: manager, settings: settings)

        XCTAssertTrue(manager.isGlobalOptionEnabled(.strongsNumbers))
        XCTAssertFalse(manager.isGlobalOptionEnabled(.morphology))
        XCTAssertFalse(manager.isGlobalOptionEnabled(.footnotes))
        XCTAssertFalse(manager.isGlobalOptionEnabled(.crossReferences))
    }
}
