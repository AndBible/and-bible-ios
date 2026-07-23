// StudyPadContentSearch.swift -- Shared Android-compatible Study Pad content search

import Foundation

/// Android's two Study Pad content-search entry categories.
public enum StudyPadContentEntryType: String, Sendable, Equatable {
    /// Match from a free-form Study Pad text row.
    case textEntry = "TEXT_ENTRY"

    /// Match from either a Bible or generic bookmark note.
    case bookmarkNote = "BOOKMARK_NOTE"
}

/**
 Immutable searchable Study Pad entry detached from SwiftData actor ownership.

 The snapshot allows UI and AI callers to perform matching off the main actor without moving
 `@Model` instances across concurrency domains.
 */
public struct StudyPadSearchDocumentEntry: Sendable, Equatable {
    /// Entry or bookmark identifier passed back to Vue for targeted navigation.
    public let id: UUID

    /// Android entry category emitted to UI and AI callers.
    public let type: StudyPadContentEntryType

    /// Raw persisted rich-text or note payload searched by Android.
    public let text: String

    /** Creates one detached search entry without side effects or validation failures. */
    public init(id: UUID, type: StudyPadContentEntryType, text: String) {
        self.id = id
        self.type = type
        self.text = text
    }
}

/**
 Immutable label-backed Study Pad search document detached from SwiftData.

 `isSpecialLabel` preserves Android's rule that content results omit all reserved labels even
 though normal Study Pad selection still exposes Speak, Paragraph break, and AI.
 */
public struct StudyPadSearchDocument: Sendable, Equatable {
    /// Persisted label identifier.
    public let labelID: UUID

    /// Raw label name used by Android's result sorting.
    public let labelName: String

    /// Signed ARGB label color.
    public let labelColor: Int

    /// Whether the label is one of Android's reserved system labels.
    public let isSpecialLabel: Bool

    /// Searchable text, Bible-note, and generic-note entries.
    public let entries: [StudyPadSearchDocumentEntry]

    /** Creates one detached search document without side effects or validation failures. */
    public init(
        labelID: UUID,
        labelName: String,
        labelColor: Int,
        isSpecialLabel: Bool,
        entries: [StudyPadSearchDocumentEntry]
    ) {
        self.labelID = labelID
        self.labelName = labelName
        self.labelColor = labelColor
        self.isSpecialLabel = isSpecialLabel
        self.entries = entries
    }
}

/// One Android-compatible match within a Study Pad search result.
public struct StudyPadContentMatch: Sendable, Equatable {
    /// Matching Study Pad entry or bookmark identifier.
    public let entryID: UUID

    /// Matching Android entry category.
    public let entryType: StudyPadContentEntryType

    /// Approximately one hundred UTF-16 code units surrounding the first match.
    public let textSnippet: String

    /// UTF-16 offset of the first matched code unit inside `textSnippet`.
    public let matchStart: Int

    /// Exclusive UTF-16 end offset inside `textSnippet`.
    public let matchEnd: Int

    /** Creates one complete search match without side effects or validation failures. */
    public init(
        entryID: UUID,
        entryType: StudyPadContentEntryType,
        textSnippet: String,
        matchStart: Int,
        matchEnd: Int
    ) {
        self.entryID = entryID
        self.entryType = entryType
        self.textSnippet = textSnippet
        self.matchStart = matchStart
        self.matchEnd = matchEnd
    }
}

/// Android-compatible grouped result for one matching Study Pad label.
public struct StudyPadContentSearchResult: Sendable, Equatable, Identifiable {
    /// Persisted label identifier and SwiftUI identity.
    public let labelID: UUID

    /// Raw persisted label name.
    public let labelName: String

    /// Signed ARGB label color.
    public let labelColor: Int

    /// All matching entries in Android source-category order.
    public let matches: [StudyPadContentMatch]

    /// SwiftUI and collection identity.
    public var id: UUID { labelID }

    /// Number shown by Android's content-result row.
    public var matchCount: Int { matches.count }

    /** Creates one grouped result without side effects or validation failures. */
    public init(labelID: UUID, labelName: String, labelColor: Int, matches: [StudyPadContentMatch]) {
        self.labelID = labelID
        self.labelName = labelName
        self.labelColor = labelColor
        self.matches = matches
    }
}

/**
 Implements Android's shared Study Pad content-search contract for UI and AI consumers.

 The service snapshots SwiftData relationships before asynchronous work, searches free-form text
 plus Bible and generic bookmark notes, omits reserved labels, creates Android-sized snippets, and
 sorts grouped results by descending match count then raw label name.

 Inputs: label models for snapshotting or immutable search documents plus a non-empty query

 Outputs: deterministic grouped search results containing entry IDs suitable for Vue navigation

 Side effects: none

 Failure modes: missing relationships and empty note payloads are skipped; empty queries return an
 empty result set; malformed Unicode boundaries are expanded to composed-character boundaries
 */
