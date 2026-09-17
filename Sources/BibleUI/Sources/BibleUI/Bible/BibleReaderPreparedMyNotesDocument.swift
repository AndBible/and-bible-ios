// BibleReaderPreparedMyNotesDocument.swift -- Immutable My Notes bridge preparation

import BibleCore
import BibleView
import Foundation

/** Exact UTF-16 mirror for every string-valued Bible bookmark input used by bridge projection. */
private struct BibleReaderPreparedBibleBookmarkTextIdentity: Hashable, Sendable {
    let sourceVersification: BibleReaderPreparationExactText
    let sourceBookInitials: BibleReaderPreparationExactText
    let sourceBookName: BibleReaderPreparationExactText?
    let customIcon: BibleReaderPreparationExactText?
    let editActionMode: BibleReaderPreparationExactText?
    let editActionContent: BibleReaderPreparationExactText?
    let note: BibleReaderPreparationExactText?
    let notesContentType: BibleReaderPreparationExactText?
    let labelIDs: [BibleReaderPreparationExactText]
    let primaryLabelID: BibleReaderPreparationExactText?
}

/** Exact UTF-16 mirror for every string-valued generic bookmark input used by bridge projection. */
private struct BibleReaderPreparedGenericBookmarkTextIdentity: Hashable, Sendable {
    let key: BibleReaderPreparationExactText
    let sourceBookInitials: BibleReaderPreparationExactText
    let customIcon: BibleReaderPreparationExactText?
    let editActionMode: BibleReaderPreparationExactText?
    let editActionContent: BibleReaderPreparationExactText?
    let note: BibleReaderPreparationExactText?
    let notesContentType: BibleReaderPreparationExactText?
    let labelIDs: [BibleReaderPreparationExactText]
    let primaryLabelID: BibleReaderPreparationExactText?
}

/**
 Persistence-only Bible bookmark values copied before annotation preparation leaves SwiftData.

 Source text, module display metadata, mapped display ranges, and OSIS fragments are deliberately
 absent. A serialized SWORD operation can enrich this immutable value without moving the model or
 touching its relationships off-owner. Equality covers every persisted scalar used by the current
 annotation projector, including direct note and offset changes that may not advance timestamps.
 */
struct BibleReaderPreparedBibleBookmarkInput: Hashable, Sendable {
    let id: UUID
    let hashCode: Int
    let kjvaOrdinalStart: Int
    let kjvaOrdinalEnd: Int
    let sourceOrdinalStart: Int
    let sourceOrdinalEnd: Int
    let sourceVersification: String
    let sourceBookInitials: String
    let sourceBookName: String?
    let hasTrustedPersistedOrdinals: Bool
    let createdAtMilliseconds: Int
    let startOffset: Int?
    let endOffset: Int?
    let lastUpdatedOnMilliseconds: Int
    let wholeVerse: Bool
    let customIcon: String?
    let editActionMode: String?
    let editActionContent: String?
    let note: String?
    let notesContentType: String?
    let labelIDs: [String]
    let bookmarkToLabels: [BibleReaderPreparedBookmarkToLabelIdentity]
    let primaryLabelID: String?
    private let textIdentity: BibleReaderPreparedBibleBookmarkTextIdentity

