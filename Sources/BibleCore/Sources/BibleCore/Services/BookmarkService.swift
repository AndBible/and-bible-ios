// BookmarkService.swift — Bookmark business logic

import Foundation
import Observation

/// Business logic for bookmark operations, coordinating between
/// BookmarkStore and the bridge layer.
@Observable
public final class BookmarkService {
    private let store: BookmarkStore

    /// Creates a bookmark service backed by the given persistence store.
    /// - Parameter store: Store responsible for all bookmark, label, and StudyPad persistence.
    public init(store: BookmarkStore) {
        self.store = store
    }

    // MARK: - Bible Bookmarks

    /// Create a new Bible bookmark for a verse range.
    @discardableResult
    public func addBibleBookmark(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int,
        v11n: String = "KJVA",
        wholeVerse: Bool = true,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        addNote: Bool = false
    ) -> BibleBookmark {
        let bookmark = BibleBookmark(
            kjvOrdinalStart: startOrdinal,
            kjvOrdinalEnd: endOrdinal,
            ordinalStart: startOrdinal,
            ordinalEnd: endOrdinal,
            v11n: v11n,
            wholeVerse: wholeVerse
        )
        bookmark.startOffset = startOffset
        bookmark.endOffset = endOffset
        store.insert(bookmark)
        return bookmark
    }

    /// Save or update a bookmark note (Bible or generic).
    public func saveBibleBookmarkNote(bookmarkId: UUID, note: String?) {
        // Try Bible bookmark first
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            if let note, !note.isEmpty {
                if let existing = bookmark.notes {
                    existing.notes = note
                } else {
                    let notes = BibleBookmarkNotes(bookmarkId: bookmarkId, notes: note)
                    bookmark.notes = notes
                }
            } else {
                bookmark.notes = nil
            }
            bookmark.lastUpdatedOn = Date()
            return
        }

