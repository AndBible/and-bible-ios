import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
import SwordKit
import BibleView

/** Behavioral coverage for Android's per-category reader default preferences. */
@MainActor
final class BibleReaderDocumentDefaultPreferenceTests: BibleUISwordFixtureTestCase {
    /** Toolbar request keys keep the exact My Documents UUID across equivalent initials. */
    func testMyDocumentToolbarRequestIdentityRetainsExactOwner() {
        let commonID = UUID()
        let first = BibleReaderMyDocumentPreparationRequestIdentity(
            requestedInitials: "SameInitials",
            requestedKey: "first",
            selectedOrdinalRange: nil,
            expectedFragment: nil,
            expectedDocumentID: commonID
        )
        let same = BibleReaderMyDocumentPreparationRequestIdentity(
            requestedInitials: "SameInitials",
            requestedKey: "first",
            selectedOrdinalRange: nil,
            expectedFragment: nil,
            expectedDocumentID: commonID
        )
        let replacement = BibleReaderMyDocumentPreparationRequestIdentity(
            requestedInitials: "SameInitials",
            requestedKey: "first",
            selectedOrdinalRange: nil,
            expectedFragment: nil,
            expectedDocumentID: UUID()
        )

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, replacement)
    }

    /** Category keys retain Android BookCategory spelling, including plural MAPS. */
    func testSettingKeysUseExactAndroidBookCategoryNames() {
        XCTAssertEqual(BibleReaderDocumentDefaultPreference.settingKey(for: .bible), "default-BIBLE")
        XCTAssertEqual(
            BibleReaderDocumentDefaultPreference.settingKey(for: .commentary),
            "default-COMMENTARY"
        )
        XCTAssertEqual(
            BibleReaderDocumentDefaultPreference.settingKey(for: .dictionary),
            "default-DICTIONARY"
        )
        XCTAssertEqual(
            BibleReaderDocumentDefaultPreference.settingKey(for: .generalBook),
            "default-GENERAL_BOOK"
        )
        XCTAssertEqual(BibleReaderDocumentDefaultPreference.settingKey(for: .map), "default-MAPS")
        XCTAssertNil(BibleReaderDocumentDefaultPreference.settingKey(for: .glossary))
    }

    /** Every installed reader category resolves its registered saved owner before fallback. */
    func testMissingSelectionsResolveSavedRegisteredOwnersAcrossInstalledCategories() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(named: "SavedBible", description: "Saved Bible", in: modulePath)
        try seedEmptyRawCommentaryModule(named: "SavedCommentary", in: modulePath)
        try seedEmptyRawDictionaryModule(named: "SavedDictionary", in: modulePath)
        try seedEmptyRawGeneralBookModule(named: "SavedGeneralBook", in: modulePath)
        try seedEmptyRawMapModule(named: "SavedMap", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let resolver = BibleReaderInstalledModuleResolver(swordManager: manager, sqliteModules: [])
        let context = ModelContext(try makeWorkspaceModelContainer())
        let settingsStore = SettingsStore(modelContext: context)
        let expected: [(ModuleCategory, String)] = [
            (.bible, "SavedBible"),
            (.commentary, "SavedCommentary"),
            (.dictionary, "SavedDictionary"),
            (.generalBook, "SavedGeneralBook"),
            (.map, "SavedMap"),
        ]
        for (category, name) in expected {
            let key = try XCTUnwrap(BibleReaderDocumentDefaultPreference.settingKey(for: category))
            settingsStore.setString(key, value: name)
        }

        for (category, name) in expected {
            let selection = BibleReaderDocumentDefaultPreference.replacement(
                forMissing: "REMOVED",
                category: category,
                settingsStore: settingsStore,
                resolver: resolver
            )
            XCTAssertEqual(
                selection?.installedInfo?.name,
                name,
                "Expected the registered saved owner for \(category.rawValue)"
            )
            XCTAssertNotNil(
                selection?.installedReadableSource,
                "Expected an admitted unlocked source handle for \(category.rawValue)"
            )
        }
    }

    /** General-book defaults resolve EPUB and My Documents through the complete shared registry. */
    func testGeneralBookSavedDefaultsResolveEpubAndMyDocumentsOwners() throws {
        let archiveURL = try makeDefaultLibraryEpubArchiveFixture(
            title: "Default owner \(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let identifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: identifier) }
        let epub = try XCTUnwrap(EpubReader(identifier: identifier))

        let documentContainer = try makeMyDocumentModelContainer()
        let documentContext = ModelContext(documentContainer)
        let document = MyDocument(
            name: "Saved local default",
            initials: "SavedLocalDefault\(UUID().uuidString)"
        )
        documentContext.insert(document)
        try documentContext.save()

        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let resolver = BibleReaderInstalledModuleResolver(swordManager: manager, sqliteModules: [])
        let authorizationService = BibleReaderDocumentAuthorizationService(
            swordManager: manager,
            sqliteModules: [],
            myDocumentStore: MyDocumentStore(modelContext: documentContext),
            activeEpubReader: epub,
            resolveCommentaryReference: { _ in nil }
        )
        let settingsContext = ModelContext(try makeWorkspaceModelContainer())
        let settingsStore = SettingsStore(modelContext: settingsContext)

        settingsStore.setString("default-GENERAL_BOOK", value: epub.initials)
        let epubSelection = BibleReaderDocumentDefaultPreference.generalBookReplacement(
            forMissing: "RemovedGeneralBook",
            settingsStore: settingsStore,
            authorizationService: authorizationService,
            resolver: resolver,
            preferredEpub: epub
        )
        guard let epubSelection,
              case .local(.epub(let selectedEpub)) = epubSelection else {
            return XCTFail("Expected exact saved EPUB owner")
        }
        XCTAssertEqual(selectedEpub.identifier, identifier)

        settingsStore.setString("default-GENERAL_BOOK", value: document.initials)
        let myDocumentSelection = BibleReaderDocumentDefaultPreference.generalBookReplacement(
            forMissing: "RemovedGeneralBook",
            settingsStore: settingsStore,
            authorizationService: authorizationService,
            resolver: resolver,
            preferredEpub: epub
        )
        guard let myDocumentSelection,
              case .local(.myDocument(let selectedDocument)) = myDocumentSelection else {
            return XCTFail("Expected exact saved My Documents owner")
        }
        XCTAssertEqual(selectedDocument.id, document.id)
    }

    /** A locked installed owner wins over a valid colliding My Documents registration. */
    func testLockedInstalledOwnerPrecedesConflictingLocalRegistration() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawGeneralBookModule(named: "InstalledGeneralBook", in: modulePath)
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/installedgeneralbook.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let resolver = BibleReaderInstalledModuleResolver(swordManager: manager, sqliteModules: [])
        XCTAssertEqual(manager.moduleAccessState(named: "InstalledGeneralBook"), .locked)

        let documentContext = ModelContext(try makeMyDocumentModelContainer())
        let conflictingDocument = MyDocument(
            name: "Conflicting local document",
            initials: "InstalledGeneralBook"
        )
        documentContext.insert(conflictingDocument)
        try documentContext.save()
        let localStore = MyDocumentStore(modelContext: documentContext)
        XCTAssertEqual(
            try localStore.documentsInRegistrationOrder().map(\.id),
            [conflictingDocument.id],
            "The local collision must be a valid independently enumerable registration."
        )
        let authorizationService = BibleReaderDocumentAuthorizationService(
            swordManager: manager,
            sqliteModules: [],
            myDocumentStore: localStore,
            activeEpubReader: nil,
            resolveCommentaryReference: { _ in nil }
        )

        let owner = authorizationService.owner(
            named: "InstalledGeneralBook",
            resolver: resolver
        )
        guard case .installed(let info, let readableSource)? = owner else {
            return XCTFail("Expected installed owner without local metadata capture")
        }
        XCTAssertEqual(info.name, "InstalledGeneralBook")
        XCTAssertNil(readableSource, "The locked native owner must reserve identity without content.")
    }

    /** Only successful toolbar switches write defaults; full-picker-style and failed switches do not. */
    func testToolbarSwitchWritesDefaultWithoutChangingOrdinarySwitchSemantics() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(named: "ToolbarBible", description: "Toolbar Bible", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let context = ModelContext(try makeWorkspaceModelContainer())
        let settingsStore = SettingsStore(modelContext: context)
        let controller = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.settingsStore = settingsStore
        controller.restoreSavedPosition()

        XCTAssertEqual(controller.switchBibleDocument(to: "ToolbarBible"), .switched)
        XCTAssertNil(settingsStore.getString("default-BIBLE"))

        XCTAssertEqual(controller.switchBibleToolbarDocument(to: "KJV"), .switched)
        XCTAssertEqual(settingsStore.getString("default-BIBLE"), "KJV")

        XCTAssertEqual(controller.switchBibleToolbarDocument(to: "MISSING"), .unavailable)
        XCTAssertEqual(settingsStore.getString("default-BIBLE"), "KJV")
    }

    /**
     EPUB and My Documents toolbar rows write the shared general-book default only after selection.

     The EPUB path commits synchronously through its exact installed-library generation. The My
     Documents path waits for the real preparation owner to commit the exact first page before the
     setting becomes visible.
     */
    func testLocalGeneralBookToolbarSelectionsWriteAcceptedDefault() async throws {
        let archiveURL = try makeDefaultLibraryEpubArchiveFixture(
            title: "Toolbar EPUB \(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: archiveURL.deletingLastPathComponent()) }
        let epubIdentifier = try installDefaultLibraryEpubFixture(epubURL: archiveURL)
        defer { try? EpubReader.delete(identifier: epubIdentifier) }
        let epub = try XCTUnwrap(EpubReader(identifier: epubIdentifier))

        let documentContainer = try makeMyDocumentModelContainer()
        let documentContext = ModelContext(documentContainer)
        let identitySuffix = UUID().uuidString
        let composedInitials = "ToolbarCaf\u{00E9}\(identitySuffix)"
        let decomposedInitials = "ToolbarCafe\u{0301}\(identitySuffix)"
        let composedRetainedKey = "Caf\u{00E9}-retained"
        let decomposedRetainedKey = "Cafe\u{0301}-retained"
        XCTAssertEqual(composedInitials, decomposedInitials)
        XCTAssertFalse(composedInitials.utf16.elementsEqual(decomposedInitials.utf16))
        XCTAssertEqual(composedRetainedKey, decomposedRetainedKey)
        XCTAssertFalse(composedRetainedKey.utf16.elementsEqual(decomposedRetainedKey.utf16))
        let document = MyDocument(
            name: "Toolbar document",
            initials: decomposedInitials
        )
        let fallbackPage = MyDocumentPage(
            title: "Fallback first",
            pageKey: "fallback-first",
            orderNumber: 0
        )
        let fallbackContent = MyDocumentPageContent(
            pageId: fallbackPage.id,
            content: "Fallback first-page body"
        )
        let canonicallyEquivalentPage = MyDocumentPage(
            title: "Canonical sibling",
            pageKey: composedRetainedKey,
            orderNumber: 1
        )
        let canonicallyEquivalentContent = MyDocumentPageContent(
            pageId: canonicallyEquivalentPage.id,
            content: "Wrong canonically equivalent page body"
        )
        let exactRetainedPage = MyDocumentPage(
            title: "Exact retained page",
            pageKey: decomposedRetainedKey,
            orderNumber: 2
        )
        let exactRetainedContent = MyDocumentPageContent(
            pageId: exactRetainedPage.id,
            content: "Exact retained-key toolbar body"
        )
        let javaDistinctDocument = MyDocument(
            name: "Java-distinct toolbar sibling",
            initials: composedInitials
        )
        let javaDistinctPage = MyDocumentPage(
            title: "Sibling page",
            pageKey: decomposedRetainedKey,
            orderNumber: 0
        )
        let javaDistinctContent = MyDocumentPageContent(
            pageId: javaDistinctPage.id,
            content: "Wrong Java-distinct document body"
        )
        documentContext.insert(document)
        documentContext.insert(fallbackPage)
        documentContext.insert(fallbackContent)
        documentContext.insert(canonicallyEquivalentPage)
        documentContext.insert(canonicallyEquivalentContent)
        documentContext.insert(exactRetainedPage)
        documentContext.insert(exactRetainedContent)
        documentContext.insert(javaDistinctDocument)
        documentContext.insert(javaDistinctPage)
        documentContext.insert(javaDistinctContent)
        fallbackPage.document = document
        fallbackPage.pageContent = fallbackContent
        canonicallyEquivalentPage.document = document
        canonicallyEquivalentPage.pageContent = canonicallyEquivalentContent
        exactRetainedPage.document = document
        exactRetainedPage.pageContent = exactRetainedContent
        javaDistinctPage.document = javaDistinctDocument
        javaDistinctPage.pageContent = javaDistinctContent
        fallbackContent.page = fallbackPage
        canonicallyEquivalentContent.page = canonicallyEquivalentPage
        exactRetainedContent.page = exactRetainedPage
        javaDistinctContent.page = javaDistinctPage
        document.pages = [fallbackPage, canonicallyEquivalentPage, exactRetainedPage]
        javaDistinctDocument.pages = [javaDistinctPage]
        try documentContext.save()

        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let settingsContext = ModelContext(try makeWorkspaceModelContainer())
        let settingsStore = SettingsStore(modelContext: settingsContext)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = settingsStore
        controller.myDocumentStore = MyDocumentStore(modelContext: documentContext)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.restoreSavedPosition()

        let quickSelections = try XCTUnwrap(
            controller.commentaryQuickDocumentSelections(includeAuxiliaryDocuments: true)
        )
        XCTAssertTrue(quickSelections.contains {
            guard case .epub(let identifier, _, let initials, _, _) = $0 else { return false }
            return identifier == epubIdentifier && initials == epub.initials
        })
        XCTAssertTrue(quickSelections.contains {
            guard case .myDocument(let id, let initials, _, _) = $0 else { return false }
            return id == document.id && initials == document.initials
        })

        XCTAssertFalse(
            controller.switchEpubToolbarDocument(
                identifier: epubIdentifier,
                expectedGenerationIdentifier: "stale-\(epub.generationIdentifier)",
                expectedInitials: epub.initials
            )
        )
        XCTAssertNil(settingsStore.getString("default-GENERAL_BOOK"))
        XCTAssertNil(controller.activeEpubIdentifier)

        XCTAssertTrue(
            controller.switchEpubToolbarDocument(
                identifier: epubIdentifier,
                expectedGenerationIdentifier: epub.generationIdentifier,
                expectedInitials: epub.initials
            )
        )
        XCTAssertEqual(settingsStore.getString("default-GENERAL_BOOK"), epub.initials)
        XCTAssertFalse(
            controller.switchMyDocumentToolbarDocument(
                expectedID: javaDistinctDocument.id,
                initials: document.initials
            )
        )
        XCTAssertEqual(settingsStore.getString("default-GENERAL_BOOK"), epub.initials)

        controller.bridgeDidSetClientReady(bridge)
        pageManager.generalBookKey = decomposedRetainedKey
        let boundary = scripts().count
        XCTAssertTrue(
            controller.switchMyDocumentToolbarDocument(
                expectedID: document.id,
                initials: document.initials
            )
        )
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )

        let committedDefault = try XCTUnwrap(
            settingsStore.getString("default-GENERAL_BOOK")
        )
        let committedModule = try XCTUnwrap(controller.activeGeneralBookModuleName)
        let committedKey = try XCTUnwrap(controller.currentGeneralBookKey)
        XCTAssertTrue(SwordJavaStringIdentity.equals(committedDefault, decomposedInitials))
        XCTAssertFalse(SwordJavaStringIdentity.equals(committedDefault, composedInitials))
        XCTAssertTrue(SwordJavaStringIdentity.equals(committedModule, decomposedInitials))
        XCTAssertFalse(SwordJavaStringIdentity.equals(committedModule, composedInitials))
        XCTAssertTrue(SwordJavaStringIdentity.equals(committedKey, decomposedRetainedKey))
        XCTAssertFalse(SwordJavaStringIdentity.equals(committedKey, composedRetainedKey))
        let emittedDocument = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        let emittedFragment = try XCTUnwrap(
            emittedDocument["osisFragment"] as? [String: Any]
        )
        let emittedXML = try XCTUnwrap(emittedFragment["xml"] as? String)
        let addDocumentsCount = emissions.filter {
            $0.contains("bibleView.emit('add_documents', ")
        }.count
        let diagnosticContext = [
            "documentID=\(document.id.uuidString)",
            "module=\(committedModule)",
            "key=\(committedKey)",
            "add_documents=\(addDocumentsCount)",
            "xmlPrefix=\(String(emittedXML.prefix(640)))",
        ].joined(separator: ";")
        XCTAssertEqual(addDocumentsCount, 1, diagnosticContext)
        let emittedText = try XCTUnwrap(
            defaultPreferenceXMLCharacterText(emittedXML),
            diagnosticContext
        )
        XCTAssertTrue(
            emittedText.contains("Exact retained-key toolbar body"),
            diagnosticContext
        )
        XCTAssertFalse(
            emittedText.contains("Wrong canonically equivalent page body"),
            diagnosticContext
        )
        XCTAssertFalse(
            emittedText.contains("Wrong Java-distinct document body"),
            diagnosticContext
        )
        XCTAssertFalse(emittedText.contains("Fallback first-page body"), diagnosticContext)
    }

    /** A stale toolbar row cannot retry into a replacement My Document with the same initials. */
    func testMyDocumentToolbarRetryRetainsExactDocumentOwner() async throws {
        let documentContainer = try makeMyDocumentModelContainer()
        let documentContext = ModelContext(documentContainer)
        let initials = "ToolbarOwner\(UUID().uuidString)"
        let replacement = MyDocumentToolbarReplacementFixture(
            context: documentContext,
            initials: initials
        )
        try replacement.seedOriginal()

        let publication = expectation(description: "original and retry settle")
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family == "my-document",
                      case .myDocumentRequest(let request) = key.annotationIdentity,
                      request.expectedDocumentID == replacement.originalID else { return }
                MainActor.assumeIsolated {
                    do {
                        if try replacement.replaceOriginalAtFirstPublication() {
                            return
                        }
                    } catch {
                        replacement.recordMutationError(error)
                    }
                    DispatchQueue.main.async { publication.fulfill() }
                }
            }
        )
        defer { coordinator.cancelAll() }
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let settingsStore = SettingsStore(
            modelContext: ModelContext(try makeWorkspaceModelContainer())
        )
        settingsStore.setString("default-GENERAL_BOOK", value: "PriorGeneralBook")
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.settingsStore = settingsStore
        controller.myDocumentStore = MyDocumentStore(modelContext: documentContext)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.restoreSavedPosition()
        controller.bridgeDidSetClientReady(bridge)

        XCTAssertTrue(
            controller.switchMyDocumentToolbarDocument(
                expectedID: replacement.originalID,
                initials: initials
            )
        )
        await fulfillment(of: [publication], timeout: 3)
        await Task.yield()
        try replacement.rethrowRecordedMutationError()

        XCTAssertEqual(replacement.currentDocumentID(), replacement.replacementID)
        XCTAssertEqual(settingsStore.getString("default-GENERAL_BOOK"), "PriorGeneralBook")
        XCTAssertNil(controller.activeGeneralBookModuleName)
        XCTAssertFalse(scripts().contains { $0.contains("Replacement body") })
    }

    /** Reentrant pane persistence supersession prevents the stale My Documents default write. */
    func testMyDocumentToolbarDefaultWaitsForPostSelectionAuthorization() async throws {
        let documentContainer = try makeMyDocumentModelContainer()
        let documentContext = ModelContext(documentContainer)
        let document = MyDocument(
            name: "Superseded toolbar document",
            initials: "SupersededToolbar\(UUID().uuidString)"
        )
        let page = MyDocumentPage(title: "First", pageKey: "first", orderNumber: 0)
        let content = MyDocumentPageContent(pageId: page.id, content: "Superseded body")
        documentContext.insert(document)
        documentContext.insert(page)
        documentContext.insert(content)
        page.document = document
        page.pageContent = content
        content.page = page
        document.pages = [page]
        try documentContext.save()

        let publication = expectation(description: "superseded request settles")
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family == "my-document",
                      case .myDocumentRequest(let request) = key.annotationIdentity,
                      request.expectedDocumentID == document.id else { return }
                DispatchQueue.main.async { publication.fulfill() }
            }
        )
        defer { coordinator.cancelAll() }
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let settingsStore = SettingsStore(
            modelContext: ModelContext(try makeWorkspaceModelContainer())
        )
        settingsStore.setString("default-GENERAL_BOOK", value: "PriorGeneralBook")
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.settingsStore = settingsStore
        controller.myDocumentStore = MyDocumentStore(modelContext: documentContext)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.restoreSavedPosition()
        controller.bridgeDidSetClientReady(bridge)
        controller.onPersistState = { [weak controller] in
            controller?.onPersistState = nil
            _ = controller?.switchBibleDocument(to: "KJV")
        }

        XCTAssertTrue(
            controller.switchMyDocumentToolbarDocument(
                expectedID: document.id,
                initials: document.initials
            )
        )
        await fulfillment(of: [publication], timeout: 3)
        await Task.yield()

        XCTAssertEqual(settingsStore.getString("default-GENERAL_BOOK"), "PriorGeneralBook")
        XCTAssertEqual(controller.currentCategory, .bible)
        XCTAssertEqual(controller.activeModuleName, "KJV")
        XCTAssertFalse(scripts().contains { $0.contains("Superseded body") })
    }

    /**
     A page-less My Document supersedes pre-ready StudyPad replay and publishes ordinary no-content.
     */
    func testEmptyMyDocumentToolbarSelectionCommitsOwnerAndDefault() async throws {
        let documentContainer = try makeMyDocumentModelContainer()
        let documentContext = ModelContext(documentContainer)
        let document = MyDocument(
            name: "Empty toolbar document",
            initials: "EmptyToolbar\(UUID().uuidString)"
        )
        documentContext.insert(document)
        try documentContext.save()

        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let settingsStore = SettingsStore(
            modelContext: ModelContext(try makeWorkspaceModelContainer())
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = settingsStore
        controller.myDocumentStore = MyDocumentStore(modelContext: documentContext)
        let bookmarkService = BookmarkService(
            store: BookmarkStore(modelContext: ModelContext(try makeBookmarkListModelContainer()))
        )
        let studyPadLabel = bookmarkService.createLabel(
            name: "Superseded empty-owner StudyPad",
            color: Label.defaultColor
        )
        controller.bookmarkService = bookmarkService
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.restoreSavedPosition()

        controller.loadStudyPadDocument(labelId: studyPadLabel.id)
        XCTAssertTrue(controller.showingStudyPad)
        XCTAssertEqual(controller.activeStudyPadLabelId, studyPadLabel.id)

        XCTAssertTrue(
            controller.switchMyDocumentToolbarDocument(
                expectedID: document.id,
                initials: document.initials
            )
        )
        XCTAssertFalse(controller.showingStudyPad)
        XCTAssertNil(controller.activeStudyPadLabelId)
        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(settingsStore.getString("default-GENERAL_BOOK"), document.initials)
        let replaySentinelDefault = "RetainedGeneralBookDefault"
        settingsStore.setString("default-GENERAL_BOOK", value: replaySentinelDefault)

        let replayBoundary = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: replayBoundary
        )

        XCTAssertEqual(settingsStore.getString("default-GENERAL_BOOK"), replaySentinelDefault)
        XCTAssertEqual(controller.activeGeneralBookModuleName, document.initials)
        XCTAssertNil(controller.currentGeneralBookKey)
        XCTAssertNil(pageManager.generalBookKey)
        XCTAssertTrue(emissions.joined().contains("No content for this passage"))
        let publishedDocumentTypes = try emissions
            .filter { $0.contains("bibleView.emit('add_documents', ") }
            .map {
                let payload = try XCTUnwrap(
                    bridgeEmissionPayload(from: [$0], event: "add_documents") as? [String: Any]
                )
                return payload["type"] as? String
            }
        XCTAssertEqual(publishedDocumentTypes.count, 1)
        XCTAssertFalse(publishedDocumentTypes.contains("journal"))
    }

    /** A selected empty owner may load a page added to that same UUID before client readiness. */
    func testEmptyMyDocumentReplayLoadsPageAddedToSameOwner() async throws {
        let context = ModelContext(try makeMyDocumentModelContainer())
        let initials = "EmptyGrowth\(UUID().uuidString)"
        let fixture = MyDocumentToolbarReplacementFixture(context: context, initials: initials)
        try fixture.seedEmptyOriginal()
        let publication = expectation(description: "same empty owner publishes its new page")
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family == "my-document",
                      case .myDocumentRequest(let request) = key.annotationIdentity,
                      request.expectedDocumentID == fixture.originalID else { return }
                DispatchQueue.main.async { publication.fulfill() }
            }
        )
        defer { coordinator.cancelAll() }
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: try XCTUnwrap(
                SwordManager(modulePath: makeTemporarySwordFixturePath())
            ),
            documentPreparationCoordinator: coordinator
        )
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.restoreSavedPosition()

        XCTAssertTrue(
            controller.switchMyDocumentToolbarDocument(
                expectedID: fixture.originalID,
                initials: initials
            )
        )
        try fixture.addPageToOriginal(body: "Same empty owner gained this page")
        let boundary = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        await fulfillment(of: [publication], timeout: 3)
        let emissions = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )

        XCTAssertTrue(emissions.joined().contains("Same empty owner gained this page"))
        XCTAssertEqual(controller.activeGeneralBookModuleName, initials)
        XCTAssertEqual(controller.currentGeneralBookKey, "first")
        XCTAssertEqual(try XCTUnwrap(controller.committedRenderState.identity).moduleName, initials)
    }

    /** A replacement UUID with the same initials cannot inherit an accepted empty selection. */
    func testEmptyMyDocumentReplayRejectsReplacementOwnerWithPages() async throws {
        let context = ModelContext(try makeMyDocumentModelContainer())
        let initials = "EmptyReplacement\(UUID().uuidString)"
        let fixture = MyDocumentToolbarReplacementFixture(context: context, initials: initials)
        try fixture.seedEmptyOriginal()
        let publication = expectation(description: "replacement owner request is rejected")
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family == "my-document",
                      case .myDocumentRequest(let request) = key.annotationIdentity,
                      request.expectedDocumentID == fixture.originalID else { return }
                DispatchQueue.main.async { publication.fulfill() }
            }
        )
        defer { coordinator.cancelAll() }
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: try XCTUnwrap(
                SwordManager(modulePath: makeTemporarySwordFixturePath())
            ),
            documentPreparationCoordinator: coordinator
        )
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        retainReaderWindowGraph(window, attaching: pageManager)
        controller.activeWindow = window
        controller.restoreSavedPosition()

        XCTAssertTrue(
            controller.switchMyDocumentToolbarDocument(
                expectedID: fixture.originalID,
                initials: initials
            )
        )
        let committedBeforeReplay = controller.committedRenderState
        try fixture.replaceEmptyOriginalWithPage(body: "Replacement owner must stay hidden")
        let boundary = scripts().count
        controller.bridgeDidSetClientReady(bridge)
        await fulfillment(of: [publication], timeout: 3)
        await Task.yield()
        let laterScripts = Array(scripts().dropFirst(boundary))

        XCTAssertEqual(fixture.currentDocumentID(), fixture.replacementID)
        XCTAssertFalse(laterScripts.contains { $0.contains("Replacement owner must stay hidden") })
        XCTAssertFalse(laterScripts.contains { $0.contains("bibleView.emit('add_documents', ") })
        XCTAssertEqual(controller.activeGeneralBookModuleName, initials)
        XCTAssertNil(controller.currentGeneralBookKey)
        XCTAssertEqual(controller.committedRenderState, committedBeforeReplay)
    }
}

