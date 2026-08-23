import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Controller integration tests for exact Bible and generic bookmark destinations.

 Each test uses an isolated SWORD tree and an in-memory recording bridge. Temporary module files are
 removed by the inherited fixture teardown; no test touches network or shared persistence.
 */
final class BibleReaderBookmarkNavigationIntegrationTests: BibleUISwordFixtureTestCase {
    /**
     Verifies a Bible bookmark commits the complete mapped range in the active module.

     - Side effects: Loads one fixture chapter and records reader bridge events.
     - Failure modes: Fails if controller integration substitutes a module, drops the range endpoint,
       or emits a single-verse setup highlight.
     */
    @MainActor
    func testBibleTargetCommitsCompleteMappedRangeToActiveModule() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let sourceStart = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let sourceEnd = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 3)
        )
        let kjvaStart = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let kjvaEnd = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 3)
        )
        let target = BookmarkNavigationTarget.bible(.init(
            sourceModuleInitials: "KJV",
            sourceVersification: "KJV",
            sourceOrdinalRange: sourceStart...sourceEnd,
            sourceOSISReference: "Gen.1.1-Gen.1.3",
            kjvaOrdinalRange: kjvaStart...kjvaEnd,
            kjvaOSISReference: "Gen.1.1-Gen.1.3"
        ))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        try controller.navigate(toBookmarkTarget: target)

        let setup = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(scripts().dropFirst(baseline)),
                event: "setup_content"
            ) as? [String: Any]
        )
        XCTAssertEqual(controller.activeModuleName, "KJV")
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(setup["ordinalStart"] as? Int, sourceStart)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, sourceEnd)
        XCTAssertEqual(setup["highlight"] as? Bool, true)
    }

    /**
     Rejects a Java-distinct destination replacement between Bible bookmark planning and commit.

     - Setup: Installs composed and decomposed module initials backed by the same KJV verses, plans
       against the composed destination, then switches the active pane to the decomposed spelling.
     - Expected result: Commit throws `destinationChanged` before navigation, persistence, or bridge
       emission even though Swift considers the two module names canonically equal.
     - Failure meaning: A stale plan can authorize a different Android book identity and navigate it
       because the controller's time-of-check/time-of-use comparison uses Swift normalization.
     - Side effects: Writes two inherited SWORD descriptors and records only pre-commit baseline state.
     */
    @MainActor
    func testBibleBookmarkCommitRejectsComposedToDecomposedDestinationReplacement() throws {
        let composed = "Destin\u{00E9}"
        let decomposed = "Destine\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertFalse(SwordJavaStringIdentity.equals(composed, decomposed))
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: composed,
            description: "Composed destination",
            in: modulePath
        )
        let modsDURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.moveItem(
            at: modsDURL.appendingPathComponent("\(composed.lowercased()).conf"),
            to: modsDURL.appendingPathComponent("unicode-composed-destination.conf")
        )
        try seedBibleAliasModule(
            named: decomposed,
            description: "Decomposed destination",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let composedModule = try XCTUnwrap(manager.module(named: composed))
        let sourceOrdinal = try XCTUnwrap(
            composedModule.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let kjvaOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let target = BookmarkNavigationTarget.bible(.init(
            sourceModuleInitials: composed,
            sourceVersification: "KJV",
            sourceOrdinalRange: sourceOrdinal...sourceOrdinal,
            sourceOSISReference: "Gen.1.1",
            kjvaOrdinalRange: kjvaOrdinal...kjvaOrdinal,
            kjvaOSISReference: "Gen.1.1"
        ))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        XCTAssertEqual(controller.switchBibleDocument(to: composed), .switched)
        let inventory = try controller.bookmarkNavigationInventory(for: target)
        let planned = try BibleReaderBookmarkNavigationCoordinator().plan(
            target: target,
            inventory: inventory
        )
        guard case .bible(let plan) = planned else {
            return XCTFail("Expected a Bible bookmark plan")
        }
        XCTAssertTrue(SwordJavaStringIdentity.equals(plan.destinationModuleInitials, composed))
        XCTAssertEqual(controller.switchBibleDocument(to: decomposed), .switched)
        XCTAssertTrue(SwordJavaStringIdentity.equals(controller.activeModuleName, decomposed))
        let baselineCategory = controller.currentCategory
        let baselineModule = controller.activeModuleName
        let baselineBook = controller.currentBook
        let baselineChapter = controller.currentChapter
        let baselineVerse = controller.currentVerse
        let baselineScripts = scripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        XCTAssertThrowsError(try controller.commitBibleBookmarkNavigation(plan)) { error in
            XCTAssertEqual(
                error as? BibleReaderBookmarkNavigationCommitFailure,
                .destinationChanged
            )
        }
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertTrue(SwordJavaStringIdentity.equals(controller.activeModuleName, baselineModule))
        XCTAssertEqual(controller.currentBook, baselineBook)
        XCTAssertEqual(controller.currentChapter, baselineChapter)
        XCTAssertEqual(controller.currentVerse, baselineVerse)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(scripts().count, baselineScripts)
    }

    /**
     Verifies an exact generic target emits one owning-module document and one scoped setup payload.

     - Side effects: Writes one RawLD dictionary, resolves its exact structural fragment, and records
       one controller navigation.
     - Failure modes: Fails if controller integration borrows the active Bible, chooses another key,
       drops the BVA range, or emits duplicate content.
     */
    @MainActor
    func testGenericTargetCommitsExactModuleKeyAndSelectionOnce() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeBookmarkNavigationRawLDModule(
            named: "BOOKNAV",
            entries: [
                ("G0001", "<div><p>Exact dictionary entry.</p></div>"),
                ("G0002", "<div><p>Neighbor entry.</p></div>"),
            ],
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "BOOKNAV"))
        let fragment = try module.rawOSISFragment(forKey: "G0001")
        let available = fragment.keyOrdinalRange ?? fragment.contentOrdinalRange
        let selected = available.lowerBound...available.lowerBound
        let target = BookmarkNavigationTarget.generic(.init(
            moduleInitials: "BOOKNAV",
            key: "G0001",
            ordinalRange: selected
        ))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        try controller.navigate(toBookmarkTarget: target)

        let emissions = Array(scripts().dropFirst(baseline))
        let documentEmissions = emissions.filter { $0.contains("bibleView.emit('add_documents', ") }
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(documentEmissions.count, 1)
        XCTAssertEqual(document["bookInitials"] as? String, "BOOKNAV")
        XCTAssertEqual(document["key"] as? String, "G0001")
        XCTAssertEqual(setup["bookInitials"] as? String, "BOOKNAV")
        XCTAssertEqual(setup["osisRef"] as? String, "G0001")
        XCTAssertEqual(setup["ordinalStart"] as? Int, selected.lowerBound)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, selected.upperBound)
        XCTAssertEqual(controller.currentCategory, .dictionary)
        XCTAssertEqual(controller.activeModuleName(for: .dictionary), "BOOKNAV")
    }

    /**
     Verifies a missing exact generic key performs no reader or bridge mutation.

     - Side effects: Writes one RawLD dictionary and attempts one invalid navigation.
     - Failure modes: Fails if the controller falls back to a neighboring/current key or clears the
       existing document before exact planning succeeds.
     */
    @MainActor
    func testMissingGenericKeyFailsBeforeReaderMutation() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeBookmarkNavigationRawLDModule(
            named: "BOOKNAV",
            entries: [("ONLY", "<div><p>Only exact entry.</p></div>")],
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count
        let originalCategory = controller.currentCategory

        XCTAssertThrowsError(
            try controller.navigate(
                toBookmarkTarget: .generic(.init(
                    moduleInitials: "BOOKNAV",
                    key: "MISSING",
                    ordinalRange: nil
                ))
            )
        )

        XCTAssertEqual(scripts().count, baseline)
        XCTAssertEqual(controller.currentCategory, originalCategory)
        XCTAssertNil(controller.activeModuleName(for: .dictionary))
    }

    /**
     Rejects an installed-but-locked SWORD bookmark before any exact fragment read or UI mutation.

     - Setup: Writes a plaintext RawLD record behind a locked descriptor so the inclusive native
       handle could still expose the record, then opens the bookmark through a recording controller.
     - Expected result: Readable inventory omits the source and planning fails with
       `genericModuleNotFound`; bridge, category, and active dictionary identity stay unchanged.
     - Failure meaning: Bookmark-list navigation can treat installed metadata as content authority
       and read a relocked native module.
     - Side effects: Writes only an inherited temporary SWORD fixture.
     */
    @MainActor
    func testLockedGenericSwordTargetFailsBeforeReadOrMutation() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeBookmarkNavigationRawLDModule(
            named: "BOOKLOCK",
            entries: [("ENTRY", "<div><p>Locked bookmark content.</p></div>")],
            in: modulePath
        )
        try lockBookmarkNavigationModule(named: "BOOKLOCK", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertNotNil(manager.module(named: "BOOKLOCK"))
        XCTAssertNil(manager.readableModule(named: "BOOKLOCK"))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baselineScripts = scripts().count
        let baselineCategory = controller.currentCategory

        XCTAssertThrowsError(
            try controller.navigate(
                toBookmarkTarget: .generic(.init(
                    moduleInitials: "BOOKLOCK",
                    key: "ENTRY",
                    ordinalRange: nil
                ))
            )
        ) { error in
            XCTAssertEqual(
                error as? BibleReaderBookmarkNavigationFailure,
                .genericModuleNotFound("BOOKLOCK")
            )
        }

        XCTAssertEqual(scripts().count, baselineScripts)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertNil(controller.activeModuleName(for: .dictionary))
    }

    /**
     Reauthorizes a SWORD bookmark after planning to close the relock time-of-check/time-of-use gap.

     - Setup: Plans from a readable RawLD source, then relocks the descriptor and constructs the
       fresh reader process that performs the delayed commit with the immutable earlier plan.
     - Expected result: Commit resolves current access state, rejects the locked module, and makes
       no bridge or reader-state mutation.
     - Failure meaning: A bookmark plan can retain content authority after credentials are revoked.
     - Side effects: Rewrites only an inherited temporary descriptor between planning and commit.
     */
    @MainActor
    func testGenericSwordCommitFailsWhenSourceRelocksAfterPlan() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeBookmarkNavigationRawLDModule(
            named: "BOOKTOCTOU",
            entries: [("ENTRY", "<div><p>Initially readable content.</p></div>")],
            in: modulePath
        )
        let target = BookmarkNavigationTarget.generic(.init(
            moduleInitials: "BOOKTOCTOU",
            key: "ENTRY",
            ordinalRange: nil
        ))
        let readableManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let planningController = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: readableManager
        )
        let inventory = try planningController.bookmarkNavigationInventory(for: target)
        let commitPlan = try BibleReaderBookmarkNavigationCoordinator().plan(
            target: target,
            inventory: inventory
        )
        guard case .sword(let swordPlan) = commitPlan else {
            return XCTFail("Expected a SWORD bookmark commit plan")
        }

        try lockBookmarkNavigationModule(named: "BOOKTOCTOU", in: modulePath)
        let lockedManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertNil(lockedManager.readableModule(named: "BOOKTOCTOU"))
        let (bridge, scripts) = makeRecordingBridge()
        let commitController = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: lockedManager
        )
        commitController.bridgeDidSetClientReady(bridge)
        let baselineScripts = scripts().count
        let baselineCategory = commitController.currentCategory

        XCTAssertThrowsError(try commitController.commitSwordBookmarkNavigation(swordPlan)) { error in
            XCTAssertEqual(
                error as? BibleReaderBookmarkNavigationFailure,
                .genericModuleNotFound("BOOKTOCTOU")
            )
        }
        XCTAssertEqual(scripts().count, baselineScripts)
        XCTAssertEqual(commitController.currentCategory, baselineCategory)
        XCTAssertNil(commitController.activeModuleName(for: .dictionary))
    }

    /**
     Preserves locked native ownership over colliding app-local generic documents.

     - Setup: Installs a locked dictionary and a readable My Documents page with identical initials
       and key, then requests that exact persisted bookmark identity.
     - Expected result: Global native ownership suppresses local candidates, producing
       `genericModuleNotFound` with no bridge or reader-state mutation.
     - Failure meaning: A locked native identity can silently fall through to unrelated local or
       EPUB content; SQLite collision precedence is covered by `InstalledScriptureSourceTests`.
     - Side effects: Writes an inherited temporary module and an in-memory SwiftData document.
     */
    @MainActor
    func testLockedNativeGenericIdentityDoesNotFallThroughToMyDocument() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeBookmarkNavigationRawLDModule(
            named: "BOOKCOLLIDE",
            entries: [("NATIVE", "<div><p>Locked native content.</p></div>")],
            in: modulePath
        )
        try lockBookmarkNavigationModule(named: "BOOKCOLLIDE", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Collision Document", initials: "BOOKCOLLIDE")
        let page = MyDocumentPage(title: "Entry", pageKey: "ENTRY", contentType: .markdown)
        let content = MyDocumentPageContent(pageId: page.id, content: "Local collision content")
        page.pageContent = content
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        controller.bridgeDidSetClientReady(bridge)
        let baselineScripts = scripts().count
        let baselineCategory = controller.currentCategory

        XCTAssertThrowsError(
            try controller.navigate(
                toBookmarkTarget: .generic(.init(
                    moduleInitials: "BOOKCOLLIDE",
                    key: "ENTRY",
                    ordinalRange: nil
                ))
            )
        ) { error in
            XCTAssertEqual(
                error as? BibleReaderBookmarkNavigationFailure,
                .genericModuleNotFound("BOOKCOLLIDE")
            )
        }
        XCTAssertEqual(scripts().count, baselineScripts)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertNil(controller.activeModuleName(for: .dictionary))
    }

    /**
     Reauthorizes a planned My Documents bookmark when a native owner appears before commit.

     - Setup: Plans one exact local page while globally unowned, then publishes a readable Bible
       whose full name owns the local initials and deletes the local page before delayed commit.
     - Expected: Commit reports `destinationChanged` from the fresh owner gate—not an exact-page
       lookup failure—and leaves category, pane, persistence, and bridge state unchanged.
     - Failure meaning: A detached local plan remains content authority after Android's global
       registry transfers ownership, or the commit reads the shadowed page before authorization.
     - Side effects: Writes one inherited SWORD fixture and an in-memory My Documents graph.
     */
    @MainActor
    func testMyDocumentBookmarkCommitRejectsNativeOwnerAppearingAfterPlanBeforePageRead() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Delayed bookmark document", initials: "DelayedLocal")
        let page = MyDocumentPage(title: "Entry", pageKey: "entry", contentType: .markdown)
        let content = MyDocumentPageContent(pageId: page.id, content: "Private delayed content")
        page.pageContent = content
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        let window = Window(isSynchronized: false, isLinksWindow: false)
        window.pageManager = PageManager(
            id: window.id,
            currentCategoryName: DocumentCategory.bible.pageManagerKey
        )
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)
        let target = BookmarkNavigationTarget.generic(.init(
            moduleInitials: document.initials,
            key: page.pageKey,
            ordinalRange: nil
        ))
        let inventory = try controller.bookmarkNavigationInventory(for: target)
        let planned = try BibleReaderBookmarkNavigationCoordinator().plan(
            target: target,
            inventory: inventory
        )
        guard case .myDocument(let plan) = planned else {
            return XCTFail("Expected a My Documents bookmark plan")
        }

        try seedBibleAliasModule(
            named: "LateNativeBookmarkOwner",
            description: document.initials,
            in: modulePath
        )
        let moduleCacheURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/modules-conf.cache")
        if FileManager.default.fileExists(atPath: moduleCacheURL.path) {
            try FileManager.default.removeItem(at: moduleCacheURL)
        }
        controller.refreshInstalledModules()
        XCTAssertEqual(
            controller.registeredInstalledModuleInfo(named: document.initials)?.name,
            "LateNativeBookmarkOwner"
        )
        context.delete(page)
        context.delete(content)
        try context.save()

        let baselineCategory = controller.currentCategory
        let baselineModule = controller.activeModuleName
        let baselineGeneralBook = controller.activeGeneralBookModuleName
        let baselineGeneralBookKey = controller.currentGeneralBookKey
        let baselinePageCategory = window.pageManager?.currentCategoryName
        let baselinePageGeneralBook = window.pageManager?.generalBookDocument
        let baselinePageGeneralBookKey = window.pageManager?.generalBookKey
        let baselineScripts = scripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        XCTAssertThrowsError(try controller.commitMyDocumentBookmarkNavigation(plan)) { error in
            XCTAssertEqual(
                error as? BibleReaderBookmarkNavigationCommitFailure,
                .destinationChanged
            )
        }
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.activeModuleName, baselineModule)
        XCTAssertEqual(controller.activeGeneralBookModuleName, baselineGeneralBook)
        XCTAssertEqual(controller.currentGeneralBookKey, baselineGeneralBookKey)
        XCTAssertEqual(window.pageManager?.currentCategoryName, baselinePageCategory)
        XCTAssertEqual(window.pageManager?.generalBookDocument, baselinePageGeneralBook)
        XCTAssertEqual(window.pageManager?.generalBookKey, baselinePageGeneralBookKey)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(scripts().count, baselineScripts)
    }
}

