import SwiftData
import XCTest

@testable import BibleCore

/**
 Protects Android's generated-page transaction and strict/loose cache lookup contracts.

 Tests use an in-memory My Documents graph without `Setting`, so the production sync-journal helper
 deliberately takes its documented graph-only direct-save path. Marker delivery uses an isolated
 event center and is synchronous, making assertions deterministic without sleeps.
 */
@MainActor
final class AIGeneratedPageStoreTests: XCTestCase {
  /**
   Verifies page metadata, content, cache identity, and marker publication commit together.

   A failure means iOS could create an unreadable or non-regenerable AI page, or show no source
   marker even though Android would publish one after the transaction.
   */
  func testSaveCommitsCompleteAndroidGeneratedPageGraphAndMarker() throws {
    let container = try makeContainer()
    let context = ModelContext(container)
    let events = LockedMarkerEvents()
    let center = MyDocumentAIDocMarkerEventCenter()
    let observation = center.observe { events.append($0) }
    let store = AIGeneratedPageStore(
      modelContext: context,
      markerEventCenter: center,
      languageCodeProvider: { "en" }
    )
    let promptID = UUID()
    let cacheContext = CacheableContext(
      kjvOrdinalStart: 4,
      kjvOrdinalEnd: 5,
      activeDocumentInitials: "KJV",
      selectedContent: "<verse>In the beginning</verse>",
      selectedText: "In the beginning",
      highlightedText: nil,
      selectionStartOffset: nil,
      selectionEndOffset: nil,
      sourceBookKey: "Gen.1.1-Gen.1.2"
    )

    let location = try store.save(
      content: "# Result\nBody",
      title: "Result",
      promptID: promptID,
      context: cacheContext,
      usedWriteTools: true,
      sourceModelName: "model-a"
    )

    let verification = ModelContext(container)
    let document = try XCTUnwrap(
      verification.fetch(FetchDescriptor<MyDocument>()).first
    )
    let page = try XCTUnwrap(
      verification.fetch(FetchDescriptor<MyDocumentPage>()).first
    )
    let cache = try XCTUnwrap(
      verification.fetch(FetchDescriptor<AiPageCacheEntry>()).first
    )
    XCTAssertEqual(document.initials, "AIDocuments")
    XCTAssertEqual(page.id, location.pageID)
    XCTAssertEqual(page.pageKey, location.pageKey)
    XCTAssertEqual(page.pageContent?.content, "# Result\nBody")
    XCTAssertEqual(page.languageCode, "en")
    XCTAssertEqual(cache.sourceContext, try cacheContext.canonicalJSON())
    XCTAssertEqual(cache.contextHash, try cacheContext.computeHash())
    XCTAssertEqual(cache.kjvOrdinalStart, 4)
    XCTAssertEqual(cache.kjvOrdinalEnd, 5)
    XCTAssertTrue(cache.usedWriteTools)
    XCTAssertEqual(cache.sourceModelName, "model-a")
    XCTAssertEqual(cache.sourceBookInitials, "KJV")
    XCTAssertEqual(cache.sourceBookKey, "Gen.1.1-Gen.1.2")
    XCTAssertEqual(events.values.single?.markers.single?.pageId, location.pageID)
    XCTAssertEqual(events.values.single?.markers.single?.sourcePromptId, promptID)
    withExtendedLifetime(observation) {}
  }

