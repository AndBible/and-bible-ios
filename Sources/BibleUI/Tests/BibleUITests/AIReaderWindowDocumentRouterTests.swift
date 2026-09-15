// AIReaderWindowDocumentRouterTests.swift -- Fail-closed AI reader document routing

import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/** Protects live-pane AI routing from bypassing reader module activation preflights. */
@MainActor
final class AIReaderWindowDocumentRouterTests: BibleUISwordFixtureTestCase {
    /**
     Routes a local full-name/case alias through the canonical combined-registry owner.

     - Setup: Registers one My Documents page and a live empty pane, then calls the production
       router directly with a case-varied display name rather than initials.
     - Expected: The exact page renders and observed/persisted state reports canonical initials.
     - Failure meaning: The Agent preflight and live router use different JSword lookup tiers, or
       the router reuses the alias for exact local storage reads.
     - Side effects: Writes in-memory workspace/My Documents graphs and emits one reader document.
     */
    func testMyDocumentFullNameAliasRoutesWithCanonicalInitials() async throws {
        let myDocumentContainer = try makeMyDocumentModelContainer()
        let myDocumentContext = myDocumentContainer.mainContext
        let document = MyDocument(name: "Router Local Full Name", initials: "RouterLocal")
        let page = MyDocumentPage(title: "Entry", pageKey: "entry", contentType: .markdown)
        let content = MyDocumentPageContent(pageId: page.id, content: "Canonical route")
        myDocumentContext.insert(document)
        myDocumentContext.insert(page)
        myDocumentContext.insert(content)
        page.pageContent = content
        page.document = document
        try myDocumentContext.save()

        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI local alias route")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let store = MyDocumentStore(modelContext: myDocumentContext)
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        controller.myDocumentStore = store
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        windowManager.registerController(controller, for: window.id)
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: store
        )

        let observed = try await router.setDocument(
            windowID: window.id,
            documentInitials: "router local full name",
            key: "entry"
        )