    /** Copies the complete persistence-owned projection while the bookmark graph is on its owner. */
    init(_ bookmark: BibleBookmark, unlabeledLabelID: String) {
        let idString = bookmark.id.uuidString
        let labels = BookmarkLabelSerializationSupport.biblePayload(
            bookmarkID: bookmark.id,
            links: bookmark.bookmarkToLabels,
            unlabeledLabelID: unlabeledLabelID
        )
        id = bookmark.id
        hashCode = BibleReaderAnnotationPayloadFactory.normalizedBridgeHashCode(
            from: idString.hashValue
        )
        kjvaOrdinalStart = bookmark.kjvOrdinalStart
        kjvaOrdinalEnd = bookmark.kjvOrdinalEnd
        sourceOrdinalStart = bookmark.ordinalStart
        sourceOrdinalEnd = bookmark.ordinalEnd
        sourceVersification = bookmark.v11n
        sourceBookInitials = bookmark.bookInitials
        sourceBookName = bookmark.book
        hasTrustedPersistedOrdinals = bookmark.hasTrustedPersistedOrdinals
        createdAtMilliseconds = Int(bookmark.createdAt.timeIntervalSince1970 * 1000)
        startOffset = bookmark.startOffset
        endOffset = bookmark.endOffset
        lastUpdatedOnMilliseconds = Int(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000)
        wholeVerse = bookmark.wholeVerse
        customIcon = bookmark.customIcon
        editActionMode = bookmark.editAction?.mode?.rawValue
        editActionContent = bookmark.editAction?.content
        let rawNote = bookmark.notes?.notes ?? ""
        note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rawNote
        notesContentType = bookmark.notes?.contentType
        labelIDs = labels.labelIDs
        bookmarkToLabels = labels.relationItems.map(BibleReaderPreparedBookmarkToLabelIdentity.init)
        primaryLabelID = BookmarkLabelSerializationSupport.primaryLabelID(
            primaryLabelID: bookmark.primaryLabelId,
            validLabelIDs: labels.labelIDs
        )
        textIdentity = BibleReaderPreparedBibleBookmarkTextIdentity(
            sourceVersification: BibleReaderPreparationExactText(sourceVersification),
            sourceBookInitials: BibleReaderPreparationExactText(sourceBookInitials),
            sourceBookName: sourceBookName.map { BibleReaderPreparationExactText($0) },
            customIcon: customIcon.map { BibleReaderPreparationExactText($0) },
            editActionMode: editActionMode.map { BibleReaderPreparationExactText($0) },
            editActionContent: editActionContent.map { BibleReaderPreparationExactText($0) },
            note: note.map { BibleReaderPreparationExactText($0) },
            notesContentType: notesContentType.map { BibleReaderPreparationExactText($0) },
            labelIDs: labelIDs.map { BibleReaderPreparationExactText($0) },
            primaryLabelID: primaryLabelID.map { BibleReaderPreparationExactText($0) }
        )
    }
}

/** Persistence-only generic bookmark values copied before source enrichment leaves SwiftData. */
struct BibleReaderPreparedGenericBookmarkInput: Hashable, Sendable {
    let id: UUID
    let hashCode: Int
    let key: String
    let sourceBookInitials: String
    let createdAtMilliseconds: Int
    let ordinalStart: Int?
    let ordinalEnd: Int?
    let startOffset: Int?
    let endOffset: Int?
    let lastUpdatedOnMilliseconds: Int
    let wholeVerse: Bool
    let customIcon: String?
    let editActionMode: String?
    let editActionContent: String?
    let note: String?
    let notesContentType: String?
    let labelIDs: [String]
    let bookmarkToLabels: [BibleReaderPreparedBookmarkToLabelIdentity]
    let primaryLabelID: String?
    private let textIdentity: BibleReaderPreparedGenericBookmarkTextIdentity

    /** Copies the complete persistence-owned projection while the bookmark graph is on its owner. */
    init(_ bookmark: GenericBookmark, unlabeledLabelID: String) {
        let idString = bookmark.id.uuidString
        let labels = BookmarkLabelSerializationSupport.genericPayload(
            bookmarkID: bookmark.id,
            links: bookmark.bookmarkToLabels,
            unlabeledLabelID: unlabeledLabelID
        )
        id = bookmark.id
        hashCode = BibleReaderAnnotationPayloadFactory.normalizedBridgeHashCode(
            from: idString.hashValue
        )
        key = bookmark.key
        sourceBookInitials = bookmark.bookInitials
        createdAtMilliseconds = Int(bookmark.createdAt.timeIntervalSince1970 * 1000)
        ordinalStart = bookmark.ordinalStart
        ordinalEnd = bookmark.ordinalEnd
        startOffset = bookmark.startOffset
        endOffset = bookmark.endOffset
        lastUpdatedOnMilliseconds = Int(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000)
        wholeVerse = bookmark.wholeVerse
        customIcon = bookmark.customIcon
        editActionMode = bookmark.editAction?.mode?.rawValue
        editActionContent = bookmark.editAction?.content
        let rawNote = bookmark.notes?.notes ?? ""
        note = rawNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : rawNote
        notesContentType = bookmark.notes?.contentType
        labelIDs = labels.labelIDs
        bookmarkToLabels = labels.relationItems.map(BibleReaderPreparedBookmarkToLabelIdentity.init)
        primaryLabelID = BookmarkLabelSerializationSupport.primaryLabelID(
            primaryLabelID: bookmark.primaryLabelId,
            validLabelIDs: labels.labelIDs
        )
        textIdentity = BibleReaderPreparedGenericBookmarkTextIdentity(
            key: BibleReaderPreparationExactText(key),
            sourceBookInitials: BibleReaderPreparationExactText(sourceBookInitials),
            customIcon: customIcon.map { BibleReaderPreparationExactText($0) },
            editActionMode: editActionMode.map { BibleReaderPreparationExactText($0) },
            editActionContent: editActionContent.map { BibleReaderPreparationExactText($0) },
            note: note.map { BibleReaderPreparationExactText($0) },
            notesContentType: notesContentType.map { BibleReaderPreparationExactText($0) },
            labelIDs: labelIDs.map { BibleReaderPreparationExactText($0) },
            primaryLabelID: primaryLabelID.map { BibleReaderPreparationExactText($0) }
        )
    }
}