  /**
   Verifies strict cache matching uses the full canonical hash while loose matching uses only the
   exact KJVA range and returns the newest matching page.

   A failure would either reuse content for the wrong translation/selection or miss Android's
   cross-version loose cache behavior.
   */
  func testCacheLookupMatchesAndroidStrictAndLooseQueries() throws {
    let container = try makeContainer()
    let store = AIGeneratedPageStore(modelContext: ModelContext(container))
    let promptID = UUID()
    let strictPrompt = prompt(id: promptID, strict: true)
    let loosePrompt = prompt(id: promptID, strict: false)
    let firstContext = cacheContext(selectedText: "first")
    let secondContext = cacheContext(selectedText: "second")

    let first = try store.save(
      content: "First",
      title: "First",
      promptID: promptID,
      context: firstContext,
      usedWriteTools: false,
      sourceModelName: nil
    )
    let second = try store.save(
      content: "Second",
      title: "Second",
      promptID: promptID,
      context: secondContext,
      usedWriteTools: false,
      sourceModelName: nil
    )

    XCTAssertEqual(try store.cachedPage(for: strictPrompt, context: firstContext), first)
    XCTAssertEqual(try store.cachedPage(for: strictPrompt, context: secondContext), second)
    XCTAssertEqual(try store.cachedPage(for: loosePrompt, context: firstContext), second)
    XCTAssertNil(
      try store.cachedPage(
        for: loosePrompt,
        context: CacheableContext(
          kjvOrdinalStart: nil,
          kjvOrdinalEnd: nil,
          activeDocumentInitials: "Commentary",
          selectedContent: nil,
          selectedText: "text",
          highlightedText: nil,
          selectionStartOffset: nil,
          selectionEndOffset: nil
        )
      )
    )
  }

  /**
   Verifies first-time AI Documents creation matches Android's metadata and ordering transaction.

   - Setup: Persists two ordinary documents in display order before saving the first generated
     page through `AIGeneratedPageStore`.
   - Expected result: AI Documents owns order zero and Android's exact description while the
     existing documents are shifted to contiguous orders one and two.
   - Failure meaning: iOS would surface AI Documents at the end of My Documents or sync divergent
     container metadata to Android.
   - Side effects: Uses only an in-memory SwiftData container.
   */
  func testFirstGeneratedPageCreatesAndroidOrderedAIDocumentsContainer() throws {
    let container = try makeContainer()
    let setup = ModelContext(container)
    let second = MyDocument(
      name: "Second",
      initials: "MyDoc_Second",
      orderNumber: 1,
      createdAt: Date(timeIntervalSince1970: 2)
    )
    let first = MyDocument(
      name: "First",
      initials: "MyDoc_First",
      orderNumber: 0,
      createdAt: Date(timeIntervalSince1970: 1)
    )
    setup.insert(second)
    setup.insert(first)
    try setup.save()

    let store = AIGeneratedPageStore(modelContext: setup)
    _ = try store.save(
      content: "Generated",
      title: "Generated",
      promptID: UUID(),
      context: cacheContext(selectedText: "source"),
      usedWriteTools: false,
      sourceModelName: nil
    )

    let documents = try ModelContext(container).fetch(FetchDescriptor<MyDocument>())
      .sorted { $0.orderNumber < $1.orderNumber }
    XCTAssertEqual(documents.map(\.initials), ["AIDocuments", "MyDoc_First", "MyDoc_Second"])
    XCTAssertEqual(documents.map(\.orderNumber), [0, 1, 2])
    XCTAssertEqual(
      documents.first?.documentDescription,
      "Automatically generated documents from AI"
    )
    XCTAssertNil(documents.first?.sourcePromptId)
  }

