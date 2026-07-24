// BookmarkStore.swift — Bookmark persistence operations

import Foundation
import SwiftData

/**
 * Manages bookmark, label, StudyPad, and junction-table persistence operations.
 *
 * This store is the low-level persistence layer behind bookmark workflows. It is intentionally
 * eager-saving: every mutation flushes immediately so the web view, bookmark overlays, and label
 * UI all observe a consistent database state.
 *
 * Several relationship lookups still fetch broadly and then filter in memory. Those call sites are
 * documented explicitly because they have different complexity characteristics than pure
 * predicate-backed fetches.
 *
 * - Important: This store inherits the thread/actor confinement of the supplied `ModelContext`.
 */
@Observable
public final class BookmarkStore {
    /// SwiftData context used for bookmark, label, and StudyPad reads and writes.
    private let modelContext: ModelContext

    /**
     * Creates a bookmark store bound to the caller's SwiftData context.
     * - Parameter modelContext: Context used for all bookmark, label, and StudyPad queries.
     * - Important: The caller owns context lifecycle and confinement.
     */
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Bible Bookmarks

    /**
     * Fetches Bible bookmarks using the requested sort order.
     * - Parameters:
     *   - labelId: Optional label filter. When present, results are filtered after fetch by
     *     inspecting the bookmark-to-label relationship.
     *   - sortOrder: Ordering strategy for the returned bookmarks.
     * - Returns: Matching Bible bookmarks whose persisted KJVA provenance is verified.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     * - Complexity: `O(n)` when `labelId` is provided because label filtering currently happens in memory after fetch.
     */
    public func bibleBookmarks(labelId: UUID? = nil, sortOrder: BookmarkSortOrder = .bibleOrder) -> [BibleBookmark] {
        var descriptor = FetchDescriptor<BibleBookmark>()

        switch sortOrder {
        case .bibleOrder:
            descriptor.sortBy = [
                SortDescriptor(\.kjvOrdinalStart),
                SortDescriptor(\.startOffset),
            ]
        case .bibleOrderDesc:
            descriptor.sortBy = [
                SortDescriptor(\.kjvOrdinalStart, order: .reverse),
                SortDescriptor(\.startOffset, order: .reverse),
            ]
        case .createdAt:
            descriptor.sortBy = [SortDescriptor(\.createdAt)]
        case .createdAtDesc:
            descriptor.sortBy = [SortDescriptor(\.createdAt, order: .reverse)]
        case .lastUpdated:
            descriptor.sortBy = [SortDescriptor(\.lastUpdatedOn)]
        case .orderNumber:
            descriptor.sortBy = [
                SortDescriptor(\.kjvOrdinalStart),
                SortDescriptor(\.startOffset),
            ]
        }

        var results = ((try? modelContext.fetch(descriptor)) ?? [])
            .filter(\.hasTrustedPersistedOrdinals)
        if case .bibleOrderDesc = sortOrder {
            // Android orders by `-startOffset`, so SQLite keeps NULL before non-NULL values even
            // when concrete offsets descend. A normal SQL DESC descriptor puts NULL last.
            results.sort { lhs, rhs in
                if lhs.kjvOrdinalStart != rhs.kjvOrdinalStart {
                    return lhs.kjvOrdinalStart > rhs.kjvOrdinalStart
                }
                switch (lhs.startOffset, rhs.startOffset) {
                case (nil, _?):
                    return true
                case (_?, nil):
                    return false
                case let (lhsOffset?, rhsOffset?) where lhsOffset != rhsOffset:
                    return lhsOffset > rhsOffset
                default:
                    return lhs.id.uuidString < rhs.id.uuidString
                }
            }
        }
        guard let labelId else { return results }
        let filtered = results.filter { bookmark in
            bookmark.bookmarkToLabels?.contains { $0.label?.id == labelId } ?? false
        }
        guard sortOrder == .orderNumber else { return filtered }
        return filtered.sorted { lhs, rhs in
            let lhsOrder = lhs.bookmarkToLabels?
                .first(where: { $0.label?.id == labelId })?.orderNumber ?? -1
            let rhsOrder = rhs.bookmarkToLabels?
                .first(where: { $0.label?.id == labelId })?.orderNumber ?? -1
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            if lhs.kjvOrdinalStart != rhs.kjvOrdinalStart {
                return lhs.kjvOrdinalStart < rhs.kjvOrdinalStart
            }
            return (lhs.startOffset ?? Int.min) < (rhs.startOffset ?? Int.min)
        }
    }

    /**
     * Fetches a single Bible bookmark by primary key.
     * - Parameter id: Bookmark UUID.
     * - Returns: The verified bookmark when found, otherwise `nil`.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     */
    public func bibleBookmark(id: UUID) -> BibleBookmark? {
        var descriptor = FetchDescriptor<BibleBookmark>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first(where: \.hasTrustedPersistedOrdinals)
    }

