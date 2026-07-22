import Foundation
import SQLite3
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 End-to-end coverage for Android-compatible SQLite modules in the native reader runtime.

 The fixtures exercise MyBible, MySword, and e-Sword through the same inventories, PageManager
 fields, Vue payloads, copy/share source text, and speech-provider contracts used by SWORD books.
 Tests intentionally keep dictionary keys exact and verify that real SWORD modules own canonical
 case-insensitive identity collisions.
 */
final class SQLiteReaderRuntimeIntegrationTests: BibleUISwordFixtureTestCase {
    /**
     Verifies all supported SQLite families enter their category inventories with source languages.

     - Setup: Installs three MyBible modules, three MySword modules, and one e-Sword Bible beside the
       normal SWORD fixture.
     - Expected result: Every readable identity appears once in its category and client-ready
       language projection includes SQLite metadata.
     - Failure meaning: A validated Android module remains download-only or loses source language.
     */
    @MainActor
    func testSQLiteFamiliesMergeIntoRuntimeInventoriesAndLanguages() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installAllSQLiteFixtures(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        XCTAssertTrue(controller.installedBibleModules.contains { $0.name == "MyBible-bible" })
        XCTAssertTrue(controller.installedBibleModules.contains { $0.name == "MySword-sample_bbl" })
        XCTAssertTrue(controller.installedBibleModules.contains { $0.name == "ESword-sample" })
        XCTAssertTrue(controller.installedCommentaryModules.contains { $0.name == "MyBible-commentary" })
        XCTAssertTrue(controller.installedCommentaryModules.contains { $0.name == "MySword-sample_cmt" })
        XCTAssertTrue(controller.installedDictionaryModules.contains { $0.name == "MyBible-dictionary" })
        XCTAssertTrue(controller.installedDictionaryModules.contains { $0.name == "MySword-sample_dct" })

        controller.bridgeDidSetClientReady(bridge)

        let languageScript = try XCTUnwrap(
            scripts().last { $0.contains("window.__activeLanguages__") }
        )
        XCTAssertTrue(languageScript.contains("eng"))
        XCTAssertTrue(languageScript.contains("heb"))
    }

    /**
     Verifies genuine SWORD precedence and canonical persistence for case-insensitive duplicates.

     - Setup: Installs a valid MyBible package whose sidecar initials are lowercase `kjv` beside the
       readable fixture SWORD KJV.
     - Expected result: The inventory contains one KJV identity, selection and restore resolve to
       canonical `KJV`, and both payload and PageManager retain that canonical SWORD name.
     - Failure meaning: SQLite shadows a real SWORD book or duplicate case variants leak into state.
     */
    @MainActor
    func testReadableSwordWinsCanonicalCaseInsensitiveSQLiteIdentityCollision() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installMyBiblePackageDuplicate(initials: "kjv", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let pageManager = attachWindow(to: controller)

        let duplicateRows = controller.installedBibleModules.filter {
            $0.name.caseInsensitiveCompare("KJV") == .orderedSame
        }
        XCTAssertEqual(duplicateRows.count, 1)

        controller.switchBibleDocument(to: "kjv")
        controller.bridgeDidSetClientReady(bridge)

        let payload = try latestDocumentPayload(from: scripts())
        XCTAssertEqual(controller.activeModuleName, "KJV")
        XCTAssertEqual(pageManager.bibleDocument, "KJV")
        XCTAssertEqual(payload["bookInitials"] as? String, "KJV")

        pageManager.bibleDocument = "kjv"
        let (restoredBridge, restoredScripts) = makeRecordingBridge()
        let restored = BibleReaderController(
            bridge: restoredBridge,
            swordManagerOverride: manager
        )
        restored.activeWindow = controller.activeWindow
        restored.restoreSavedPosition()
        restored.bridgeDidSetClientReady(restoredBridge)
        XCTAssertEqual(restored.activeModuleName, "KJV")
        XCTAssertEqual(pageManager.bibleDocument, "KJV")
        XCTAssertEqual(
            try latestDocumentPayload(from: restoredScripts())["bookInitials"] as? String,
            "KJV"
        )
    }

    /**
     Verifies BibleUI consumes BibleCore's Java UTF-16 identity without NFC normalization.

     - Setup: Installs two readable MyBible packages whose sidecar initials use composed and
       decomposed spellings of the same visible name.
     - Expected result: Both identities remain installed and each exact spelling resolves its own
       module. Their conflicting sidecar languages do not override the English database metadata,
       matching MyBible's Android-generated configuration.
     - Failure meaning: A UI-local Foundation normalization or case fold can hide an Android-visible
       module or route selection to the wrong package.
     */
    func testSQLiteCatalogKeepsCanonicallyDistinctJavaUTF16Identities() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let composed = "\u{00C9}Bible"
        let decomposed = "E\u{0301}Bible"
        try installMyBiblePackage(
            initials: composed,
            directoryName: "canonical-a",
            language: "fr",
            in: modulePath
        )
        try installMyBiblePackage(
            initials: decomposed,
            directoryName: "canonical-b",
            language: "de",
            in: modulePath
        )

        var catalog = BibleReaderSQLiteModuleCatalog()
        catalog.reload(moduleRootURL: URL(fileURLWithPath: modulePath, isDirectory: true))