        // Try generic bookmark
        if let bookmark = store.genericBookmark(id: bookmarkId) {
            if let note, !note.isEmpty {
                if let existing = bookmark.notes {
                    existing.notes = note
                } else {
                    let notes = GenericBookmarkNotes(bookmarkId: bookmarkId, notes: note)
                    bookmark.notes = notes
                }
            } else {
                bookmark.notes = nil
            }
            bookmark.lastUpdatedOn = Date()
        }
    }

    /// Remove a Bible bookmark.
    public func removeBibleBookmark(id: UUID) {
        store.deleteBibleBookmark(id: id)
    }

    /// Get bookmarks overlapping a verse range (for rendering highlights).
    /// Pass `book` to prevent cross-book ordinal collisions.
    public func bookmarks(for startOrdinal: Int, endOrdinal: Int, book: String? = nil) -> [BibleBookmark] {
        store.bibleBookmarks(overlapping: startOrdinal, endOrdinal: endOrdinal, book: book)
    }

    /// Find a single Bible bookmark by ID.
    public func bibleBookmark(id: UUID) -> BibleBookmark? {
        store.bibleBookmark(id: id)
    }

    /// Find a single generic bookmark by ID.
    public func genericBookmark(id: UUID) -> GenericBookmark? {
        store.genericBookmark(id: id)
    }

    // MARK: - Generic Bookmarks

    /// Create a generic bookmark for non-Bible documents.
    @discardableResult
    public func addGenericBookmark(
        bookInitials: String,
        key: String,
        startOrdinal: Int,
        endOrdinal: Int,
        wholeVerse: Bool = true
    ) -> GenericBookmark {
        let bookmark = GenericBookmark(
            key: key,
            bookInitials: bookInitials,
            ordinalStart: startOrdinal,
            ordinalEnd: endOrdinal,
            wholeVerse: wholeVerse
        )
        store.insert(bookmark)
        return bookmark
    }

    /// Remove a generic bookmark.
    public func removeGenericBookmark(id: UUID) {
        if let bookmark = store.genericBookmark(id: id) {
            store.delete(bookmark)
        }
    }

    // MARK: - Labels

    /// Toggle a label on a bookmark (Bible or generic).
    /// Returns "bible" or "generic" to indicate which type was toggled, or nil on failure.
    @discardableResult
    public func toggleLabel(bookmarkId: UUID, labelId: UUID) -> String? {
        guard let label = store.label(id: labelId) else { return nil }

        // Try Bible bookmark first
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            let hasLabel = bookmark.bookmarkToLabels?.contains { $0.label?.id == labelId } ?? false
            if hasLabel {
                bookmark.bookmarkToLabels?.removeAll { $0.label?.id == labelId }
            } else {
                let btl = BibleBookmarkToLabel()
                btl.bookmark = bookmark
                btl.label = label
                store.insert(btl)
            }
            bookmark.lastUpdatedOn = Date()
            return "bible"
        }

        // Try generic bookmark
        if let bookmark = store.genericBookmark(id: bookmarkId) {
            let hasLabel = bookmark.bookmarkToLabels?.contains { $0.label?.id == labelId } ?? false
            if hasLabel {
                bookmark.bookmarkToLabels?.removeAll { $0.label?.id == labelId }
            } else {
                let gbtl = GenericBookmarkToLabel()
                gbtl.bookmark = bookmark
                gbtl.label = label
                store.insert(gbtl)
            }
            bookmark.lastUpdatedOn = Date()
            return "generic"
        }

        return nil
    }

    /// Set the primary label for a bookmark (Bible or generic).
    public func setPrimaryLabel(bookmarkId: UUID, labelId: UUID) {
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            bookmark.primaryLabelId = labelId
            bookmark.lastUpdatedOn = Date()
        } else if let bookmark = store.genericBookmark(id: bookmarkId) {
            bookmark.primaryLabelId = labelId
            bookmark.lastUpdatedOn = Date()
        }
    }

    /// Remove a label from a bookmark (Bible or generic).
    public func removeLabel(bookmarkId: UUID, labelId: UUID) {
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            bookmark.bookmarkToLabels?.removeAll { $0.label?.id == labelId }
            bookmark.lastUpdatedOn = Date()
        } else if let bookmark = store.genericBookmark(id: bookmarkId) {
            bookmark.bookmarkToLabels?.removeAll { $0.label?.id == labelId }
            bookmark.lastUpdatedOn = Date()
        }
    }

    /// Set whole verse mode for a bookmark (Bible or generic).
    public func setWholeVerse(bookmarkId: UUID, value: Bool) {
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            bookmark.wholeVerse = value
            bookmark.lastUpdatedOn = Date()
        } else if let bookmark = store.genericBookmark(id: bookmarkId) {
            bookmark.wholeVerse = value
            bookmark.lastUpdatedOn = Date()
        }
    }

    /// Set custom icon for a bookmark (Bible or generic).
    public func setCustomIcon(bookmarkId: UUID, value: String?) {
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            bookmark.customIcon = value
            bookmark.lastUpdatedOn = Date()
        } else if let bookmark = store.genericBookmark(id: bookmarkId) {
            bookmark.customIcon = value
            bookmark.lastUpdatedOn = Date()
        }
    }

    // MARK: - Labels CRUD

    /// Ensure system labels exist with deterministic UUIDs for CloudKit cross-device dedup.
    /// If a system label already exists with a different UUID, update it to the canonical UUID.
    /// If it doesn't exist, create it. System labels are invisible to users.
    public func ensureSystemLabels() {
        let systemLabels: [(name: String, id: UUID)] = [
            (Label.speakLabelName, Label.speakLabelId),
            (Label.unlabeledName, Label.unlabeledId),
            (Label.paragraphBreakLabelName, Label.paragraphBreakLabelId),
        ]

        let allLabels = store.labels(includeSystem: true)

        for (name, canonicalId) in systemLabels {
            if let existing = allLabels.first(where: { $0.name == name }) {
                // Already exists — fix UUID if needed
                if existing.id != canonicalId {
                    existing.id = canonicalId
                }
            } else if store.label(id: canonicalId) == nil {
                // Create with deterministic UUID
                let label = Label(id: canonicalId, name: name)
                store.insert(label)
            }
        }
    }

    /// Seed default highlight labels on first launch (matches Android).
    /// Only creates labels if no user labels exist yet.
    public func prepareDefaultLabels() {
        let existingLabels = store.labels()  // already filters to isRealLabel
        guard existingLabels.isEmpty else { return }

        // Android ARGB values as signed Int32:
        // Color.argb(255, 255, 0, 0) = 0xFFFF0000 = -65536
        // Color.argb(255, 0, 255, 0) = 0xFF00FF00 = -16711936
        // Color.argb(255, 0, 0, 255) = 0xFF0000FF = -16776961
        // Color.argb(255, 255, 0, 255) = 0xFFFF00FF = -65281
        // Color.argb(255, 100, 0, 150) = 0xFF640096 = -10223466

        let red = Label(
            name: "Red",
            color: Int(Int32(bitPattern: 0xFFFF0000)),
            underlineStyleWholeVerse: false,
            favourite: true
        )
        red.type = LabelType.highlight.rawValue

        let green = Label(
            name: "Green",
            color: Int(Int32(bitPattern: 0xFF00FF00)),
            underlineStyleWholeVerse: false,
            favourite: true
        )
        green.type = LabelType.highlight.rawValue

        let blue = Label(
            name: "Blue",
            color: Int(Int32(bitPattern: 0xFF0000FF)),
            underlineStyleWholeVerse: false,
            favourite: true
        )
        blue.type = LabelType.highlight.rawValue

        let underline = Label(
            name: "Underline",
            color: Int(Int32(bitPattern: 0xFFFF00FF)),
            underlineStyle: true,
            underlineStyleWholeVerse: true,
            favourite: true
        )
        underline.type = LabelType.highlight.rawValue

        let salvation = Label(
            name: "Salvation",
            color: Int(Int32(bitPattern: 0xFF640096))
        )
        salvation.type = LabelType.example.rawValue

        for label in [red, green, blue, underline, salvation] {
            store.insert(label)
        }
    }

    /// Get all user-visible labels.
    public func allLabels() -> [Label] {
        store.labels()
    }

    /// Create a new label.
    @discardableResult
    public func createLabel(name: String, color: Int = Label.defaultColor) -> Label {
        let label = Label(name: name, color: color)
        store.insert(label)
        return label
    }

    /// Delete a label.
    public func deleteLabel(id: UUID) {
        if let label = store.label(id: id) {
            store.delete(label)
        }
    }

    // MARK: - StudyPad Operations

    /// Passthrough: single StudyPad entry by ID.
    public func studyPadEntry(id: UUID) -> StudyPadTextEntry? {
        store.studyPadEntry(id: id)
    }

    /// Passthrough: StudyPad entries for a label, ordered by orderNumber.
    public func studyPadEntries(labelId: UUID) -> [StudyPadTextEntry] {
        store.studyPadEntries(labelId: labelId)
    }

    /// Passthrough: BibleBookmarkToLabel junction lookup.
    public func bibleBookmarkToLabel(bookmarkId: UUID, labelId: UUID) -> BibleBookmarkToLabel? {
        store.bibleBookmarkToLabel(bookmarkId: bookmarkId, labelId: labelId)
    }

    /// Passthrough: GenericBookmarkToLabel junction lookup.
    public func genericBookmarkToLabel(bookmarkId: UUID, labelId: UUID) -> GenericBookmarkToLabel? {
        store.genericBookmarkToLabel(bookmarkId: bookmarkId, labelId: labelId)
    }

    /// Passthrough: all BibleBookmarkToLabel junctions for a label.
    public func bibleBookmarkToLabels(labelId: UUID) -> [BibleBookmarkToLabel] {
        store.bibleBookmarkToLabels(labelId: labelId)
    }

    /// Passthrough: all GenericBookmarkToLabel junctions for a label.
    public func genericBookmarkToLabels(labelId: UUID) -> [GenericBookmarkToLabel] {
        store.genericBookmarkToLabels(labelId: labelId)
    }

    /// Passthrough: Bible bookmarks having a specific label.
    public func bibleBookmarks(withLabel labelId: UUID) -> [BibleBookmark] {
        store.bibleBookmarks(withLabel: labelId)
    }

    /// Passthrough: Generic bookmarks having a specific label.
    public func genericBookmarks(withLabel labelId: UUID) -> [GenericBookmark] {
        store.genericBookmarks(withLabel: labelId)
    }

    /// Passthrough: label by ID.
    public func label(id: UUID) -> Label? {
        store.label(id: id)
    }

    /// Create a new StudyPad text entry for a label, inserted after the given order number.
    /// Returns (newEntry, bumpedBibleBtls, bumpedGenericBtls, bumpedEntries).
    @discardableResult
    public func createStudyPadEntry(
        labelId: UUID,
        afterOrderNumber: Int
    ) -> (StudyPadTextEntry, [BibleBookmarkToLabel], [GenericBookmarkToLabel], [StudyPadTextEntry])? {
        guard let label = store.label(id: labelId) else { return nil }

        let newOrder = afterOrderNumber + 1

        // Bump all items at or above the new position
        let bumped = incrementOrderNumbers(labelId: labelId, fromOrder: newOrder, excludingEntryId: nil)

        // Create the entry
        let entry = StudyPadTextEntry(orderNumber: newOrder, indentLevel: 0)
        entry.label = label
        store.insert(entry)

        // Create empty text content
        store.upsertStudyPadEntryText(entryId: entry.id, text: "")

        return (entry, bumped.bibleBtls, bumped.genericBtls, bumped.entries)
    }

    /// Delete a StudyPad text entry. Re-sanitizes order numbers.
    /// Returns (deletedId, labelId, changedBibleBtls, changedGenericBtls, changedEntries).
    public func deleteStudyPadEntry(
        id: UUID
    ) -> (UUID, UUID, [BibleBookmarkToLabel], [GenericBookmarkToLabel], [StudyPadTextEntry])? {
        guard let entry = store.studyPadEntry(id: id),
              let labelId = entry.label?.id else { return nil }

        store.delete(entry)

        // Re-sanitize order numbers
        let changed = sanitizeStudyPadOrder(labelId: labelId)
        return (id, labelId, changed.bibleBtls, changed.genericBtls, changed.entries)
    }

    /// Update a StudyPad text entry's metadata (orderNumber, indentLevel).
    public func updateStudyPadTextEntry(id: UUID, orderNumber: Int?, indentLevel: Int?) {
        guard let entry = store.studyPadEntry(id: id) else { return }
        if let orderNumber { entry.orderNumber = orderNumber }
        if let indentLevel { entry.indentLevel = indentLevel }
    }

    /// Update the text content of a StudyPad text entry.
    public func updateStudyPadTextEntryText(id: UUID, text: String) {
        store.upsertStudyPadEntryText(entryId: id, text: text)
    }

    /// Update a BibleBookmarkToLabel junction's StudyPad properties.
    public func updateBibleBookmarkToLabel(
        bookmarkId: UUID,
        labelId: UUID,
        orderNumber: Int?,
        indentLevel: Int?,
        expandContent: Bool?
    ) {
        guard let btl = store.bibleBookmarkToLabel(bookmarkId: bookmarkId, labelId: labelId) else { return }
        if let orderNumber { btl.orderNumber = orderNumber }
        if let indentLevel { btl.indentLevel = indentLevel }
        if let expandContent { btl.expandContent = expandContent }
        // Bump bookmark timestamp
        btl.bookmark?.lastUpdatedOn = Date()
    }

    /// Update a GenericBookmarkToLabel junction's StudyPad properties.
    public func updateGenericBookmarkToLabel(
        bookmarkId: UUID,
        labelId: UUID,
        orderNumber: Int?,
        indentLevel: Int?,
        expandContent: Bool?
    ) {
        guard let gbtl = store.genericBookmarkToLabel(bookmarkId: bookmarkId, labelId: labelId) else { return }
        if let orderNumber { gbtl.orderNumber = orderNumber }
        if let indentLevel { gbtl.indentLevel = indentLevel }
        if let expandContent { gbtl.expandContent = expandContent }
        gbtl.bookmark?.lastUpdatedOn = Date()
    }

    /// Batch update order numbers from a drag-drop reorder.
    public func updateOrderNumbers(
        labelId: UUID,
        bibleBookmarkOrders: [(bookmarkId: UUID, orderNumber: Int)],
        genericBookmarkOrders: [(bookmarkId: UUID, orderNumber: Int)],
        studyPadEntryOrders: [(entryId: UUID, orderNumber: Int)]
    ) {
        for (bmId, order) in bibleBookmarkOrders {
            if let btl = store.bibleBookmarkToLabel(bookmarkId: bmId, labelId: labelId) {
                btl.orderNumber = order
            }
        }
        for (bmId, order) in genericBookmarkOrders {
            if let gbtl = store.genericBookmarkToLabel(bookmarkId: bmId, labelId: labelId) {
                gbtl.orderNumber = order
            }
        }
        for (entryId, order) in studyPadEntryOrders {
            if let entry = store.studyPadEntry(id: entryId) {
                entry.orderNumber = order
            }
        }
    }

    /// Set edit action on a Bible or generic bookmark.
    public func setBookmarkEditAction(bookmarkId: UUID, editAction: EditAction?) {
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            bookmark.editAction = editAction
            bookmark.lastUpdatedOn = Date()
        } else if let bookmark = store.genericBookmark(id: bookmarkId) {
            bookmark.editAction = editAction
            bookmark.lastUpdatedOn = Date()
        }
    }

    // MARK: - StudyPad Private Helpers

    /// Bump order numbers for all items in a label at or above fromOrder.
    private func incrementOrderNumbers(
        labelId: UUID,
        fromOrder: Int,
        excludingEntryId: UUID?
    ) -> (bibleBtls: [BibleBookmarkToLabel], genericBtls: [GenericBookmarkToLabel], entries: [StudyPadTextEntry]) {
        var changedBtls: [BibleBookmarkToLabel] = []
        var changedGbtls: [GenericBookmarkToLabel] = []
        var changedEntries: [StudyPadTextEntry] = []

        for btl in store.bibleBookmarkToLabels(labelId: labelId) {
            if btl.orderNumber >= fromOrder {
                btl.orderNumber += 1
                changedBtls.append(btl)
            }
        }
        for gbtl in store.genericBookmarkToLabels(labelId: labelId) {
            if gbtl.orderNumber >= fromOrder {
                gbtl.orderNumber += 1
                changedGbtls.append(gbtl)
            }
        }
        for entry in store.studyPadEntries(labelId: labelId) {
            if let excludingEntryId, entry.id == excludingEntryId { continue }
            if entry.orderNumber >= fromOrder {
                entry.orderNumber += 1
                changedEntries.append(entry)
            }
        }

        return (changedBtls, changedGbtls, changedEntries)
    }

    /// Re-number all StudyPad items contiguously (0, 1, 2, ...).
    @discardableResult
    private func sanitizeStudyPadOrder(
        labelId: UUID
    ) -> (bibleBtls: [BibleBookmarkToLabel], genericBtls: [GenericBookmarkToLabel], entries: [StudyPadTextEntry]) {
        // Collect all items with their current order
        struct OrderedItem: Comparable {
            let orderNumber: Int
            let kind: Int // 0=btl, 1=gbtl, 2=entry
            let index: Int
            static func < (lhs: OrderedItem, rhs: OrderedItem) -> Bool {
                lhs.orderNumber < rhs.orderNumber
            }
        }

        let btls = store.bibleBookmarkToLabels(labelId: labelId)
        let gbtls = store.genericBookmarkToLabels(labelId: labelId)
        let entries = store.studyPadEntries(labelId: labelId)

        var items: [OrderedItem] = []
        for (i, btl) in btls.enumerated() {
            items.append(OrderedItem(orderNumber: btl.orderNumber, kind: 0, index: i))
        }
        for (i, gbtl) in gbtls.enumerated() {
            items.append(OrderedItem(orderNumber: gbtl.orderNumber, kind: 1, index: i))
        }
        for (i, entry) in entries.enumerated() {
            items.append(OrderedItem(orderNumber: entry.orderNumber, kind: 2, index: i))
        }

        items.sort()

        var changedBtls: [BibleBookmarkToLabel] = []
        var changedGbtls: [GenericBookmarkToLabel] = []
        var changedEntries: [StudyPadTextEntry] = []

        for (newOrder, item) in items.enumerated() {
            switch item.kind {
            case 0:
                let btl = btls[item.index]
                if btl.orderNumber != newOrder {
                    btl.orderNumber = newOrder
                    changedBtls.append(btl)
                }
            case 1:
                let gbtl = gbtls[item.index]
                if gbtl.orderNumber != newOrder {
                    gbtl.orderNumber = newOrder
                    changedGbtls.append(gbtl)
                }
            case 2:
                let entry = entries[item.index]
                if entry.orderNumber != newOrder {
                    entry.orderNumber = newOrder
                    changedEntries.append(entry)
                }
            default:
                break
            }
        }

        return (changedBtls, changedGbtls, changedEntries)
    }
}
