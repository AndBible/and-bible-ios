// BookmarkStore.swift — Bookmark persistence operations

import Foundation
import SwiftData

/// Manages bookmark, label, and StudyPad persistence operations.
@Observable
public final class BookmarkStore {
    private let modelContext: ModelContext

    /// Creates a bookmark store bound to the caller's SwiftData context.
    /// - Parameter modelContext: Context used for all bookmark, label, and StudyPad queries.
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Bible Bookmarks

    /// Fetches Bible bookmarks using the requested sort order.
    /// - Parameters:
    ///   - labelId: Optional label filter. When present, results are filtered after fetch by
    ///     inspecting the bookmark-to-label relationship.
    ///   - sortOrder: Ordering strategy for the returned bookmarks.
    /// - Returns: Matching Bible bookmarks.
    public func bibleBookmarks(labelId: UUID? = nil, sortOrder: BookmarkSortOrder = .bibleOrder) -> [BibleBookmark] {
        var descriptor = FetchDescriptor<BibleBookmark>()

        switch sortOrder {
        case .bibleOrder:
            descriptor.sortBy = [SortDescriptor(\.kjvOrdinalStart)]
        case .bibleOrderDesc:
            descriptor.sortBy = [SortDescriptor(\.kjvOrdinalStart, order: .reverse)]
        case .createdAt:
            descriptor.sortBy = [SortDescriptor(\.createdAt)]
        case .createdAtDesc:
            descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        case .lastUpdated:
            descriptor.sortBy = [SortDescriptor(\.lastUpdatedOn, order: .reverse)]
        case .orderNumber:
            descriptor.sortBy = [SortDescriptor(\.kjvOrdinalStart)]
        }

        let results = (try? modelContext.fetch(descriptor)) ?? []
        guard let labelId else { return results }
        return results.filter { bookmark in
            bookmark.bookmarkToLabels?.contains { $0.label?.id == labelId } ?? false
        }
    }

    /// Fetches a single Bible bookmark by primary key.
    /// - Parameter id: Bookmark UUID.
    /// - Returns: The bookmark when found, otherwise `nil`.
    public func bibleBookmark(id: UUID) -> BibleBookmark? {
        var descriptor = FetchDescriptor<BibleBookmark>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Fetches Bible bookmarks whose stored KJVA ordinal range overlaps the given range.
    /// - Parameters:
    ///   - startOrdinal: Inclusive start of the query range.
    ///   - endOrdinal: Inclusive end of the query range.
    ///   - book: Optional book name filter used to avoid cross-book collisions when the current
    ///     ordinal scheme is only unique within a book.
    /// - Returns: Overlapping bookmarks.
    public func bibleBookmarks(overlapping startOrdinal: Int, endOrdinal: Int, book: String? = nil) -> [BibleBookmark] {
        let descriptor: FetchDescriptor<BibleBookmark>
        if let book {
            descriptor = FetchDescriptor<BibleBookmark>(
                predicate: #Predicate {
                    $0.kjvOrdinalStart <= endOrdinal && $0.kjvOrdinalEnd >= startOrdinal && $0.book == book
                }
            )
        } else {
            descriptor = FetchDescriptor<BibleBookmark>(
                predicate: #Predicate {
                    $0.kjvOrdinalStart <= endOrdinal && $0.kjvOrdinalEnd >= startOrdinal
                }
            )
        }
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Inserts a new Bible bookmark and immediately saves the context.
    /// - Parameter bookmark: Bookmark to persist.
    public func insert(_ bookmark: BibleBookmark) {
        modelContext.insert(bookmark)
        save()
    }

    /// Inserts a Bible-to-label junction row and immediately saves the context.
    /// - Parameter btl: Junction row linking a bookmark and a label.
    public func insert(_ btl: BibleBookmarkToLabel) {
        modelContext.insert(btl)
        save()
    }

    /// Deletes a Bible bookmark and relies on SwiftData cascade rules for attached notes/junctions.
    /// - Parameter bookmark: Bookmark to delete.
    public func delete(_ bookmark: BibleBookmark) {
        modelContext.delete(bookmark)
        save()
    }