/** Extracts normalized XML character data independently of the production fragment processor. */
private func defaultPreferenceXMLCharacterText(_ xml: String) -> String? {
    let collector = DefaultPreferenceXMLTextCollector()
    let parser = XMLParser(data: Data("<default-preference-root>\(xml)</default-preference-root>".utf8))
    parser.delegate = collector
    guard parser.parse() else { return nil }
    return collector.text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
}

/** Test-only XML delegate that preserves character data across adjacent BVA elements. */
private final class DefaultPreferenceXMLTextCollector: NSObject, XMLParserDelegate {
    private(set) var text = ""

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }
}

/** Main-owned SwiftData replacement used to exercise one real stale-retry boundary. */
@MainActor
private final class MyDocumentToolbarReplacementFixture {
    let originalID = UUID()
    let replacementID = UUID()
    private let context: ModelContext
    private let initials: String
    private var didReplace = false
    private var mutationError: Error?

    init(context: ModelContext, initials: String) {
        self.context = context
        self.initials = initials
    }

    func seedOriginal() throws {
        try insertDocument(id: originalID, body: "Original body")
    }

    func seedEmptyOriginal() throws {
        let document = MyDocument(id: originalID, name: "Toolbar owner", initials: initials)
        context.insert(document)
        try context.save()
    }

