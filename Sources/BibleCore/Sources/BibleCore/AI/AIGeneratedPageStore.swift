// AIGeneratedPageStore.swift -- Atomic Android-compatible AI page cache persistence

import Foundation
import SwiftData
import SwordKit

/**
 Identifies one persisted AI-generated My Documents page without exposing managed SwiftData rows.

 Callers use the parent initials and page key for reader navigation. The page identifier remains the
 durable identity used by regeneration, marker selection, and deletion. Construction and access are
 deterministic and have no side effects.
 */
public struct AIGeneratedPageLocation: Equatable, Sendable {
  /// Durable generated-page identity.
  public let pageID: UUID
  /// Android-compatible AI Documents initials.
  public let documentInitials: String
  /// Parent-scoped generated page key.
  public let pageKey: String

  /** Creates one immutable generated-page location. */
  public init(pageID: UUID, documentInitials: String, pageKey: String) {
    self.pageID = pageID
    self.documentInitials = documentInitials
    self.pageKey = pageKey
  }
}

/// Stable failures from Android-compatible AI page cache persistence.
public enum AIGeneratedPageStoreError: Error, Equatable, LocalizedError, Sendable {
  /// More than one document claims Android's reserved AI Documents initials.
  case duplicateAIDocuments
  /// Another installed book already owns the reserved identity, so iOS rejects the first graph.
  case documentIdentityOwned(String)
  /// The complete installed-book registry could not be captured before first publication.
  case registryUnavailable(String)
  /// A generated page could not be associated with its parent after insertion.
  case invalidGeneratedGraph
  /// A regeneration source no longer exists.
  case regenerationPageNotFound
  /// A regeneration page does not belong to Android's reserved AI Documents collection.
  case invalidRegenerationPage
  /// The supplied source context could not be serialized or hashed.
  case invalidSourceContext
  /// SwiftData or the sync journal rejected the transaction.
  case persistenceFailed(String)

  /// Credential-free user-facing description suitable for an execution failure surface.
  public var errorDescription: String? {
    switch self {
    case .duplicateAIDocuments:
      return "More than one AI Documents collection exists."
    case .documentIdentityOwned(let initials):
      return "Another installed document already owns module identity \(initials)."
    case .registryUnavailable:
      return "The installed document registry could not be read."
    case .invalidGeneratedGraph:
      return "The generated page could not be linked to AI Documents."
    case .regenerationPageNotFound:
      return "The AI document page is no longer available."
    case .invalidRegenerationPage:
      return "The AI document page could not be regenerated."
    case .invalidSourceContext:
      return "The AI source context could not be saved."
    case .persistenceFailed:
      return "The generated page could not be saved."
    }
  }
}

/**
 Persists and resolves AI-generated pages using Android's `AiPageCacheEntry` contract.

 Every operation uses a fresh context from the supplied container. A save stages the document,
 page, body, and cache entry together and commits them with the My Documents sync journal.
 Regeneration validates its source without persisting reader presentation state, then atomically
 inserts the completed page and optionally removes the prior result.
 Cache lookup joins through live page/document relationships and chooses the newest matching page,
 just like Android's `AiCachedPageWithContent` queries.

 - Important: The store is main-actor isolated because SwiftData contexts and marker publication
   participate in app-owned UI persistence.
 - Important: First-time identity collision is an intentional fail-closed safety divergence.
   Android persists the AI Documents row/page and then lets JSword skip its hidden registration;
   iOS rejects before graph mutation so generated content cannot become durable but reader-invisible.
 */
@MainActor
public final class AIGeneratedPageStore {
  /// Reserved Android document identity.
  public static let documentInitials = MyDocumentManagementSession.aiDocumentsInitials

  /// Container used to create operation-scoped contexts.
  private let modelContainer: ModelContainer
  /// Broadcast boundary for committed generated-page markers.
  private let markerEventCenter: MyDocumentAIDocMarkerEventCenter
  /// Language resolver kept injectable for deterministic tests.
  private let languageCodeProvider: () -> String?
  /// Canonical root-wide lease shared by every installed-book identity publisher.
  private let mutationCoordinator: ModuleStoreMutationCoordinator
  /// Throwing live ownership check used only before first-time AI Documents publication.
  private let isDocumentInitialsUnavailable: (String) throws -> Bool