        XCTAssertEqual(observed.documentInitials, "RouterLocal")
        XCTAssertEqual(observed.currentKey, "entry")
        XCTAssertEqual(window.pageManager?.generalBookDocument, "RouterLocal")
        XCTAssertEqual(window.pageManager?.generalBookKey, "entry")
    }

    /**
     Verifies a locked Bible plus reference cannot navigate the currently active readable Bible.

     - Setup: Registers a ready KJV pane beside an installed encrypted Bible, then asks the
       production AI router to open the locked module at John 3:16.
     - Expected result: Routing throws the stable credential-free `NAVIGATION_FAILED` error before
       changing location, module, category, pane persistence, callbacks, or bridge emissions.
     - Failure meaning: An AI document request can ignore `.requiresUnlock` and apply its key to the
       previously active Bible, creating a partial cross-document navigation.
     - Side effects: Creates isolated in-memory workspace/My Documents stores and a temporary SWORD
       fixture removed by the inherited cleanup contract.
     */
    func testLockedBibleWithKeyFailsBeforeNavigationOrPaneMutation() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "LOCKED",
            description: "Locked AI router Bible",
            in: modulePath
        )
        let configURL = URL(fileURLWithPath: modulePath)
            .appendingPathComponent("mods.d/locked.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI router lock preflight")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)

        let (bridge, recordedScripts) = makeRecordingBridge()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        window.pageManager?.bibleDocument = "KJV"
        window.pageManager?.currentCategoryName = DocumentCategory.bible.pageManagerKey
        windowManager.registerController(controller, for: window.id)
        controller.bridgeDidSetClientReady(bridge)
        XCTAssertEqual(manager.moduleAccessState(named: "LOCKED"), .locked)

        let myDocumentContainer = try makeMyDocumentModelContainer()
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContainer.mainContext)
        )
        let baselineModule = controller.activeModuleName
        let baselineCategory = controller.currentCategory
        let baselineBook = controller.currentBook
        let baselineChapter = controller.currentChapter
        let baselineVerse = controller.currentVerse
        let baselineBibleDocument = window.pageManager?.bibleDocument
        let baselineCategoryName = window.pageManager?.currentCategoryName
        let baselineScriptCount = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        do {
            _ = try await router.setDocument(
                windowID: window.id,
                documentInitials: "LOCKED",
                key: "John.3.16"
            )
            XCTFail("Expected locked Bible routing to fail before key navigation.")
        } catch let error as BibleUIAgentDomainError {
            XCTAssertEqual(error.code, "NAVIGATION_FAILED")
            XCTAssertEqual(error.message, "The requested document could not be opened.")
        }

        XCTAssertEqual(controller.activeModuleName, baselineModule)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.currentBook, baselineBook)
        XCTAssertEqual(controller.currentChapter, baselineChapter)
        XCTAssertEqual(controller.currentVerse, baselineVerse)
        XCTAssertEqual(window.pageManager?.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(window.pageManager?.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(recordedScripts().count, baselineScriptCount)
    }

    /**
     Verifies locked commentary authorization runs before the AI route applies its requested key.

     - Setup: Registers a ready KJV pane beside an installed plaintext-backed but locked commentary,
       then asks the production AI router to open that commentary at John 3:16.
     - Expected result: Routing throws `NAVIGATION_FAILED` before changing the readable Bible's
       location, active commentary/category, `PageManager`, persistence count, or bridge emissions.
     - Failure meaning: Commentary routing can navigate the previously active source first and only
       discover afterward that the requested document was not authorized.
     - Side effects: Creates isolated in-memory workspace/My Documents stores and one temporary
       SWORD fixture removed by inherited teardown.
     - Failure modes: Fixture, SwiftData, or manager setup failures throw through XCTest.
     */
    func testLockedCommentaryWithKeyFailsBeforeNavigationOrPaneMutation() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(named: "LockedComm", in: modulePath)
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/lockedcomm.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI commentary lock preflight")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)

        let (bridge, recordedScripts) = makeRecordingBridge()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        window.pageManager?.bibleDocument = "KJV"
        window.pageManager?.currentCategoryName = DocumentCategory.bible.pageManagerKey
        windowManager.registerController(controller, for: window.id)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        XCTAssertEqual(manager.moduleAccessState(named: "LockedComm"), .locked)

        let myDocumentContainer = try makeMyDocumentModelContainer()
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContainer.mainContext)
        )
        let baselineModule = controller.activeModuleName
        let baselineCommentary = controller.activeCommentaryModuleName
        let baselineCategory = controller.currentCategory
        let baselineBook = controller.currentBook
        let baselineChapter = controller.currentChapter
        let baselineVerse = controller.currentVerse
        let baselineBibleDocument = window.pageManager?.bibleDocument
        let baselineCommentaryDocument = window.pageManager?.commentaryDocument
        let baselineCategoryName = window.pageManager?.currentCategoryName
        let baselineScriptCount = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        do {
            _ = try await router.setDocument(
                windowID: window.id,
                documentInitials: "LockedComm",
                key: "John.3.16"
            )
            XCTFail("Expected locked commentary routing to fail before key navigation.")
        } catch let error as BibleUIAgentDomainError {
            XCTAssertEqual(error.code, "NAVIGATION_FAILED")
            XCTAssertEqual(error.message, "The requested document could not be opened.")
        }

        XCTAssertEqual(controller.activeModuleName, baselineModule)
        XCTAssertEqual(controller.activeCommentaryModuleName, baselineCommentary)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.currentBook, baselineBook)
        XCTAssertEqual(controller.currentChapter, baselineChapter)
        XCTAssertEqual(controller.currentVerse, baselineVerse)
        XCTAssertEqual(window.pageManager?.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(window.pageManager?.commentaryDocument, baselineCommentaryDocument)
        XCTAssertEqual(window.pageManager?.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(recordedScripts().count, baselineScriptCount)
    }

    /**
     Preflights invalid optional keys for every Android-routable installed document category.

     - Setup: Registers readable Bible, commentary, dictionary, general-book, and map fixtures in one
       live KJV pane, then requests an invalid reference/key for each through the production router.
     - Expected: Every request reports `KEY_NOT_FOUND` before changing any category-owned handle,
       key/reference, PageManager field, persistence count, or Vue emission.
     - Failure meaning: `setDocument` switches or persists a requested source before proving its
       optional key, leaving a partially changed window when the second navigation step fails.
     - Side effects: Writes inherited temporary SWORD fixtures plus isolated in-memory workspace and
       My Documents graphs.
     */
    func testInvalidInstalledKeysFailAcrossAndroidCategoryMatrixBeforeAnyPaneMutation() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(named: "RouterCommentary", in: modulePath)
        try seedEmptyRawDictionaryModule(named: "RouterDictionary", in: modulePath)
        try seedEmptyRawGeneralBookModule(named: "RouterGeneralBook", in: modulePath)
        try seedEmptyRawMapModule(named: "RouterMap", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI key preflight matrix")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        window.pageManager?.bibleDocument = "KJV"
        window.pageManager?.currentCategoryName = DocumentCategory.bible.pageManagerKey
        windowManager.registerController(controller, for: window.id)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)

        let myDocumentContainer = try makeMyDocumentModelContainer()
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContainer.mainContext)
        )
        let baselineModule = controller.activeModuleName
        let baselineCommentary = controller.activeCommentaryModuleName
        let baselineDictionary = controller.activeDictionaryModuleName
        let baselineGeneralBook = controller.activeGeneralBookModuleName
        let baselineMap = controller.activeMapModuleName
        let baselineDictionaryKey = controller.currentDictionaryKey
        let baselineGeneralBookKey = controller.currentGeneralBookKey
        let baselineMapKey = controller.currentMapKey
        let baselineCategory = controller.currentCategory
        let baselineBook = controller.currentBook
        let baselineChapter = controller.currentChapter
        let baselineVerse = controller.currentVerse
        let pageManager = try XCTUnwrap(window.pageManager)
        let baselinePageCategory = pageManager.currentCategoryName
        let baselinePageBible = pageManager.bibleDocument
        let baselinePageCommentary = pageManager.commentaryDocument
        let baselinePageDictionary = pageManager.dictionaryDocument
        let baselinePageDictionaryKey = pageManager.dictionaryKey
        let baselinePageGeneralBook = pageManager.generalBookDocument
        let baselinePageGeneralBookKey = pageManager.generalBookKey
        let baselinePageMap = pageManager.mapDocument
        let baselinePageMapKey = pageManager.mapKey
        let baselineScripts = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }
        let requests = [
            ("KJV", "Gen.999.1"),
            ("RouterCommentary", "Gen.999.1"),
            ("RouterDictionary", "missing-dictionary-key"),
            ("RouterGeneralBook", "missing-general-book-key"),
            ("RouterMap", "missing-map-key"),
        ]

        for (initials, key) in requests {
            do {
                _ = try await router.setDocument(
                    windowID: window.id,
                    documentInitials: initials,
                    key: key
                )
                XCTFail("Expected optional key preflight to reject \(initials).")
            } catch let error as BibleUIAgentDomainError {
                XCTAssertEqual(error.code, "KEY_NOT_FOUND", initials)
            }

            XCTAssertEqual(controller.activeModuleName, baselineModule, initials)
            XCTAssertEqual(controller.activeCommentaryModuleName, baselineCommentary, initials)
            XCTAssertEqual(controller.activeDictionaryModuleName, baselineDictionary, initials)
            XCTAssertEqual(controller.activeGeneralBookModuleName, baselineGeneralBook, initials)
            XCTAssertEqual(controller.activeMapModuleName, baselineMap, initials)
            XCTAssertEqual(controller.currentDictionaryKey, baselineDictionaryKey, initials)
            XCTAssertEqual(controller.currentGeneralBookKey, baselineGeneralBookKey, initials)
            XCTAssertEqual(controller.currentMapKey, baselineMapKey, initials)
            XCTAssertEqual(controller.currentCategory, baselineCategory, initials)
            XCTAssertEqual(controller.currentBook, baselineBook, initials)
            XCTAssertEqual(controller.currentChapter, baselineChapter, initials)
            XCTAssertEqual(controller.currentVerse, baselineVerse, initials)
            XCTAssertEqual(pageManager.currentCategoryName, baselinePageCategory, initials)
            XCTAssertEqual(pageManager.bibleDocument, baselinePageBible, initials)
            XCTAssertEqual(pageManager.commentaryDocument, baselinePageCommentary, initials)
            XCTAssertEqual(pageManager.dictionaryDocument, baselinePageDictionary, initials)
            XCTAssertEqual(pageManager.dictionaryKey, baselinePageDictionaryKey, initials)
            XCTAssertEqual(pageManager.generalBookDocument, baselinePageGeneralBook, initials)
            XCTAssertEqual(pageManager.generalBookKey, baselinePageGeneralBookKey, initials)
            XCTAssertEqual(pageManager.mapDocument, baselinePageMap, initials)
            XCTAssertEqual(pageManager.mapKey, baselinePageMapKey, initials)
            XCTAssertEqual(persistCount, 0, initials)
            XCTAssertEqual(recordedScripts().count, baselineScripts, initials)
        }
    }

    /** Every asynchronously prepared installed entry settles before the AI route reads state back. */
    func testInstalledAuxiliaryCategoryMatrixReturnsCommittedExactKeys() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let targets = [
            ("RouterLiveDictionary", "Lexicons / Dictionaries", DocumentCategory.dictionary),
            ("RouterLiveBook", "Generic Books", DocumentCategory.generalBook),
            ("RouterLiveMap", "Maps", DocumentCategory.map),
        ]
        for (initials, category, _) in targets {
            try writeAIReaderRawLDModule(
                named: initials,
                category: category,
                entries: [
                    ("FIRST", "<div><p>\(initials) first content.</p></div>"),
                    ("TARGET", "<div><p>\(initials) target content.</p></div>"),
                ],
                in: modulePath
            )
        }
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        for (initials, _, _) in targets {
            let module = try XCTUnwrap(manager.module(named: initials))
            XCTAssertEqual(try module.loadAllKeys(), ["FIRST", "TARGET"], initials)
        }
        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI auxiliary settlement")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        windowManager.registerController(controller, for: window.id)
        let readinessBoundary = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: readinessBoundary
        )
        let myDocumentContainer = try makeMyDocumentModelContainer()
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContainer.mainContext)
        )

        for (initials, _, category) in targets {
            let boundary = scripts().count
            let observed = try await router.setDocument(
                windowID: window.id,
                documentInitials: initials,
                key: "TARGET"
            )
            let emissions = Array(scripts().dropFirst(boundary))
            let document = try XCTUnwrap(
                bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
            )

            XCTAssertEqual(observed.documentInitials, initials)
            XCTAssertEqual(observed.currentKey, "TARGET")
            XCTAssertEqual(controller.currentCategory, category)
            XCTAssertEqual(document["bookInitials"] as? String, initials)
            XCTAssertEqual(document["key"] as? String, "TARGET")
        }
    }

    /** EPUB href resolution stays off-main and returns the worker-canonicalized selected key. */
    func testEpubRouteReturnsCanonicalKeyAfterPreparedCandidateActivation() async throws {
        let archiveURL = try makeDefaultLibraryEpubArchiveFixture(
            title: "AI Router EPUB \(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let reader = try XCTUnwrap(EpubReader(identifier: identifier))
        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI EPUB selection")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        windowManager.registerController(controller, for: window.id)
        controller.bridgeDidSetClientReady(bridge)
        let myDocumentContainer = try makeMyDocumentModelContainer()
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContainer.mainContext)
        )
        let boundary = scripts().count

        let observed = try await router.setDocument(
            windowID: window.id,
            documentInitials: reader.initials,
            key: "OPS/text/second.xhtml#target"
        )
        let emissions = Array(scripts().dropFirst(boundary))
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )

        XCTAssertEqual(observed.documentInitials, reader.initials)
        XCTAssertEqual(observed.currentKey, "2")
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
        XCTAssertEqual(document["key"] as? String, "2")

        let invalidBoundary = scripts().count
        do {
            _ = try await router.setDocument(
                windowID: window.id,
                documentInitials: reader.initials,
                key: "OPS/text/missing.xhtml"
            )
            XCTFail("Expected the missing EPUB href to settle without candidate activation.")
        } catch let error as BibleUIAgentDomainError {
            XCTAssertEqual(error.code, "KEY_NOT_FOUND")
        }
        XCTAssertEqual(controller.activeEpubIdentifier, identifier)
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
        XCTAssertFalse(scripts().dropFirst(invalidBoundary).contains {
            $0.contains("add_documents")
        })
    }

    /** An older candidate EPUB cannot activate after a newer AI EPUB route supersedes it. */
    func testSupersededEpubCandidateCannotActivateOverNewerRoute() async throws {
        let firstArchive = try makeDefaultLibraryEpubArchiveFixture(
            title: "AI Router EPUB A \(UUID().uuidString)"
        )
        let secondArchive = try makeDefaultLibraryEpubArchiveFixture(
            title: "AI Router EPUB B \(UUID().uuidString)"
        )
        defer {
            try? FileManager.default.removeItem(at: firstArchive.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondArchive.deletingLastPathComponent())
        }
        let firstIdentifier = try installDefaultLibraryEpubFixture(epubURL: firstArchive)
        let secondIdentifier = try installDefaultLibraryEpubFixture(epubURL: secondArchive)
        defer {
            try? EpubReader.delete(identifier: firstIdentifier)
            try? EpubReader.delete(identifier: secondIdentifier)
        }
        let firstReader = try XCTUnwrap(EpubReader(identifier: firstIdentifier))
        let secondReader = try XCTUnwrap(EpubReader(identifier: secondIdentifier))
        let firstCaptureEntered = expectation(description: "first EPUB candidate capture entered")
        let releaseFirstCapture = DispatchSemaphore(value: 0)
        let blockedFirstCapture = AIReaderLockedValue(false)
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .sourceCapture, key.family.rawValue == "epub" else { return }
                let shouldBlock = blockedFirstCapture.withValue { blocked -> Bool in
                    guard !blocked else { return false }
                    blocked = true
                    return true
                }
                guard shouldBlock else { return }
                firstCaptureEntered.fulfill()
                releaseFirstCapture.wait()
            }
        )
        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI EPUB supersession")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let manager = try XCTUnwrap(
            SwordManager(modulePath: try makeTemporarySwordFixturePath())
        )
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        windowManager.registerController(controller, for: window.id)
        let myDocumentContainer = try makeMyDocumentModelContainer()
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContainer.mainContext)
        )

        let firstRoute = Task { @MainActor in
            do {
                _ = try await router.setDocument(
                    windowID: window.id,
                    documentInitials: firstReader.initials,
                    key: "1"
                )
                return nil as BibleUIAgentDomainError?
            } catch {
                return error as? BibleUIAgentDomainError
            }
        }
        await fulfillment(of: [firstCaptureEntered], timeout: 3)
        let secondRoute = Task { @MainActor in
            try await router.setDocument(
                windowID: window.id,
                documentInitials: secondReader.initials,
                key: "2"
            )
        }
        let firstError = await firstRoute.value
        releaseFirstCapture.signal()
        let secondResult = try await secondRoute.value

        XCTAssertEqual(firstError?.code, "NAVIGATION_FAILED")
        XCTAssertEqual(secondResult.documentInitials, secondReader.initials)
        XCTAssertEqual(secondResult.currentKey, "2")
        XCTAssertEqual(controller.activeEpubIdentifier, secondIdentifier)
        XCTAssertEqual(controller.currentGeneralBookKey, "2")
        XCTAssertEqual(window.pageManager?.generalBookDocument, secondReader.initials)
        XCTAssertEqual(window.pageManager?.generalBookKey, "2")
    }

    /** A cancelled installed-entry route settles and cannot report its uncommitted key. */
    func testCancelledDictionaryPreparationReturnsFailureWithoutPublishingSelection() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeAIReaderRawLDModule(
            named: "RouterCancelledDictionary",
            category: "Lexicons / Dictionaries",
            entries: [
                ("FIRST", "<div><p>Initial dictionary content.</p></div>"),
                ("TARGET", "<div><p>Cancelled dictionary content.</p></div>"),
            ],
            in: modulePath
        )
        let captureEntered = expectation(description: "dictionary source capture entered")
        let releaseCapture = DispatchSemaphore(value: 0)
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .sourceCapture,
                      key.contentIdentity == BibleReaderPreparationExactText("TARGET") else { return }
                captureEntered.fulfill()
                releaseCapture.wait()
            }
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let dictionary = try XCTUnwrap(manager.module(named: "RouterCancelledDictionary"))
        XCTAssertEqual(try dictionary.loadAllKeys(), ["FIRST", "TARGET"])
        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI cancelled dictionary")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        windowManager.registerController(controller, for: window.id)
        let readinessBoundary = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: readinessBoundary
        )
        let myDocumentContainer = try makeMyDocumentModelContainer()
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContainer.mainContext)
        )
        let boundary = scripts().count

        let route = Task { @MainActor in
            do {
                _ = try await router.setDocument(
                    windowID: window.id,
                    documentInitials: "RouterCancelledDictionary",
                    key: "TARGET"
                )
                return nil as BibleUIAgentDomainError?
            } catch {
                return error as? BibleUIAgentDomainError
            }
        }
        await fulfillment(of: [captureEntered], timeout: 3)
        coordinator.cancelAll()
        let error = await route.value
        releaseCapture.signal()

        XCTAssertEqual(error?.code, "NAVIGATION_FAILED")
        XCTAssertNil(controller.currentDictionaryKey)
        XCTAssertNil(window.pageManager?.dictionaryKey)
        XCTAssertFalse(scripts().dropFirst(boundary).contains { $0.contains("add_documents") })
    }

    /** A superseded local-page route settles without selecting over the newer AI request. */
    func testSupersededMyDocumentRouteCannotOverwriteNewerPageSelection() async throws {
        let myDocumentContainer = try makeMyDocumentModelContainer()
        let myDocumentContext = myDocumentContainer.mainContext
        let document = MyDocument(name: "Router supersession", initials: "RouterSupersede")
        let firstPage = MyDocumentPage(title: "First", pageKey: "first", contentType: .markdown)
        let secondPage = MyDocumentPage(title: "Second", pageKey: "second", contentType: .markdown)
        let firstContent = MyDocumentPageContent(pageId: firstPage.id, content: "First body")
        let secondContent = MyDocumentPageContent(pageId: secondPage.id, content: "Second body")
        myDocumentContext.insert(document)
        myDocumentContext.insert(firstPage)
        myDocumentContext.insert(secondPage)
        myDocumentContext.insert(firstContent)
        myDocumentContext.insert(secondContent)
        firstPage.pageContent = firstContent
        secondPage.pageContent = secondContent
        firstPage.document = document
        secondPage.document = document
        try myDocumentContext.save()

        let firstCaptureEntered = expectation(description: "first local page capture entered")
        let releaseFirstCapture = DispatchSemaphore(value: 0)
        let blockedFirstCapture = AIReaderLockedValue(false)
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .sourceCapture, key.family.rawValue == "my-document" else { return }
                let shouldBlock = blockedFirstCapture.withValue { blocked -> Bool in
                    guard !blocked else { return false }
                    blocked = true
                    return true
                }
                guard shouldBlock else { return }
                firstCaptureEntered.fulfill()
                releaseFirstCapture.wait()
            }
        )
        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI local supersession")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let store = MyDocumentStore(modelContext: myDocumentContext)
        let manager = try XCTUnwrap(
            SwordManager(modulePath: try makeTemporarySwordFixturePath())
        )
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.myDocumentStore = store
        self.retainReaderWindowGraph(window)
        controller.activeWindow = window
        windowManager.registerController(controller, for: window.id)
        let router = AIReaderWindowDocumentRouter(windowManager: windowManager, myDocumentStore: store)

        let firstRoute = Task { @MainActor in
            do {
                _ = try await router.setDocument(
                    windowID: window.id,
                    documentInitials: "RouterSupersede",
                    key: "first"
                )
                return nil as BibleUIAgentDomainError?
            } catch {
                return error as? BibleUIAgentDomainError
            }
        }
        await fulfillment(of: [firstCaptureEntered], timeout: 3)
        let secondRoute = Task { @MainActor in
            try await router.setDocument(
                windowID: window.id,
                documentInitials: "RouterSupersede",
                key: "second"
            )
        }
        let firstError = await firstRoute.value
        releaseFirstCapture.signal()
        let secondResult = try await secondRoute.value

        XCTAssertEqual(firstError?.code, "NAVIGATION_FAILED")
        XCTAssertEqual(secondResult.documentInitials, "RouterSupersede")
        XCTAssertEqual(secondResult.currentKey, "second")
        XCTAssertEqual(controller.currentGeneralBookKey, "second")
        XCTAssertEqual(window.pageManager?.generalBookKey, "second")
    }
}