        let modules = catalog.modules(category: .bible)
        XCTAssertEqual(modules.count, 2)
        let composedModule = try XCTUnwrap(catalog.module(named: composed))
        let decomposedModule = try XCTUnwrap(catalog.module(named: decomposed))
        XCTAssertFalse(composedModule === decomposedModule)
        XCTAssertEqual(BibleReaderSQLiteSourceMetadata(module: composedModule).language, "en")
        XCTAssertEqual(BibleReaderSQLiteSourceMetadata(module: decomposedModule).language, "en")
    }

    /**
     Verifies downstream catalog consumers use SQLite's exact JSword KJVA ordinal domain.

     - Setup: Creates a non-SWORD catalog over the real Genesis row shape exposed by SQLite.
     - Expected result: Forward, reverse, and chapter-range lookups use intro-inclusive KJVA
       ordinals while the legacy no-module initializer remains unchanged elsewhere.
     - Failure meaning: Bookmark/annotation consumers can reinterpret rendered SQLite ordinals with
       the historical forty-verses-per-chapter placeholder formula.
     */
    func testSQLiteBookCatalogUsesExactKJVAOrdinalDomain() throws {
        let book = BookInfo(
            name: "Genesis",
            osisId: "Gen",
            abbreviation: "Gen",
            chapterCount: 1,
            testament: 1
        )
        let catalog = BibleReaderBookCatalog(
            activeModule: nil,
            moduleBookList: [book],
            usesExactKJVAOrdinals: true
        )
        let first = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let second = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 2)
        )

        XCTAssertEqual(catalog.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1), first)
        XCTAssertEqual(catalog.verseReference(book: "Genesis", ordinal: second)?.verse, 2)
        let range = try XCTUnwrap(
            catalog.chapterOrdinalRange(book: "Genesis", chapter: 1, verseCount: 2)
        )
        XCTAssertEqual(range.start, first)
        XCTAssertEqual(range.end, second)
        XCTAssertEqual(range.verseCount, 2)
    }

    /**
     Verifies an active SQLite Bible never re-enters the no-backend static catalog fallback.

     - Setup: Creates exact-KJVA catalogs with and without the real SQLite book inventory.
     - Expected result: A present book uses KJVA verse metadata; an unavailable real inventory
       exposes no books, chapter count, OSIS identity, or placeholder verse count.
     - Failure meaning: An unreadable SQLite module can present fabricated navigation metadata and
       later render placeholder content under an apparently active Android document identity.
     */
    func testSQLiteBookCatalogDoesNotExposeStaticFallbackWithoutRealBooks() {
        let genesis = BookInfo(
            name: "Genesis",
            osisId: "Gen",
            abbreviation: "Gen",
            chapterCount: 50,
            testament: 1
        )
        let readableCatalog = BibleReaderBookCatalog(
            activeModule: nil,
            moduleBookList: [genesis],
            usesExactKJVAOrdinals: true
        )
        XCTAssertEqual(readableCatalog.verseCount(book: "Genesis", chapter: 1), 31)

        let unreadableCatalog = BibleReaderBookCatalog(
            activeModule: nil,
            moduleBookList: [],
            usesExactKJVAOrdinals: true
        )
        XCTAssertTrue(unreadableCatalog.books.isEmpty)
        XCTAssertEqual(unreadableCatalog.chapterCount(for: "Genesis"), 0)
        XCTAssertEqual(unreadableCatalog.osisBookId(for: "Genesis"), "")
        XCTAssertNil(unreadableCatalog.verseCount(book: "Genesis", chapter: 1))
    }

    /**
     Verifies dictionary retention distinguishes canonical-equivalent source-key byte sequences.

     - Setup: Supplies one decomposed source key and asks for both decomposed and composed forms.
     - Expected result: Only the UTF-8-identical form resolves, while source order and spelling are
       returned unchanged.
     - Failure meaning: Restore or switching can retain a visually equivalent key that an exact
       SQLite dictionary lookup cannot resolve.
     */
    func testSQLiteDictionaryChooserRetainsOnlyUTF8ExactSourceKeys() {
        let decomposed = "Cafe\u{301}"
        let composed = "Caf\u{E9}"
        let keys = ["Alpha", decomposed, "Omega"]

        XCTAssertEqual(
            BibleReaderSQLiteDictionaryChooser.exactSourceKey(
                matching: decomposed,
                in: keys
            ),
            decomposed
        )
        XCTAssertNil(
            BibleReaderSQLiteDictionaryChooser.exactSourceKey(
                matching: composed,
                in: keys
            )
        )
        XCTAssertEqual(keys, ["Alpha", decomposed, "Omega"])
    }

    /**
     Verifies select, render, persist, restore, and pane-copy behavior for every SQLite Bible family.

     - Setup: Selects one MyBible, MySword, and e-Sword Bible at Genesis 1 in turn.
     - Expected result: Each emits its real fixture text, exact intro-inclusive KJVA ordinal, source
       language and initials, persists the selected document, restores in a fresh controller, and
       copies into a pane with an independent SQLite catalog.
     - Failure meaning: SQLite Bibles use placeholder text, local ordinals, stale handles, or lose
       their selection outside the immediate switch.
     */
    @MainActor
    func testEverySQLiteBibleSelectsRendersPersistsRestoresAndCopies() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installAllSQLiteFixtures(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let pageManager = attachWindow(to: controller)
        controller.bridgeDidSetClientReady(bridge)
        let ordinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(
                osisId: "Gen",
                chapter: 1,
                verse: 1
            )
        )
        let expectations = [
            ("MyBible-bible", "In the <J>beginning</J>", "en"),
            ("MySword-sample_bbl", "strong:G123", "eng"),
            ("ESword-sample", "God created", "en"),
        ]

        for (initials, expectedText, language) in expectations {
            let baseline = scripts().count
            controller.switchBibleDocument(to: initials)
            let emissions = Array(scripts().dropFirst(baseline))
            let payload = try latestDocumentPayload(from: emissions)
            let fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])
            let xml = try XCTUnwrap(fragment["xml"] as? String)

            XCTAssertEqual(payload["bookInitials"] as? String, initials)
            XCTAssertEqual(fragment["language"] as? String, language)
            XCTAssertEqual(pageManager.bibleDocument, initials)
            XCTAssertTrue(xml.contains(expectedText), "Expected real \(initials) fixture content")
            XCTAssertTrue(xml.contains("verseOrdinal=\"\(ordinal)\""))
            XCTAssertFalse(xml.contains("The Creation of the World"))

            let (restoredBridge, restoredScripts) = makeRecordingBridge()
            let restored = BibleReaderController(
                bridge: restoredBridge,
                swordManagerOverride: manager
            )
            restored.activeWindow = controller.activeWindow
            restored.restoreSavedPosition()
            restored.bridgeDidSetClientReady(restoredBridge)
            let restoredPayload = try latestDocumentPayload(from: restoredScripts())
            XCTAssertEqual(restored.activeModuleName, initials)
            XCTAssertEqual(restoredPayload["bookInitials"] as? String, initials)
        }

        controller.switchBibleDocument(to: "MyBible-bible")
        let (copyBridge, copyScripts) = makeRecordingBridge()
        let copied = BibleReaderController(bridge: copyBridge, initializesSword: false)
        XCTAssertTrue(copied.copyModuleState(from: controller))
        XCTAssertEqual(copied.activeModuleName, "MyBible-bible")
        copied.bridgeDidSetClientReady(copyBridge)
        let copiedPayload = try latestDocumentPayload(from: copyScripts())
        XCTAssertEqual(copiedPayload["bookInitials"] as? String, "MyBible-bible")
    }

    /**
     Verifies covering commentary and exact dictionary content across both SQLite families.

     - Setup: Selects Genesis 1:2 commentary and exact dictionary keys in MyBible and MySword.
     - Expected result: Covering rows render with source metadata; chooser arrays preserve source
       order and spelling; successful keys persist and restore; a case mismatch emits deterministic
       no-content without replacing the retained exact key.
     - Failure meaning: Runtime lookup uses exact-start commentary only, snaps dictionary keys, or
       loses auxiliary selections across restore.
     */
    @MainActor
    func testSQLiteCommentaryAndDictionarySelectRenderPersistAndRestoreExactly() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installAllSQLiteFixtures(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let pageManager = attachWindow(to: controller)
        controller.bridgeDidSetClientReady(bridge)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 2)

        for (initials, expectedText) in [
            ("MyBible-commentary", "Range commentary"),
            ("MySword-sample_cmt", "Range"),
        ] {
            let baseline = scripts().count
            controller.switchCommentaryDocument(to: initials)
            let payload = try latestDocumentPayload(
                from: Array(scripts().dropFirst(baseline))
            )
            let fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])
            XCTAssertEqual(payload["bookInitials"] as? String, initials)
            XCTAssertEqual(payload["bookCategory"] as? String, "COMMENTARY")
            XCTAssertTrue((fragment["xml"] as? String)?.contains(expectedText) == true)
            XCTAssertFalse((payload["bookName"] as? String ?? "").isEmpty)
            XCTAssertFalse((payload["bookAbbreviation"] as? String ?? "").isEmpty)
            XCTAssertFalse((fragment["language"] as? String ?? "").isEmpty)
            XCTAssertTrue(["ltr", "rtl"].contains(fragment["direction"] as? String ?? ""))
            XCTAssertEqual(pageManager.commentaryDocument, initials)
        }

        controller.switchCommentaryDocument(to: "MyBible-commentary")
        let (commentaryBridge, commentaryScripts) = makeRecordingBridge()
        let restoredCommentary = BibleReaderController(
            bridge: commentaryBridge,
            swordManagerOverride: manager
        )
        restoredCommentary.activeWindow = controller.activeWindow
        restoredCommentary.restoreSavedPosition()
        restoredCommentary.bridgeDidSetClientReady(commentaryBridge)
        XCTAssertEqual(
            try latestDocumentPayload(from: commentaryScripts())["bookInitials"] as? String,
            "MyBible-commentary"
        )

        let dictionaries: [(String, [String], String, String)] = [
            ("MyBible-dictionary", ["G0001", "H0430"], "H0430", "Hebrew definition"),
            ("MySword-sample_dct", ["Elohim", "Logos"], "Elohim", "strong:H430"),
        ]
        for (initials, keys, selectedKey, expectedText) in dictionaries {
            let outcome = controller.switchDictionaryDocument(to: initials)
            XCTAssertEqual(outcome, .switchedRequiringKeySelection)
            XCTAssertEqual(try controller.activeDictionaryKeys(), keys)
            XCTAssertEqual(try controller.activeDictionaryBrowserSource()?.keys(), keys)

            let baseline = scripts().count
            controller.loadDictionaryEntry(key: selectedKey)
            let payload = try latestDocumentPayload(
                from: Array(scripts().dropFirst(baseline))
            )
            let fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])
            XCTAssertEqual(payload["key"] as? String, selectedKey)
            XCTAssertEqual(payload["bookInitials"] as? String, initials)
            XCTAssertTrue((fragment["xml"] as? String)?.contains(expectedText) == true)
            XCTAssertFalse((payload["bookName"] as? String ?? "").isEmpty)
            XCTAssertFalse((payload["bookAbbreviation"] as? String ?? "").isEmpty)
            XCTAssertFalse((fragment["language"] as? String ?? "").isEmpty)
            XCTAssertTrue(["ltr", "rtl"].contains(fragment["direction"] as? String ?? ""))
            XCTAssertEqual(pageManager.dictionaryDocument, initials)
            XCTAssertEqual(pageManager.dictionaryKey, selectedKey)
        }

        controller.switchDictionaryDocument(to: "MyBible-dictionary")
        controller.loadDictionaryEntry(key: "H0430")
        let mismatchBaseline = scripts().count
        controller.loadDictionaryEntry(key: "h0430")
        let mismatchPayload = try latestDocumentPayload(
            from: Array(scripts().dropFirst(mismatchBaseline))
        )
        XCTAssertEqual(mismatchPayload["type"] as? String, "error")
        XCTAssertEqual(controller.currentDictionaryKey, "H0430")
        XCTAssertEqual(pageManager.dictionaryKey, "H0430")

        let (dictionaryBridge, dictionaryScripts) = makeRecordingBridge()
        let restoredDictionary = BibleReaderController(
            bridge: dictionaryBridge,
            swordManagerOverride: manager
        )
        restoredDictionary.activeWindow = controller.activeWindow
        restoredDictionary.restoreSavedPosition()
        restoredDictionary.bridgeDidSetClientReady(dictionaryBridge)
        let restoredPayload = try latestDocumentPayload(from: dictionaryScripts())
        XCTAssertEqual(restoredDictionary.currentDictionaryKey, "H0430")
        XCTAssertEqual(restoredPayload["key"] as? String, "H0430")
        XCTAssertEqual(restoredPayload["bookInitials"] as? String, "MyBible-dictionary")
    }

    /**
     Verifies reader previous/next actions use linked blocks for SQLite commentary modules.

     - Setup: Adds a second two-verse commentary block after an empty separator, selects the first
       block's last verse through the real controller, and invokes public reader navigation.
     - Expected result: Next skips the empty verse and opens the second block; previous returns to
       the first block start. Both payloads retain Android commentary-range metadata.
     - Failure meaning: SQLite commentary remains render-only and public navigation falls through to
       ordinary Bible chapter movement or recognizes only native SWORD commentary.
     - Side effects: Copies and extends one temporary SQLite fixture; no installed module is changed.
     */
    @MainActor
    func testSQLiteCommentaryReaderNavigationUsesAdjacentLinkedBlocks() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installAllSQLiteFixtures(in: modulePath)
        let commentaryURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mybible/commentary.SQLite3")
        try executeSQLite(
            """
            INSERT INTO commentaries (
                book_number,
                chapter_number_from,
                verse_number_from,
                chapter_number_to,
                verse_number_to,
                text
            ) VALUES (10, 1, 4, 1, 5, 'Second linked block')
            """,
            at: commentaryURL
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        _ = attachWindow(to: controller)
        controller.bridgeDidSetClientReady(bridge)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 2)
        controller.switchCommentaryDocument(to: "MyBible-commentary")

        var baseline = scripts().count
        controller.navigateNext()
        var payload = try latestDocumentPayload(from: Array(scripts().dropFirst(baseline)))
        var range = try XCTUnwrap(payload["commentaryRange"] as? [String: Any])
        XCTAssertEqual(payload["key"] as? String, "Gen.1.4")
        XCTAssertEqual(range["startOsisRef"] as? String, "Gen.1.4")
        XCTAssertEqual(range["endOsisRef"] as? String, "Gen.1.5")

        baseline = scripts().count
        controller.navigatePrevious()
        payload = try latestDocumentPayload(from: Array(scripts().dropFirst(baseline)))
        range = try XCTUnwrap(payload["commentaryRange"] as? [String: Any])
        XCTAssertEqual(payload["key"] as? String, "Gen.1.2")
        XCTAssertEqual(range["startOsisRef"] as? String, "Gen.1.2")
        XCTAssertEqual(range["endOsisRef"] as? String, "Gen.1.2")
    }

    /**
     Verifies SQLite commentary uses Android's public versification conversion in both directions.

     - Setup: Maps a known Synodal Psalm offset into KJVA, then maps the resulting linked-block target
       back through an exact destination-owned resolver.
     - Expected result: Synodal Psalm 9:22 becomes KJVA Psalm 10:1 and reverse routing invokes the
       destination addressability check exactly once without neighboring-key search.
     - Failure meaning: SQLite commentary display and next/previous can disagree or treat source
       coordinates as KJVA identity when the synchronized Bible uses a divergent canon.
     - Side effects: Reads pinned versification resources and records one in-memory callback.
     */
    func testSQLiteCommentaryRoutingConvertsDivergentVersificationBothWays() throws {
        let kjva = try XCTUnwrap(
            SQLiteCommentaryReferenceRouter.kjvaReference(
                for: .init(osisBookId: "Ps", chapter: 9, verse: 22),
                sourceVersification: "Synodal"
            )
        )
        XCTAssertEqual(kjva.osisRef, "Ps.10.1")

        var resolvedCandidates: [SwordVersification.Reference] = []
        let source: SwordVersification.Reference? =
            SQLiteCommentaryReferenceRouter.sourceReference(
                for: kjva,
                destinationVersification: "Synodal"
            ) { candidate in
                resolvedCandidates.append(candidate)
                return candidate
            }

        XCTAssertEqual(source, .init(osisBookId: "Ps", chapter: 9, verse: 22))
        XCTAssertEqual(resolvedCandidates, [source].compactMap { $0 })
    }

    /**
     Verifies switching between SQLite and real SWORD clears the inactive backend in each category.

     - Setup: Adds empty readable SWORD commentary/dictionary modules, renders SQLite content, then
       switches to each SWORD source and back.
     - Expected result: SWORD selections emit deterministic empty-source errors rather than stale
       SQLite content; returning to SQLite renders its real content again.
     - Failure meaning: Both backend handles remain active and renderer precedence hides switches.
     */
    @MainActor
    func testSwordAndSQLiteSwitchesClearOppositeRuntimeHandles() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installAllSQLiteFixtures(in: modulePath)
        try seedEmptyRawCommentaryModule(named: "SwordEmptyComm", in: modulePath)
        try seedReadableRawDictionaryModule(
            named: "SwordEmptyDict",
            entryKey: "different-key",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        _ = attachWindow(to: controller)
        controller.bridgeDidSetClientReady(bridge)

        controller.switchBibleDocument(to: "MyBible-bible")
        var baseline = scripts().count
        controller.switchBibleDocument(to: "KJV")
        var payload = try latestDocumentPayload(from: Array(scripts().dropFirst(baseline)))
        XCTAssertEqual(payload["bookInitials"] as? String, "KJV")
        XCTAssertEqual(controller.activeModuleName, "KJV")

        controller.switchCommentaryDocument(to: "MyBible-commentary")
        baseline = scripts().count
        controller.switchCommentaryDocument(to: "SwordEmptyComm")
        payload = try latestDocumentPayload(from: Array(scripts().dropFirst(baseline)))
        XCTAssertEqual(payload["type"] as? String, "error")
        XCTAssertEqual(controller.activeCommentaryModuleName, "SwordEmptyComm")

        controller.switchDictionaryDocument(to: "MyBible-dictionary")
        controller.loadDictionaryEntry(key: "H0430")
        _ = controller.switchDictionaryDocument(to: "SwordEmptyDict")
        baseline = scripts().count
        controller.loadDictionaryEntry(key: "H0430")
        payload = try latestDocumentPayload(from: Array(scripts().dropFirst(baseline)))
        XCTAssertEqual(payload["type"] as? String, "error")
        XCTAssertEqual(controller.activeDictionaryModuleName, "SwordEmptyDict")

        _ = controller.switchDictionaryDocument(to: "MyBible-dictionary")
        baseline = scripts().count
        controller.loadDictionaryEntry(key: "H0430")
        payload = try latestDocumentPayload(from: Array(scripts().dropFirst(baseline)))
        XCTAssertEqual(payload["bookInitials"] as? String, "MyBible-dictionary")
        XCTAssertEqual(payload["key"] as? String, "H0430")
    }

    /**
     Verifies pane copy resolves independent SQLite handles for every persisted document category.

     - Setup: Selects a MySword Bible, commentary, dictionary, and exact dictionary key in one pane,
       then copies module state into a controller with its own cloned PageManager fields.
     - Expected result: Restore retains every category identity and exact key, and the copied pane
       renders dictionary, commentary, and Bible source content through its refreshed catalog.
     - Failure meaning: Pane creation copies only SWORD state, shares stale SQLite connections, or
       drops an auxiliary selection/key before restore.
     */
    @MainActor
    func testPaneCopyRestoresSQLiteSelectionsForEveryCategory() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installAllSQLiteFixtures(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (sourceBridge, _) = makeRecordingBridge()
        let source = BibleReaderController(
            bridge: sourceBridge,
            swordManagerOverride: manager
        )
        let sourcePageManager = attachWindow(to: source)
        source.switchModule(to: "MySword-sample_bbl")
        source.switchCommentaryModule(to: "MySword-sample_cmt")
        XCTAssertEqual(
            source.switchDictionaryDocument(to: "MySword-sample_dct"),
            .switchedRequiringKeySelection
        )
        source.loadDictionaryEntry(key: "Elohim")

        let (copiedBridge, copiedScripts) = makeRecordingBridge()
        let copied = BibleReaderController(bridge: copiedBridge, initializesSword: false)
        let copiedPageManager = attachWindow(to: copied)
        copiedPageManager.bibleDocument = sourcePageManager.bibleDocument
        copiedPageManager.commentaryDocument = sourcePageManager.commentaryDocument
        copiedPageManager.dictionaryDocument = sourcePageManager.dictionaryDocument
        copiedPageManager.dictionaryKey = sourcePageManager.dictionaryKey
        copiedPageManager.currentCategoryName = sourcePageManager.currentCategoryName

        XCTAssertTrue(copied.copyModuleState(from: source))
        copied.restoreSavedPosition()
        copied.bridgeDidSetClientReady(copiedBridge)

        XCTAssertEqual(copied.activeModuleName, "MySword-sample_bbl")
        XCTAssertEqual(copied.activeCommentaryModuleName, "MySword-sample_cmt")
        XCTAssertEqual(copied.activeDictionaryModuleName, "MySword-sample_dct")
        XCTAssertEqual(copied.currentDictionaryKey, "Elohim")
        XCTAssertEqual(try copied.activeDictionaryKeys(), ["Elohim", "Logos"])
        var payload = try latestDocumentPayload(from: copiedScripts())
        XCTAssertEqual(payload["bookInitials"] as? String, "MySword-sample_dct")
        XCTAssertEqual(payload["key"] as? String, "Elohim")

        var baseline = copiedScripts().count
        copied.switchCommentaryDocument(to: "MySword-sample_cmt")
        payload = try latestDocumentPayload(
            from: Array(copiedScripts().dropFirst(baseline))
        )
        XCTAssertEqual(payload["bookInitials"] as? String, "MySword-sample_cmt")

        baseline = copiedScripts().count
        copied.switchBibleDocument(to: "MySword-sample_bbl")
        payload = try latestDocumentPayload(
            from: Array(copiedScripts().dropFirst(baseline))
        )
        XCTAssertEqual(payload["bookInitials"] as? String, "MySword-sample_bbl")
    }

    /**
     Verifies a real manager refresh retains all category-owned SQLite selections and exact keys.

     - Setup: Selects MySword Bible, commentary, and dictionary content in a temporary injected
       module root, then recreates both runtime catalogs through `refreshInstalledModules`.
     - Expected result: The same root is rediscovered, PageManager identities remain unchanged,
       dictionary spelling remains exact, and all three categories render through fresh handles.
     - Failure meaning: Refresh silently returns to the default root, loses category state, reuses
       stale SQLite connections, or normalizes a dictionary key.
     - Side effects: Creates and deletes the fixture root through the shared test-case lifecycle;
       no global module installation is modified.
     */
    @MainActor
    func testRefreshRetainsSQLiteSelectionsAndExactDictionaryKeyAcrossAllCategories() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installAllSQLiteFixtures(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let pageManager = attachWindow(to: controller)

        controller.switchModule(to: "MySword-sample_bbl")
        controller.switchCommentaryModule(to: "MySword-sample_cmt")
        XCTAssertEqual(
            controller.switchDictionaryModule(to: "MySword-sample_dct"),
            .switchedRequiringKeySelection
        )
        controller.loadDictionaryEntry(key: "Elohim")

        controller.refreshInstalledModules()

        XCTAssertEqual(controller.activeModuleName, "MySword-sample_bbl")
        XCTAssertEqual(controller.activeCommentaryModuleName, "MySword-sample_cmt")
        XCTAssertEqual(controller.activeDictionaryModuleName, "MySword-sample_dct")
        XCTAssertEqual(controller.currentDictionaryKey, "Elohim")
        XCTAssertEqual(pageManager.bibleDocument, "MySword-sample_bbl")
        XCTAssertEqual(pageManager.commentaryDocument, "MySword-sample_cmt")
        XCTAssertEqual(pageManager.dictionaryDocument, "MySword-sample_dct")
        XCTAssertEqual(pageManager.dictionaryKey, "Elohim")
        XCTAssertEqual(try controller.activeDictionaryKeys(), ["Elohim", "Logos"])

        let readyBaseline = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        var payload = try latestDocumentPayload(
            from: Array(scripts().dropFirst(readyBaseline))
        )
        XCTAssertEqual(payload["bookInitials"] as? String, "MySword-sample_bbl")

        var baseline = scripts().count
        controller.switchCommentaryDocument(to: "MySword-sample_cmt")
        payload = try latestDocumentPayload(from: Array(scripts().dropFirst(baseline)))
        XCTAssertEqual(payload["bookInitials"] as? String, "MySword-sample_cmt")

        baseline = scripts().count
        XCTAssertEqual(
            controller.switchDictionaryDocument(to: "MySword-sample_dct"),
            .switchedPreservingKey
        )
        payload = try latestDocumentPayload(from: Array(scripts().dropFirst(baseline)))
        XCTAssertEqual(payload["bookInitials"] as? String, "MySword-sample_dct")
        XCTAssertEqual(payload["key"] as? String, "Elohim")
    }

    /**
     Verifies native share text uses SQLite source verses and absent commentary stays deterministic.

     - Setup: Renders MyBible Genesis 1:1, invokes the bridge share path for its exact KJVA ordinal,
       then selects MyBible commentary and navigates beyond its covering range.
     - Expected result: Shared text is real markup-free MyBible content with source initials, while
       Genesis 1:3 emits the standard no-content error and never falls back to SWORD/placeholder.
     - Failure meaning: Native copy/share reads the inactive SWORD handle or commentary fabricates
       content after a covering lookup misses.
     - Side effects: Records the share callback and bridge scripts only; no platform pasteboard is
       mutated, keeping the test deterministic in parallel runs.
     */
    @MainActor
    func testSQLiteShareTextAndCommentaryNoContentUseExactSourcePaths() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installAllSQLiteFixtures(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        _ = attachWindow(to: controller)
        controller.bridgeDidSetClientReady(bridge)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.switchBibleDocument(to: "MyBible-bible")
        XCTAssertEqual(
            controller.verseCountForActiveModule(book: "Genesis", chapter: 1),
            2
        )

        let ordinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        var sharedText: String?
        controller.onShareVerseText = { sharedText = $0 }
        controller.bridge(
            bridge,
            shareVerse: "MyBible-bible",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )
        XCTAssertTrue(sharedText?.contains("In the beginning") == true)
        XCTAssertTrue(sharedText?.contains("(MyBible-bible)") == true)
        XCTAssertFalse(sharedText?.contains("<J>") == true)

        controller.switchCommentaryDocument(to: "MyBible-commentary")
        let baseline = scripts().count
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 3)
        let payload = try latestDocumentPayload(from: Array(scripts().dropFirst(baseline)))
        XCTAssertEqual(payload["type"] as? String, "error")
        XCTAssertEqual(payload["errorMessage"] as? String, "No content for selected verse")
    }

    /**
     Verifies plain-text e-Sword modules remain XML-safe without changing visible source text.

     - Setup: Installs the `.bbli` fixture under a unique runtime identity and selects Genesis 1:1.
     - Expected result: Rendering escapes literal XML characters, generated configuration defaults
       to LTR because Android does not emit `Direction`, PageManager persists/restores the module,
       and native share text contains the original text.
     - Failure meaning: Plain e-Sword text can break OSIS parsing, leak escaped entities into copy,
       or lose source/runtime identity across restore.
     - Side effects: Creates a temporary module root and records bridge/share callbacks only.
     */
    @MainActor
    func testPlainESwordBibleRendersCopiesPersistsAndRestoresSourceText() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try copySQLiteFixture(
            "sample.bbli",
            to: "esword/plain.bbli",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let pageManager = attachWindow(to: controller)
        controller.bridgeDidSetClientReady(bridge)
        let switchBaseline = scripts().count
        controller.switchBibleDocument(to: "ESword-plain")

        var payload = try latestDocumentPayload(
            from: Array(scripts().dropFirst(switchBaseline))
        )
        var fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        XCTAssertTrue(xml.contains("Plain &lt;text&gt; stays unchanged &amp; readable"))
        XCTAssertFalse(xml.contains("Plain <text>"))
        XCTAssertEqual(fragment["direction"] as? String, "ltr")
        XCTAssertEqual(pageManager.bibleDocument, "ESword-plain")

        let ordinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        var sharedText: String?
        controller.onShareVerseText = { sharedText = $0 }
        controller.bridge(
            bridge,
            shareVerse: "ESword-plain",
            startOrdinal: ordinal,
            endOrdinal: ordinal
        )
        XCTAssertTrue(sharedText?.contains("Plain <text> stays unchanged & readable") == true)
        XCTAssertFalse(sharedText?.contains("&lt;") == true)

        let (restoredBridge, restoredScripts) = makeRecordingBridge()
        let restored = BibleReaderController(
            bridge: restoredBridge,
            swordManagerOverride: manager
        )
        restored.activeWindow = controller.activeWindow
        restored.restoreSavedPosition()
        restored.bridgeDidSetClientReady(restoredBridge)
        payload = try latestDocumentPayload(from: restoredScripts())
        fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])
        XCTAssertEqual(payload["bookInitials"] as? String, "ESword-plain")
        XCTAssertTrue(
            (fragment["xml"] as? String)?
                .contains("Plain &lt;text&gt; stays unchanged &amp; readable") == true
        )
    }

    /**
     Verifies SQLite Bible, commentary, and dictionary speech use real text and reconstruct cursors.

     - Setup: Builds providers directly from immutable handles without starting platform audio.
     - Expected result: Providers expose source language/identity, materialize fixture text, retain
       exact generic keys, and reconstruct their version-one checkpoints.
     - Failure meaning: TTS falls through to SWORD/current Bible, loses key identity, or reads a
       different source after pause.
     */
    func testSQLiteSpeechProvidersUseSourceTextLanguageAndExactCheckpoints() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installAllSQLiteFixtures(in: modulePath)
        var catalog = BibleReaderSQLiteModuleCatalog()
        catalog.reload(moduleRootURL: URL(fileURLWithPath: modulePath, isDirectory: true))
        let service = SpeakService()

        let bible = try XCTUnwrap(catalog.module(named: "MySword-sample_bbl", category: .bible))
        let bibleOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let bibleBuilder = SQLiteReaderSpeechSessionBuilder(module: bible)
        let bibleSession = try XCTUnwrap(bibleBuilder.bibleSession(
            category: .bible,
            startOrdinal: bibleOrdinal,
            endOrdinal: bibleOrdinal,
            service: service,
            positionChanged: { _ in },
            stopped: {}
        ))
        XCTAssertEqual(bibleSession.provider.currentPosition?.language, "en-US")
        XCTAssertTrue(
            bibleSession.provider.currentUnit(settings: service.settings)?
                .commands.compactMap(\.spokenText).joined(separator: " ").contains("Word") == true
        )
        let bibleCheckpoint = try XCTUnwrap(bibleSession.provider.checkpoint())
        XCTAssertNotNil(bibleBuilder.bibleSession(
            category: .bible,
            startOrdinal: nil,
            endOrdinal: nil,
            checkpoint: bibleCheckpoint,
            service: service,
            positionChanged: { _ in },
            stopped: {}
        ))

        let commentary = try XCTUnwrap(
            catalog.module(named: "MyBible-commentary", category: .commentary)
        )
        let commentaryBuilder = SQLiteReaderSpeechSessionBuilder(module: commentary)
        let commentarySession = try XCTUnwrap(commentaryBuilder.genericSession(
            category: .commentary,
            key: "Gen 1:2",
            startOrdinal: nil,
            endOrdinal: nil,
            service: service,
            synchronize: { _, _ in }
        ))
        XCTAssertTrue(
            commentarySession.provider.currentUnit(settings: service.settings)?
                .commands.compactMap(\.spokenText).joined(separator: " ")
                .contains("Range commentary") == true
        )

        let dictionary = try XCTUnwrap(
            catalog.module(named: "MyBible-dictionary", category: .dictionary)
        )
        let dictionaryBuilder = SQLiteReaderSpeechSessionBuilder(module: dictionary)
        let dictionarySession = try XCTUnwrap(dictionaryBuilder.genericSession(
            category: .dictionary,
            key: "H0430",
            startOrdinal: nil,
            endOrdinal: nil,
            service: service,
            synchronize: { _, _ in }
        ))
        XCTAssertEqual(dictionarySession.provider.currentPosition?.key, "H0430")
        XCTAssertTrue(
            dictionarySession.provider.currentUnit(settings: service.settings)?
                .commands.compactMap(\.spokenText).joined(separator: " ")
                .contains("Hebrew definition") == true
        )
        let dictionaryCheckpoint = try XCTUnwrap(dictionarySession.provider.checkpoint())
        XCTAssertNotNil(dictionaryBuilder.genericSession(
            category: .dictionary,
            key: nil,
            startOrdinal: nil,
            endOrdinal: nil,
            checkpoint: dictionaryCheckpoint,
            service: service,
            synchronize: { _, _ in }
        ))
    }

    /**
     Verifies SQLite speech advances across a missing requested verse like Android.

     - Setup: Copies a MySword Bible, removes Genesis 1:2, and adds Genesis 1:3 as the next real
       source row.
     - Expected result: Ordinary and bounded memorization sessions requested at verse two begin at
       verse three and speak its source text without synthesizing verse two.
     - Failure meaning: Sparse Android SQLite modules can render later verses but speech refuses to
       start from the same visible canonical position.
     - Side effects: Creates and mutates one caller-owned temporary SQLite fixture.
     */
    func testSQLiteSpeechAdvancesFromMissingVerseToNextRealSourceRow() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let relativePath = "mysword/sparse.bbl.mybible"
        try copySQLiteFixture(
            "sample.bbl.mybible",
            to: relativePath,
            in: modulePath
        )
        let databaseURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent(relativePath)
        try executeSQLite(
            """
            DELETE FROM Bible WHERE Book = 1 AND Chapter = 1 AND Verse = 2;
            INSERT INTO Bible (Book, Chapter, Verse, Scripture)
            VALUES (1, 1, 3, 'Third source verse');
            """,
            at: databaseURL
        )

        var catalog = BibleReaderSQLiteModuleCatalog()
        catalog.reload(moduleRootURL: URL(fileURLWithPath: modulePath, isDirectory: true))
        let module = try XCTUnwrap(
            catalog.module(named: "MySword-sparse_bbl", category: .bible)
        )
        let missingOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 2)
        )
        let nextOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 3)
        )
        let service = SpeakService()
        let builder = SQLiteReaderSpeechSessionBuilder(module: module)

        let bibleSession = try XCTUnwrap(builder.bibleSession(
            category: .bible,
            startOrdinal: missingOrdinal,
            endOrdinal: missingOrdinal,
            service: service,
            positionChanged: { _ in },
            stopped: {}
        ))
        XCTAssertEqual(bibleSession.provider.currentPosition?.ordinalStart, nextOrdinal)
        XCTAssertTrue(
            bibleSession.provider.currentUnit(settings: service.settings)?
                .commands.compactMap(\.spokenText).joined(separator: " ")
                .contains("Third source verse") == true
        )

        let memorizationSession = try XCTUnwrap(builder.bibleSession(
            category: .memorization,
            startOrdinal: missingOrdinal,
            endOrdinal: nextOrdinal,
            service: service,
            positionChanged: { _ in },
            stopped: {}
        ))
        XCTAssertEqual(memorizationSession.provider.currentPosition?.ordinalStart, nextOrdinal)
        XCTAssertEqual(memorizationSession.provider.checkpoint()?.lowerBound.ordinalStart, nextOrdinal)
        XCTAssertEqual(memorizationSession.provider.checkpoint()?.upperBound.ordinalStart, nextOrdinal)
    }

    /**
     Verifies the dictionary browser abstraction exposes SQLite keys and exact lazy definitions.

     - Setup: Discovers the real MyBible dictionary fixture and captures its immutable runtime
       handle in a backend-independent browser source.
     - Expected result: Source-order exact keys are retained and the H0430 row displays its own
       definition rather than requiring a native SWORD module or accepting a nearest key.
     - Failure meaning: SQLite dictionaries can be selected in the reader but remain unusable in
       the dictionary sheet introduced for Android parity.
     - Side effects: Creates a temporary module root and performs read-only SQLite queries.
     */
    func testSQLiteDictionaryBrowserSourceDisplaysExactKeysAndDefinitions() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try copySQLiteFixture(
            "mybible-dictionary.SQLite3",
            to: "mybible/dictionary.SQLite3",
            in: modulePath
        )
        var catalog = BibleReaderSQLiteModuleCatalog()
        catalog.reload(moduleRootURL: URL(fileURLWithPath: modulePath, isDirectory: true))
        let module = try XCTUnwrap(
            catalog.module(named: "MyBible-dictionary", category: .dictionary)
        )
        let source = DictionaryBrowserSource(sqliteModule: module)

        let keys = try await source.loadKeys()
        XCTAssertEqual(keys, ["G0001", "H0430"])
        let presentation = await source.displayCache(capacity: 2).presentation(for: "H0430")
        XCTAssertEqual(presentation.key, "H0430")
        XCTAssertEqual(presentation.snippet, "Hebrew definition ")
        XCTAssertEqual(presentation.displayText, "H0430 - Hebrew definition ")
    }

    /**
     Verifies a transient SQLite row failure never poisons the dictionary browser cache.

     - Setup: Captures a real SQLite dictionary source, temporarily moves its database away for the
       first exact-entry read, then restores the same file before requesting the row again.
     - Expected result: The first request shows a key-only fallback without caching it; the second
       request retries the source and displays the exact restored definition.
     - Failure meaning: Cancellation or transient filesystem/database errors can permanently hide
       dictionary snippets until the user closes and reopens the browser.
     - Side effects: Creates a temporary module root and moves one fixture database within it.
     */
    func testSQLiteDictionaryBrowserRetriesTransientEntryFailure() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let relativePath = "mybible/dictionary.SQLite3"
        try copySQLiteFixture(
            "mybible-dictionary.SQLite3",
            to: relativePath,
            in: modulePath
        )
        let databaseURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent(relativePath)
        let unavailableURL = databaseURL.appendingPathExtension("unavailable")
        var catalog = BibleReaderSQLiteModuleCatalog()
        catalog.reload(moduleRootURL: URL(fileURLWithPath: modulePath, isDirectory: true))
        let module = try XCTUnwrap(
            catalog.module(named: "MyBible-dictionary", category: .dictionary)
        )
        let cache = DictionaryBrowserSource(sqliteModule: module).displayCache(capacity: 2)

        try FileManager.default.moveItem(at: databaseURL, to: unavailableURL)
        let failedPresentation = await cache.presentation(for: "H0430")
        let failedPresentationWasCached = await cache.contains("H0430")
        XCTAssertEqual(failedPresentation.displayText, "H0430")
        XCTAssertFalse(failedPresentationWasCached)

        try FileManager.default.moveItem(at: unavailableURL, to: databaseURL)
        let recoveredPresentation = await cache.presentation(for: "H0430")
        let recoveredPresentationWasCached = await cache.contains("H0430")
        XCTAssertEqual(recoveredPresentation.displayText, "H0430 - Hebrew definition ")
        XCTAssertTrue(recoveredPresentationWasCached)
    }

    /**
     Verifies linked-block navigation retries Android's nullable cache misses.

     - Setup: Makes key two fail its first render while block expansion probes it, then succeed when
       forward navigation immediately revisits it.
     - Expected result: Key two becomes the next block start and successful content is retained;
       the first transient nil never poisons the operation cache.
     - Failure meaning: A cancellation or transient SQLite read can be mistaken for a genuine empty
       separator and silently skip the adjacent commentary block.
     - Side effects: Mutates one in-memory render counter; no files or backends are touched.
     */
    func testLinkedBlockNavigationRetriesTransientEmptyRender() {
        var secondKeyRenderCount = 0
        let resolver = LinkedDocumentBlockResolver<Int>(
            next: { $0 < 2 ? $0 + 1 : nil },
            previous: { $0 > 1 ? $0 - 1 : nil },
            render: { key in
                if key == 1 { return "First" }
                secondKeyRenderCount += 1
                return secondKeyRenderCount == 1 ? nil : "Second"
            }
        )

        XCTAssertEqual(resolver.adjacentBlockStart(from: 1, forward: true), 2)
        XCTAssertEqual(secondKeyRenderCount, 2)
    }

    /**
     Verifies SQLite commentary uses Android's linked equal-content block navigation.

     - Setup: Supplies two equal verses, an empty separator, and a second equal pair through one
       immutable commentary handle.
     - Expected result: The selected range expands across equal consecutive verses, next/previous
       skip the empty separator, and the document payload carries the complete first block range.
     - Failure meaning: SQLite commentary can render but previous/next or Vue range metadata still
       follows the native-SWORD-only path.
     - Side effects: Executes deterministic in-memory reader calls; no files are created.
     */
    func testSQLiteCommentaryNavigatorResolvesLinkedBlocksAndPayloadRange() throws {
        let module = SQLiteDocumentModule(
            reader: LinkedBlockSQLiteCommentaryReader(),
            origin: .manual
        )
        let handle = BibleReaderSQLiteModuleHandle(module: module)
        let navigator = SQLiteCommentaryBlockNavigator(module: handle)

        let block = try XCTUnwrap(
            navigator.block(osisId: "Gen", chapter: 1, verse: 2)
        )
        XCTAssertEqual(block.start.osisRef, "Gen.1.1")
        XCTAssertEqual(block.end.osisRef, "Gen.1.2")
        XCTAssertEqual(block.name, "Genesis 1:1-2")
        XCTAssertEqual(
            navigator.adjacentBlockStart(
                osisId: "Gen",
                chapter: 1,
                verse: 2,
                forward: true
            )?.osisRef,
            "Gen.1.4"
        )
        XCTAssertEqual(
            navigator.adjacentBlockStart(
                osisId: "Gen",
                chapter: 1,
                verse: 4,
                forward: false
            )?.osisRef,
            "Gen.1.1"
        )

        let document = try SQLiteReaderDocumentContentBuilder(module: handle).commentary(
            osisBookId: "Gen",
            bookName: "Genesis",
            chapter: 1,
            verse: 2,
            isNewTestament: false
        )
        XCTAssertEqual(
            document.request.commentaryRange,
            ReaderCommentaryRangePayload(
                startOsisRef: "Gen.1.1",
                endOsisRef: "Gen.1.2",
                name: "Genesis 1:1-2"
            )
        )
    }

    /**
     Verifies SQLite commentary traversal respects Android's document and scripture boundaries.

     - Setup: Exposes Malachi, Tobit, and Matthew commentary rows in one KJVA-ordered module.
     - Expected result: Forward traversal from Malachi skips non-scripture Tobit and lands on
       Matthew, reverse traversal returns to Malachi, and Tobit does not cross into scripture.
     - Failure meaning: SQLite commentary arrows can enter a different Android book scope or walk
       through KJVA books that the active document does not expose.
     - Side effects: Executes deterministic in-memory reader calls only.
     */
    func testSQLiteCommentaryTraversalKeepsAndroidScriptureScope() throws {
        let module = SQLiteDocumentModule(
            reader: ScriptureBoundarySQLiteCommentaryReader(),
            origin: .manual
        )
        let navigator = SQLiteCommentaryBlockNavigator(
            module: BibleReaderSQLiteModuleHandle(module: module)
        )

        XCTAssertEqual(
            navigator.adjacentBlockStart(
                osisId: "Mal",
                chapter: 4,
                verse: 6,
                forward: true
            )?.osisRef,
            "Matt.1.1"
        )
        XCTAssertEqual(
            navigator.adjacentBlockStart(
                osisId: "Matt",
                chapter: 1,
                verse: 1,
                forward: false
            )?.osisRef,
            "Mal.4.6"
        )
        XCTAssertNil(
            navigator.adjacentBlockStart(
                osisId: "Tob",
                chapter: 1,
                verse: 1,
                forward: true
            )
        )
    }

    /**
     Verifies BibleUI handles do not add blocking locks around operation-isolated SQLite readers.

     - Setup: Wraps one instrumented reader in two handles, then runs point, chapter-batch, and
       key-derived book-list reads concurrently through both.
     - Expected result: Calls overlap while every operation completes, leaving cancellation and
       independent read-only connection ownership at the BibleCore database boundary.
     - Failure meaning: A UI lock can make a cancelled request occupy an executor thread behind
       unrelated SQLite work and recreate the removed layered-isolation defect.
     */
    func testSQLiteRuntimeHandlesAllowOperationOwnedReaderCallsToOverlap() async throws {
        let reader = ConcurrentCallSQLiteBibleReader()
        let module = SQLiteDocumentModule(reader: reader, origin: .manual)
        let firstHandle = BibleReaderSQLiteModuleHandle(module: module)
        let secondHandle = BibleReaderSQLiteModuleHandle(module: module)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let handle = index.isMultiple(of: 2) ? firstHandle : secondHandle
                    if index.isMultiple(of: 5) {
                        _ = try? handle.bookList()
                    } else if index.isMultiple(of: 3) {
                        _ = try? handle.chapterContent(osisId: "Gen", chapter: 1)
                    } else {
                        _ = try? handle.verseContent(
                            osisId: "Gen",
                            chapter: 1,
                            verse: 1
                        )
                    }
                }
            }
        }

        XCTAssertGreaterThan(reader.maximumConcurrentCalls, 1)
        XCTAssertGreaterThan(reader.completedCallCount, 1)
    }

    /**
     Verifies copy/share text applies the same deterministic duplicate-row policy as rendering.

     - Setup: Returns two source rows for Genesis 1:1 followed by one row for Genesis 1:2.
     - Expected result: The visible range contains the first verse-one row and verse two exactly
       once, preserving source order while excluding the later duplicate.
     - Failure meaning: Native copy/share text can disagree with the rendered chapter or speech.
     */
    func testSQLiteVisibleRangeTextKeepsFirstDuplicateVerseRow() throws {
        let reader = ConcurrentCallSQLiteBibleReader()
        let module = SQLiteDocumentModule(reader: reader, origin: .manual)
        let handle = BibleReaderSQLiteModuleHandle(module: module)
        let firstOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let secondOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 2)
        )

        XCTAssertEqual(
            SQLiteReaderVerseRangeTextBuilder(module: handle).text(
                osisBookId: "Gen",
                chapter: 1,
                startOrdinal: firstOrdinal,
                endOrdinal: secondOrdinal
            ),
            "First source Second source"
        )
    }

    /**
     Attaches a fresh pane-owned PageManager for persistence assertions.

     - Parameter controller: Reader controller receiving the test window.
     - Returns: New PageManager retained by the attached window.
     - Side effects: Replaces `controller.activeWindow` with an in-memory test window.
     - Failure modes: None; no SwiftData context or global window registry is involved.
     */
    @MainActor
    private func attachWindow(to controller: BibleReaderController) -> PageManager {
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        return pageManager
    }

    /**
     Decodes the latest document event from a caller-scoped bridge script slice.

     - Parameter scripts: Recorded scripts emitted after the action under test.
     - Returns: Decoded top-level document dictionary.
     - Throws: XCTest unwrap failures when no valid `add_documents` payload was emitted.
     - Side effects: None.
     */
    private func latestDocumentPayload(from scripts: [String]) throws -> [String: Any] {
        try XCTUnwrap(
            bridgeEmissionPayload(from: scripts, event: "add_documents") as? [String: Any]
        )
    }

    /**
     Copies every supported real SQLite fixture into its Android discovery family directory.

     - Parameter modulePath: Temporary installed-module root owned by the current test.
     - Side effects: Creates MyBible, MySword, and e-Sword directories and copies seven fixtures.
     - Throws: Repository-location, directory-creation, and file-copy failures.
     - Note: Fixture names and destinations keep discovery deterministic.
     */
    private func installAllSQLiteFixtures(in modulePath: String) throws {
        try copySQLiteFixture(
            "mybible-bible.SQLite3",
            to: "mybible/bible.SQLite3",
            in: modulePath
        )
        try copySQLiteFixture(
            "mybible-commentary.SQLite3",
            to: "mybible/commentary.SQLite3",
            in: modulePath
        )
        try copySQLiteFixture(
            "mybible-dictionary.SQLite3",
            to: "mybible/dictionary.SQLite3",
            in: modulePath
        )
        try copySQLiteFixture(
            "sample.bbl.mybible",
            to: "mysword/sample.bbl.mybible",
            in: modulePath
        )
        try copySQLiteFixture(
            "sample.cmt.mybible",
            to: "mysword/sample.cmt.mybible",
            in: modulePath
        )
        try copySQLiteFixture(
            "sample.dct.mybible",
            to: "mysword/sample.dct.mybible",
            in: modulePath
        )
        try copySQLiteFixture(
            "sample.bblx",
            to: "esword/sample.bblx",
            in: modulePath
        )
    }

    /**
     Copies one checked-in BibleCore SQLite fixture into a temporary module root.

     - Parameters:
       - fixtureName: Exact checked-in fixture filename.
       - relativePath: Android-family destination relative to the module root.
       - modulePath: Temporary installed-module root.
     - Side effects: Creates the destination parent and copies one immutable fixture.
     - Throws: Source-location, directory-creation, or copy failures.
     */
    private func copySQLiteFixture(
        _ fixtureName: String,
        to relativePath: String,
        in modulePath: String
    ) throws {
        let repositoryRoot = try BibleUITestSourceLocator.repositoryRoot(
            containing: "Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders"
        )
        let source = repositoryRoot
            .appendingPathComponent("Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders")
            .appendingPathComponent(fixtureName)
        let destination = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /**
     Executes one fixture mutation against a temporary SQLite module.

     - Parameters:
       - sql: Static test-only SQL statement.
       - url: Existing temporary database URL opened read-write.
     - Side effects: Mutates only the caller-owned temporary fixture database.
     - Throws: An `NSError` carrying SQLite's open or execution diagnostic.
     */
    private func executeSQLite(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK, let database else {
            throw NSError(
                domain: "SQLiteReaderRuntimeIntegrationTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not open \(url.lastPathComponent)"]
            )
        }
        defer { sqlite3_close(database) }

        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? "Unknown SQLite fixture error"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "SQLiteReaderRuntimeIntegrationTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    /**
     Installs one package-owned MyBible identity for SWORD-precedence coverage.

     - Parameters:
       - initials: Exact sidecar initials, including caller-controlled casing.
       - modulePath: Temporary installed-module root.
     - Side effects: Copies a Bible database and writes a matching package sidecar.
     - Throws: Fixture-copy or JSON serialization/write failures.
     */
    private func installMyBiblePackageDuplicate(
        initials: String,
        in modulePath: String
    ) throws {
        let package = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mybible/duplicate-kjv", isDirectory: true)
        let packageFileName = "duplicate-kjv.SQLite3.zip"
        try copySQLiteFixture(
            "mybible-bible.SQLite3",
            to: "mybible/duplicate-kjv/duplicate-kjv.SQLite3",
            in: modulePath
        )
        let sidecar = try JSONSerialization.data(withJSONObject: [
            "name": initials,
            "description": "SQLite duplicate KJV",
            "category": "Biblical Texts",
            "language": "en",
            "version": "1",
            "sourceName": "Fixture",
            "packageFileName": packageFileName,
            "downloadURL": "https://example.invalid/\(packageFileName)",
            "installedAt": 0,
        ], options: [.sortedKeys])
        try sidecar.write(to: package.appendingPathComponent("module.json"))
    }

    /**
     Installs one package-owned MyBible payload with caller-controlled exact initials.

     - Parameters:
       - initials: Exact sidecar identity, including canonical Unicode form.
       - directoryName: ASCII package-directory name controlling discovery order.
       - language: Deliberately conflicting sidecar language used to prove database ownership.
       - modulePath: Temporary installed-module root.
     - Side effects: Copies a Bible database and writes one package sidecar.
     - Throws: Fixture-copy or JSON serialization/write failures.
     */
    private func installMyBiblePackage(
        initials: String,
        directoryName: String,
        language: String = "en",
        in modulePath: String
    ) throws {
        let package = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mybible/\(directoryName)", isDirectory: true)
        let payloadName = "\(directoryName).SQLite3"
        let packageFileName = "\(payloadName).zip"
        try copySQLiteFixture(
            "mybible-bible.SQLite3",
            to: "mybible/\(directoryName)/\(payloadName)",
            in: modulePath
        )
        let sidecar = try JSONSerialization.data(withJSONObject: [
            "name": initials,
            "description": "Canonical identity fixture",
            "category": "Biblical Texts",
            "language": language,
            "version": "1",
            "sourceName": "Fixture",
            "packageFileName": packageFileName,
            "downloadURL": "https://example.invalid/\(packageFileName)",
            "installedAt": 0,
        ], options: [.sortedKeys])
        try sidecar.write(to: package.appendingPathComponent("module.json"))
    }

    /**
     Seeds one readable RawLD entry for exact-key SWORD switch preflight.

     - Parameters:
       - moduleName: SWORD module identity previously installed by the empty-module fixture helper.
       - entryKey: Exact dictionary key written into the RawLD record.
       - modulePath: Temporary SWORD module root.
     - Side effects: Creates RawLD data/index files beneath the fixture module.
     - Throws: Fixture setup, record-size conversion, or file-write failures.
     */
    private func seedReadableRawDictionaryModule(
        named moduleName: String,
        entryKey: String,
        in modulePath: String
    ) throws {
        try seedEmptyRawDictionaryModule(named: moduleName, in: modulePath)
        let moduleKey = moduleName.lowercased()
        let prefix = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("modules/lexdict/rawld/\(moduleKey)/\(moduleKey)")
        let record = Data("\(entryKey)\r\n<div type=\"entry\">Readable fixture</div>".utf8)
        var recordLength = try XCTUnwrap(UInt16(exactly: record.count)).littleEndian
        var index = Data([0, 0, 0, 0])
        withUnsafeBytes(of: &recordLength) { index.append(contentsOf: $0) }
        var data = record
        data.append(0x0A)
        try data.write(to: prefix.appendingPathExtension("dat"))
        try index.write(to: prefix.appendingPathExtension("idx"))
    }
}