/** Every bridge-visible value of one copied bookmark-to-label relationship. */
struct BibleReaderPreparedBookmarkToLabelIdentity: Hashable, Sendable {
    let bookmarkID: BibleReaderPreparationExactText
    let labelID: BibleReaderPreparationExactText
    let orderNumber: Int
    let indentLevel: Int
    let expandContent: Bool
    let type: BibleReaderPreparationExactText

    init(_ value: BookmarkToLabelData) {
        bookmarkID = BibleReaderPreparationExactText(value.bookmarkId)
        labelID = BibleReaderPreparationExactText(value.labelId)
        orderNumber = value.orderNumber
        indentLevel = value.indentLevel
        expandContent = value.expandContent
        type = BibleReaderPreparationExactText(value.type)
    }
}

/** Every bridge-visible style value nested inside one label. */
private struct BibleReaderPreparedBookmarkStyleIdentity: Hashable, Sendable {
    let color: Int
    let isSpeak: Bool
    let isParagraphBreak: Bool
    let underline: Bool
    let underlineWholeVerse: Bool
    let markerStyle: Bool
    let markerStyleWholeVerse: Bool
    let hideStyle: Bool
    let hideStyleWholeVerse: Bool
    let customIcon: BibleReaderPreparationExactText?

    init(_ value: BookmarkStyleData) {
        color = value.color
        isSpeak = value.isSpeak
        isParagraphBreak = value.isParagraphBreak
        underline = value.underline
        underlineWholeVerse = value.underlineWholeVerse
        markerStyle = value.markerStyle
        markerStyleWholeVerse = value.markerStyleWholeVerse
        hideStyle = value.hideStyle
        hideStyleWholeVerse = value.hideStyleWholeVerse
        customIcon = value.customIcon.map { BibleReaderPreparationExactText($0) }
    }
}

/** Exact bridge-visible identity for one copied label. */
struct BibleReaderPreparedLabelIdentity: Hashable, Sendable {
    let id: BibleReaderPreparationExactText
    let name: BibleReaderPreparationExactText
    private let style: BibleReaderPreparedBookmarkStyleIdentity
    let isRealLabel: Bool

    init(_ value: LabelData) {
        id = BibleReaderPreparationExactText(value.id)
        name = BibleReaderPreparationExactText(value.name)
        style = BibleReaderPreparedBookmarkStyleIdentity(value.style)
        isRealLabel = value.isRealLabel
    }
}

/** Exact mapped source identity for one My Notes document request. */
private struct BibleReaderPreparedMyNotesReferenceIdentity: Hashable, Sendable {
    let sourceVersification: BibleReaderPreparationExactText
    let sourceOSISBookID: BibleReaderPreparationExactText
    let requestedSourceChapter: Int
    let effectiveSourceChapter: Int
    let mappedStartOSISBookID: BibleReaderPreparationExactText
    let mappedStartChapter: Int
    let mappedStartVerse: Int
    let mappedEndOSISBookID: BibleReaderPreparationExactText
    let mappedEndChapter: Int
    let mappedEndVerse: Int
    let kjvaOrdinalStart: Int
    let kjvaOrdinalEnd: Int
    let displayHeading: BibleReaderPreparationExactText

    init(_ value: MyNotesChapterReference) {
        sourceVersification = BibleReaderPreparationExactText(value.source.versification)
        sourceOSISBookID = BibleReaderPreparationExactText(value.source.osisBookId)
        requestedSourceChapter = value.source.chapter
        effectiveSourceChapter = value.effectiveSourceChapter
        mappedStartOSISBookID = BibleReaderPreparationExactText(value.mappedKJVAStart.osisBookId)
        mappedStartChapter = value.mappedKJVAStart.chapter
        mappedStartVerse = value.mappedKJVAStart.verse
        mappedEndOSISBookID = BibleReaderPreparationExactText(value.mappedKJVAEnd.osisBookId)
        mappedEndChapter = value.mappedKJVAEnd.chapter
        mappedEndVerse = value.mappedKJVAEnd.verse
        kjvaOrdinalStart = value.kjvaOrdinalStart
        kjvaOrdinalEnd = value.kjvaOrdinalEnd
        displayHeading = BibleReaderPreparationExactText(value.displayHeading)
    }
}

