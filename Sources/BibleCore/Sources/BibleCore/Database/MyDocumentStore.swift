// MyDocumentStore.swift -- Local My Documents persistence operations

import Foundation
import SwiftData

/**
 Raw page content payload returned to the WebView bridge.

 The encoded key names match Android's `PageRawContent` serializer output.
 */
public struct MyDocumentRawContentPayload: Codable, Equatable, Sendable {
    public let pageId: String
    public let contentType: String
    public let content: String
    public let title: String
    public let sourcePromptId: String?

    public init(
        pageId: String,
        contentType: String,
        content: String,
        title: String,
        sourcePromptId: String?
    ) {
        self.pageId = pageId
        self.contentType = contentType
        self.content = content
        self.title = title
        self.sourcePromptId = sourcePromptId
    }
}

/**
 Low-level persistence API for My Documents pages and raw content.

 This store deliberately resolves pages by Android-compatible `(initials,
 pageKey)` pairs because those values are what the WebView bridge receives.

 - Important: This store inherits the thread/actor confinement of the supplied
   `ModelContext`.
 */
public final class MyDocumentStore {
    /// SwiftData context supplied by the owning UI/app actor.
    private let modelContext: ModelContext

    /**
     Creates a My Documents store for the supplied SwiftData context.

     - Important: The caller owns the context lifetime and must use this store
       on the same actor/thread as `modelContext`.
     */
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /**
     Fetches one document by its stable bridge initials.
     */
    public func document(initials: String) -> MyDocument? {
        var descriptor = FetchDescriptor<MyDocument>(
            predicate: #Predicate { $0.initials == initials }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     Resolves one page by the Android-compatible document initials and page key.
     */
    public func page(bookInitials: String, pageKey: String) -> MyDocumentPage? {
        var descriptor = FetchDescriptor<MyDocumentPage>(
            predicate: #Predicate {
                $0.pageKey == pageKey && $0.document?.initials == bookInitials
            },
            sortBy: [
                SortDescriptor(\.orderNumber),
                SortDescriptor(\.createdAt),
                SortDescriptor(\.updatedAt),
                SortDescriptor(\.title),
            ]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     Resolves one page by its stable page identifier and parent document initials.
     */
    public func page(bookInitials: String, pageId: UUID) -> MyDocumentPage? {
        var descriptor = FetchDescriptor<MyDocumentPage>(
            predicate: #Predicate {
                $0.id == pageId && $0.document?.initials == bookInitials
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     Builds the raw-content bridge payload for one page.
     */
    public func rawContentPayload(bookInitials: String, pageKey: String) -> MyDocumentRawContentPayload? {
        guard let page = page(bookInitials: bookInitials, pageKey: pageKey) else {
            return nil
        }

        return MyDocumentRawContentPayload(
            pageId: page.id.uuidString,
            contentType: page.contentType.rawValue,
            content: page.pageContent?.content ?? "",
            title: page.title,
            sourcePromptId: page.sourcePromptId?.uuidString
        )
    }

    /**
     Returns only the stored raw content for copy/share workflows.
     */
    public func rawContent(bookInitials: String, pageKey: String) -> String? {
        rawContentPayload(bookInitials: bookInitials, pageKey: pageKey)?.content
    }

    /**
     Persists raw editable content for one My Documents page.

     - Parameters:
       - bookInitials: Parent document initials supplied by the bridge.
       - pageId: Stable page UUID supplied by the editor payload.
       - content: Replacement raw page body.
       - title: Optional replacement page title; `nil` preserves the current title.
     - Returns: `true` when a matching page was found and saved.
     */
    @discardableResult
    public func savePageContent(
        bookInitials: String,
        pageId: UUID,
        content: String,
        title: String?
    ) -> Bool {
        guard let page = page(bookInitials: bookInitials, pageId: pageId) else {
            return false
        }

        let now = Date()
        if let title {
            page.title = title
        }
        page.updatedAt = now
        page.document?.updatedAt = now

        if let pageContent = page.pageContent {
            pageContent.content = content
        } else {
            let pageContent = MyDocumentPageContent(pageId: page.id, content: content)
            pageContent.page = page
            page.pageContent = pageContent
            modelContext.insert(pageContent)
        }

        do {
            try modelContext.save()
            return true
        } catch {
            return false
        }
    }

    /**
     Inserts a My Documents graph and saves immediately.
     */
    public func insert(_ document: MyDocument) {
        modelContext.insert(document)
        save()
    }

    /**
     Saves any pending My Documents changes.
     */
    public func save() {
        try? modelContext.save()
    }
}
