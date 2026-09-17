// BibleReaderPreparedStudyPadDocument.swift -- Immutable StudyPad bridge preparation

import BibleCore
import BibleView
import Foundation

/** Exact persisted source lookup identity for one copied generic bookmark. */
struct BibleReaderPreparedGenericBookmarkSourceKey: Hashable, Sendable {
    let bookInitials: BibleReaderPreparationExactText
    let key: BibleReaderPreparationExactText

    init(bookInitials: String, key: String) {
        self.bookInitials = BibleReaderPreparationExactText(bookInitials)
        self.key = BibleReaderPreparationExactText(key)
    }
}

/** Local source retained after installed ownership is resolved from one worker snapshot. */
enum BibleReaderPreparedGenericLocalSource: @unchecked Sendable {
    /// Exact persistence-only My Documents page copied on the database owner.
    case myDocument(BibleReaderPreparedMyDocumentSource)
    /// Immutable EPUB reader generation whose exact content is captured on the worker.
    case epub(EpubReader)
}

/** Immutable installed-source registry captured before StudyPad persistence ownership. */
struct BibleReaderPreparedStudyPadSourceRegistry: @unchecked Sendable {
    let installedResolver: BibleReaderInstalledModuleResolver
}

/** Exact bridge-visible identity for one copied StudyPad text entry. */
private struct BibleReaderPreparedStudyPadEntryIdentity: Hashable, Sendable {
    let id: BibleReaderPreparationExactText
    let type: BibleReaderPreparationExactText
    let hashCode: Int
    let labelID: BibleReaderPreparationExactText
    let text: BibleReaderPreparationExactText
    let contentType: BibleReaderPreparationExactText?
    let orderNumber: Int
    let indentLevel: Int
    let sourcePromptID: BibleReaderPreparationExactText?

    init(_ value: StudyPadTextItemData) {
        id = BibleReaderPreparationExactText(value.id)
        type = BibleReaderPreparationExactText(value.type)
        hashCode = value.hashCode
        labelID = BibleReaderPreparationExactText(value.labelId)
        text = BibleReaderPreparationExactText(value.text)
        contentType = value.contentType.map { BibleReaderPreparationExactText($0) }
        orderNumber = value.orderNumber
        indentLevel = value.indentLevel
        sourcePromptID = value.sourcePromptId.map { BibleReaderPreparationExactText($0) }
    }
}

/** Exact owner identity checked immediately before a prepared StudyPad result is published. */
struct BibleReaderPreparedStudyPadOwnerIdentity: Hashable, Sendable {
    let labelID: UUID
    let displayName: BibleReaderPreparationExactText
    let jumpToID: BibleReaderPreparationExactText?
    private let label: BibleReaderPreparedLabelIdentity
    private let bookmarks: [BibleReaderPreparedBibleBookmarkInput]
    private let genericBookmarks: [BibleReaderPreparedGenericBookmarkInput]
    private let bookmarkToLabels: [BibleReaderPreparedBookmarkToLabelIdentity]
    private let genericBookmarkToLabels: [BibleReaderPreparedBookmarkToLabelIdentity]
    private let journalTextEntries: [BibleReaderPreparedStudyPadEntryIdentity]
    private let labels: [BibleReaderPreparedLabelIdentity]

    init(
        labelID: UUID,
        displayName: String,
        jumpToID: String?,
        label: LabelData,
        bookmarks: [BibleReaderPreparedBibleBookmarkInput],
        genericBookmarks: [BibleReaderPreparedGenericBookmarkInput],
        bookmarkToLabels: [BookmarkToLabelData],
        genericBookmarkToLabels: [BookmarkToLabelData],
        journalTextEntries: [StudyPadTextItemData],
        labels: [LabelData]
    ) {
        self.labelID = labelID
        self.displayName = BibleReaderPreparationExactText(displayName)
        self.jumpToID = jumpToID.map { BibleReaderPreparationExactText($0) }
        self.label = BibleReaderPreparedLabelIdentity(label)
        self.bookmarks = bookmarks
        self.genericBookmarks = genericBookmarks
        self.bookmarkToLabels = bookmarkToLabels.map(BibleReaderPreparedBookmarkToLabelIdentity.init)
        self.genericBookmarkToLabels = genericBookmarkToLabels.map(BibleReaderPreparedBookmarkToLabelIdentity.init)
        self.journalTextEntries = journalTextEntries.map(BibleReaderPreparedStudyPadEntryIdentity.init)
        self.labels = labels.map(BibleReaderPreparedLabelIdentity.init)
    }
}

/** Complete StudyPad persistence graph copied before source enrichment leaves the main owner. */
struct BibleReaderPreparedStudyPadOwnerSnapshot: Sendable {
    let labelID: UUID
    let displayName: String
    let jumpToID: String?
    let label: LabelData
    let bookmarkInputs: [BibleReaderPreparedBibleBookmarkInput]
    let genericBookmarkInputs: [BibleReaderPreparedGenericBookmarkInput]
    let bookmarkToLabels: [BookmarkToLabelData]
    let genericBookmarkToLabels: [BookmarkToLabelData]
    let journalTextEntries: [StudyPadTextItemData]
    let labels: [LabelData]
    let localGenericSources: [
        BibleReaderPreparedGenericBookmarkSourceKey: BibleReaderPreparedGenericLocalSource
    ]
    let identity: BibleReaderPreparedStudyPadOwnerIdentity

