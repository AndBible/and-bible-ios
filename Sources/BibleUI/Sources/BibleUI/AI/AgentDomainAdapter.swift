// AgentDomainAdapter.swift -- Production routing for Android-compatible AI tools

import BibleCore
import Foundation
import SwordKit

/** App-owned policy for Android's user-configurable AI document exclusions. */
@MainActor
public protocol BibleUIAgentDocumentAccessPolicy: Sendable {
    /** Returns whether AI tools may disclose or navigate one installed document. */
    func allows(documentInitials: String) -> Bool
}

/** Production exclusion policy backed by Android-compatible global AI settings. */
@MainActor
public final class BibleUIAgentSettingsDocumentAccessPolicy: BibleUIAgentDocumentAccessPolicy {
    private let settingsStore: AISettingsStore

    /**
     Creates a policy over the existing settings store.

     - Parameter settingsStore: Main-actor AI settings persistence service.
     - Side effects: None.
     - Failure modes: None; read failures fail closed when queried.
     */
    public init(settingsStore: AISettingsStore) {
        self.settingsStore = settingsStore
    }

    /** Reads only the excluded-initials set and fails closed on persistence errors. */
    public func allows(documentInitials: String) -> Bool {
        guard let settings = try? settingsStore.globalSettings() else { return false }
        return !settings.aiExcludedDocuments.contains(documentInitials)
    }
}

/** UI-owned document/key state returned after a window navigation mutation. */
public struct BibleUIAgentWindowDocumentState: Equatable, Sendable {
    public let windowID: UUID
    public let documentInitials: String
    public let documentName: String
    public let currentKey: String?
    public let currentKeyName: String?

    /** Creates the verified state observed by the UI after navigation completes. */
    public init(
        windowID: UUID,
        documentInitials: String,
        documentName: String,
        currentKey: String?,
        currentKeyName: String?
    ) {
        self.windowID = windowID
        self.documentInitials = documentInitials
        self.documentName = documentName
        self.currentKey = currentKey
        self.currentKeyName = currentKeyName
    }
}

/**
 Explicit app-runtime boundary for mutations that require a live reader controller.

 The domain adapter owns window identity and document validation. The injected UI router owns the
 actual pane transition and reports the state it observed after rendering/navigation settled.
 */
@MainActor
public protocol BibleUIAgentWindowDocumentRouting: Sendable {
    func setDocument(
        windowID: UUID,
        documentInitials: String,
        key: String?
    ) async throws -> BibleUIAgentWindowDocumentState
}

/** Closure-backed router suitable for an app composition root without exposing controller types. */
public struct BibleUIAgentWindowDocumentRouter: BibleUIAgentWindowDocumentRouting, Sendable {
    public typealias Operation = @MainActor @Sendable (
        UUID,
        String,
        String?
    ) async throws -> BibleUIAgentWindowDocumentState

    private let operation: Operation

    /** Creates a router from one app-owned main-actor operation. */
    public init(operation: @escaping Operation) {
        self.operation = operation
    }

    /** Executes the injected pane navigation operation on the main actor. */
    @MainActor
    public func setDocument(
        windowID: UUID,
        documentInitials: String,
        key: String?
    ) async throws -> BibleUIAgentWindowDocumentState {
        try await operation(windowID, documentInitials, key)
    }
}

/**
 Production app-domain implementation for every validated Android agent request.

 SwiftData-backed services and all workspace state stay on the main actor. SWORD and SQLite access
 remains behind their existing serialization boundaries, and live pane mutations require an
 explicit UI router instead of reaching through untyped controller registries.
 */
@MainActor
public final class BibleUIAgentDomainAdapter: BibleUIAgentToolExecuting {
    let swordManager: SwordManager
    let sqliteLibrary: SQLiteDocumentModuleLibrary
    let searchIndexService: SearchIndexService
    let bookmarkService: BookmarkService
    let myDocumentLibraryStore: MyDocumentLibraryStore
    let myDocumentStore: MyDocumentStore
    let windowManager: WindowManager
    let documentAccessPolicy: any BibleUIAgentDocumentAccessPolicy
    let windowDocumentRouter: any BibleUIAgentWindowDocumentRouting