  /**
   Creates a generated-page store over the app's My Documents container.

   - Parameters:
     - modelContext: Context whose container owns My Documents and sync-journal models.
     - markerEventCenter: Shared marker broadcast channel.
     - languageCodeProvider: BCP-47 language code assigned to new pages.
     - moduleStoreRootURL: Canonical SWORD root shared by every installed-book publisher.
     - isDocumentInitialsUnavailable: Fresh complete-registry ownership check invoked only when the
       reserved AI Documents row does not already exist. A positive result intentionally rejects
       the complete first graph instead of reproducing Android's durable-but-unregistered row.
   - Side effects: Retains the container only; no reads or writes occur.
   - Failure modes: Initialization itself cannot fail; the injected registry check may fail later
     while saving the first generated page.
   */
  public init(
    modelContext: ModelContext,
    markerEventCenter: MyDocumentAIDocMarkerEventCenter = .shared,
    languageCodeProvider: @escaping () -> String? = {
      Locale.current.language.languageCode?.identifier
    },
    moduleStoreRootURL: URL = URL(
      fileURLWithPath: SwordManager.defaultModulePath(),
      isDirectory: true
    ),
    isDocumentInitialsUnavailable: @escaping (String) throws -> Bool
  ) {
    modelContainer = modelContext.container
    self.markerEventCenter = markerEventCenter
    self.languageCodeProvider = languageCodeProvider
    mutationCoordinator = ModuleStoreMutationCoordinator.shared(forModuleRoot: moduleStoreRootURL)
    self.isDocumentInitialsUnavailable = isDocumentInitialsUnavailable
  }

  /**
   Finds Android's newest cache hit for a prompt and captured source context.

   Strict prompts match the canonical context hash. Loose prompts match only an exact non-null
   KJVA range. Dangling cache rows are ignored because they cannot be opened by the reader.

   - Parameters:
     - prompt: Effective prompt containing strict-versus-loose cache policy.
     - context: Captured output-affecting source context.
   - Returns: Newest matching live page, or `nil` when Android would execute a fresh run.
   - Side effects: Reads SwiftData through a fresh context.
   - Throws: Context hashing or SwiftData fetch failures.
   */
  public func cachedPage(
    for prompt: AgentPrompt,
    context: CacheableContext
  ) throws -> AIGeneratedPageLocation? {
    let modelContext = ModelContext(modelContainer)
    let entries: [AiPageCacheEntry]
    do {
      entries = try modelContext.fetch(FetchDescriptor<AiPageCacheEntry>())
    } catch {
      throw AIGeneratedPageStoreError.persistenceFailed(error.localizedDescription)
    }

    let matches: [AiPageCacheEntry]
    if prompt.strictContextMatching {
      let hash: String
      do {
        hash = try context.computeHash()
      } catch {
        throw AIGeneratedPageStoreError.invalidSourceContext
      }
      matches = entries.filter {
        $0.sourcePromptId == prompt.id && $0.contextHash == hash
      }
    } else {
      guard let start = context.kjvOrdinalStart,
        let end = context.kjvOrdinalEnd
      else {
        return nil
      }
      matches = entries.filter {
        $0.sourcePromptId == prompt.id
          && $0.kjvOrdinalStart == start
          && $0.kjvOrdinalEnd == end
      }
    }

    return
      matches
      .compactMap(Self.locationAndCreatedAt(for:))
      .max { lhs, rhs in
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.location.pageID.uuidString < rhs.location.pageID.uuidString
      }?
      .location
  }