    /// Deletes a Bible bookmark by ID when it exists.
    /// - Parameter id: Bookmark UUID.
    public func deleteBibleBookmark(id: UUID) {
        if let bookmark = bibleBookmark(id: id) {
            delete(bookmark)
        }
    }

    // MARK: - Generic Bookmarks

    /// Fetches all generic bookmarks ordered by most recent creation time first.
    /// - Returns: Generic bookmarks across all non-Bible documents.
    public func genericBookmarks() -> [GenericBookmark] {
        let descriptor = FetchDescriptor<GenericBookmark>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetches a single generic bookmark by primary key.
    /// - Parameter id: Bookmark UUID.
    /// - Returns: The bookmark when found, otherwise `nil`.
    public func genericBookmark(id: UUID) -> GenericBookmark? {
        var descriptor = FetchDescriptor<GenericBookmark>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Inserts a new generic bookmark and immediately saves the context.
    /// - Parameter bookmark: Bookmark to persist.
    public func insert(_ bookmark: GenericBookmark) {
        modelContext.insert(bookmark)
        save()
    }

    /// Inserts a generic-bookmark-to-label junction row and immediately saves the context.
    /// - Parameter gbtl: Junction row linking a generic bookmark and a label.
    public func insert(_ gbtl: GenericBookmarkToLabel) {
        modelContext.insert(gbtl)
        save()
    }

    /// Deletes a generic bookmark and relies on SwiftData cascade rules for attached notes/junctions.
    /// - Parameter bookmark: Bookmark to delete.
    public func delete(_ bookmark: GenericBookmark) {
        modelContext.delete(bookmark)
        save()
    }

    // MARK: - Labels

    /// Fetches labels ordered by name.
    /// - Parameter includeSystem: Whether reserved internal labels should be included.
    /// - Returns: Matching labels.
    public func labels(includeSystem: Bool = false) -> [Label] {
        let descriptor = FetchDescriptor<Label>(
            sortBy: [SortDescriptor(\.name)]
        )
        var results = (try? modelContext.fetch(descriptor)) ?? []
        if !includeSystem {
            results = results.filter { $0.isRealLabel }
        }
        return results
    }

    /// Fetches a label by primary key.
    /// - Parameter id: Label UUID.
    /// - Returns: The label when found, otherwise `nil`.
    public func label(id: UUID) -> Label? {
        var descriptor = FetchDescriptor<Label>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Inserts a new label and immediately saves the context.
    /// - Parameter label: Label to persist.
    public func insert(_ label: Label) {
        modelContext.insert(label)
        save()
    }

    /// Deletes a label and relies on SwiftData cascade rules for attached StudyPad entries.
    /// - Parameter label: Label to delete.
    public func delete(_ label: Label) {
        modelContext.delete(label)
        save()
    }

    // MARK: - StudyPad

    /// Fetches StudyPad entries for a label ordered by `orderNumber`.
    /// - Parameter labelId: Label UUID owning the StudyPad.
    /// - Returns: Entries belonging to that label.
    /// - Note: The current implementation sorts in SwiftData, then filters by relationship in
    ///   memory.
    public func studyPadEntries(labelId: UUID) -> [StudyPadTextEntry] {
        let descriptor = FetchDescriptor<StudyPadTextEntry>(
            sortBy: [SortDescriptor(\.orderNumber)]
        )
        // Filter by label relationship after fetch
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.label?.id == labelId }
    }

    /// Inserts a StudyPad entry shell and immediately saves the context.
    /// - Parameter entry: Entry to persist.
    public func insert(_ entry: StudyPadTextEntry) {
        modelContext.insert(entry)
        save()
    }

    /// Deletes a StudyPad entry and relies on cascade rules for detached text content.
    /// - Parameter entry: Entry to delete.
    public func delete(_ entry: StudyPadTextEntry) {
        modelContext.delete(entry)
        save()
    }

    /// Fetches a StudyPad entry shell by primary key.
    /// - Parameter id: Entry UUID.
    /// - Returns: The entry when found, otherwise `nil`.
    public func studyPadEntry(id: UUID) -> StudyPadTextEntry? {
        var descriptor = FetchDescriptor<StudyPadTextEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Fetches the detached text payload for a StudyPad entry.
    /// - Parameter entryId: Parent StudyPad entry UUID.
    /// - Returns: The text row when found, otherwise `nil`.
    public func studyPadEntryText(entryId: UUID) -> StudyPadTextEntryText? {
        var descriptor = FetchDescriptor<StudyPadTextEntryText>(
            predicate: #Predicate { $0.studyPadTextEntryId == entryId }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Inserts or updates detached StudyPad text content for an entry.
    /// - Parameters:
    ///   - entryId: Parent StudyPad entry UUID.
    ///   - text: New text payload.
    public func upsertStudyPadEntryText(entryId: UUID, text: String) {
        if let existing = studyPadEntryText(entryId: entryId) {
            existing.text = text
        } else {
            let entryText = StudyPadTextEntryText(studyPadTextEntryId: entryId, text: text)
            // Link to parent entry
            if let entry = studyPadEntry(id: entryId) {
                entryText.entry = entry
            }
            modelContext.insert(entryText)
        }
        save()
    }

    // MARK: - BookmarkToLabel Lookups

    /// Fetches a Bible bookmark-to-label junction for the given bookmark/label pair.
    /// - Parameters:
    ///   - bookmarkId: Bookmark UUID.
    ///   - labelId: Label UUID.
    /// - Returns: Matching junction row when present.
    public func bibleBookmarkToLabel(bookmarkId: UUID, labelId: UUID) -> BibleBookmarkToLabel? {
        let descriptor = FetchDescriptor<BibleBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.first { $0.bookmark?.id == bookmarkId && $0.label?.id == labelId }
    }

    /// Fetches a generic bookmark-to-label junction for the given bookmark/label pair.
    /// - Parameters:
    ///   - bookmarkId: Bookmark UUID.
    ///   - labelId: Label UUID.
    /// - Returns: Matching junction row when present.
    public func genericBookmarkToLabel(bookmarkId: UUID, labelId: UUID) -> GenericBookmarkToLabel? {
        let descriptor = FetchDescriptor<GenericBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.first { $0.bookmark?.id == bookmarkId && $0.label?.id == labelId }
    }

    /// Fetches all Bible bookmark-to-label junction rows for a label.
    /// - Parameter labelId: Label UUID.
    /// - Returns: Matching junction rows.
    public func bibleBookmarkToLabels(labelId: UUID) -> [BibleBookmarkToLabel] {
        let descriptor = FetchDescriptor<BibleBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.label?.id == labelId }
    }

    /// Fetches all generic bookmark-to-label junction rows for a label.
    /// - Parameter labelId: Label UUID.
    /// - Returns: Matching junction rows.
    public func genericBookmarkToLabels(labelId: UUID) -> [GenericBookmarkToLabel] {
        let descriptor = FetchDescriptor<GenericBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.label?.id == labelId }
    }

    /// Fetches Bible bookmarks carrying the given label.
    /// - Parameter labelId: Label UUID.
    /// - Returns: Bible bookmarks associated with the label.
    public func bibleBookmarks(withLabel labelId: UUID) -> [BibleBookmark] {
        let btls = bibleBookmarkToLabels(labelId: labelId)
        return btls.compactMap { $0.bookmark }
    }

    /// Fetches generic bookmarks carrying the given label.
    /// - Parameter labelId: Label UUID.
    /// - Returns: Generic bookmarks associated with the label.
    public func genericBookmarks(withLabel labelId: UUID) -> [GenericBookmark] {
        let gbtls = genericBookmarkToLabels(labelId: labelId)
        return gbtls.compactMap { $0.bookmark }
    }

    // MARK: - Persistence

    private func save() {
        try? modelContext.save()
    }
}