/** Errors raised while writing the test-only RawLD fixture. */
private enum BookmarkNavigationFixtureError: Error {
    /// RawLD records exceeded their fixed index widths.
    case recordTooLarge
}

/**
 Writes a deterministic dictionary with exact lexical keys into an isolated SWORD root.

 - Parameters:
   - moduleName: Stable installed module initials.
   - entries: Exact key and structural OSIS body pairs.
   - modulePath: Existing temporary SWORD root.
 - Side effects: Writes one config plus RawLD data and index files.
 - Failure modes: Propagates filesystem errors and rejects records beyond RawLD index widths.
 */
private func writeBookmarkNavigationRawLDModule(
    named moduleName: String,
    entries: [(String, String)],
    in modulePath: String
) throws {
    let key = moduleName.lowercased()
    let root = URL(fileURLWithPath: modulePath, isDirectory: true)
    let modsDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
    let dataDirectory = root.appendingPathComponent(
        "modules/lexdict/rawld/\(key)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

    var data = Data()
    var index = Data()
    for (entryKey, xml) in entries {
        let record = Data("\(entryKey)\r\n\(xml)".utf8)
        guard record.count <= Int(UInt16.max), data.count <= Int(UInt32.max) else {
            throw BookmarkNavigationFixtureError.recordTooLarge
        }
        index.appendBookmarkNavigationLittleEndian(UInt32(data.count))
        index.appendBookmarkNavigationLittleEndian(UInt16(record.count))
        data.append(record)
        data.append(0x0A)
    }

    let prefix = dataDirectory.appendingPathComponent(key, isDirectory: false)
    try data.write(to: prefix.appendingPathExtension("dat"))
    try index.write(to: prefix.appendingPathExtension("idx"))
    try """
    [\(moduleName)]
    Description=Bookmark Navigation Dictionary
    Abbreviation=\(moduleName)
    Category=Lexicons / Dictionaries
    DataPath=./modules/lexdict/rawld/\(key)/\(key)
    ModDrv=RawLD
    SourceType=OSIS
    Encoding=UTF-8
    Lang=en
    """.write(
        to: modsDirectory.appendingPathComponent("\(key).conf", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )
}

/**
 Marks one temporary SWORD fixture as installed but locked.

 - Parameters:
   - moduleName: Exact fixture initials whose descriptor should require credentials.
   - modulePath: Existing temporary SWORD root.
 - Side effects: Appends an empty `CipherKey` to the module descriptor and removes a generated
   module cache when present so the next manager observes the authorization change.
 - Failure modes: Propagates descriptor read/write and cache-removal errors.
 */
private func lockBookmarkNavigationModule(named moduleName: String, in modulePath: String) throws {
    let moduleRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
    let configURL = moduleRoot.appendingPathComponent(
        "mods.d/\(moduleName.lowercased()).conf",
        isDirectory: false
    )
    var configuration = try String(contentsOf: configURL, encoding: .utf8)
    configuration.append("\nCipherKey=\n")
    try configuration.write(to: configURL, atomically: true, encoding: .utf8)
    let moduleCacheURL = moduleRoot.appendingPathComponent(
        "mods.d/modules-conf.cache",
        isDirectory: false
    )
    if FileManager.default.fileExists(atPath: moduleCacheURL.path) {
        try FileManager.default.removeItem(at: moduleCacheURL)
    }
}

private extension Data {
    /** Appends one RawLD index integer in little-endian order. */
    mutating func appendBookmarkNavigationLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