  /**
   Atomically creates an AI Documents page and its complete Android cache metadata.

   - Parameters:
     - content: Raw Markdown model response retained without an injected footer.
     - title: User-visible title, trimmed and limited to Android's 80-character boundary.
     - promptID: Effective source prompt identity.
     - context: Canonical source context used for cache and regeneration.
     - usedWriteTools: Whether this run committed at least one permission-requiring tool.
     - sourceModelName: Provider model identifier, omitted when blank.
   - Returns: Durable page location for reader navigation.
   - Side effects: Under the canonical installed-book lease, may create AI Documents, inserts
     page/content/cache rows, commits the sync journal once, and broadcasts the committed marker.
   - Throws: Duplicate or foreign reserved identities, strict registry failures, context
     serialization/hash failures, or atomic persistence errors. Failed saves roll back every staged
     row and release the root-wide lease before a queued identity publisher proceeds.
   */
  public func save(
    content: String,
    title: String,
    promptID: UUID,
    context: CacheableContext,
    usedWriteTools: Bool,
    sourceModelName: String?
  ) throws -> AIGeneratedPageLocation {
    let metadata = try generatedPageMetadata(
      promptID: promptID,
      context: context,
      usedWriteTools: usedWriteTools,
      sourceModelName: sourceModelName
    )

    return try mutationCoordinator.withExclusiveTransaction(
      kind: .myDocument,
      prepare: { () },
      commit: { _ in
        let modelContext = ModelContext(modelContainer)
        do {
          let now = Date()
          let document = try resolveOrCreateAIDocument(in: modelContext, now: now)
          let staged = try stagePage(
            in: modelContext,
            document: document,
            content: content,
            title: title,
            orderNumber: nil,
            metadata: metadata,
            now: now
          )
          try RemoteSyncMutationJournalService.savePendingGraphChanges(
            for: .myDocuments,
            modelContext: modelContext
          )

          guard let cache = staged.cache else {
            throw AIGeneratedPageStoreError.invalidGeneratedGraph
          }
          let location = Self.location(document: document, page: staged.page)
          markerEventCenter.post(
            MyDocumentAIDocMarkersChangedEvent(
              markers: [
                Self.marker(
                  document: document,
                  page: staged.page,
                  cache: cache
                )
              ]
            )
          )
          return location
        } catch let error as AIGeneratedPageStoreError {
          modelContext.rollback()
          throw error
        } catch {
          modelContext.rollback()
          throw AIGeneratedPageStoreError.persistenceFailed(error.localizedDescription)
        }
      }
    )
  }

  /**
   Validates that one persisted page can serve as an AI regeneration source.

   Android's `ai_document_regenerating` document is reader-local and never enters Room. This
   preflight therefore reads the source graph without inserting a temporary My Documents row or
   journaling a sync mutation.

   - Parameter sourcePageID: Existing generated page selected for regeneration.
   - Side effects: Reads SwiftData through a fresh context; performs no mutation or sync journaling.
   - Throws: Missing/non-AI source pages, duplicate AI Documents containers, or fetch failures.
   */
  public func validateRegenerationSource(sourcePageID: UUID) throws {
    let modelContext = ModelContext(modelContainer)
    do {
      _ = try validatedRegenerationSource(id: sourcePageID, in: modelContext)
    } catch let error as AIGeneratedPageStoreError {
      throw error
    } catch {
      throw AIGeneratedPageStoreError.persistenceFailed(error.localizedDescription)
    }
  }

  /**
   Atomically saves a completed regeneration and optionally replaces its successful source page.

   Reader-visible loading and terminal states remain transient, matching Android's `ErrorDocument`
   presentation. The previous successful page is deleted only in the same transaction that commits
   the new content and cache metadata, avoiding data loss when execution fails or is cancelled.

   - Parameters:
     - sourcePageID: Prior generated page supplying the owning AI Documents collection.
     - replacesSourcePage: Whether success removes the prior generated page.
     - content: Raw completed Markdown response.
     - title: Completed response title.
     - promptID: Effective source prompt identity.
     - context: Canonical source context used by future cache lookup and regeneration.
     - usedWriteTools: Whether the run committed a permission-requiring tool.
     - sourceModelName: Provider model identifier, omitted when blank.
   - Returns: New completed-page location for reader navigation.
   - Side effects: Inserts the complete page/cache graph, optionally removes the prior page,
     commits once, then broadcasts marker additions/deletions.
   - Throws: Invalid source pages, context serialization failures, or atomic persistence failures.
     Rollback retains the prior successful page.
   */
  public func completeRegeneration(
    sourcePageID: UUID,
    replacesSourcePage: Bool,
    content: String,
    title: String,
    promptID: UUID,
    context: CacheableContext,
    usedWriteTools: Bool,
    sourceModelName: String?
  ) throws -> AIGeneratedPageLocation {
    let metadata = try generatedPageMetadata(
      promptID: promptID,
      context: context,
      usedWriteTools: usedWriteTools,
      sourceModelName: sourceModelName
    )
    let modelContext = ModelContext(modelContainer)
    do {
      let sourcePage = try validatedRegenerationSource(id: sourcePageID, in: modelContext)
      guard let document = sourcePage.document else {
        throw AIGeneratedPageStoreError.invalidRegenerationPage
      }

      let now = Date()
      let staged = try stagePage(
        in: modelContext,
        document: document,
        content: content,
        title: title,
        orderNumber: replacesSourcePage ? sourcePage.orderNumber : nil,
        metadata: metadata,
        now: now
      )
      var deletedPageIDs: [UUID] = []
      if replacesSourcePage {
        modelContext.delete(sourcePage)
        deletedPageIDs.append(sourcePageID)
      }
      try RemoteSyncMutationJournalService.savePendingGraphChanges(
        for: .myDocuments,
        modelContext: modelContext
      )

      guard let cache = staged.cache else {
        throw AIGeneratedPageStoreError.invalidGeneratedGraph
      }
      let location = Self.location(document: document, page: staged.page)
      markerEventCenter.post(
        MyDocumentAIDocMarkersChangedEvent(
          markers: [
            Self.marker(
              document: document,
              page: staged.page,
              cache: cache
            )
          ],
          deletedPageIDs: deletedPageIDs
        )
      )
      return location
    } catch let error as AIGeneratedPageStoreError {
      modelContext.rollback()
      throw error
    } catch {
      modelContext.rollback()
      throw AIGeneratedPageStoreError.persistenceFailed(error.localizedDescription)
    }
  }