    /**
     Creates production routing over existing app stores and runtime services.

     - Parameters:
       - swordManager: Installed SWORD module registry.
       - sqliteLibrary: Installed Android SQLite document registry.
       - searchIndexService: Existing text and Strong's index service.
       - bookmarkService: Existing bookmarks, labels, and StudyPads service.
       - myDocumentLibraryStore: Transactional My Documents graph store.
       - myDocumentStore: Existing page lookup and atomic page-content store.
       - windowManager: Active workspace/window state owner.
       - documentAccessPolicy: Global AI document exclusion policy.
       - windowDocumentRouter: App-owned live pane navigation operation.
     - Side effects: None; dependencies retain their existing ownership.
     - Failure modes: None.
     */
    public init(
        swordManager: SwordManager,
        sqliteLibrary: SQLiteDocumentModuleLibrary,
        searchIndexService: SearchIndexService,
        bookmarkService: BookmarkService,
        myDocumentLibraryStore: MyDocumentLibraryStore,
        myDocumentStore: MyDocumentStore,
        windowManager: WindowManager,
        documentAccessPolicy: any BibleUIAgentDocumentAccessPolicy,
        windowDocumentRouter: any BibleUIAgentWindowDocumentRouting
    ) {
        self.swordManager = swordManager
        self.sqliteLibrary = sqliteLibrary
        self.searchIndexService = searchIndexService
        self.bookmarkService = bookmarkService
        self.myDocumentLibraryStore = myDocumentLibraryStore
        self.myDocumentStore = myDocumentStore
        self.windowManager = windowManager
        self.documentAccessPolicy = documentAccessPolicy
        self.windowDocumentRouter = windowDocumentRouter
    }