  /**
   Verifies replacement regeneration keeps the successful source until final content commits.

   - Setup: Saves one cached generated page, validates it without mutation, then completes a
     regeneration while asking the store to replace the source page.
   - Expected result: Validation creates no temporary page or sync mutation. Completion atomically
     removes the old identity, inserts a newly cached final page, and publishes one marker addition
     plus the old marker deletion.
   - Failure meaning: A failed or interrupted regeneration could destroy the only successful
     result or leak reader-local status into synced persistence.
   - Side effects: Commits only to an in-memory container and records synchronous marker events.
   */
  func testRegenerationReplacesSourceOnlyAfterCompletedPageCommits() throws {
    let container = try makeContainer()
    let events = LockedMarkerEvents()
    let center = MyDocumentAIDocMarkerEventCenter()
    let observation = center.observe { events.append($0) }
    let store = AIGeneratedPageStore(
      modelContext: ModelContext(container),
      markerEventCenter: center,
      languageCodeProvider: { "en" }
    )
    let promptID = UUID()
    let context = cacheContext(selectedText: "source")
    let source = try store.save(
      content: "Previous response",
      title: "Previous",
      promptID: promptID,
      context: context,
      usedWriteTools: false,
      sourceModelName: "old-model"
    )

    try store.validateRegenerationSource(sourcePageID: source.pageID)
    let duringRunPages = try ModelContext(container).fetch(FetchDescriptor<MyDocumentPage>())
    let duringSource = try XCTUnwrap(duringRunPages.first { $0.id == source.pageID })
    XCTAssertEqual(duringRunPages.count, 1)
    XCTAssertEqual(duringSource.pageContent?.content, "Previous response")
    XCTAssertEqual(duringSource.aiPageCacheEntries?.count, 1)

    let completed = try store.completeRegeneration(
      sourcePageID: source.pageID,
      replacesSourcePage: true,
      content: "Replacement response",
      title: "Replacement",
      promptID: promptID,
      context: context,
      usedWriteTools: true,
      sourceModelName: "new-model"
    )

    let completedPages = try ModelContext(container).fetch(FetchDescriptor<MyDocumentPage>())
    XCTAssertNil(completedPages.first { $0.id == source.pageID })
    let finalPage = try XCTUnwrap(completedPages.first { $0.id == completed.pageID })
    XCTAssertEqual(finalPage.pageContent?.content, "Replacement response")
    XCTAssertEqual(finalPage.sourcePromptId, promptID)
    XCTAssertEqual(finalPage.aiPageCacheEntries?.first?.sourceModelName, "new-model")
    XCTAssertEqual(events.values.last?.deletedPageIDs, [source.pageID])
    XCTAssertEqual(events.values.last?.markers.single?.pageId, completed.pageID)
    withExtendedLifetime(observation) {}
  }

  /**
   Verifies keep-previous regeneration retains both successful pages without transient persistence.

   - Setup: Saves one cached generated page, gives it an unambiguously older creation time, begins
   regeneration, and completes without replacing the source page.
   - Expected result: Source and completed pages each retain cache metadata, no temporary page is
     inserted, no marker deletion is broadcast, and future lookup selects the newer result.
   - Failure meaning: Android's keep-previous option could silently delete its source, leave transient
     content behind, or keep reopening the superseded cache entry.
   - Side effects: Commits only to an in-memory container and records synchronous marker events.
   */
  func testRegenerationKeepPreviousRetainsSourceAndCachesNewestResult() throws {
    let container = try makeContainer()
    let events = LockedMarkerEvents()
    let center = MyDocumentAIDocMarkerEventCenter()
    let observation = center.observe { events.append($0) }
    let store = AIGeneratedPageStore(
      modelContext: ModelContext(container),
      markerEventCenter: center,
      languageCodeProvider: { "en" }
    )
    let promptID = UUID()
    let context = cacheContext(selectedText: "source")
    let source = try store.save(
      content: "Previous response",
      title: "Previous",
      promptID: promptID,
      context: context,
      usedWriteTools: false,
      sourceModelName: "old-model"
    )
    let timestampContext = ModelContext(container)
    let sourcePage = try XCTUnwrap(
      timestampContext.fetch(FetchDescriptor<MyDocumentPage>())
        .first { $0.id == source.pageID }
    )
    sourcePage.createdAt = Date(timeIntervalSince1970: 1)
    try timestampContext.save()
    try store.validateRegenerationSource(sourcePageID: source.pageID)

    let completed = try store.completeRegeneration(
      sourcePageID: source.pageID,
      replacesSourcePage: false,
      content: "Additional response",
      title: "Additional",
      promptID: promptID,
      context: context,
      usedWriteTools: false,
      sourceModelName: "new-model"
    )

    let pages = try ModelContext(container).fetch(FetchDescriptor<MyDocumentPage>())
    XCTAssertNotNil(pages.first { $0.id == source.pageID })
    XCTAssertNotNil(pages.first { $0.id == completed.pageID })
    XCTAssertEqual(
      pages.filter { $0.id == source.pageID || $0.id == completed.pageID }
        .compactMap { $0.aiPageCacheEntries?.single }
        .count,
      2
    )
    XCTAssertEqual(events.values.last?.deletedPageIDs, [])
    XCTAssertEqual(events.values.last?.markers.single?.pageId, completed.pageID)
    XCTAssertEqual(
      try store.cachedPage(for: prompt(id: promptID, strict: true), context: context),
      completed
    )
    withExtendedLifetime(observation) {}
  }