  /** Fully serialized metadata staged with one completed generated page. */
  private struct GeneratedPageMetadata {
    /// Effective prompt identity.
    let promptID: UUID
    /// Canonical source context JSON.
    let sourceJSON: String
    /// Canonical context digest used by strict cache lookup.
    let contextHash: String
    /// Captured cache context fields that do not require recomputation.
    let context: CacheableContext
    /// Whether the run committed at least one write tool.
    let usedWriteTools: Bool
    /// Normalized provider model identifier.
    let sourceModelName: String?
  }

  /** Page graph staged in an operation context before the transaction commits. */
  private struct StagedPage {
    /// Inserted page row.
    let page: MyDocumentPage
    /// Inserted cache row for completed pages; transient and failure pages omit it.
    let cache: AiPageCacheEntry?
  }

  /**
   Serializes and hashes cache context before opening a persistence transaction.

   - Parameters:
     - promptID: Effective prompt identity.
     - context: Captured output-affecting context.
     - usedWriteTools: Whether a permission-requiring tool committed.
     - sourceModelName: Provider model identifier, normalized when present.
   - Returns: Complete immutable metadata for one final generated page.
   - Side effects: None.
   - Throws: `invalidSourceContext` when canonical serialization or hashing fails.
   */
  private func generatedPageMetadata(
    promptID: UUID,
    context: CacheableContext,
    usedWriteTools: Bool,
    sourceModelName: String?
  ) throws -> GeneratedPageMetadata {
    do {
      return GeneratedPageMetadata(
        promptID: promptID,
        sourceJSON: try context.canonicalJSON(),
        contextHash: try context.computeHash(),
        context: context,
        usedWriteTools: usedWriteTools,
        sourceModelName: sourceModelName?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .nilIfEmpty
      )
    } catch {
      throw AIGeneratedPageStoreError.invalidSourceContext
    }
  }