/** Deterministic commentary reader with two linked blocks separated by one empty verse. */
private final class LinkedBlockSQLiteCommentaryReader: SQLiteDocumentReading {
    /// Immutable MyBible commentary metadata used by the runtime facade.
    let metadata = SQLiteDocumentMetadata(
        sourceURL: URL(fileURLWithPath: "/tmp/linked-commentary.SQLite3"),
        format: .myBible,
        initials: "MyBible-linked-commentary",
        abbreviation: "Linked",
        title: "Linked commentary",
        description: "Linked commentary",
        language: "en",
        version: "1",
        category: .commentary,
        direction: .ltr,
        hasStrongs: false,
        isStrongsDictionary: false,
        hasWordsOfChrist: false
    )

    /// Fixed commentary category required by linked-block navigation.
    var category: DocumentCategory { .commentary }

    /** Returns every fixture coordinate in source order. */
    func keys() throws -> [SQLiteDocumentKey] {
        (1...5).map { .verse(book: 10, chapter: 1, verse: $0) }
    }

    /** Returns equal semantic blocks at verses 1-2 and 4-5 with verse 3 empty. */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        guard case .verse(book: 10, chapter: 1, let verse) = key,
              (1...5).contains(verse) else { return nil }
        let text: String
        switch verse {
        case 1, 2: text = "Shared first block"
        case 4, 5: text = "Shared second block"
        default: text = ""
        }
        return SQLiteDocumentContent(key: key, text: text)
    }

    /** Returns the complete fixture chapter without additional point reads. */
    func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        guard book == 10, chapter == 1 else { return [] }
        return try keys().compactMap { key in
            guard case .verse(_, _, let verse) = key,
                  let content = try content(for: key) else { return nil }
            return (verse, content.text)
        }
    }
}

