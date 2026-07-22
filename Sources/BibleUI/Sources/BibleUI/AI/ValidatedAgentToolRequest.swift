// ValidatedAgentToolRequest.swift -- Typed Android agent tool invocation values

import BibleCore
import Foundation

/** Output form accepted by Bible, commentary, dictionary, and general-book reads. */
public enum BibleUIAgentContentFormat: String, Sendable {
    case text
    case xml
}

/** Persisted rich-text form accepted by bookmark and StudyPad writes. */
public enum BibleUIAgentNoteContentType: String, Sendable {
    case html = "HTML"
    case markdown = "MARKDOWN"
}

/** Persisted source form accepted by My Documents page creation. */
public enum BibleUIAgentPageContentType: String, Sendable {
    case markdown = "MARKDOWN"
    case html = "HTML"
    case osis = "OSIS"
}

/** Installed-document category names exposed by Android's document inventory tool. */
public enum BibleUIAgentDocumentCategory: String, Sendable {
    case bible = "BIBLE"
    case commentary = "COMMENTARY"
    case dictionary = "DICTIONARY"
    case generalBook = "GENERAL_BOOK"
    case maps = "MAPS"
}

/** Read projections supported by Android's StudyPad tool. */
public enum BibleUIAgentStudyPadReadMode: String, Sendable {
    case full
    case info
    case index
    case page
}

/** Window lifecycle commands accepted by Android's window-management tool. */
public enum BibleUIAgentWindowAction: String, Sendable {
    case close = "CLOSE"
    case minimize = "MINIMIZE"
    case restore = "RESTORE"
}

/** Optional bookmark fields exposed by the label query. */
public enum BibleUIAgentBookmarkField: String, Hashable, Sendable {
    case verseRange
    case verseName
    case notes
    case createdAt
}

/** One validated item in a compound StudyPad creation request. */
public struct BibleUIAgentStudyPadItem: Sendable, Equatable {
    /** Item domain selected by the model. */
    public enum Kind: String, Sendable {
        case text
        case bookmark
    }

    public let kind: Kind
    public let text: String?
    public let verseReference: String?
    public let indentLevel: Int
    public let contentType: BibleUIAgentNoteContentType

    /**
     Creates an immutable StudyPad item.

     - Parameters:
       - kind: Text or Bible-bookmark item kind.
       - text: Text body or optional bookmark note.
       - verseReference: Required OSIS reference for bookmark items.
       - indentLevel: Android outline depth from zero through three.
       - contentType: Durable rich-text representation.
     - Side effects: None.
     - Failure modes: None; the public argument parser validates values before construction.
     */
    public init(
        kind: Kind,
        text: String?,
        verseReference: String?,
        indentLevel: Int,
        contentType: BibleUIAgentNoteContentType
    ) {
        self.kind = kind
        self.text = text
        self.verseReference = verseReference
        self.indentLevel = indentLevel
        self.contentType = contentType
    }
}

/**
 Complete typed request vocabulary for Android's 38 production agent tools.

 Every associated value has passed JSON type, UUID, enum, and coarse resource-bound validation.
 Domain existence and verse-versification validation remain with the production domain adapter,
 where installed modules and current persistence state are available.
 */
