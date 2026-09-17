// MyDocumentDeletionBoundary.swift -- Durable My Documents child-first deletion staging

import Foundation
import SwiftData

/**
 Stages Android-equivalent My Documents deletions in one caller-owned context.

 Android's My Documents tables enforce `ON DELETE CASCADE` from a page to its content and AI cache
 rows. SwiftData models the same ownership relationships, but its SQLite store does not install
 foreign keys and supported iOS 17 runtimes can persist the parent deletion without deleting the
 related children. This boundary therefore resolves children by their exact Android `pageId`
 identity and stages them before their parent.

 The helper deliberately does not save, roll back, or publish events. Callers retain ownership of
 their journal transaction and can discard an isolated non-autosaving context after any failure.
 */
enum MyDocumentDeletionBoundary {
    /**
     Stages one page and every detached row Android would delete through its page foreign key.

     - Parameters:
       - page: Persisted page owned by `modelContext`.
       - modelContext: Isolated context receiving all child and parent deletions.
     - Side effects: Fetches exact `pageId` content/cache rows, stages every match for deletion,
       then stages the page.
     - Failure modes: Rethrows either child fetch failure before the page is staged. A caller that
       catches an error must discard the operation context rather than save its partial mutations.
     */
    static func stagePageDeletion(
        _ page: MyDocumentPage,
        in modelContext: ModelContext
    ) throws {
        let pageID = page.id
        let contents = try modelContext.fetch(
            FetchDescriptor<MyDocumentPageContent>(
                predicate: #Predicate { $0.pageId == pageID }
            )
        )
        let cacheEntries = try modelContext.fetch(
            FetchDescriptor<AiPageCacheEntry>(
                predicate: #Predicate { $0.pageId == pageID }
            )
        )

        for cacheEntry in cacheEntries {
            modelContext.delete(cacheEntry)
        }
        for content in contents {
            modelContext.delete(content)
        }
        modelContext.delete(page)
    }

    /**
     Stages one document after every page-owned child graph has been staged for deletion.

     - Parameters:
       - document: Persisted document owned by `modelContext`.
       - modelContext: Isolated context receiving all descendant and document deletions.
     - Side effects: Fetches pages by exact parent UUID, stages each through
       `stagePageDeletion(_:in:)`, then stages the document.
     - Failure modes: Rethrows page or child fetch failures. The caller must discard the operation
       context rather than commit after an error.
     */
    static func stageDocumentDeletion(
        _ document: MyDocument,
        in modelContext: ModelContext
    ) throws {
        let documentID = document.id
        let pages = try modelContext.fetch(
            FetchDescriptor<MyDocumentPage>(
                predicate: #Predicate { $0.document?.id == documentID }
            )
        )
        for page in pages {
            try stagePageDeletion(page, in: modelContext)
        }
        modelContext.delete(document)
    }
}