/** Exact owner identity checked immediately before a prepared My Notes result is published. */
struct BibleReaderPreparedMyNotesOwnerIdentity: Hashable, Sendable {
    private let reference: BibleReaderPreparedMyNotesReferenceIdentity
    private let bookmarks: [BibleReaderPreparedBibleBookmarkInput]
    private let labels: [BibleReaderPreparedLabelIdentity]
    let jumpToOrdinal: Int?

    init(
        reference: MyNotesChapterReference,
        bookmarks: [BibleReaderPreparedBibleBookmarkInput],
        labels: [LabelData],
        jumpToOrdinal: Int?
    ) {
        self.reference = BibleReaderPreparedMyNotesReferenceIdentity(reference)
        self.bookmarks = bookmarks
        self.labels = labels.map(BibleReaderPreparedLabelIdentity.init)
        self.jumpToOrdinal = jumpToOrdinal
    }
}

/** Persistence-owner snapshot resumed by the worker after mapped-range capture. */
struct BibleReaderPreparedMyNotesOwnerSnapshot: Sendable {
    let reference: MyNotesChapterReference
    let bookmarkInputs: [BibleReaderPreparedBibleBookmarkInput]
    let labels: [LabelData]
    let jumpToOrdinal: Int?
    let identity: BibleReaderPreparedMyNotesOwnerIdentity

    init(
        reference: MyNotesChapterReference,
        bookmarkInputs: [BibleReaderPreparedBibleBookmarkInput],
        labels: [LabelData],
        jumpToOrdinal: Int?
    ) {
        self.reference = reference
        self.bookmarkInputs = bookmarkInputs
        self.labels = labels
        self.jumpToOrdinal = jumpToOrdinal
        identity = BibleReaderPreparedMyNotesOwnerIdentity(
            reference: reference,
            bookmarks: bookmarkInputs,
            labels: labels,
            jumpToOrdinal: jumpToOrdinal
        )
    }
}

/**
 Immutable copied values required to encode one mapped My Notes chapter away from SwiftData.

 `bookmarks` affect the My Notes document JSON. `labels` are retained for the separate
 `update_labels` event. The live reader configuration remains publication-owned and is deliberately
 absent because the replacement emitter resolves it atomically when the prepared document commits.
 */
struct BibleReaderPreparedMyNotesDocument: Sendable {
    let reference: MyNotesChapterReference
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
    let bookmarkInputs: [BibleReaderPreparedBibleBookmarkInput]
    let bookmarks: [BibleBookmarkData]
    let labels: [LabelData]
    let jumpToOrdinal: Int?
    let ownerIdentity: BibleReaderPreparedMyNotesOwnerIdentity

    init(
        reference: MyNotesChapterReference,
        sourceDependencies: [BibleReaderPreparationSourceDependency],
        bookmarkInputs: [BibleReaderPreparedBibleBookmarkInput],
        bookmarks: [BibleBookmarkData],
        labels: [LabelData],
        jumpToOrdinal: Int?
    ) {
        self.reference = reference
        self.sourceDependencies = sourceDependencies
        self.bookmarkInputs = bookmarkInputs
        self.bookmarks = bookmarks
        self.labels = labels
        self.jumpToOrdinal = jumpToOrdinal
        ownerIdentity = BibleReaderPreparedMyNotesOwnerIdentity(
            reference: reference,
            bookmarks: bookmarkInputs,
            labels: labels,
            jumpToOrdinal: jumpToOrdinal
        )
    }

    /// Stable Vue document id derived from the authoritative mapped KJVA span.
    var documentID: String {
        "ordinal-\(reference.kjvaOrdinalStart)-\(reference.kjvaOrdinalEnd)"
    }

    /** Serializes only the existing My Notes document contract from frozen copied values. */
    func encodedJSON() -> String? {
        guard bookmarkInputs.map({ $0.id.uuidString }) == bookmarks.map(\.id) else {
            return nil
        }
        return bibleReaderPreparedJSONString(
            MyNotesDocumentPayload(
                id: documentID,
                type: "notes",
                bookmarks: bookmarks,
                verseRange: reference.displayHeading,
                ordinalRange: [reference.kjvaOrdinalStart, reference.kjvaOrdinalEnd]
            )
        )
    }
}

/** Serialized My Notes output paired with the exact values authorized for publication. */
struct BibleReaderEncodedMyNotesDocument: Sendable {
    let prepared: BibleReaderPreparedMyNotesDocument
    let documentJSON: String
}

/** Encodes one frozen bridge value without sharing a mutable global encoder across workers. */
func bibleReaderPreparedJSONString<Value: Encodable>(_ value: Value) -> String? {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
}