public enum BibleUIAgentToolRequest: Sendable, Equatable {
    case getVerseContent(book: String, verseReference: String, format: BibleUIAgentContentFormat)
    case searchBible(query: String, books: [String], maximumResults: Int, offset: Int)
    case searchByStrongs(
        reportedNumber: String,
        canonicalToken: String,
        book: String?,
        maximumResults: Int,
        offset: Int
    )
    case getCommentaries(
        verseReference: String,
        commentaries: [String],
        format: BibleUIAgentContentFormat
    )
    case getDictionaryEntry(
        dictionary: String,
        key: String,
        format: BibleUIAgentContentFormat
    )
    case getBookmarksForVerse(verseReference: String)
    case getBookmarksWithLabel(
        labelID: UUID,
        maximumResults: Int,
        fields: Set<BibleUIAgentBookmarkField>
    )
    case getAllLabels
    case getStudyPadContent(
        labelID: UUID,
        mode: BibleUIAgentStudyPadReadMode,
        offset: Int,
        limit: Int
    )
    case searchStudyPads(query: String)
    case getInstalledDocuments(category: BibleUIAgentDocumentCategory?)
    case getMyDocuments
    case getMyDocumentPages(documentID: UUID?, initials: String?, includeContent: Bool)
    case getGenBookKeys(book: String, offset: Int, limit: Int)
    case getGenBookContent(book: String, key: String, format: BibleUIAgentContentFormat)
    case getWindows
    case createBookmark(
        verseReference: String,
        note: String?,
        noteContentType: BibleUIAgentNoteContentType,
        labelIDs: [UUID],
        primaryLabelID: UUID?,
        bookInitials: String?,
        startOffset: Int?,
        endOffset: Int?
    )
    case addBookmarkNote(
        bookmarkID: UUID,
        note: String,
        contentType: BibleUIAgentNoteContentType
    )
    case updateBookmarkNote(bookmarkID: UUID, note: String)
    case createLabel(name: String, color: Int?)
    case addLabelToBookmark(bookmarkID: UUID, labelID: UUID)
    case deleteBookmark(bookmarkID: UUID)
    case deleteLabel(labelID: UUID, deleteOrphanedBookmarks: Bool)
    case removeLabelFromBookmark(bookmarkID: UUID, labelID: UUID)
    case addStudyPadEntry(
        labelID: UUID,
        text: String,
        contentType: BibleUIAgentNoteContentType,
        orderNumber: Int?
    )
    case updateStudyPadTextEntry(entryID: UUID, text: String)
    case createStudyPad(name: String, color: Int?, items: [BibleUIAgentStudyPadItem])
    case createMyDocument(name: String, description: String?)
    case addMyDocumentPage(
        documentID: UUID?,
        initials: String?,
        title: String,
        content: String,
        contentType: BibleUIAgentPageContentType
    )
    case editMyDocumentPage(pageID: UUID, title: String?, content: String?, orderNumber: Int?)
    case deleteMyDocumentPage(pageID: UUID)
    case createWindow(documentInitials: String?, key: String?, minimized: Bool)
    case manageWindow(windowID: UUID, action: BibleUIAgentWindowAction)
    case setWindowDocument(windowID: UUID?, documentInitials: String, key: String?)
    case setDocumentTitle(title: String)
    case finishWithStudyPad(labelID: UUID, scrollToEntryID: UUID?, message: String)
    case finishWithMyDocumentPage(pageID: UUID, message: String)
    case finishWithoutDocument(message: String)

    /** Returns the registered tool identity represented by this request. */
    public var tool: AgentTool {
        switch self {
        case .getVerseContent: return .getVerseContent
        case .searchBible: return .searchBible
        case .searchByStrongs: return .searchByStrongs
        case .getCommentaries: return .getCommentaries
        case .getDictionaryEntry: return .getDictionaryEntry
        case .getBookmarksForVerse: return .getBookmarksForVerse
        case .getBookmarksWithLabel: return .getBookmarksWithLabel
        case .getAllLabels: return .getAllLabels
        case .getStudyPadContent: return .getStudyPadContent
        case .searchStudyPads: return .searchStudyPads
        case .getInstalledDocuments: return .getInstalledDocuments
        case .getMyDocuments: return .getMyDocuments
        case .getMyDocumentPages: return .getMyDocumentPages
        case .getGenBookKeys: return .getGenBookKeys
        case .getGenBookContent: return .getGenBookContent
        case .getWindows: return .getWindows
        case .createBookmark: return .createBookmark
        case .addBookmarkNote: return .addBookmarkNote
        case .updateBookmarkNote: return .updateBookmarkNote
        case .createLabel: return .createLabel
        case .addLabelToBookmark: return .addLabelToBookmark
        case .deleteBookmark: return .deleteBookmark
        case .deleteLabel: return .deleteLabel
        case .removeLabelFromBookmark: return .removeLabelFromBookmark
        case .addStudyPadEntry: return .addStudyPadEntry
        case .updateStudyPadTextEntry: return .updateStudyPadTextEntry
        case .createStudyPad: return .createStudyPad
        case .createMyDocument: return .createMyDocument
        case .addMyDocumentPage: return .addMyDocumentPage
        case .editMyDocumentPage: return .editMyDocumentPage
        case .deleteMyDocumentPage: return .deleteMyDocumentPage
        case .createWindow: return .createWindow
        case .manageWindow: return .manageWindow
        case .setWindowDocument: return .setWindowDocument
        case .setDocumentTitle: return .setDocumentTitle
        case .finishWithStudyPad: return .finishWithStudyPad
        case .finishWithMyDocumentPage: return .finishWithMyDocumentPage
        case .finishWithoutDocument: return .finishWithoutDocument
        }
    }
}

/** Stable validation failure returned to the model without reflecting supplied content. */
public struct BibleUIAgentArgumentError: Error, Equatable, LocalizedError, Sendable {
    public let code: String
    public let message: String

    /**
     Creates a secret-free validation failure.

     - Parameters:
       - code: Stable machine-readable error code.
       - message: Value-free explanation suitable for model history.
     - Side effects: None.
     - Failure modes: None.
     */
    public init(code: String = "INVALID_ARGS", message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}