    init(
        labelID: UUID,
        displayName: String,
        jumpToID: String?,
        label: LabelData,
        bookmarkInputs: [BibleReaderPreparedBibleBookmarkInput],
        genericBookmarkInputs: [BibleReaderPreparedGenericBookmarkInput],
        bookmarkToLabels: [BookmarkToLabelData],
        genericBookmarkToLabels: [BookmarkToLabelData],
        journalTextEntries: [StudyPadTextItemData],
        labels: [LabelData],
        localGenericSources: [
            BibleReaderPreparedGenericBookmarkSourceKey: BibleReaderPreparedGenericLocalSource
        ] = [:]
    ) {
        self.labelID = labelID
        self.displayName = displayName
        self.jumpToID = jumpToID
        self.label = label
        self.bookmarkInputs = bookmarkInputs
        self.genericBookmarkInputs = genericBookmarkInputs
        self.bookmarkToLabels = bookmarkToLabels
        self.genericBookmarkToLabels = genericBookmarkToLabels
        self.journalTextEntries = journalTextEntries
        self.labels = labels
        self.localGenericSources = localGenericSources
        identity = BibleReaderPreparedStudyPadOwnerIdentity(
            labelID: labelID,
            displayName: displayName,
            jumpToID: jumpToID,
            label: label,
            bookmarks: bookmarkInputs,
            genericBookmarks: genericBookmarkInputs,
            bookmarkToLabels: bookmarkToLabels,
            genericBookmarkToLabels: genericBookmarkToLabels,
            journalTextEntries: journalTextEntries,
            labels: labels
        )
    }
}

/**
 Immutable copied values required to encode one StudyPad away from its SwiftData owner.

 The label and five row collections affect document JSON. `labels` are retained for the separate
 `update_labels` event. `displayName` and `jumpToID` affect native presentation and setup rather
 than the document JSON, so the exact owner identity includes both.
 */
struct BibleReaderPreparedStudyPadDocument: Sendable {
    let labelID: UUID
    let displayName: String
    let jumpToID: String?
    let sourceDependencies: [BibleReaderPreparationSourceDependency]
    let label: LabelData
    let bookmarkInputs: [BibleReaderPreparedBibleBookmarkInput]
    let bookmarks: [BibleBookmarkData]
    let genericBookmarkInputs: [BibleReaderPreparedGenericBookmarkInput]
    let genericBookmarks: [GenericBookmarkData]
    let bookmarkToLabels: [BookmarkToLabelData]
    let genericBookmarkToLabels: [BookmarkToLabelData]
    let journalTextEntries: [StudyPadTextItemData]
    let labels: [LabelData]
    let ownerIdentity: BibleReaderPreparedStudyPadOwnerIdentity

    init(
        labelID: UUID,
        displayName: String,
        jumpToID: String?,
        sourceDependencies: [BibleReaderPreparationSourceDependency],
        label: LabelData,
        bookmarkInputs: [BibleReaderPreparedBibleBookmarkInput],
        bookmarks: [BibleBookmarkData],
        genericBookmarkInputs: [BibleReaderPreparedGenericBookmarkInput],
        genericBookmarks: [GenericBookmarkData],
        bookmarkToLabels: [BookmarkToLabelData],
        genericBookmarkToLabels: [BookmarkToLabelData],
        journalTextEntries: [StudyPadTextItemData],
        labels: [LabelData]
    ) {
        self.labelID = labelID
        self.displayName = displayName
        self.jumpToID = jumpToID
        self.sourceDependencies = sourceDependencies
        self.label = label
        self.bookmarkInputs = bookmarkInputs
        self.bookmarks = bookmarks
        self.genericBookmarkInputs = genericBookmarkInputs
        self.genericBookmarks = genericBookmarks
        self.bookmarkToLabels = bookmarkToLabels
        self.genericBookmarkToLabels = genericBookmarkToLabels
        self.journalTextEntries = journalTextEntries
        self.labels = labels
        ownerIdentity = BibleReaderPreparedStudyPadOwnerIdentity(
            labelID: labelID,
            displayName: displayName,
            jumpToID: jumpToID,
            label: label,
            bookmarks: bookmarkInputs,
            genericBookmarks: genericBookmarkInputs,
            bookmarkToLabels: bookmarkToLabels,
            genericBookmarkToLabels: genericBookmarkToLabels,
            journalTextEntries: journalTextEntries,
            labels: labels
        )
    }

    /// Stable Vue journal id derived from the exact persisted label owner.
    var documentID: String { "journal_\(labelID.uuidString)" }

    /** Serializes only the existing StudyPad document contract from frozen copied values. */
    func encodedJSON() -> String? {
        guard bookmarkInputs.map({ $0.id.uuidString }) == bookmarks.map(\.id),
              genericBookmarkInputs.map({ $0.id.uuidString }) == genericBookmarks.map(\.id) else {
            return nil
        }
        return bibleReaderPreparedJSONString(
            StudyPadDocumentPayload(
                id: documentID,
                type: "journal",
                label: label,
                bookmarks: bookmarks,
                genericBookmarks: genericBookmarks,
                bookmarkToLabels: bookmarkToLabels,
                genericBookmarkToLabels: genericBookmarkToLabels,
                journalTextEntries: journalTextEntries
            )
        )
    }
}

/** Serialized StudyPad output paired with the exact values authorized for publication. */
struct BibleReaderEncodedStudyPadDocument: Sendable {
    let prepared: BibleReaderPreparedStudyPadDocument
    let documentJSON: String
    let sourceRegistry: BibleReaderPreparedStudyPadSourceRegistry
}