/** Commentary fixture spanning Android's scripture/non-scripture KJVA boundary. */
private final class ScriptureBoundarySQLiteCommentaryReader: SQLiteDocumentReading {
    /// Immutable MyBible commentary metadata used by the runtime facade.
    let metadata = SQLiteDocumentMetadata(
        sourceURL: URL(fileURLWithPath: "/tmp/scripture-boundary-commentary.SQLite3"),
        format: .myBible,
        initials: "MyBible-scripture-boundary-commentary",
        abbreviation: "Boundary",
        title: "Scripture boundary commentary",
        description: "Scripture boundary commentary",
        language: "en",
        version: "1",
        category: .commentary,
        direction: .ltr,
        hasStrongs: false,
        isStrongsDictionary: false,
        hasWordsOfChrist: false
    )

    /// Fixed commentary category required by linked-block navigation.
    var category: DocumentCategory { .commentary }

    /** Returns book probes plus the exact Malachi boundary row in KJVA order. */
    func keys() throws -> [SQLiteDocumentKey] {
        [
            .verse(book: 460, chapter: 1, verse: 1),
            .verse(book: 460, chapter: 4, verse: 6),
            .verse(book: 170, chapter: 1, verse: 1),
            .verse(book: 470, chapter: 1, verse: 1),
        ]
    }