  /**
   Verifies regeneration validation is read-only and leaves terminal presentation outside storage.

   - Setup: Saves a successful generated page and validates it as a regeneration source.
   - Expected result: The source page/cache remain the only persisted graph and cache lookup still
     returns the prior successful page.
   - Failure meaning: Reader-local loading or failure state could leak into sync and later reopen as
     a durable My Documents page.
   - Side effects: Uses only an in-memory SwiftData container.
   */
  func testRegenerationValidationLeavesPersistedPagesUntouched() throws {
    let container = try makeContainer()
    let store = AIGeneratedPageStore(modelContext: ModelContext(container))
    let promptID = UUID()
    let context = cacheContext(selectedText: "source")
    let source = try store.save(
      content: "Previous response",
      title: "Previous",
      promptID: promptID,
      context: context,
      usedWriteTools: false,
      sourceModelName: nil
    )
    try store.validateRegenerationSource(sourcePageID: source.pageID)

    let pages = try ModelContext(container).fetch(FetchDescriptor<MyDocumentPage>())
    XCTAssertEqual(pages.count, 1)
    let retainedSource = try XCTUnwrap(pages.first { $0.id == source.pageID })
    XCTAssertEqual(retainedSource.pageContent?.content, "Previous response")
    XCTAssertEqual(retainedSource.aiPageCacheEntries?.count, 1)
    XCTAssertEqual(
      try store.cachedPage(for: prompt(id: promptID, strict: true), context: context),
      source
    )
  }

  /** Creates an unmanaged prompt with only cache behavior varied. */
  private func prompt(id: UUID, strict: Bool) -> AgentPrompt {
    AgentPrompt(
      id: id,
      name: "Explain",
      promptTemplate: "Explain",
      showIn: [.verseSelection],
      strictContextMatching: strict
    )
  }

  /** Creates two contexts that share a KJVA range but differ under strict hashing. */
  private func cacheContext(selectedText: String) -> CacheableContext {
    CacheableContext(
      kjvOrdinalStart: 4,
      kjvOrdinalEnd: 4,
      activeDocumentInitials: "KJV",
      selectedContent: nil,
      selectedText: selectedText,
      highlightedText: nil,
      selectionStartOffset: nil,
      selectionEndOffset: nil,
      sourceBookKey: "Gen.1.1"
    )
  }

  /** Builds the graph-only in-memory schema needed by generated-page persistence. */
  private func makeContainer() throws -> ModelContainer {
    let schema = Schema([
      MyDocument.self,
      MyDocumentPage.self,
      MyDocumentPageContent.self,
      AiPageCacheEntry.self,
    ])
    return try ModelContainer(
      for: schema,
      configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
    )
  }
}

/// Lock-backed marker recorder because the event center's callback is not actor isolated.
private final class LockedMarkerEvents: @unchecked Sendable {
  /// Protects callback writes and test reads.
  private let lock = NSLock()
  /// Backing events in delivery order.
  private var storage: [MyDocumentAIDocMarkersChangedEvent] = []

  /** Appends one synchronously delivered event. */
  func append(_ event: MyDocumentAIDocMarkersChangedEvent) {
    lock.lock()
    storage.append(event)
    lock.unlock()
  }

  /** Returns an immutable delivery snapshot. */
  var values: [MyDocumentAIDocMarkersChangedEvent] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

/// Test-only exact-one projection that keeps assertions readable and fail-closed.
extension Array {
  /// Returns the sole element or nil when the collection is empty or ambiguous.
  fileprivate var single: Element? { count == 1 ? first : nil }
}