    /** Routes every typed request to its owning production domain operation. */
    public func execute(
        _ request: BibleUIAgentToolRequest,
        context: AgentExecutionContext
    ) async throws -> AgentToolResult {
        switch request {
        case .getVerseContent(let book, let reference, let format):
            return try getVerseContent(book: book, reference: reference, format: format)
        case .searchBible(let query, let books, let maximum, let offset):
            return try searchBible(query: query, books: books, maximum: maximum, offset: offset)
        case .searchByStrongs(let reported, let token, let book, let maximum, let offset):
            return try searchByStrongs(
                reportedNumber: reported,
                canonicalToken: token,
                book: book,
                maximum: maximum,
                offset: offset
            )
        case .getCommentaries(let reference, let commentaries, let format):
            return try getCommentaries(
                reference: reference,
                requestedInitials: commentaries,
                format: format
            )
        case .getDictionaryEntry(let dictionary, let key, let format):
            return try getDictionaryEntry(dictionary: dictionary, key: key, format: format)
        case .getBookmarksForVerse(let reference):
            return try getBookmarksForVerse(reference: reference)
        case .getBookmarksWithLabel(let labelID, let maximum, let fields):
            return try getBookmarksWithLabel(
                labelID: labelID,
                maximum: maximum,
                fields: fields
            )
        case .getAllLabels:
            return try getAllLabels()
        case .getStudyPadContent(let labelID, let mode, let offset, let limit):
            return try getStudyPadContent(
                labelID: labelID,
                mode: mode,
                offset: offset,
                limit: limit
            )
        case .searchStudyPads(let query):
            return try searchStudyPads(query: query)
        case .getInstalledDocuments(let category):
            return try getInstalledDocuments(category: category)
        case .getMyDocuments:
            return try getMyDocuments()
        case .getMyDocumentPages(let documentID, let initials, let includeContent):
            return try getMyDocumentPages(
                documentID: documentID,
                initials: initials,
                includeContent: includeContent
            )
        case .getGenBookKeys(let book, let offset, let limit):
            return try getGenBookKeys(book: book, offset: offset, limit: limit)
        case .getGenBookContent(let book, let key, let format):
            return try getGenBookContent(book: book, key: key, format: format)
        case .getWindows:
            return try getWindows()
        case .createBookmark(
            let reference,
            let note,
            let contentType,
            let labelIDs,
            let primaryLabelID,
            let bookInitials,
            let startOffset,
            let endOffset
        ):
            return try createBookmark(
                reference: reference,
                note: note,
                contentType: contentType,
                labelIDs: labelIDs,
                primaryLabelID: primaryLabelID,
                bookInitials: bookInitials,
                startOffset: startOffset,
                endOffset: endOffset,
                context: context
            )
        case .addBookmarkNote(let bookmarkID, let note, let contentType):
            return try addBookmarkNote(
                bookmarkID: bookmarkID,
                note: note,
                contentType: contentType,
                context: context
            )
        case .updateBookmarkNote(let bookmarkID, let note):
            return try updateBookmarkNote(
                bookmarkID: bookmarkID,
                note: note,
                context: context
            )
        case .createLabel(let name, let color):
            return try createLabel(name: name, color: color)
        case .addLabelToBookmark(let bookmarkID, let labelID):
            return try addLabelToBookmark(bookmarkID: bookmarkID, labelID: labelID)
        case .deleteBookmark(let bookmarkID):
            return try deleteBookmark(bookmarkID: bookmarkID)
        case .deleteLabel(let labelID, let deleteOrphanedBookmarks):
            return try deleteLabel(
                labelID: labelID,
                deleteOrphanedBookmarks: deleteOrphanedBookmarks
            )
        case .removeLabelFromBookmark(let bookmarkID, let labelID):
            return try removeLabelFromBookmark(bookmarkID: bookmarkID, labelID: labelID)
        case .addStudyPadEntry(let labelID, let text, let contentType, let orderNumber):
            return try addStudyPadEntry(
                labelID: labelID,
                text: text,
                contentType: contentType,
                orderNumber: orderNumber,
                context: context
            )
        case .updateStudyPadTextEntry(let entryID, let text):
            return try updateStudyPadTextEntry(entryID: entryID, text: text)
        case .createStudyPad(let name, let color, let items):
            return try createStudyPad(
                name: name,
                color: color,
                items: items,
                context: context
            )
        case .createMyDocument(let name, let description):
            return try createMyDocument(name: name, description: description, context: context)
        case .addMyDocumentPage(let documentID, let initials, let title, let content, let type):
            return try addMyDocumentPage(
                documentID: documentID,
                initials: initials,
                title: title,
                content: content,
                contentType: type,
                context: context
            )
        case .editMyDocumentPage(let pageID, let title, let content, let orderNumber):
            return try editMyDocumentPage(
                pageID: pageID,
                title: title,
                content: content,
                orderNumber: orderNumber
            )
        case .deleteMyDocumentPage(let pageID):
            return try deleteMyDocumentPage(pageID: pageID)
        case .createWindow(let documentInitials, let key, let minimized):
            return try await createWindow(
                documentInitials: documentInitials,
                key: key,
                minimized: minimized
            )
        case .manageWindow(let windowID, let action):
            return try manageWindow(windowID: windowID, action: action)
        case .setWindowDocument(let windowID, let documentInitials, let key):
            return try await setWindowDocument(
                windowID: windowID,
                documentInitials: documentInitials,
                key: key
            )
        case .setDocumentTitle(let title):
            return try setDocumentTitle(title: title)
        case .finishWithStudyPad(let labelID, let entryID, let message):
            return try finishWithStudyPad(
                labelID: labelID,
                scrollToEntryID: entryID,
                message: message
            )
        case .finishWithMyDocumentPage(let pageID, let message):
            return try finishWithMyDocumentPage(pageID: pageID, message: message)
        case .finishWithoutDocument(let message):
            return try finishWithoutDocument(message: message)
        }
    }

    /** Resolves AI Documents ownership from a fresh transactional library snapshot. */
    public func isAIDocument(documentID: UUID?, initials: String?) async -> Bool {
        guard let session = try? myDocumentLibraryStore.loadSession() else { return false }
        let byID = documentID.flatMap { id in session.documents.first { $0.id == id } }
        let byInitials = initials.flatMap { value in
            session.documents.first { $0.initials == value }
        }
        if documentID != nil, initials != nil, byID?.id != byInitials?.id { return false }
        let document = byID ?? byInitials
        return document?.initials == MyDocumentManagementSession.aiDocumentsInitials
    }

    var reservedDocumentInitials: Set<String> {
        Set(swordManager.installedModules().map(\.name) + sqliteLibrary.modules.map { $0.info.name })
    }
}

/** Discoverable production name for app composition. */
public typealias ProductionAgentToolDomainAdapter = BibleUIAgentDomainAdapter
