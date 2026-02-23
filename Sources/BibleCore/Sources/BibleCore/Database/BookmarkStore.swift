// BookmarkStore.swift — Bookmark persistence operations

import Foundation
import SwiftData

/// Manages bookmark, label, and StudyPad persistence operations.
@Observable
public final class BookmarkStore {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Bible Bookmarks

    /// Fetch all Bible bookmarks, optionally filtered by label.
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

        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetch a single Bible bookmark by ID.
    public func bibleBookmark(id: UUID) -> BibleBookmark? {
        var descriptor = FetchDescriptor<BibleBookmark>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Fetch Bible bookmarks overlapping an ordinal range.
    public func bibleBookmarks(overlapping startOrdinal: Int, endOrdinal: Int) -> [BibleBookmark] {
        let descriptor = FetchDescriptor<BibleBookmark>(
            predicate: #Predicate {
                $0.kjvOrdinalStart <= endOrdinal && $0.kjvOrdinalEnd >= startOrdinal
            }
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Insert a new Bible bookmark.
    public func insert(_ bookmark: BibleBookmark) {
        modelContext.insert(bookmark)
        save()
    }

    /// Insert a BibleBookmarkToLabel junction.
    public func insert(_ btl: BibleBookmarkToLabel) {
        modelContext.insert(btl)
        save()
    }

    /// Delete a Bible bookmark.
    public func delete(_ bookmark: BibleBookmark) {
        modelContext.delete(bookmark)
        save()
    }

    /// Delete a Bible bookmark by ID.
    public func deleteBibleBookmark(id: UUID) {
        if let bookmark = bibleBookmark(id: id) {
            delete(bookmark)
        }
    }

    // MARK: - Generic Bookmarks

    /// Fetch all generic bookmarks.
    public func genericBookmarks() -> [GenericBookmark] {
        let descriptor = FetchDescriptor<GenericBookmark>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetch a single generic bookmark by ID.
    public func genericBookmark(id: UUID) -> GenericBookmark? {
        var descriptor = FetchDescriptor<GenericBookmark>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Insert a new generic bookmark.
    public func insert(_ bookmark: GenericBookmark) {
        modelContext.insert(bookmark)
        save()
    }

    /// Insert a GenericBookmarkToLabel junction.
    public func insert(_ gbtl: GenericBookmarkToLabel) {
        modelContext.insert(gbtl)
        save()
    }

    /// Delete a generic bookmark.
    public func delete(_ bookmark: GenericBookmark) {
        modelContext.delete(bookmark)
        save()
    }

    // MARK: - Labels

    /// Fetch all labels.
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

    /// Fetch a label by ID.
    public func label(id: UUID) -> Label? {
        var descriptor = FetchDescriptor<Label>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Insert a new label.
    public func insert(_ label: Label) {
        modelContext.insert(label)
        save()
    }

    /// Delete a label.
    public func delete(_ label: Label) {
        modelContext.delete(label)
        save()
    }

    // MARK: - StudyPad

    /// Fetch StudyPad text entries for a label, ordered by orderNumber.
    public func studyPadEntries(labelId: UUID) -> [StudyPadTextEntry] {
        let descriptor = FetchDescriptor<StudyPadTextEntry>(
            sortBy: [SortDescriptor(\.orderNumber)]
        )
        // Filter by label relationship after fetch
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.label?.id == labelId }
    }

    /// Insert a StudyPad text entry.
    public func insert(_ entry: StudyPadTextEntry) {
        modelContext.insert(entry)
        save()
    }

    /// Delete a StudyPad text entry.
    public func delete(_ entry: StudyPadTextEntry) {
        modelContext.delete(entry)
        save()
    }

    /// Fetch a single StudyPad text entry by ID.
    public func studyPadEntry(id: UUID) -> StudyPadTextEntry? {
        var descriptor = FetchDescriptor<StudyPadTextEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Fetch the text content for a StudyPad entry.
    public func studyPadEntryText(entryId: UUID) -> StudyPadTextEntryText? {
        var descriptor = FetchDescriptor<StudyPadTextEntryText>(
            predicate: #Predicate { $0.studyPadTextEntryId == entryId }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Insert or update text content for a StudyPad entry.
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

    /// Fetch a single BibleBookmarkToLabel junction by bookmark and label IDs.
    public func bibleBookmarkToLabel(bookmarkId: UUID, labelId: UUID) -> BibleBookmarkToLabel? {
        let descriptor = FetchDescriptor<BibleBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.first { $0.bookmark?.id == bookmarkId && $0.label?.id == labelId }
    }

    /// Fetch a single GenericBookmarkToLabel junction by bookmark and label IDs.
    public func genericBookmarkToLabel(bookmarkId: UUID, labelId: UUID) -> GenericBookmarkToLabel? {
        let descriptor = FetchDescriptor<GenericBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.first { $0.bookmark?.id == bookmarkId && $0.label?.id == labelId }
    }

    /// Fetch all BibleBookmarkToLabel junctions for a given label.
    public func bibleBookmarkToLabels(labelId: UUID) -> [BibleBookmarkToLabel] {
        let descriptor = FetchDescriptor<BibleBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.label?.id == labelId }
    }

    /// Fetch all GenericBookmarkToLabel junctions for a given label.
    public func genericBookmarkToLabels(labelId: UUID) -> [GenericBookmarkToLabel] {
        let descriptor = FetchDescriptor<GenericBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.label?.id == labelId }
    }

    /// Fetch Bible bookmarks that have a specific label.
    public func bibleBookmarks(withLabel labelId: UUID) -> [BibleBookmark] {
        let btls = bibleBookmarkToLabels(labelId: labelId)
        return btls.compactMap { $0.bookmark }
    }

    /// Fetch generic bookmarks that have a specific label.
    public func genericBookmarks(withLabel labelId: UUID) -> [GenericBookmark] {
        let gbtls = genericBookmarkToLabels(labelId: labelId)
        return gbtls.compactMap { $0.bookmark }
    }

    // MARK: - Persistence

    private func save() {
        try? modelContext.save()
    }
}
