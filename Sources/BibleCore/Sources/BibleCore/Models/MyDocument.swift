// MyDocument.swift -- Local My Documents persistence models

import Foundation
import SwiftData

/**
 Android-aligned content types for stored My Documents page bodies.

 The raw values intentionally match Android's `MyDocumentContentType` enum so
 raw bridge payloads and future sync mapping can pass the value through without
 translation.
 */
public enum MyDocumentContentType: String, Codable, Sendable {
    case markdown = "MARKDOWN"
    case html = "HTML"
    case osis = "OSIS"
}

/**
 Stores one user-created or AI-generated My Documents collection.

 Android registers each My Document as a generated general-book module. iOS keeps
 the same stable `initials` identity locally without registering a SWORD module.
 */
@Model
public final class MyDocument {
    /// Stable primary key used by SwiftData and future sync mapping.
    @Attribute(.unique) public var id: UUID

    /// User-visible document name.
    public var name: String

    /// Optional document description.
    public var documentDescription: String?

    /// Stable Android-style document initials used by bridge lookups.
    @Attribute(.unique) public var initials: String

    /// Zero-based display order.
    public var orderNumber: Int

    /// Creation timestamp.
    public var createdAt: Date

    /// Last metadata/content update timestamp.
    public var updatedAt: Date

    /// Prompt identifier when this document was created from AI output.
    public var sourcePromptId: UUID?

    /// Pages owned by this document. Deleting the document removes all pages.
    @Relationship(deleteRule: .cascade, inverse: \MyDocumentPage.document)
    public var pages: [MyDocumentPage]?

    public init(
        id: UUID = UUID(),
        name: String,
        documentDescription: String? = nil,
        initials: String,
        orderNumber: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourcePromptId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.documentDescription = documentDescription
        self.initials = initials
        self.orderNumber = orderNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourcePromptId = sourcePromptId
    }
}

/**
 Stores metadata for one page within a My Document.

 Heavy raw content lives in `MyDocumentPageContent` so metadata-only operations
 can stay cheap and future Android `mydocuments` sync mapping can preserve the
 same split.
 */
@Model
public final class MyDocumentPage {
    /// Stable primary key for the page.
    @Attribute(.unique) public var id: UUID

    /// Parent document.
    public var document: MyDocument?

    /// User-visible page title.
    public var title: String

    /// Stable key unique within the parent document and used by bridge calls.
    public var pageKey: String

    /// Persisted raw content type value.
    public var contentTypeRawValue: String

    /// Zero-based display order within the document.
    public var orderNumber: Int

    /// Creation timestamp.
    public var createdAt: Date

    /// Last metadata/content update timestamp.
    public var updatedAt: Date

    /// Prompt identifier when this page was generated from AI output.
    public var sourcePromptId: UUID?

    /// Optional language code for the page content.
    public var languageCode: String?

    /// Raw content payload owned by this page.
    @Relationship(deleteRule: .cascade, inverse: \MyDocumentPageContent.page)
    public var pageContent: MyDocumentPageContent?

    /// AI cache metadata associated with this page.
    @Relationship(deleteRule: .cascade, inverse: \AiPageCacheEntry.page)
    public var aiPageCacheEntries: [AiPageCacheEntry]?

    public var contentType: MyDocumentContentType {
        get { MyDocumentContentType(rawValue: contentTypeRawValue) ?? .markdown }
        set { contentTypeRawValue = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        title: String,
        pageKey: String,
        contentType: MyDocumentContentType = .markdown,
        orderNumber: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourcePromptId: UUID? = nil,
        languageCode: String? = nil
    ) {
        self.id = id
        self.title = title
        self.pageKey = pageKey
        self.contentTypeRawValue = contentType.rawValue
        self.orderNumber = orderNumber
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourcePromptId = sourcePromptId
        self.languageCode = languageCode
    }
}

/**
 Stores the raw editable content for one My Documents page.
 */
@Model
public final class MyDocumentPageContent {
    /// Mirrors the owning page identifier for 1:1 lookup and future sync mapping.
    @Attribute(.unique) public var pageId: UUID

    /// Back-reference to the owning page.
    public var page: MyDocumentPage?

    /// Stored raw page content.
    public var content: String

    public init(pageId: UUID, content: String = "") {
        self.pageId = pageId
        self.content = content
    }
}

/**
 Stores AI regeneration/cache metadata for a My Documents page.
 */
@Model
public final class AiPageCacheEntry {
    /// Stable primary key for the cache row.
    @Attribute(.unique) public var id: UUID

    /// Owning page identifier.
    public var pageId: UUID

    /// Back-reference to the owning page.
    public var page: MyDocumentPage?

    /// Prompt that generated or updated the page.
    public var sourcePromptId: UUID

    /// Optional serialized source context.
    public var sourceContext: String?

    /// Optional KJV ordinal context start.
    public var kjvOrdinalStart: Int?

    /// Optional KJV ordinal context end.
    public var kjvOrdinalEnd: Int?

    /// Optional source context hash.
    public var contextHash: String?

    /// Whether the AI write tools were used for this cache entry.
    public var usedWriteTools: Bool

    /// Optional AI model name.
    public var sourceModelName: String?

    /// Optional source module initials.
    public var sourceBookInitials: String?

    /// Optional source module key.
    public var sourceBookKey: String?

    public init(
        id: UUID = UUID(),
        pageId: UUID,
        sourcePromptId: UUID,
        sourceContext: String? = nil,
        kjvOrdinalStart: Int? = nil,
        kjvOrdinalEnd: Int? = nil,
        contextHash: String? = nil,
        usedWriteTools: Bool = false,
        sourceModelName: String? = nil,
        sourceBookInitials: String? = nil,
        sourceBookKey: String? = nil
    ) {
        self.id = id
        self.pageId = pageId
        self.sourcePromptId = sourcePromptId
        self.sourceContext = sourceContext
        self.kjvOrdinalStart = kjvOrdinalStart
        self.kjvOrdinalEnd = kjvOrdinalEnd
        self.contextHash = contextHash
        self.usedWriteTools = usedWriteTools
        self.sourceModelName = sourceModelName
        self.sourceBookInitials = sourceBookInitials
        self.sourceBookKey = sourceBookKey
    }
}