    /** Returns distinct non-empty content for every fixture key. */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        let text: String
        switch key {
        case .verse(book: 460, chapter: 1, verse: 1): text = "Malachi probe"
        case .verse(book: 460, chapter: 4, verse: 6): text = "Malachi boundary"
        case .verse(book: 170, chapter: 1, verse: 1): text = "Tobit boundary"
        case .verse(book: 470, chapter: 1, verse: 1): text = "Matthew boundary"
        default: return nil
        }
        return SQLiteDocumentContent(key: key, text: text)
    }

    /** Returns source rows for the requested fixture chapter. */
    func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        try keys().compactMap { key in
            guard case .verse(let keyBook, let keyChapter, let verse) = key,
                  keyBook == book,
                  keyChapter == chapter,
                  let content = try content(for: key) else {
                return nil
            }
            return (verse, content.text)
        }
    }
}

/**
 Instrumented SQLite reader used to prove BibleUI does not add a serialization boundary.

 The mock implements one Genesis point verse plus a duplicate-row chapter batch and records
 active/completed raw reader calls behind a separate state lock. Each call sleeps for a fixed
 interval so unsynchronized overlap is observable without clocks, polling, or probabilistic
 assertions. It intentionally omits real SQLite I/O, format parsing, and mutable content because
 the test contract concerns direct concurrent delegation only.
 */