/** Test-only lock for coordinating source capture without blocking the main actor. */
private final class AIReaderLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&storage)
    }
}

/** Writes exact source-ordered RawLD entries used by the AI router's installed-source contracts. */
private func writeAIReaderRawLDModule(
    named moduleName: String,
    category: String,
    entries: [(key: String, xml: String)],
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
    for entry in entries {
        let record = Data("\(entry.key)\r\n\(entry.xml)".utf8)
        guard data.count <= Int(UInt32.max),
              record.count <= Int(UInt16.max) else {
            throw AIReaderFixtureError.recordTooLarge
        }
        index.appendAIReaderLittleEndian(UInt32(data.count))
        index.appendAIReaderLittleEndian(UInt16(record.count))
        data.append(record)
        data.append(0x0A)
    }
    let prefix = dataDirectory.appendingPathComponent(key, isDirectory: false)
    try data.write(to: prefix.appendingPathExtension("dat"))
    try index.write(to: prefix.appendingPathExtension("idx"))
    try """
    [\(moduleName)]
    Description=\(moduleName)
    Abbreviation=\(moduleName)
    Category=\(category)
    DataPath=./modules/lexdict/rawld/\(key)/\(key)
    ModDrv=RawLD
    SourceType=OSIS
    Encoding=UTF-8
    Lang=en
    Versification=KJV
    """.write(
        to: modsDirectory.appendingPathComponent("\(key).conf", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )
}

private enum AIReaderFixtureError: Error {
    case recordTooLarge
}

private extension Data {
    mutating func appendAIReaderLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