public enum StudyPadContentSearch {
    /**
     Snapshots all Android-searchable content from persisted labels.

     Text entries are emitted first, followed by Bible bookmark notes and generic bookmark notes,
     matching Android's three-query aggregation order. Entries within each category use Study Pad
     order and stable UUID tiebreakers.

     - Parameter labels: Persisted label graph read on its owning actor.
     - Returns: Sendable documents safe for detached matching.
     - Side effects: Resolves SwiftData relationships but does not mutate them.
     - Failure modes: Missing relationship endpoints and absent note rows are skipped.
     */
    public static func documents(from labels: [Label]) -> [StudyPadSearchDocument] {
        labels.map { label in
            let textEntries = (label.studyPadEntries ?? [])
                .sorted(by: studyPadTextEntryOrder)
                .compactMap { entry -> StudyPadSearchDocumentEntry? in
                    guard let text = entry.textEntry?.text else { return nil }
                    return StudyPadSearchDocumentEntry(id: entry.id, type: .textEntry, text: text)
                }

            let bibleNotes = (label.bibleBookmarkToLabels ?? [])
                .sorted(by: bibleBookmarkRelationOrder)
                .compactMap { relation -> StudyPadSearchDocumentEntry? in
                    guard let bookmark = relation.bookmark,
                          let text = bookmark.notes?.notes else { return nil }
                    return StudyPadSearchDocumentEntry(id: bookmark.id, type: .bookmarkNote, text: text)
                }

            let genericNotes = (label.genericBookmarkToLabels ?? [])
                .sorted(by: genericBookmarkRelationOrder)
                .compactMap { relation -> StudyPadSearchDocumentEntry? in
                    guard let bookmark = relation.bookmark,
                          let text = bookmark.notes?.notes else { return nil }
                    return StudyPadSearchDocumentEntry(id: bookmark.id, type: .bookmarkNote, text: text)
                }

            return StudyPadSearchDocument(
                labelID: label.id,
                labelName: label.name,
                labelColor: label.color,
                isSpecialLabel: label.isSystemLabel,
                entries: textEntries + bibleNotes + genericNotes
            )
        }
    }

    /**
     Searches detached Study Pad documents using Android's grouping and sorting rules.

     - Parameters:
       - documents: Immutable snapshots created by `documents(from:)` or a test fixture.
       - query: Exact search text; callers own Android's three-character UI threshold.
     - Returns: Non-special matching labels sorted by match count descending, name ascending.
     - Side effects: none.
     - Failure modes: Empty queries return no results; entries without a match are ignored.
     */
    public static func search(
        documents: [StudyPadSearchDocument],
        query: String
    ) -> [StudyPadContentSearchResult] {
        guard !query.isEmpty else { return [] }

        return documents.compactMap { document -> StudyPadContentSearchResult? in
            guard !document.isSpecialLabel else { return nil }
            let matches = document.entries.compactMap { entry -> StudyPadContentMatch? in
                guard let snippet = snippet(fullText: entry.text, query: query) else { return nil }
                return StudyPadContentMatch(
                    entryID: entry.id,
                    entryType: entry.type,
                    textSnippet: snippet.text,
                    matchStart: snippet.matchStart,
                    matchEnd: snippet.matchEnd
                )
            }
            guard !matches.isEmpty else { return nil }
            return StudyPadContentSearchResult(
                labelID: document.labelID,
                labelName: document.labelName,
                labelColor: document.labelColor,
                matches: matches
            )
        }.sorted { lhs, rhs in
            if lhs.matchCount != rhs.matchCount { return lhs.matchCount > rhs.matchCount }
            let comparison = lhs.labelName.localizedCaseInsensitiveCompare(rhs.labelName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.labelID.uuidString < rhs.labelID.uuidString
        }
    }

    /// Pure snippet projection equivalent to Android `generateTextSnippet`.
    private static func snippet(
        fullText: String,
        query: String,
        contextUTF16Units: Int = 50
    ) -> (text: String, matchStart: Int, matchEnd: Int)? {
        let source = fullText as NSString
        let matchRange = source.range(of: query, options: [.caseInsensitive])
        guard matchRange.location != NSNotFound else { return nil }

        let desiredStart = max(0, matchRange.location - contextUTF16Units)
        let desiredEnd = min(source.length, NSMaxRange(matchRange) + contextUTF16Units)
        let safeRange = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: desiredStart, length: desiredEnd - desiredStart)
        )
        let prefix = safeRange.location > 0 ? "..." : ""
        let suffix = NSMaxRange(safeRange) < source.length ? "..." : ""
        let body = source.substring(with: safeRange)
        let matchStart = prefix.utf16.count + matchRange.location - safeRange.location
        return (
            prefix + body + suffix,
            matchStart,
            matchStart + matchRange.length
        )
    }

    /// Stable Android Study Pad text-row ordering for snapshot creation.
    private static func studyPadTextEntryOrder(_ lhs: StudyPadTextEntry, _ rhs: StudyPadTextEntry) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Stable Bible relation ordering for snapshot creation.
    private static func bibleBookmarkRelationOrder(
        _ lhs: BibleBookmarkToLabel,
        _ rhs: BibleBookmarkToLabel
    ) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        return (lhs.bookmark?.id.uuidString ?? "") < (rhs.bookmark?.id.uuidString ?? "")
    }

    /// Stable generic relation ordering for snapshot creation.
    private static func genericBookmarkRelationOrder(
        _ lhs: GenericBookmarkToLabel,
        _ rhs: GenericBookmarkToLabel
    ) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        return (lhs.bookmark?.id.uuidString ?? "") < (rhs.bookmark?.id.uuidString ?? "")
    }
}