private final class ConcurrentCallSQLiteBibleReader: SQLiteDocumentReading, @unchecked Sendable {
    /// Immutable source metadata sufficient for a validated MyBible facade.
    let metadata = SQLiteDocumentMetadata(
        sourceURL: URL(fileURLWithPath: "/tmp/concurrent-reader.SQLite3"),
        format: .myBible,
        initials: "MyBible-concurrent-reader",
        abbreviation: "Concurrent",
        title: "Concurrent reader",
        description: "Concurrent reader",
        language: "en",
        version: "1",
        category: .bible,
        direction: .ltr,
        hasStrongs: false,
        isStrongsDictionary: false,
        hasWordsOfChrist: false
    )

    /// Fixed Bible category required by the module facade.
    var category: DocumentCategory { .bible }

    /// Protects all instrumentation counters independently of the production reader lock.
    private let stateLock = NSLock()

    /// Number of raw mock operations currently inside the measured interval.
    private var activeCalls = 0

    /// Highest observed simultaneous raw-operation count.
    private var maximumCalls = 0

    /// Number of measured raw operations that completed.
    private var completedCalls = 0

    /// Thread-safe maximum concurrency snapshot used by the assertion.
    var maximumConcurrentCalls: Int {
        stateLock.withLock { maximumCalls }
    }

