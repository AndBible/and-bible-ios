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
        let modulePath = try makeTemporarySwordFixturePath()
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
     Preserves the selected inventory row's canonical initials after Java-compatible matching.

     - Setup: Requests readable KJV through a lowercased persisted spelling.
     - Expected result: The active handle and persisted state both use canonical `KJV` initials.
     - Failure meaning: Case aliases can become a second state identity and break later exact source
       comparisons, bookmark ownership, or Android-compatible preference restoration.
     - Side effects: Copies and removes one inherited temporary SWORD fixture.
     */
    func testActiveBibleCanonicalizesCaseInsensitiveRequestedInitials() throws {
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )

        let state = BibleReaderSwordCoordinator().configure(
            manager: manager,
            selection: BibleReaderSwordSelection(
                activeModuleName: "kjv",
                activeCommentaryModuleName: nil,
                activeDictionaryModuleName: nil,
                activeGeneralBookModuleName: nil,
                activeMapModuleName: nil
            ),
            displaySettings: .appDefaults
        )

        XCTAssertEqual(state.activeModuleName, "KJV")
        XCTAssertEqual(state.activeModule?.info.name, "KJV")
    }

    /**
     Verifies a Bible module with an unrecognized versification is invisible to the coordinator.

     Android marks a module whose versification JSword does not recognize unsupported and never adds
     it to `Books.installed()`, so it is invisible everywhere. iOS mirrors that with a single filter
     in `SwordManager.installedModules()`: such a module appears in neither the raw `installedModules`
     inventory nor `installedBibleModules`, so it is not selectable, annotatable, or shown as
     installed. See ADR-0010.
     */
    func testExcludesBibleModuleWithUnrecognizedVersificationFromReadableSet() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(named: "BOGUS", description: "Bogus Versification Bible", in: modulePath)
        // Point BOGUS at a versification SWORD does not recognize.
        let bogusConf = URL(fileURLWithPath: modulePath)
            .appendingPathComponent("mods.d/bogus.conf")
        var conf = try String(contentsOf: bogusConf, encoding: .utf8)
        conf = conf.replacingOccurrences(of: "Versification=KJV", with: "Versification=BogusV11n")
        try conf.write(to: bogusConf, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        // The single SwordManager filter (mirroring Android's Books.installed()) hides the unsupported
        // module from the inventory and from by-name resolution.
        XCTAssertFalse(
            manager.installedModules().contains { $0.name == "BOGUS" },
            "installedModules() must exclude an unknown-versification Bible."
        )
        XCTAssertTrue(
            manager.installedModules().contains { $0.name == "KJV" },
            "installedModules() keeps a supported Bible."
        )
        XCTAssertNil(manager.module(named: "BOGUS"), "module(named:) returns nil for an unsupported module.")
        XCTAssertNotNil(manager.module(named: "KJV"), "module(named:) resolves a supported module.")

        let state = BibleReaderSwordCoordinator().configure(
            manager: manager,
            selection: BibleReaderSwordSelection(
                activeModuleName: "KJV",
                activeCommentaryModuleName: nil,
                activeDictionaryModuleName: nil,
                activeGeneralBookModuleName: nil,
                activeMapModuleName: nil
            ),
            displaySettings: .appDefaults
        )

        XCTAssertFalse(
            state.installedBibleModules.contains { $0.name == "BOGUS" },
            "A module with an unrecognized versification must not be readable/bookmarkable."
        )
        XCTAssertTrue(
            state.installedBibleModules.contains { $0.name == "KJV" },
            "A module with a recognized versification stays readable."
        )
        XCTAssertFalse(
            state.installedModules.contains { $0.name == "BOGUS" },
            "The unsupported module is invisible in the inventory too, matching Android's Books.installed()."
        )
    }

    /**
     Verifies a Bible module declaring a recognized non-KJV canon survives the isSupported filter.

     `isSupported` must exclude only versifications SWORD cannot map, not every non-KJV canon. This
     guards against the filter ever being narrowed to reject a legitimate divergent canon (Vulgate,
     Synodal, LXX, etc.): a module with `Versification=Vulg` stays in the inventory, is by-name
     resolvable, and is readable. See ADR-0010.
     */
    func testKeepsBibleModuleWithRecognizedNonKJVVersification() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(named: "VULGATE", description: "Vulgate-versification Bible", in: modulePath)
        let vulgConf = URL(fileURLWithPath: modulePath).appendingPathComponent("mods.d/vulgate.conf")
        var conf = try String(contentsOf: vulgConf, encoding: .utf8)
        conf = conf.replacingOccurrences(of: "Versification=KJV", with: "Versification=Vulg")
        try conf.write(to: vulgConf, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertTrue(
            manager.installedModules().contains { $0.name == "VULGATE" },
            "A recognized non-KJV canon (Vulg) must remain installed/readable."
        )
        XCTAssertNotNil(manager.module(named: "VULGATE"), "module(named:) resolves a supported non-KJV canon.")

        let state = BibleReaderSwordCoordinator().configure(
            manager: manager,
            selection: BibleReaderSwordSelection(
                activeModuleName: "VULGATE",
                activeCommentaryModuleName: nil,
                activeDictionaryModuleName: nil,
                activeGeneralBookModuleName: nil,
                activeMapModuleName: nil
            ),
            displaySettings: .appDefaults
        )
        XCTAssertTrue(state.installedBibleModules.contains { $0.name == "VULGATE" })
        XCTAssertEqual(state.activeModuleName, "VULGATE", "A supported non-KJV canon can be the active Bible.")
    }

    /**
     Verifies an unknown-versification module requested as the active Bible falls back to a supported one.

     The readable-Bible gate must also cover active-module resolution: a persisted or synced selection
     naming an unknown-versification module must not become the active/rendered Bible (it would render
     mis-numbered under KJV while being absent from every picker). The coordinator falls back to KJV.
     See ADR-0010.
     */
    func testActiveBibleModuleFallsBackWhenRequestedModuleHasUnrecognizedVersification() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(named: "BOGUS", description: "Bogus Versification Bible", in: modulePath)
        let bogusConf = URL(fileURLWithPath: modulePath).appendingPathComponent("mods.d/bogus.conf")
        var conf = try String(contentsOf: bogusConf, encoding: .utf8)
        conf = conf.replacingOccurrences(of: "Versification=KJV", with: "Versification=BogusV11n")
        try conf.write(to: bogusConf, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let state = BibleReaderSwordCoordinator().configure(
            manager: manager,
            selection: BibleReaderSwordSelection(
                activeModuleName: "BOGUS",
                activeCommentaryModuleName: nil,
                activeDictionaryModuleName: nil,
                activeGeneralBookModuleName: nil,
                activeMapModuleName: nil
            ),
            displaySettings: .appDefaults
        )

        XCTAssertNotEqual(state.activeModuleName, "BOGUS", "An unknown-versification module must not become the active Bible.")
        XCTAssertEqual(state.activeModuleName, "KJV", "The coordinator falls back to a supported Bible (KJV).")
        XCTAssertEqual(state.activeModule?.info.name, "KJV")
    }

    /**
     Verifies initial reader configuration preserves locked inventory without activating it.

     - Setup: Adds a supported Bible whose config declares an empty `CipherKey`, then requests that
       locked module while the fixture's plain KJV remains readable.
     - Expected result: The locked row stays installed for chooser/unlock workflows, but initial
       reader activation falls back to KJV and never exposes the locked native handle.
     - Failure meaning: Startup or pane construction can render an encrypted module before the user
       authorizes it, recreating issue #389 outside the document picker.
     - Side effects: Writes only the inherited temporary module root and relies on test-case cleanup.
     */
    func testActiveBibleModuleFallsBackWhenRequestedModuleIsLocked() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "LOCKED",
            description: "Locked test Bible",
            in: modulePath
        )
        let configURL = URL(fileURLWithPath: modulePath)
            .appendingPathComponent("mods.d/locked.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let state = BibleReaderSwordCoordinator().configure(
            manager: manager,
            selection: BibleReaderSwordSelection(
                activeModuleName: "LOCKED",
                activeCommentaryModuleName: nil,
                activeDictionaryModuleName: nil,
                activeGeneralBookModuleName: nil,
                activeMapModuleName: nil
            ),
            displaySettings: .appDefaults
        )

        XCTAssertTrue(state.installedBibleModules.contains { $0.name == "LOCKED" })
        XCTAssertEqual(manager.moduleAccessState(named: "LOCKED"), .locked)
        XCTAssertEqual(state.activeModuleName, "KJV")
        XCTAssertEqual(state.activeModule?.info.name, "KJV")
    }

    /**
     Keeps relocked auxiliary documents in inventory without restoring unauthorized content handles.

     - Setup: Installs encrypted locked commentary, dictionary, general-book, and map descriptors and
       restores every persisted category selection through one reader configuration snapshot.
     - Expected result: All rows remain visible for management/unlock, every manager access state is
       locked, every active auxiliary handle is nil, and the persisted initials remain intact.
     - Failure meaning: Relaunch or pane restoration can bypass the picker authorization gate and
       read a cached encrypted auxiliary document directly.
     - Side effects: Writes only inherited temporary fixture descriptors; teardown removes the root.
     */
    func testAuxiliaryModuleRestorePreservesLockedRowsWithoutActivatingHandles() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(named: "LockedComm", in: modulePath)
        try seedEmptyRawDictionaryModule(named: "LockedDict", in: modulePath)
        try seedEmptyRawGeneralBookModule(named: "LockedGB", in: modulePath)
        try seedEmptyRawMapModule(named: "LockedMap", in: modulePath)
        for moduleName in ["LockedComm", "LockedDict", "LockedGB", "LockedMap"] {
            let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
                .appendingPathComponent("mods.d/\(moduleName.lowercased()).conf")
            var configuration = try String(contentsOf: configURL, encoding: .utf8)
            configuration.append("\nCipherKey=\n")
            try configuration.write(to: configURL, atomically: true, encoding: .utf8)
        }
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let state = BibleReaderSwordCoordinator().configure(
            manager: manager,
            selection: BibleReaderSwordSelection(
                activeModuleName: "KJV",
                activeCommentaryModuleName: "LockedComm",
                activeDictionaryModuleName: "LockedDict",
                activeGeneralBookModuleName: "LockedGB",
                activeMapModuleName: "LockedMap"
            ),
            displaySettings: .appDefaults
        )

        for moduleName in ["LockedComm", "LockedDict", "LockedGB", "LockedMap"] {
            XCTAssertTrue(state.installedModules.contains { $0.name == moduleName })
            XCTAssertEqual(manager.moduleAccessState(named: moduleName), .locked)
        }
        XCTAssertNil(state.activeCommentaryModule)
        XCTAssertEqual(state.activeCommentaryModuleName, "LockedComm")
        XCTAssertNil(state.activeDictionaryModule)
        XCTAssertEqual(state.activeDictionaryModuleName, "LockedDict")
        XCTAssertNil(state.activeGeneralBookModule)
        XCTAssertEqual(state.activeGeneralBookModuleName, "LockedGB")
        XCTAssertNil(state.activeMapModule)
        XCTAssertEqual(state.activeMapModuleName, "LockedMap")
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
        let modulePath = try makeTemporarySwordFixturePath()
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