  /**
   Resolves Android's reserved AI Documents container or creates it with Android metadata/order.

   Android assigns the container order zero, then renumbers every existing document from one in
   current display order. Its name/initials are stable English identifiers and the description is
   persisted as `Automatically generated documents from AI`.

   - Parameters:
     - modelContext: Operation-scoped SwiftData context.
     - now: Shared creation timestamp for the new graph.
   - Returns: The sole reserved AI Documents row.
   - Side effects: When no container exists, reads the injected complete registry before renumbering
     existing documents and inserting the reserved container into the operation context.
   - Throws: Fetch failures, `duplicateAIDocuments`, foreign identity ownership, or strict registry
     capture failures. Registry checks occur before any staged graph mutation.
   - Important: The caller must hold `mutationCoordinator` so admission and publication are one
     serialization boundary with native, SQLite, EPUB, and interactive My Documents writers.
   - Important: Foreign ownership is an intentional safety divergence from Android, which saves the
     row/page before its BookSet registration can be skipped. iOS leaves zero invisible AI graph.
   */
  private func resolveOrCreateAIDocument(
    in modelContext: ModelContext,
    now: Date
  ) throws -> MyDocument {
    let allDocuments = try modelContext.fetch(FetchDescriptor<MyDocument>())
    let aiDocuments = allDocuments.filter { $0.initials == Self.documentInitials }
    guard aiDocuments.count <= 1 else {
      throw AIGeneratedPageStoreError.duplicateAIDocuments
    }
    if let existing = aiDocuments.first { return existing }

    let identityIsUnavailable: Bool
    do {
      identityIsUnavailable = try isDocumentInitialsUnavailable(Self.documentInitials)
    } catch let error as AIGeneratedPageStoreError {
      throw error
    } catch {
      throw AIGeneratedPageStoreError.registryUnavailable(error.localizedDescription)
    }
    guard !identityIsUnavailable else {
      throw AIGeneratedPageStoreError.documentIdentityOwned(Self.documentInitials)
    }

    let orderedDocuments = allDocuments.sorted { lhs, rhs in
      if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
      if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    for (index, document) in orderedDocuments.enumerated() {
      document.orderNumber = index + 1
    }
    let document = MyDocument(
      name: "AI Documents",
      documentDescription: "Automatically generated documents from AI",
      initials: Self.documentInitials,
      orderNumber: 0,
      createdAt: now,
      updatedAt: now,
      sourcePromptId: nil
    )
    document.pages = []
    modelContext.insert(document)
    return document
  }

  /**
   Stages one Markdown page and optional Android cache row in the supplied transaction context.

   - Parameters:
     - modelContext: Operation-scoped SwiftData context.
     - document: Reserved AI Documents owner.
     - content: Raw Markdown body.
     - title: User-visible title normalized to Android's storage boundary.
     - orderNumber: Explicit replacement position, or `nil` to append.
     - metadata: Completed generation metadata; `nil` creates an uncached transient/user page.
     - now: Shared mutation timestamp.
   - Returns: Staged page and optional cache row.
   - Side effects: Inserts rows and mutates the owning document relationship/timestamp in memory.
   - Throws: `invalidGeneratedGraph` if relationship wiring is incomplete.
   */
  private func stagePage(
    in modelContext: ModelContext,
    document: MyDocument,
    content: String,
    title: String,
    orderNumber: Int?,
    metadata: GeneratedPageMetadata?,
    now: Date
  ) throws -> StagedPage {
    let existingPages = document.pages ?? []
    let pageID = UUID()
    let page = MyDocumentPage(
      id: pageID,
      title: Self.normalizedTitle(title),
      pageKey: "ai_\(pageID.uuidString.lowercased())",
      contentType: .markdown,
      orderNumber: orderNumber ?? (existingPages.map(\.orderNumber).max() ?? -1) + 1,
      createdAt: now,
      updatedAt: now,
      sourcePromptId: metadata?.promptID,
      languageCode: languageCodeProvider()
    )
    let pageContent = MyDocumentPageContent(pageId: pageID, content: content)
    let cacheEntry = metadata.map {
      AiPageCacheEntry(
        pageId: pageID,
        sourcePromptId: $0.promptID,
        sourceContext: $0.sourceJSON,
        kjvOrdinalStart: $0.context.kjvOrdinalStart,
        kjvOrdinalEnd: $0.context.kjvOrdinalEnd,
        contextHash: $0.contextHash,
        usedWriteTools: $0.usedWriteTools,
        sourceModelName: $0.sourceModelName,
        sourceBookInitials: $0.context.activeDocumentInitials,
        sourceBookKey: $0.context.sourceBookKey
      )
    }
    page.document = document
    document.pages = existingPages + [page]
    document.updatedAt = now
    pageContent.page = page
    page.pageContent = pageContent
    cacheEntry?.page = page
    page.aiPageCacheEntries = cacheEntry.map { [$0] }
    modelContext.insert(page)
    modelContext.insert(pageContent)
    if let cacheEntry { modelContext.insert(cacheEntry) }

    guard page.document?.id == document.id,
      page.pageContent?.pageId == pageID,
      metadata == nil || page.aiPageCacheEntries?.first?.pageId == pageID
    else {
      throw AIGeneratedPageStoreError.invalidGeneratedGraph
    }
    return StagedPage(page: page, cache: cacheEntry)
  }

  /**
   Resolves one valid generated source inside the sole Android AI Documents collection.

   - Parameters:
     - id: Durable generated-page identity.
     - modelContext: Operation-scoped context used for all validation reads.
   - Returns: The generated page associated with the reserved collection.
   - Side effects: Reads page and document rows without mutating them.
   - Throws: Missing pages, duplicate collections, or rows without generated-page provenance.
   */
  private func validatedRegenerationSource(
    id: UUID,
    in modelContext: ModelContext
  ) throws -> MyDocumentPage {
    let sourcePage = try requiredPage(id: id, in: modelContext)
    guard let document = sourcePage.document,
      document.initials == Self.documentInitials,
      sourcePage.sourcePromptId != nil
        || !(sourcePage.aiPageCacheEntries ?? []).isEmpty
    else {
      throw AIGeneratedPageStoreError.invalidRegenerationPage
    }
    let aiDocuments = try modelContext.fetch(FetchDescriptor<MyDocument>())
      .filter { $0.initials == Self.documentInitials }
    guard aiDocuments.count == 1 else {
      throw aiDocuments.isEmpty
        ? AIGeneratedPageStoreError.invalidRegenerationPage
        : AIGeneratedPageStoreError.duplicateAIDocuments
    }
    guard aiDocuments[0].id == document.id else {
      throw AIGeneratedPageStoreError.invalidRegenerationPage
    }
    return sourcePage
  }

  /** Returns one exact page or throws when its durable UUID is missing/ambiguous. */
  private func requiredPage(
    id: UUID,
    in modelContext: ModelContext
  ) throws -> MyDocumentPage {
    guard let page = try optionalPage(id: id, in: modelContext) else {
      throw AIGeneratedPageStoreError.regenerationPageNotFound
    }
    return page
  }

  /** Returns one exact page, nil when absent, and rejects duplicate durable UUIDs. */
  private func optionalPage(
    id: UUID,
    in modelContext: ModelContext
  ) throws -> MyDocumentPage? {
    let matches = try modelContext.fetch(FetchDescriptor<MyDocumentPage>())
      .filter { $0.id == id }
    guard matches.count <= 1 else {
      throw AIGeneratedPageStoreError.invalidGeneratedGraph
    }
    return matches.first
  }

  /** Projects a staged or committed page into its durable reader navigation identity. */
  private static func location(
    document: MyDocument,
    page: MyDocumentPage
  ) -> AIGeneratedPageLocation {
    AIGeneratedPageLocation(
      pageID: page.id,
      documentInitials: document.initials,
      pageKey: page.pageKey
    )
  }

  /** Returns a live location and creation time for one cache row, or nil for a dangling row. */
  private static func locationAndCreatedAt(
    for entry: AiPageCacheEntry
  ) -> (location: AIGeneratedPageLocation, createdAt: Date)? {
    guard let page = entry.page,
      let document = page.document
    else {
      return nil
    }
    return (
      AIGeneratedPageLocation(
        pageID: page.id,
        documentInitials: document.initials,
        pageKey: page.pageKey
      ),
      page.createdAt
    )
  }

  /** Projects one committed row into the app-wide marker transport. */
  private static func marker(
    document: MyDocument,
    page: MyDocumentPage,
    cache: AiPageCacheEntry
  ) -> MyDocumentAIDocMarker {
    MyDocumentAIDocMarker(
      pageId: page.id,
      documentId: document.id,
      documentInitials: document.initials,
      pageTitle: page.title,
      pageKey: page.pageKey,
      kjvOrdinalStart: cache.kjvOrdinalStart,
      kjvOrdinalEnd: cache.kjvOrdinalEnd,
      sourcePromptId: cache.sourcePromptId,
      sourceBookInitials: cache.sourceBookInitials,
      sourceBookKey: cache.sourceBookKey
    )
  }

  /** Applies Android's non-empty title and 80-character storage boundary. */
  private static func normalizedTitle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return String((trimmed.isEmpty ? "AI Document" : trimmed).prefix(80))
  }
}

/// Internal optional-string normalization used only for persisted model metadata.
extension String {
  /// Returns nil for an empty string without changing non-empty Unicode content.
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