    func addPageToOriginal(body: String) throws {
        let expectedID = originalID
        let descriptor = FetchDescriptor<MyDocument>(predicate: #Predicate { $0.id == expectedID })
        let document = try XCTUnwrap(context.fetch(descriptor).first)
        try addFirstPage(to: document, body: body)
    }

    func replaceEmptyOriginalWithPage(body: String) throws {
        let expectedID = originalID
        let descriptor = FetchDescriptor<MyDocument>(predicate: #Predicate { $0.id == expectedID })
        let original = try XCTUnwrap(context.fetch(descriptor).first)
        context.delete(original)
        try context.save()
        try insertDocument(id: replacementID, body: body)
    }

    func replaceOriginalAtFirstPublication() throws -> Bool {
        guard !didReplace else { return false }
        didReplace = true
        let expectedID = originalID
        let descriptor = FetchDescriptor<MyDocument>(
            predicate: #Predicate { $0.id == expectedID }
        )
        let original = try XCTUnwrap(
            context.fetch(descriptor).first,
            "Expected the original My Document before publication replacement"
        )
        context.delete(original)
        try context.save()
        try insertDocument(id: replacementID, body: "Replacement body")
        return true
    }

    func recordMutationError(_ error: Error) {
        mutationError = error
    }

    func rethrowRecordedMutationError() throws {
        if let mutationError { throw mutationError }
    }

    func currentDocumentID() -> UUID? {
        let expectedInitials = initials
        let descriptor = FetchDescriptor<MyDocument>(
            predicate: #Predicate { $0.initials == expectedInitials }
        )
        return try? context.fetch(descriptor).first?.id
    }

    private func insertDocument(id: UUID, body: String) throws {
        let document = MyDocument(id: id, name: "Toolbar owner", initials: initials)
        context.insert(document)
        try addFirstPage(to: document, body: body)
    }

    private func addFirstPage(to document: MyDocument, body: String) throws {
        let page = MyDocumentPage(title: "First", pageKey: "first", orderNumber: 0)
        let content = MyDocumentPageContent(pageId: page.id, content: body)
        context.insert(page)
        context.insert(content)
        page.document = document
        page.pageContent = content
        content.page = page
        document.pages = [page]
        try context.save()
    }
}
