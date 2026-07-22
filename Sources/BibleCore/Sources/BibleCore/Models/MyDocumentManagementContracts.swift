// MyDocumentManagementContracts.swift -- Value contracts for My Documents management

import Foundation

/**
 Editable value representation of one My Documents page.

 Management screens edit these values instead of live SwiftData models so Cancel can discard every
 pending create, import, rename, delete, reorder, and content edit as one unit.
 */
public struct MyDocumentPageDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public let pageKey: String
    public var contentType: MyDocumentContentType
    public var orderNumber: Int
    public let createdAt: Date
    public var updatedAt: Date
    public let sourcePromptId: UUID?
    public var languageCode: String?
    public var content: String

    public init(
        id: UUID = UUID(),
        title: String,
        pageKey: String? = nil,
        contentType: MyDocumentContentType = .markdown,
        orderNumber: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourcePromptId: UUID? = nil,
        languageCode: String? = nil,
        content: String = ""
    ) {
        self.id = id
        self.title = title
        self.pageKey = pageKey ?? "page_\(id.uuidString.lowercased())"
        self.contentType = contentType
        self.orderNumber = orderNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourcePromptId = sourcePromptId
        self.languageCode = languageCode
        self.content = content
    }
}

/**
 Editable value representation of one My Documents collection and its ordered pages.
 */
public struct MyDocumentDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var documentDescription: String?
    public let initials: String
    public var orderNumber: Int
    public let createdAt: Date
    public var updatedAt: Date
    public let sourcePromptId: UUID?
    public var pages: [MyDocumentPageDraft]

    public init(
        id: UUID = UUID(),
        name: String,
        documentDescription: String? = nil,
        initials: String,
        orderNumber: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourcePromptId: UUID? = nil,
        pages: [MyDocumentPageDraft] = []
    ) {
        self.id = id
        self.name = name
        self.documentDescription = documentDescription
        self.initials = initials
        self.orderNumber = orderNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourcePromptId = sourcePromptId
        self.pages = pages
    }
}

/**
 One UTF-8 text file selected for Android-compatible My Documents import.
 */
public struct MyDocumentImportFile: Equatable, Sendable {
    public let fileName: String
    public let content: String

    public init(fileName: String, content: String) {
        self.fileName = fileName
        self.content = content
    }
}

/**
 One raw page file produced for native export.
 */
public struct MyDocumentExportFile: Equatable, Sendable {
    public let fileName: String
    public let contentType: String
    public let content: String

    public init(fileName: String, contentType: String, content: String) {
        self.fileName = fileName
        self.contentType = contentType
        self.content = content
    }
}

/**
 Fail-visible validation and persistence failures from My Documents management.
 */
public enum MyDocumentManagementError: Error, Equatable, LocalizedError, Sendable {
    case emptyDocumentName
    case emptyPageTitle
    case duplicateInitials(String)
    case duplicatePageKey(documentInitials: String, pageKey: String)
    case documentNotFound(UUID)
    case pageNotFound(UUID)
    case cannotDeleteNonemptyAIDocument
    case emptyImport
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyDocumentName:
            return "Document name cannot be empty."
        case .emptyPageTitle:
            return "Page title cannot be empty."
        case .duplicateInitials(let initials):
            return "Document initials are already in use: \(initials)"
        case .duplicatePageKey(let initials, let pageKey):
            return "Page key \(pageKey) is duplicated in \(initials)."
        case .documentNotFound:
            return String(
                localized: "error_key_not_in_document",
                defaultValue: "Not found in document"
            )
        case .pageNotFound:
            return String(
                localized: "error_key_not_in_document",
                defaultValue: "Not found in document"
            )
        case .cannotDeleteNonemptyAIDocument:
            return String(
                localized: "my_document_cannot_delete_ai_documents",
                defaultValue: "AI Documents cannot be deleted while it contains pages. Delete the pages first."
            )
        case .emptyImport:
            return String(
                localized: "my_document_import_empty_selection",
                defaultValue: "No importable files selected"
            )
        case .persistenceFailed(let message):
            return "My Documents could not be saved: \(message)"
        }
    }
}