    /// Thread-safe completion snapshot proving the task group exercised multiple calls.
    var completedCallCount: Int {
        stateLock.withLock { completedCalls }
    }

    /**
     Enumerates one key while recording overlap around simulated database work.

     - Returns: One Genesis 1:1 source key.
     - Side effects: Updates instrumentation counters and sleeps for a fixed two milliseconds.
     - Throws: Never throws; declaration matches the production protocol.
     - Important: Counter synchronization is intentionally independent of the runtime handle lock.
     */
    func keys() throws -> [SQLiteDocumentKey] {
        measuredCall {
            [.verse(book: 10, chapter: 1, verse: 1)]
        }
    }

    /**
     Resolves one verse while recording overlap around simulated database work.

     - Parameter key: Exact source key requested by the module facade.
     - Returns: Fixture content for Genesis 1:1, otherwise nil.
     - Side effects: Updates instrumentation counters and sleeps for a fixed two milliseconds.
     - Throws: Never throws; declaration matches the production protocol.
     */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        measuredCall {
            guard key == .verse(book: 10, chapter: 1, verse: 1) else { return nil }
            return SQLiteDocumentContent(key: key, text: "Concurrent text")
        }
    }

    /**
     Returns deterministic duplicate chapter rows while recording the raw reader boundary.

     - Parameters:
       - book: Android KJVA book number; only Genesis is supported.
       - chapter: One-based chapter; only chapter one is supported.
     - Returns: Two rows for verse one followed by one row for verse two.
     - Side effects: Updates instrumentation counters and sleeps for a fixed two milliseconds.
     - Throws: Never throws; declaration matches the production protocol.
     */
    func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        measuredCall {
            guard book == 10, chapter == 1 else { return [] }
            return [
                (1, "First source"),
                (1, "Duplicate source"),
                (2, "Second source"),
            ]
        }
    }

    /**
     Runs one deterministic slow operation while tracking active call cardinality.

     - Parameter operation: Synchronous mock value producer executed inside the measured interval.
     - Returns: Exact value produced by `operation`.
     - Side effects: Atomically increments/decrements active count, records the maximum, sleeps for
       two milliseconds, and increments completion count on every return path.
     - Failure modes: The nonthrowing operation cannot fail; fixed sleep avoids polling/timeouts.
     - Important: `stateLock` is released before sleep so production-lock failures become overlap.
     */
    private func measuredCall<Value>(_ operation: () -> Value) -> Value {
        stateLock.withLock {
            activeCalls += 1
            maximumCalls = max(maximumCalls, activeCalls)
        }
        Thread.sleep(forTimeInterval: 0.002)
        defer {
            stateLock.withLock {
                activeCalls -= 1
                completedCalls += 1
            }
        }
        return operation()
    }
}