    /**
     * Fetches the note payload row for a Bible bookmark by bookmark identifier.
     * - Parameter bookmarkId: UUID of the owning Bible bookmark.
     * - Returns: The note row when its owning bookmark is verified, otherwise `nil`.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     */
    public func bibleBookmarkNotes(bookmarkId: UUID) -> BibleBookmarkNotes? {
        var descriptor = FetchDescriptor<BibleBookmarkNotes>(
            predicate: #Predicate { $0.bookmarkId == bookmarkId }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first(where: {
            $0.bookmark?.hasTrustedPersistedOrdinals == true
        })
    }

    /**
     * Fetches Bible bookmarks whose stored KJVA ordinal range overlaps the given KJVA range.
     * - Parameters:
     *   - startOrdinal: Inclusive KJVA start of the query range.
     *   - endOrdinal: Inclusive KJVA end of the query range.
     *   - book: Deprecated compatibility parameter. Android backups store module initials or NULL in
     *     `BibleBookmark.book`, so callers must not use this value to decide verse membership.
     * - Returns: Overlapping bookmarks whose persisted KJVA provenance is verified.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     * - Note: This query matches on stored KJVA ordinals only; those ordinals are globally unique
     *   across books and are the Android-compatible key for restored and native bookmark highlights.
     */
    public func bibleBookmarks(overlapping startOrdinal: Int, endOrdinal: Int, book: String? = nil) -> [BibleBookmark] {
        let descriptor = FetchDescriptor<BibleBookmark>(
            predicate: #Predicate {
                $0.kjvOrdinalStart <= endOrdinal && $0.kjvOrdinalEnd >= startOrdinal
            }
        )
        return ((try? modelContext.fetch(descriptor)) ?? [])
            .filter(\.hasTrustedPersistedOrdinals)
    }

    /**
     * Inserts a new Bible bookmark and immediately saves the context.
     * - Parameter bookmark: Bookmark to persist.
     * - Side Effects: Inserts the bookmark graph into SwiftData and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func insert(_ bookmark: BibleBookmark) {
        modelContext.insert(bookmark)
        save()
    }

    /**
     * Inserts a Bible-to-label junction row and immediately saves the context.
     * - Parameter btl: Junction row linking a bookmark and a label.
     * - Side Effects: Inserts the junction row and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func insert(_ btl: BibleBookmarkToLabel) {
        modelContext.insert(btl)
        save()
    }

    /**
     * Deletes a Bible bookmark and relies on SwiftData cascade rules for attached notes/junctions.
     * - Parameter bookmark: Bookmark to delete.
     * - Side Effects: Deletes the bookmark graph and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func delete(_ bookmark: BibleBookmark) {
        modelContext.delete(bookmark)
        save()
    }

    /**
     * Deletes a Bible bookmark note row and immediately saves the context.
     * - Parameter notes: Note payload row to delete.
     * - Side Effects: Deletes the note row and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func delete(_ notes: BibleBookmarkNotes) {
        modelContext.delete(notes)
        save()
    }

    /**
     * Deletes a Bible bookmark by ID when it exists.
     * - Parameter id: Bookmark UUID.
     * - Side Effects: May delete a bookmark and save `modelContext`.
     * - Failure: Missing bookmarks and save failures are silently ignored.
     */
    public func deleteBibleBookmark(id: UUID) {
        if let bookmark = bibleBookmark(id: id) {
            delete(bookmark)
        }
    }

    // MARK: - Generic Bookmarks

    /**
     * Fetches all generic bookmarks in Android's fixed module-and-key order.
     * - Returns: Generic bookmarks across all non-Bible documents.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     */
    public func genericBookmarks() -> [GenericBookmark] {
        let descriptor = FetchDescriptor<GenericBookmark>(
            sortBy: [
                SortDescriptor(\.bookInitials),
                SortDescriptor(\.key),
            ]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /**
     * Fetches a single generic bookmark by primary key.
     * - Parameter id: Bookmark UUID.
     * - Returns: The bookmark when found, otherwise `nil`.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     */
    public func genericBookmark(id: UUID) -> GenericBookmark? {
        var descriptor = FetchDescriptor<GenericBookmark>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     * Fetches the note payload row for a generic bookmark by bookmark identifier.
     * - Parameter bookmarkId: UUID of the owning generic bookmark.
     * - Returns: The note row when found, otherwise `nil`.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     */
    public func genericBookmarkNotes(bookmarkId: UUID) -> GenericBookmarkNotes? {
        var descriptor = FetchDescriptor<GenericBookmarkNotes>(
            predicate: #Predicate { $0.bookmarkId == bookmarkId }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     * Inserts a new generic bookmark and immediately saves the context.
     * - Parameter bookmark: Bookmark to persist.
     * - Side Effects: Inserts the bookmark graph into SwiftData and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func insert(_ bookmark: GenericBookmark) {
        modelContext.insert(bookmark)
        save()
    }

    /**
     * Inserts a generic-bookmark-to-label junction row and immediately saves the context.
     * - Parameter gbtl: Junction row linking a generic bookmark and a label.
     * - Side Effects: Inserts the junction row and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func insert(_ gbtl: GenericBookmarkToLabel) {
        modelContext.insert(gbtl)
        save()
    }

    /**
     * Deletes one Bible bookmark-to-label junction and immediately saves the context.
     * - Parameter link: Persisted relationship to detach.
     * - Side Effects: Removes the link from its owning bookmark, deletes it, and saves.
     * - Failure: Save errors are swallowed.
     */
    public func delete(_ link: BibleBookmarkToLabel) {
        link.bookmark?.bookmarkToLabels?.removeAll { $0 === link }
        modelContext.delete(link)
        save()
    }

    /**
     * Deletes one generic bookmark-to-label junction and immediately saves the context.
     * - Parameter link: Persisted relationship to detach.
     * - Side Effects: Removes the link from its owning bookmark, deletes it, and saves.
     * - Failure: Save errors are swallowed.
     */
    public func delete(_ link: GenericBookmarkToLabel) {
        link.bookmark?.bookmarkToLabels?.removeAll { $0 === link }
        modelContext.delete(link)
        save()
    }

    /**
     * Deletes a generic bookmark and relies on SwiftData cascade rules for attached notes/junctions.
     * - Parameter bookmark: Bookmark to delete.
     * - Side Effects: Deletes the bookmark graph and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func delete(_ bookmark: GenericBookmark) {
        modelContext.delete(bookmark)
        save()
    }

    /**
     * Deletes a generic bookmark note row and immediately saves the context.
     * - Parameter notes: Note payload row to delete.
     * - Side Effects: Deletes the note row and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func delete(_ notes: GenericBookmarkNotes) {
        modelContext.delete(notes)
        save()
    }

    // MARK: - Bookmark Mutations

    /**
     Persists the whole-range mode for one Bible or generic bookmark.

     - Parameters:
       - bookmarkId: Exact bookmark identifier to update.
       - value: Whether the bookmark covers the complete verse or keyed entry.
     - Returns: `true` when a matching bookmark was found and saved; otherwise `false`.
     - Side effects: Updates `wholeVerse` and `lastUpdatedOn`, then synchronously saves the bookmark
       graph and remote-sync journal once.
     - Failure modes: Missing bookmarks return `false`; persistence failures are logged by
       `saveChanges()` and do not escape this store API.
     */
    @discardableResult
    public func setWholeVerse(bookmarkId: UUID, value: Bool) -> Bool {
        persistBookmarkMutation(bookmarkId: bookmarkId) { bookmark in
            bookmark.wholeVerse = value
        } genericMutation: { bookmark in
            bookmark.wholeVerse = value
        }
    }

    /**
     Persists the custom icon for one Bible or generic bookmark.

     - Parameters:
       - bookmarkId: Exact bookmark identifier to update.
       - value: Android icon name to store, or `nil` to clear the icon.
     - Returns: `true` when a matching bookmark was found and saved; otherwise `false`.
     - Side effects: Updates `customIcon` and `lastUpdatedOn`, then synchronously saves the bookmark
       graph and remote-sync journal once.
     - Failure modes: Missing bookmarks return `false`; persistence failures are logged by
       `saveChanges()` and do not escape this store API.
     */
    @discardableResult
    public func setCustomIcon(bookmarkId: UUID, value: String?) -> Bool {
        persistBookmarkMutation(bookmarkId: bookmarkId) { bookmark in
            bookmark.customIcon = value
        } genericMutation: { bookmark in
            bookmark.customIcon = value
        }
    }

    /**
     Persists the note-edit action for one Bible or generic bookmark.

     - Parameters:
       - bookmarkId: Exact bookmark identifier to update.
       - editAction: Append/prepend action to store, or `nil` to clear the action.
     - Returns: `true` when a matching bookmark was found and saved; otherwise `false`.
     - Side effects: Updates `editAction` and `lastUpdatedOn`, then synchronously saves the bookmark
       graph and remote-sync journal once.
     - Failure modes: Missing bookmarks return `false`; persistence failures are logged by
       `saveChanges()` and do not escape this store API.
     */
    @discardableResult
    public func setBookmarkEditAction(bookmarkId: UUID, editAction: EditAction?) -> Bool {
        persistBookmarkMutation(bookmarkId: bookmarkId) { bookmark in
            bookmark.editAction = editAction
        } genericMutation: { bookmark in
            bookmark.editAction = editAction
        }
    }

    /**
     Applies one bookmark mutation and saves it before control returns to the caller.

     Bible identifiers are checked first to preserve the service's existing identity precedence.

     - Parameters:
       - bookmarkId: Exact Bible or generic bookmark identifier.
       - bibleMutation: Mutation applied when `bookmarkId` identifies a trusted Bible bookmark.
       - genericMutation: Mutation applied when `bookmarkId` identifies a generic bookmark.
     - Returns: `true` when either bookmark type was found and saved; otherwise `false`.
     - Side effects: Mutates one bookmark, refreshes `lastUpdatedOn`, and performs one synchronous
       journaled context save.
     - Failure modes: Missing bookmarks return `false`; save failures are logged by `saveChanges()`.
     */
    private func persistBookmarkMutation(
        bookmarkId: UUID,
        bibleMutation: (BibleBookmark) -> Void,
        genericMutation: (GenericBookmark) -> Void
    ) -> Bool {
        if let bookmark = bibleBookmark(id: bookmarkId) {
            bibleMutation(bookmark)
            bookmark.lastUpdatedOn = Date()
            save()
            return true
        }
        if let bookmark = genericBookmark(id: bookmarkId) {
            genericMutation(bookmark)
            bookmark.lastUpdatedOn = Date()
            save()
            return true
        }
        return false
    }

    // MARK: - Labels

    /**
     * Fetches labels ordered by name.
     * - Parameter includeSystem: Whether reserved internal labels should be included.
     * - Returns: Matching labels.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     * - Note: System-label exclusion currently happens in memory via `Label.isRealLabel`.
     */
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

    /**
     * Fetches a label by primary key.
     * - Parameter id: Label UUID.
     * - Returns: The label when found, otherwise `nil`.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     */
    public func label(id: UUID) -> Label? {
        var descriptor = FetchDescriptor<Label>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     * Inserts a new label and immediately saves the context.
     * - Parameter label: Label to persist.
     * - Side Effects: Inserts the label and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func insert(_ label: Label) {
        modelContext.insert(label)
        save()
    }

    /**
     Deletes a label and detaches every bookmark relationship that still points at it.

     - Parameter label: Label to delete.
     - Side effects:
       - removes matching `BibleBookmarkToLabel` and `GenericBookmarkToLabel` rows from both the
         model context and their owning bookmark collections
       - clears `primaryLabelId` on bookmarks whose primary label matches the deleted label
       - deletes the label itself and saves the updated graph
     - Failure modes:
       - fetch failures are swallowed and treated as empty relationship collections
       - save failures are swallowed by `save()`
     */
    public func delete(_ label: Label) {
        delete(
            label,
            deletingBibleBookmarkIDs: [],
            deletingGenericBookmarkIDs: []
        )
    }

    /**
     Deletes one label and, when requested, bookmarks that would be orphaned by that deletion.

     This is the atomic persistence owner for Android's `deleteLabels(...,
     deleteOrphanedBookmarks)` contract. The caller supplies bookmark identifiers produced by the
     service-layer deletion preview; this store validates those identifiers against bookmarks that
     still carry the target label before deleting anything.

     - Parameters:
       - label: Label to delete.
       - deletingBibleBookmarkIDs: Bible bookmarks to remove with the label.
       - deletingGenericBookmarkIDs: Generic bookmarks to remove with the label.
     - Side effects: Deletes the requested bookmark graphs, detaches the target label from retained
       bookmarks, repairs retained primary-label references, deletes the label, and commits one
       bookmark-category journal transaction.
     - Failure modes: Missing or stale requested bookmark identifiers are ignored. Fetch and commit
       failures retain the store's existing best-effort logging behavior.
     */
    public func delete(
        _ label: Label,
        deletingBibleBookmarkIDs: Set<UUID>,
        deletingGenericBookmarkIDs: Set<UUID>
    ) {
        stageDelete(
            label,
            deletingBibleBookmarkIDs: deletingBibleBookmarkIDs,
            deletingGenericBookmarkIDs: deletingGenericBookmarkIDs
        )
        save()
    }

    /**
     Stages Android label and optional orphan-bookmark deletion without committing the context.

     This is the graph primitive used by the cross-category label service. Keeping persistence out
     of this operation allows bookmark rows, workspace auto-assignment state, fidelity overrides,
     and both remote-sync journals to share one outer transaction.

     - Parameters:
       - label: Label to delete in the caller-owned model context.
       - deletingBibleBookmarkIDs: Bible bookmarks to remove with the label.
       - deletingGenericBookmarkIDs: Generic bookmarks to remove with the label.
     - Side effects: Stages bookmark graph and label deletions in `modelContext`; does not save.
     - Failure modes: Missing or stale requested bookmark identifiers are ignored. The enclosing
       transaction owns validation, journaling, commit, and rollback failures.
     */
    func stageDelete(
        _ label: Label,
        deletingBibleBookmarkIDs: Set<UUID>,
        deletingGenericBookmarkIDs: Set<UUID>
    ) {
        let labelId = label.id

        let bibleLinksDescriptor = FetchDescriptor<BibleBookmarkToLabel>()
        let genericLinksDescriptor = FetchDescriptor<GenericBookmarkToLabel>()

        let bibleLinks = ((try? modelContext.fetch(bibleLinksDescriptor)) ?? [])
            .filter {
                guard let linkedLabel = $0.label, !linkedLabel.isDeleted else { return false }
                return linkedLabel.id == labelId
            }
        let genericLinks = ((try? modelContext.fetch(genericLinksDescriptor)) ?? [])
            .filter {
                guard let linkedLabel = $0.label, !linkedLabel.isDeleted else { return false }
                return linkedLabel.id == labelId
            }

        let bibleBookmarksToDelete = Set(
            bibleLinks.compactMap { link -> UUID? in
                guard let bookmarkID = link.bookmark?.id,
                      deletingBibleBookmarkIDs.contains(bookmarkID) else {
                    return nil
                }
                return bookmarkID
            }
        )
        let genericBookmarksToDelete = Set(
            genericLinks.compactMap { link -> UUID? in
                guard let bookmarkID = link.bookmark?.id,
                      deletingGenericBookmarkIDs.contains(bookmarkID) else {
                    return nil
                }
                return bookmarkID
            }
        )

        for link in bibleLinks {
            if let bookmarkID = link.bookmark?.id, bibleBookmarksToDelete.contains(bookmarkID) {
                continue
            }
            if link.bookmark?.primaryLabelId == labelId {
                link.bookmark?.primaryLabelId = nil
            }
            link.bookmark?.bookmarkToLabels?.removeAll { $0 === link }
            modelContext.delete(link)
        }

        for link in genericLinks {
            if let bookmarkID = link.bookmark?.id, genericBookmarksToDelete.contains(bookmarkID) {
                continue
            }
            if link.bookmark?.primaryLabelId == labelId {
                link.bookmark?.primaryLabelId = nil
            }
            link.bookmark?.bookmarkToLabels?.removeAll { $0 === link }
            modelContext.delete(link)
        }

        let allBibleBookmarks = (try? modelContext.fetch(FetchDescriptor<BibleBookmark>())) ?? []
        for bookmark in allBibleBookmarks where bibleBookmarksToDelete.contains(bookmark.id) {
            modelContext.delete(bookmark)
        }

        let allGenericBookmarks = (try? modelContext.fetch(FetchDescriptor<GenericBookmark>())) ?? []
        for bookmark in allGenericBookmarks where genericBookmarksToDelete.contains(bookmark.id) {
            modelContext.delete(bookmark)
        }

        modelContext.delete(label)
    }

    /**
     Merges a duplicate reserved label into Android's canonical label object.

     - Parameters:
       - source: Duplicate or legacy label that must be removed.
       - destination: Canonical Android-fixed label that retains every relationship.
     - Side effects: Repoints or de-duplicates bookmark links, reparents StudyPad entries, repairs
       primary-label identifiers, deletes `source`, and saves once.
     - Failure modes: Fetch failures are swallowed and leave only the relationships visible through
       the loaded model graph available for migration; save failures are logged by `save()`.
     */
    public func mergeLabel(_ source: Label, into destination: Label) {
        guard source !== destination else { return }
        let sourceID = source.id
        let destinationID = destination.id

        let bibleLinks = (try? modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>())) ?? []
        let genericLinks = (try? modelContext.fetch(FetchDescriptor<GenericBookmarkToLabel>())) ?? []
        let studyPadEntries = (try? modelContext.fetch(FetchDescriptor<StudyPadTextEntry>())) ?? []

        for link in bibleLinks where link.label?.id == sourceID {
            if let bookmark = link.bookmark,
               bibleLinks.contains(where: {
                   $0 !== link && $0.bookmark?.id == bookmark.id && $0.label?.id == destinationID
               }) {
                bookmark.bookmarkToLabels?.removeAll { $0 === link }
                modelContext.delete(link)
            } else {
                link.label = destination
            }
            if link.bookmark?.primaryLabelId == sourceID {
                link.bookmark?.primaryLabelId = destinationID
            }
        }

        for link in genericLinks where link.label?.id == sourceID {
            if let bookmark = link.bookmark,
               genericLinks.contains(where: {
                   $0 !== link && $0.bookmark?.id == bookmark.id && $0.label?.id == destinationID
               }) {
                bookmark.bookmarkToLabels?.removeAll { $0 === link }
                modelContext.delete(link)
            } else {
                link.label = destination
            }
            if link.bookmark?.primaryLabelId == sourceID {
                link.bookmark?.primaryLabelId = destinationID
            }
        }

        for entry in studyPadEntries where entry.label?.id == sourceID {
            entry.label = destination
        }
        modelContext.delete(source)
        save()
    }

    /**
     Rewrites scalar primary-label references after a reserved label ID migration.

     - Parameters:
       - sourceID: Pre-parity iOS label identifier.
       - destinationID: Android-fixed replacement identifier.
     - Side effects: Updates matching Bible and generic bookmarks and saves the context.
     - Failure modes: Fetch failures are swallowed; save failures are logged by `save()`.
     */
    public func remapPrimaryLabelIdentifier(from sourceID: UUID, to destinationID: UUID) {
        let bibleBookmarks = (try? modelContext.fetch(FetchDescriptor<BibleBookmark>())) ?? []
        let genericBookmarks = (try? modelContext.fetch(FetchDescriptor<GenericBookmark>())) ?? []
        for bookmark in bibleBookmarks where bookmark.primaryLabelId == sourceID {
            bookmark.primaryLabelId = destinationID
        }
        for bookmark in genericBookmarks where bookmark.primaryLabelId == sourceID {
            bookmark.primaryLabelId = destinationID
        }
        save()
    }

    // MARK: - StudyPad

    /**
     * Fetches StudyPad entries for a label ordered by `orderNumber`.
     * - Parameter labelId: Label UUID owning the StudyPad.
     * - Returns: Entries belonging to that label.
     * - Note: The current implementation sorts in SwiftData, then filters by relationship in
     *   memory.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     * - Complexity: `O(n)` over all StudyPad entries because label matching happens after fetch.
     */
    public func studyPadEntries(labelId: UUID) -> [StudyPadTextEntry] {
        let descriptor = FetchDescriptor<StudyPadTextEntry>(
            sortBy: [SortDescriptor(\.orderNumber)]
        )
        // Filter by label relationship after fetch
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.label?.id == labelId }
    }

    /**
     * Inserts a StudyPad entry shell and immediately saves the context.
     * - Parameter entry: Entry to persist.
     * - Side Effects: Inserts the entry and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func insert(_ entry: StudyPadTextEntry) {
        modelContext.insert(entry)
        save()
    }

    /**
     Deletes one StudyPad text entry and normalizes every remaining item in the same persisted batch.

     - Parameter id: Exact StudyPad text-entry identifier to delete.
     - Returns: Deleted identifiers plus each relationship or entry whose order changed, or `nil`
       when the entry or its label is missing.
     - Side effects: Deletes the entry graph, rewrites remaining label-scoped order numbers to a
       contiguous zero-based sequence, and synchronously saves the graph and sync journal once.
     - Failure modes: Missing entries or labels return `nil`; persistence failures are logged by
       `saveChanges()` and do not escape this store API.
     - Note: Ordering ties retain the existing Bible, generic, then text-entry collection precedence.
     */
    public func deleteStudyPadEntryAndNormalizeOrder(
        id: UUID
    ) -> (UUID, UUID, [BibleBookmarkToLabel], [GenericBookmarkToLabel], [StudyPadTextEntry])? {
        guard let entry = studyPadEntry(id: id),
              let labelId = entry.label?.id else {
            return nil
        }

        modelContext.delete(entry)
        let changed = normalizeStudyPadOrder(labelId: labelId, excludingEntryId: id)
        save()
        return (id, labelId, changed.bibleLinks, changed.genericLinks, changed.entries)
    }

    /**
     Persists mutable ordering metadata for one StudyPad text entry.

     - Parameters:
       - id: Exact StudyPad entry identifier.
       - orderNumber: Replacement display order, or `nil` to retain the current value.
       - indentLevel: Replacement nesting depth, or `nil` to retain the current value.
     - Returns: `true` when the entry was found and saved; otherwise `false`.
     - Side effects: Mutates the entry and synchronously saves the graph and sync journal once.
     - Failure modes: Missing entries return `false`; persistence failures are logged by
       `saveChanges()` and do not escape this store API.
     */
    @discardableResult
    public func updateStudyPadEntryMetadata(
        id: UUID,
        orderNumber: Int?,
        indentLevel: Int?
    ) -> Bool {
        guard let entry = studyPadEntry(id: id) else { return false }
        if let orderNumber { entry.orderNumber = orderNumber }
        if let indentLevel { entry.indentLevel = indentLevel }
        save()
        return true
    }

    /**
     Persists StudyPad metadata on one Bible-bookmark-to-label relationship.

     - Parameters:
       - bookmarkId: Exact Bible bookmark identifier.
       - labelId: Exact label identifier for the junction row.
       - orderNumber: Replacement display order, or `nil` to retain the current value.
       - indentLevel: Replacement nesting depth, or `nil` to retain the current value.
       - expandContent: Replacement expanded state, or `nil` to retain the current value.
     - Returns: `true` when the relationship was found and saved; otherwise `false`.
     - Side effects: Mutates the relationship, refreshes its bookmark timestamp, and synchronously
       saves the graph and sync journal once.
     - Failure modes: Missing relationships return `false`; persistence failures are logged by
       `saveChanges()` and do not escape this store API.
     */
    @discardableResult
    public func updateBibleBookmarkToLabelMetadata(
        bookmarkId: UUID,
        labelId: UUID,
        orderNumber: Int?,
        indentLevel: Int?,
        expandContent: Bool?
    ) -> Bool {
        guard let link = bibleBookmarkToLabel(bookmarkId: bookmarkId, labelId: labelId) else {
            return false
        }
        if let orderNumber { link.orderNumber = orderNumber }
        if let indentLevel { link.indentLevel = indentLevel }
        if let expandContent { link.expandContent = expandContent }
        link.bookmark?.lastUpdatedOn = Date()
        save()
        return true
    }

    /**
     Persists StudyPad metadata on one generic-bookmark-to-label relationship.

     - Parameters:
       - bookmarkId: Exact generic bookmark identifier.
       - labelId: Exact label identifier for the junction row.
       - orderNumber: Replacement display order, or `nil` to retain the current value.
       - indentLevel: Replacement nesting depth, or `nil` to retain the current value.
       - expandContent: Replacement expanded state, or `nil` to retain the current value.
     - Returns: `true` when the relationship was found and saved; otherwise `false`.
     - Side effects: Mutates the relationship, refreshes its bookmark timestamp, and synchronously
       saves the graph and sync journal once.
     - Failure modes: Missing relationships return `false`; persistence failures are logged by
       `saveChanges()` and do not escape this store API.
     */
    @discardableResult
    public func updateGenericBookmarkToLabelMetadata(
        bookmarkId: UUID,
        labelId: UUID,
        orderNumber: Int?,
        indentLevel: Int?,
        expandContent: Bool?
    ) -> Bool {
        guard let link = genericBookmarkToLabel(bookmarkId: bookmarkId, labelId: labelId) else {
            return false
        }
        if let orderNumber { link.orderNumber = orderNumber }
        if let indentLevel { link.indentLevel = indentLevel }
        if let expandContent { link.expandContent = expandContent }
        link.bookmark?.lastUpdatedOn = Date()
        save()
        return true
    }

    /**
     Persists one mixed StudyPad drag-and-drop ordering update as a single database batch.

     - Parameters:
       - labelId: Label whose bookmark junctions are addressed by the order payload.
       - bibleBookmarkOrders: Bible bookmark identifiers paired with replacement order numbers.
       - genericBookmarkOrders: Generic bookmark identifiers paired with replacement order numbers.
       - studyPadEntryOrders: StudyPad text-entry identifiers paired with replacement order numbers.
     - Side effects: Mutates every resolvable row and synchronously saves the graph and sync journal
       exactly once after the complete payload has been applied.
     - Failure modes: Missing rows are ignored to preserve bridge behavior; persistence failures are
       logged by `saveChanges()` and do not escape this store API.
     */
    public func updateStudyPadOrderNumbers(
        labelId: UUID,
        bibleBookmarkOrders: [(bookmarkId: UUID, orderNumber: Int)],
        genericBookmarkOrders: [(bookmarkId: UUID, orderNumber: Int)],
        studyPadEntryOrders: [(entryId: UUID, orderNumber: Int)]
    ) {
        for (bookmarkId, orderNumber) in bibleBookmarkOrders {
            bibleBookmarkToLabel(bookmarkId: bookmarkId, labelId: labelId)?.orderNumber = orderNumber
        }
        for (bookmarkId, orderNumber) in genericBookmarkOrders {
            genericBookmarkToLabel(bookmarkId: bookmarkId, labelId: labelId)?.orderNumber = orderNumber
        }
        for (entryId, orderNumber) in studyPadEntryOrders {
            studyPadEntry(id: entryId)?.orderNumber = orderNumber
        }
        save()
    }

    /**
     Rewrites all remaining StudyPad item orders for one label into a contiguous sequence.

     - Parameters:
       - labelId: Label whose mixed StudyPad rows should be normalized.
       - excludingEntryId: Entry already staged for deletion and therefore excluded even if a fetch
         still returns it before pending changes are processed.
     - Returns: Relationship and text-entry rows whose order numbers changed.
     - Side effects: Mutates rows in `modelContext` but deliberately does not save; the enclosing
       delete operation commits deletion and normalization together.
     - Failure modes: Fetch failures are represented by the store's existing empty collections.
     - Note: Equal order numbers retain collection precedence to match the previous service helper.
     */
    private func normalizeStudyPadOrder(
        labelId: UUID,
        excludingEntryId: UUID
    ) -> (
        bibleLinks: [BibleBookmarkToLabel],
        genericLinks: [GenericBookmarkToLabel],
        entries: [StudyPadTextEntry]
    ) {
        enum ItemKind: Int {
            case bibleLink
            case genericLink
            case entry
        }

        struct OrderedItem {
            let orderNumber: Int
            let kind: ItemKind
            let index: Int
        }

        let bibleLinks = bibleBookmarkToLabels(labelId: labelId)
        let genericLinks = genericBookmarkToLabels(labelId: labelId)
        let entries = studyPadEntries(labelId: labelId).filter { $0.id != excludingEntryId }
        var items = bibleLinks.enumerated().map {
            OrderedItem(orderNumber: $0.element.orderNumber, kind: .bibleLink, index: $0.offset)
        }
        items.append(contentsOf: genericLinks.enumerated().map {
            OrderedItem(orderNumber: $0.element.orderNumber, kind: .genericLink, index: $0.offset)
        })
        items.append(contentsOf: entries.enumerated().map {
            OrderedItem(orderNumber: $0.element.orderNumber, kind: .entry, index: $0.offset)
        })
        items.sort {
            if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.index < $1.index
        }

        var changedBibleLinks: [BibleBookmarkToLabel] = []
        var changedGenericLinks: [GenericBookmarkToLabel] = []
        var changedEntries: [StudyPadTextEntry] = []
        for (newOrder, item) in items.enumerated() {
            switch item.kind {
            case .bibleLink:
                let link = bibleLinks[item.index]
                if link.orderNumber != newOrder {
                    link.orderNumber = newOrder
                    changedBibleLinks.append(link)
                }
            case .genericLink:
                let link = genericLinks[item.index]
                if link.orderNumber != newOrder {
                    link.orderNumber = newOrder
                    changedGenericLinks.append(link)
                }
            case .entry:
                let entry = entries[item.index]
                if entry.orderNumber != newOrder {
                    entry.orderNumber = newOrder
                    changedEntries.append(entry)
                }
            }
        }
        return (changedBibleLinks, changedGenericLinks, changedEntries)
    }

    /**
     * Fetches a StudyPad entry shell by primary key.
     * - Parameter id: Entry UUID.
     * - Returns: The entry when found, otherwise `nil`.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     */
    public func studyPadEntry(id: UUID) -> StudyPadTextEntry? {
        var descriptor = FetchDescriptor<StudyPadTextEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     * Fetches the detached text payload for a StudyPad entry.
     * - Parameter entryId: Parent StudyPad entry UUID.
     * - Returns: The text row when found, otherwise `nil`.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     */
    public func studyPadEntryText(entryId: UUID) -> StudyPadTextEntryText? {
        var descriptor = FetchDescriptor<StudyPadTextEntryText>(
            predicate: #Predicate { $0.studyPadTextEntryId == entryId }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     * Inserts or updates detached StudyPad text content for an entry.
     * - Parameters:
     *   - entryId: Parent StudyPad entry UUID.
     *   - text: New text payload.
     * - Side Effects: Mutates or inserts `StudyPadTextEntryText`, may attach the row to its parent entry, and saves `modelContext`.
     * - Failure: Missing parents simply leave the detached text row unlinked; save errors are swallowed.
     */
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

    /**
     * Fetches a Bible bookmark-to-label junction for the given bookmark/label pair.
     * - Parameters:
     *   - bookmarkId: Bookmark UUID.
     *   - labelId: Label UUID.
     * - Returns: Matching junction row when present.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     * - Complexity: `O(n)` over all Bible bookmark junction rows because filtering happens in memory.
     */
    public func bibleBookmarkToLabel(bookmarkId: UUID, labelId: UUID) -> BibleBookmarkToLabel? {
        let descriptor = FetchDescriptor<BibleBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.first {
            $0.bookmark?.id == bookmarkId &&
                $0.bookmark?.hasTrustedPersistedOrdinals == true &&
                $0.label?.id == labelId
        }
    }

    /**
     * Fetches a generic bookmark-to-label junction for the given bookmark/label pair.
     * - Parameters:
     *   - bookmarkId: Bookmark UUID.
     *   - labelId: Label UUID.
     * - Returns: Matching junction row when present.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     * - Complexity: `O(n)` over all generic bookmark junction rows because filtering happens in memory.
     */
    public func genericBookmarkToLabel(bookmarkId: UUID, labelId: UUID) -> GenericBookmarkToLabel? {
        let descriptor = FetchDescriptor<GenericBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.first { $0.bookmark?.id == bookmarkId && $0.label?.id == labelId }
    }

    /**
     * Fetches all Bible bookmark-to-label junction rows for a label.
     * - Parameter labelId: Label UUID.
     * - Returns: Matching junction rows.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     * - Complexity: `O(n)` over all Bible bookmark junction rows because filtering happens in memory.
     */
    public func bibleBookmarkToLabels(labelId: UUID) -> [BibleBookmarkToLabel] {
        let descriptor = FetchDescriptor<BibleBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter {
            $0.label?.id == labelId && $0.bookmark?.hasTrustedPersistedOrdinals == true
        }
    }

    /**
     * Fetches all generic bookmark-to-label junction rows for a label.
     * - Parameter labelId: Label UUID.
     * - Returns: Matching junction rows.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     * - Complexity: `O(n)` over all generic bookmark junction rows because filtering happens in memory.
     */
    public func genericBookmarkToLabels(labelId: UUID) -> [GenericBookmarkToLabel] {
        let descriptor = FetchDescriptor<GenericBookmarkToLabel>()
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.label?.id == labelId }
    }

    /**
     * Fetches Bible bookmarks carrying the given label.
     * - Parameter labelId: Label UUID.
     * - Returns: Bible bookmarks associated with the label.
     * - Failure: Junction fetch failures are swallowed and reported as an empty array.
     */
    public func bibleBookmarks(withLabel labelId: UUID) -> [BibleBookmark] {
        let btls = bibleBookmarkToLabels(labelId: labelId)
        return btls.compactMap { $0.bookmark }
    }

    /**
     * Fetches generic bookmarks carrying the given label.
     * - Parameter labelId: Label UUID.
     * - Returns: Generic bookmarks associated with the label.
     * - Failure: Junction fetch failures are swallowed and reported as an empty array.
     */
    public func genericBookmarks(withLabel labelId: UUID) -> [GenericBookmark] {
        let gbtls = genericBookmarkToLabels(labelId: labelId)
        return gbtls.compactMap { $0.bookmark }
    }

    // MARK: - Persistence

    /**
     * Saves pending bookmark-related mutations.
     * - Side Effects: Flushes `modelContext` and its remote-sync mutation journal atomically.
     * - Failure: Journal or save errors are swallowed after being logged.
     */
    public func saveChanges() {
        do {
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .bookmarks,
                modelContext: modelContext
            )
        } catch {
            print("BookmarkStore.saveChanges failed: \(error)")
        }
    }

    /**
     * Saves pending bookmark-related mutations through the shared eager-save implementation.
     * - Side Effects: Flushes `modelContext` to disk.
     * - Failure: Save errors are swallowed.
     */
    private func save() {
        saveChanges()
    }
}
