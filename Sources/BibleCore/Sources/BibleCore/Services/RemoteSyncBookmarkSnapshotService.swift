// RemoteSyncBookmarkSnapshotService.swift — Android-shaped local bookmark snapshots for outbound sync

import CryptoKit
import Foundation
import SwiftData

/**
 Current local representation of one Android bookmark-note row.
 */
public struct RemoteSyncCurrentBookmarkNoteRow: Sendable, Equatable, Codable {
    /// Android bookmark identifier that owns the detached note row.
    public let bookmarkID: UUID

    /// Raw detached note payload stored in the Android note table.
    public let notes: String

    /// Optional Android `TextContentType` raw value stored beside the detached note payload.
    public let contentType: String?

    /// Optional AI prompt identifier that produced the detached note.
    public let sourcePromptId: UUID?

    /**
     Creates one Android-shaped current bookmark-note row.

     - Parameters:
       - bookmarkID: Android bookmark identifier that owns the detached note row.
       - notes: Raw detached note payload stored in the Android note table.
       - contentType: Optional Android `TextContentType` raw value for the detached note payload;
         invalid non-nil row values are represented as `nil` so they keep Android inheritance
         semantics instead of becoming the app default.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        bookmarkID: UUID,
        notes: String,
        contentType: String? = nil,
        sourcePromptId: UUID? = nil
    ) {
        self.bookmarkID = bookmarkID
        self.notes = notes
        self.contentType = AppPreferenceValueNormalizer.notesContentTypeRow(contentType)
        self.sourcePromptId = sourcePromptId
    }
}

/**
 Current local representation of one Android bookmark-to-label junction row.
 */
public struct RemoteSyncCurrentBookmarkLabelLinkRow: Sendable, Equatable, Codable {
    /// Android bookmark identifier that owns the link row.
    public let bookmarkID: UUID

    /// Android label identifier referenced by the link row.
    public let labelID: UUID

    /// Android display order used by label-backed lists.
    public let orderNumber: Int

    /// Android nesting depth used by StudyPad-like rendering.
    public let indentLevel: Int

    /// Android expand/collapse state for the linked content.
    public let expandContent: Bool

    /**
     Creates one Android-shaped current bookmark-to-label junction row.

     - Parameters:
       - bookmarkID: Android bookmark identifier that owns the link row.
       - labelID: Android label identifier referenced by the link row.
       - orderNumber: Android display order used by label-backed lists.
       - indentLevel: Android nesting depth used by StudyPad-like rendering.
       - expandContent: Android expand/collapse state for the linked content.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        bookmarkID: UUID,
        labelID: UUID,
        orderNumber: Int,
        indentLevel: Int,
        expandContent: Bool
    ) {
        self.bookmarkID = bookmarkID
        self.labelID = labelID
        self.orderNumber = orderNumber
        self.indentLevel = indentLevel
        self.expandContent = expandContent
    }
}

/**
 Current local representation of one Android `StudyPadTextEntryText` row.
 */
public struct RemoteSyncCurrentStudyPadTextRow: Sendable, Equatable, Codable {
    /// Android StudyPad-entry identifier that owns the detached text row.
    public let entryID: UUID

    /// Raw detached StudyPad text payload.
    public let text: String

    /**
     Creates one Android-shaped current StudyPad text row.

     - Parameters:
       - entryID: Android StudyPad-entry identifier that owns the detached text row.
       - text: Raw detached StudyPad text payload.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(entryID: UUID, text: String) {
        self.entryID = entryID
        self.text = text
    }
}

/**
 Snapshot of the current local bookmark state expressed in Android row form.

 The snapshot carries per-table row maps keyed by Android's `(tableName, entityId1, entityId2)`
 composite identifier together with precomputed row fingerprints. Outbound patch creation can then
 diff local state without reprojecting SwiftData repeatedly.
 */
public struct RemoteSyncBookmarkCurrentSnapshot: Sendable, Equatable {
    /// Android-shaped current `Label` rows keyed by Android composite key.
    public let labelRowsByKey: [String: RemoteSyncAndroidLabel]

    /// Android-shaped current `BibleBookmark` rows keyed by Android composite key.
    public let bibleBookmarkRowsByKey: [String: RemoteSyncAndroidBibleBookmark]

    /// Android-shaped current `BibleBookmarkNotes` rows keyed by Android composite key.
    public let bibleNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow]

    /// Android-shaped current `BibleBookmarkToLabel` rows keyed by Android composite key.
    public let bibleLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow]

    /// Android-shaped current `GenericBookmark` rows keyed by Android composite key.
    public let genericBookmarkRowsByKey: [String: RemoteSyncAndroidGenericBookmark]

    /// Android-shaped current `GenericBookmarkNotes` rows keyed by Android composite key.
    public let genericNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow]

    /// Android-shaped current `GenericBookmarkToLabel` rows keyed by Android composite key.
    public let genericLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow]

    /// Android-shaped current `StudyPadTextEntry` rows keyed by Android composite key.
    public let studyPadEntryRowsByKey: [String: RemoteSyncAndroidStudyPadEntry]

    /// Android-shaped current `StudyPadTextEntryText` rows keyed by Android composite key.
    public let studyPadTextRowsByKey: [String: RemoteSyncCurrentStudyPadTextRow]

    /// Stable content fingerprints for every current row keyed by Android composite key.
    public let fingerprintsByKey: [String: String]

    /// Quarantined local keys whose omission must never be interpreted as a remote delete.
    public let suppressedKeys: Set<String>

    /**
     Creates one current-state bookmark snapshot.

     - Parameters:
       - labelRowsByKey: Android-shaped current `Label` rows keyed by Android composite key.
       - bibleBookmarkRowsByKey: Android-shaped current `BibleBookmark` rows keyed by Android composite key.
       - bibleNoteRowsByKey: Android-shaped current `BibleBookmarkNotes` rows keyed by Android composite key.
       - bibleLinkRowsByKey: Android-shaped current `BibleBookmarkToLabel` rows keyed by Android composite key.
       - genericBookmarkRowsByKey: Android-shaped current `GenericBookmark` rows keyed by Android composite key.
       - genericNoteRowsByKey: Android-shaped current `GenericBookmarkNotes` rows keyed by Android composite key.
       - genericLinkRowsByKey: Android-shaped current `GenericBookmarkToLabel` rows keyed by Android composite key.
       - studyPadEntryRowsByKey: Android-shaped current `StudyPadTextEntry` rows keyed by Android composite key.
       - studyPadTextRowsByKey: Android-shaped current `StudyPadTextEntryText` rows keyed by Android composite key.
       - fingerprintsByKey: Stable content fingerprints for every current row keyed by Android composite key.
       - suppressedKeys: Quarantined local keys omitted from export but retained in delete baselines.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        labelRowsByKey: [String: RemoteSyncAndroidLabel],
        bibleBookmarkRowsByKey: [String: RemoteSyncAndroidBibleBookmark],
        bibleNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow],
        bibleLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow],
        genericBookmarkRowsByKey: [String: RemoteSyncAndroidGenericBookmark],
        genericNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow],
        genericLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow],
        studyPadEntryRowsByKey: [String: RemoteSyncAndroidStudyPadEntry],
        studyPadTextRowsByKey: [String: RemoteSyncCurrentStudyPadTextRow],
        fingerprintsByKey: [String: String],
        suppressedKeys: Set<String> = []
    ) {
        self.labelRowsByKey = labelRowsByKey
        self.bibleBookmarkRowsByKey = bibleBookmarkRowsByKey
        self.bibleNoteRowsByKey = bibleNoteRowsByKey
        self.bibleLinkRowsByKey = bibleLinkRowsByKey
        self.genericBookmarkRowsByKey = genericBookmarkRowsByKey
        self.genericNoteRowsByKey = genericNoteRowsByKey
        self.genericLinkRowsByKey = genericLinkRowsByKey
        self.studyPadEntryRowsByKey = studyPadEntryRowsByKey
        self.studyPadTextRowsByKey = studyPadTextRowsByKey
        self.fingerprintsByKey = fingerprintsByKey
        self.suppressedKeys = suppressedKeys
    }
}

/**
 Durable identity for one bookmark-category row accepted by outbound or inbound synchronization.

 Fingerprints prove content equality, while this identity preserves enough Android primary-key data
 to emit a later `DELETE` even when the accepted initial database carried no `LogEntry` row.
 */
struct RemoteSyncBookmarkAcceptedRowIdentity: Codable, Sendable, Equatable {
    /// Canonical bookmark-category log key for the row.
    let key: String

    /// Android table that owns the row.
    let tableName: String

    /// First Android composite-key component.
    let entityID1: RemoteSyncSQLiteValue

    /// Second Android composite-key component.
    let entityID2: RemoteSyncSQLiteValue
}

/**
 Immutable bookmark baseline accepted by one completed synchronization generation.

 The value is Codable so an outbound outbox can retain the exact generation across process death.
 Publication replaces fingerprints and the accepted-key manifest together inside the caller's
 `SettingsStore` atomic batch.
 */
struct RemoteSyncBookmarkAcceptedBaseline: Codable, Sendable, Equatable {
    /// Opaque publication revision used to reject stale outbox acceptance.
    let revision: UUID?

    /// Exact projected fingerprints keyed by canonical Android log key.
    let fingerprintsByKey: [String: String]

    /// Exportable accepted row identities used to discover future deletions.
    let rowIdentities: [RemoteSyncBookmarkAcceptedRowIdentity]

    /// Quarantined keys whose prior fingerprint must remain untouched.
    let suppressedKeys: Set<String>

    /** Creates one immutable accepted bookmark generation. */
    init(
        revision: UUID? = UUID(),
        fingerprintsByKey: [String: String],
        rowIdentities: [RemoteSyncBookmarkAcceptedRowIdentity],
        suppressedKeys: Set<String>
    ) {
        self.revision = revision
        self.fingerprintsByKey = fingerprintsByKey
        self.rowIdentities = rowIdentities
        self.suppressedKeys = suppressedKeys
    }
}

/**
 Errors raised while reading or publishing the durable bookmark accepted-generation manifest.
 */
enum RemoteSyncBookmarkAcceptedBaselineError: Error, Equatable {
    /// Persisted JSON could not be decoded as a complete accepted generation.
    case invalidStoredBaseline

    /// A projected fingerprint key did not belong to the bookmark log-key namespace.
    case invalidFingerprintKey(String)

    /// An exportable projected row had no stable fingerprint.
    case missingProjectedFingerprint(String)

    /// The accepted baseline changed after an outbox generation was projected.
    case staleAcceptedBaseline
}

/**
 Projects current local bookmark state into Android-shaped rows and row fingerprints.

 Outbound bookmark sync needs the inverse of restore and patch replay:
 - convert local labels, Bible bookmarks, generic bookmarks, notes, links, and StudyPad rows back
   into Android table rows
 - emit Android's current fixed UUIDs for reserved labels even when the local graph was restored
   through a historical remote-ID alias
 - synthesize Android's complete `playbackSettings` schema from the native model, retaining preserved
   raw JSON only as the fallback when native encoding is unavailable
 - compute stable row fingerprints keyed by Android's composite identifier so later patch creation
   can detect inserts, updates, and deletes without hidden SQLite triggers

 Data dependencies:
 - `ModelContext` provides live bookmark-category SwiftData rows
 - `RemoteSyncBookmarkPlaybackSettingsStore` provides preserved raw Android playback JSON
 - `RemoteSyncLogEntryStore` provides canonical Android composite-key encoding
 - `RemoteSyncRowFingerprintStore` persists baseline fingerprints after restore, replay, or upload

 Side effects:
 - `snapshotCurrentState` reads bookmark-category SwiftData rows and local-only fidelity settings
 - `refreshBaselineFingerprints` rewrites local fingerprint rows for the bookmark category

 Failure modes:
 - compatibility projection methods swallow per-table fetch failures and preserve historical
   empty-table behavior for non-destructive export callers
 - throwing projection and baseline methods propagate the first fetch failure before publication

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncBookmarkSnapshotService {
    /// Single settings key containing the accepted bookmark row-identity manifest.
    static let acceptedBaselineKey = "remote_sync.accepted_baseline.bookmarks"

    /**
     Selects whether snapshot projection preserves historical fail-soft fetch behavior or propagates
     every SwiftData read error to an atomic publication caller.
     */
    private enum FetchPolicy {
        /// Treats each failed table fetch as an empty table for compatibility-only callers.
        case compatibility

        /// Propagates the first failed table fetch before any durable publication begins.
        case strict
    }

    /// Deterministic pre-fetch checkpoint used by tests to model a strict SwiftData read failure.
    private let strictSnapshotCheckpoint: () throws -> Void

    /**
     Creates a bookmark snapshot service.

     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init() {
        strictSnapshotCheckpoint = {}
    }

    /**
     Creates a snapshot service with a deterministic strict-read checkpoint for data-safety tests.

     - Parameter strictSnapshotCheckpoint: Callback invoked immediately before every throwing graph
       projection. Production callers use the public initializer and therefore a no-op checkpoint.
     - Side effects: Stores the callback without invoking it.
     - Failure modes: This initializer cannot fail; callback errors are rethrown by strict methods.
     */
    init(strictSnapshotCheckpoint: @escaping () throws -> Void) {
        self.strictSnapshotCheckpoint = strictSnapshotCheckpoint
    }

    /**
     Projects the current local bookmark state into Android-shaped rows and row fingerprints.

     - Parameters:
       - modelContext: SwiftData context that owns the current bookmark graph.
       - settingsStore: Local-only settings store that holds preserved Android fidelity payloads.
     - Returns: Android-shaped current rows and their stable fingerprints keyed by Android composite key.
     - Side effects:
       - reads current bookmark-category SwiftData rows from `modelContext`
       - reads preserved Android playback JSON and label-alias rows from `SettingsStore`
     - Failure modes:
       - fetch failures from `ModelContext` are swallowed and treated as an empty snapshot
     */
    public func snapshotCurrentState(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> RemoteSyncBookmarkCurrentSnapshot {
        do {
            return try makeSnapshot(
                modelContext: modelContext,
                settingsStore: settingsStore,
                includeUnverifiedBibleBookmarks: false,
                fetchPolicy: .compatibility
            )
        } catch {
            return Self.emptySnapshot()
        }
    }

    /**
     Projects current bookmark rows while preserving every SwiftData fetch failure.

     Atomic restore and patch publication use this path because an unreadable local table cannot be
     interpreted as an authoritative empty table when replacing fingerprints or graph content.

     - Parameters:
       - modelContext: SwiftData context that owns the current bookmark graph.
       - settingsStore: Local-only settings store that holds preserved Android fidelity payloads.
     - Returns: Complete Android-shaped current rows and stable fingerprints.
     - Side effects: Reads bookmark SwiftData rows and local fidelity settings.
     - Failure modes: Rethrows the strict checkpoint and the first SwiftData fetch failure.
     */
    public func snapshotCurrentStateThrowing(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncBookmarkCurrentSnapshot {
        try strictSnapshotCheckpoint()
        return try makeSnapshot(
            modelContext: modelContext,
            settingsStore: settingsStore,
            includeUnverifiedBibleBookmarks: false,
            fetchPolicy: .strict
        )
    }

    /**
     Projects the complete local bookmark graph for lossless restore merging inside BibleCore.

     This boundary is intentionally internal so sync, export, and Android backup callers cannot opt
     quarantined rows into outbound data. Restore uses it only to carry non-colliding unresolved rows
     across an authoritative replacement.

     - Parameters:
       - modelContext: SwiftData context containing verified and quarantined bookmarks.
       - settingsStore: Local fidelity settings needed to reconstruct Android-shaped rows.
     - Returns: A current snapshot that includes unverified Bible bookmarks and marks their keys as
       suppressed.
     - Side effects: Reads SwiftData and local fidelity settings only.
     - Failure modes: Rethrows the strict checkpoint and the first SwiftData fetch failure.
     */
    func snapshotIncludingQuarantinedBibleBookmarks(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncBookmarkCurrentSnapshot {
        try strictSnapshotCheckpoint()
        return try makeSnapshot(
            modelContext: modelContext,
            settingsStore: settingsStore,
            includeUnverifiedBibleBookmarks: true,
            fetchPolicy: .strict
        )
    }

    /**
     Builds one Android-shaped bookmark snapshot under an explicit internal quarantine policy.

     - Parameters:
       - modelContext: SwiftData context that owns the current bookmark graph.
       - settingsStore: Local-only bookmark fidelity settings.
       - includeUnverifiedBibleBookmarks: Whether restore-only projection should retain quarantined
         Bible rows in the returned row dictionaries.
       - fetchPolicy: Whether table fetch errors are suppressed for compatibility or propagated.
     - Returns: Current rows, fingerprints, and suppression keys.
     - Side effects: Reads current SwiftData rows and local settings.
     - Failure modes: Strict projection rethrows the first SwiftData fetch failure; compatibility
       projection treats each failed table fetch as an empty table.
     */
    private func makeSnapshot(
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        includeUnverifiedBibleBookmarks: Bool,
        fetchPolicy: FetchPolicy
    ) throws -> RemoteSyncBookmarkCurrentSnapshot {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let playbackSettingsStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        let androidBookStore = RemoteSyncBookmarkAndroidBookStore(settingsStore: settingsStore)

        let labels = try fetch(FetchDescriptor<Label>(), from: modelContext, policy: fetchPolicy)
            .sorted(by: sortLabels)
        let bibleBookmarks = try fetch(FetchDescriptor<BibleBookmark>(), from: modelContext, policy: fetchPolicy)
            .sorted(by: sortBibleBookmarks)
        let bibleNotes = try fetch(FetchDescriptor<BibleBookmarkNotes>(), from: modelContext, policy: fetchPolicy)
        let bibleLinks = try fetch(FetchDescriptor<BibleBookmarkToLabel>(), from: modelContext, policy: fetchPolicy)
        let genericBookmarks = try fetch(FetchDescriptor<GenericBookmark>(), from: modelContext, policy: fetchPolicy)
            .sorted(by: sortGenericBookmarks)
        let genericNotes = try fetch(FetchDescriptor<GenericBookmarkNotes>(), from: modelContext, policy: fetchPolicy)
        let genericLinks = try fetch(FetchDescriptor<GenericBookmarkToLabel>(), from: modelContext, policy: fetchPolicy)
        let studyPadEntries = try fetch(FetchDescriptor<StudyPadTextEntry>(), from: modelContext, policy: fetchPolicy)
            .sorted(by: sortStudyPadEntries)
        let studyPadTexts = try fetch(FetchDescriptor<StudyPadTextEntryText>(), from: modelContext, policy: fetchPolicy)
        let remoteLabelIDsByLocalID = Dictionary(
            uniqueKeysWithValues: labels.map { label in
                (
                    label.id,
                    AndroidBookmarkDatabaseContract.fixedLabelID(forName: label.name)
                        ?? label.id
                )
            }
        )

        let bibleNotesByBookmarkID = Dictionary(uniqueKeysWithValues: bibleNotes.map { ($0.bookmarkId, $0) })
        let genericNotesByBookmarkID = Dictionary(uniqueKeysWithValues: genericNotes.map { ($0.bookmarkId, $0) })
        let studyPadTextsByEntryID = Dictionary(uniqueKeysWithValues: studyPadTexts.map { ($0.studyPadTextEntryId, $0.text) })

        var labelRowsByKey: [String: RemoteSyncAndroidLabel] = [:]
        var bibleBookmarkRowsByKey: [String: RemoteSyncAndroidBibleBookmark] = [:]
        var bibleNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow] = [:]
        var bibleLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow] = [:]
        var genericBookmarkRowsByKey: [String: RemoteSyncAndroidGenericBookmark] = [:]
        var genericNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow] = [:]
        var genericLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow] = [:]
        var studyPadEntryRowsByKey: [String: RemoteSyncAndroidStudyPadEntry] = [:]
        var studyPadTextRowsByKey: [String: RemoteSyncCurrentStudyPadTextRow] = [:]
        var fingerprintsByKey: [String: String] = [:]
        var suppressedKeys: Set<String> = []

        for label in labels {
            let remoteID = remoteLabelIDsByLocalID[label.id] ?? label.id
            let row = RemoteSyncAndroidLabel(
                id: remoteID,
                name: label.name,
                color: label.color,
                markerStyle: label.markerStyle,
                markerStyleWholeVerse: label.markerStyleWholeVerse,
                underlineStyle: label.underlineStyle,
                underlineStyleWholeVerse: label.underlineStyleWholeVerse,
                hideStyle: label.hideStyle,
                hideStyleWholeVerse: label.hideStyleWholeVerse,
                favourite: label.favourite,
                type: label.type,
                customIcon: label.customIcon
            )
            let key = logEntryStore.key(
                for: .bookmarks,
                tableName: "Label",
                entityID1: .blob(Self.uuidBlob(remoteID)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            labelRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        for bookmark in bibleBookmarks {
            let bookmarkKey = logEntryStore.key(
                for: .bookmarks,
                tableName: "BibleBookmark",
                entityID1: .blob(Self.uuidBlob(bookmark.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            let projectedLabelLinks = bibleLinks.compactMap { link -> RemoteSyncAndroidBookmarkLabelLink? in
                guard link.bookmark?.id == bookmark.id,
                      let localLabelID = link.label?.id else {
                    return nil
                }
                let remoteLabelID = remoteLabelIDsByLocalID[localLabelID] ?? localLabelID
                return RemoteSyncAndroidBookmarkLabelLink(
                    labelID: remoteLabelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
            }.sorted(by: sortLabelLinks)

            if !bookmark.hasTrustedPersistedOrdinals {
                suppressedKeys.insert(bookmarkKey)
                if bibleNotesByBookmarkID[bookmark.id] != nil {
                    suppressedKeys.insert(
                        logEntryStore.key(
                            for: .bookmarks,
                            tableName: "BibleBookmarkNotes",
                            entityID1: .blob(Self.uuidBlob(bookmark.id)),
                            entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
                        )
                    )
                }
                for link in projectedLabelLinks {
                    suppressedKeys.insert(
                        logEntryStore.key(
                            for: .bookmarks,
                            tableName: "BibleBookmarkToLabel",
                            entityID1: .blob(Self.uuidBlob(bookmark.id)),
                            entityID2: .blob(Self.uuidBlob(link.labelID))
                        )
                    )
                }
                guard includeUnverifiedBibleBookmarks else {
                    continue
                }
            }

            let playbackJSON = Self.synthesizedPlaybackSettingsJSON(from: bookmark.playbackSettings)
                ?? playbackSettingsStore.playbackSettingsJSON(for: bookmark.id, kind: .bible)
            let primaryLabelID = bookmark.primaryLabelId.map { remoteLabelIDsByLocalID[$0] ?? $0 }

            let row = RemoteSyncAndroidBibleBookmark(
                id: bookmark.id,
                kjvOrdinalStart: bookmark.kjvOrdinalStart,
                kjvOrdinalEnd: bookmark.kjvOrdinalEnd,
                ordinalStart: bookmark.ordinalStart,
                ordinalEnd: bookmark.ordinalEnd,
                v11n: bookmark.v11n,
                playbackSettingsJSON: playbackJSON,
                createdAt: bookmark.createdAt,
                book: androidBookStore.androidBookValue(
                    for: bookmark.id,
                    localBook: Self.androidBookColumnValue(for: bookmark)
                ),
                startOffset: bookmark.startOffset,
                endOffset: bookmark.endOffset,
                primaryLabelID: primaryLabelID,
                notes: bibleNotesByBookmarkID[bookmark.id]?.notes,
                notesContentType: bibleNotesByBookmarkID[bookmark.id]?.contentType,
                lastUpdatedOn: bookmark.lastUpdatedOn,
                wholeVerse: bookmark.wholeVerse,
                type: bookmark.type,
                customIcon: bookmark.customIcon,
                sourcePromptId: bookmark.sourcePromptId,
                notesSourcePromptId: bibleNotesByBookmarkID[bookmark.id]?.sourcePromptId,
                editAction: bookmark.editAction,
                labelLinks: projectedLabelLinks,
                ordinalTrustMetadata: bookmark.ordinalTrustMetadata
            )
            bibleBookmarkRowsByKey[bookmarkKey] = row
            fingerprintsByKey[bookmarkKey] = Self.fingerprintHex(for: row)

            if let notes = row.notes {
                let noteRow = RemoteSyncCurrentBookmarkNoteRow(
                    bookmarkID: row.id,
                    notes: notes,
                    contentType: row.notesContentType,
                    sourcePromptId: row.notesSourcePromptId
                )
                let noteKey = logEntryStore.key(
                    for: .bookmarks,
                    tableName: "BibleBookmarkNotes",
                    entityID1: .blob(Self.uuidBlob(row.id)),
                    entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
                )
                bibleNoteRowsByKey[noteKey] = noteRow
                fingerprintsByKey[noteKey] = Self.fingerprintHex(for: noteRow)
            }

            for link in row.labelLinks {
                let linkRow = RemoteSyncCurrentBookmarkLabelLinkRow(
                    bookmarkID: row.id,
                    labelID: link.labelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
                let linkKey = logEntryStore.key(
                    for: .bookmarks,
                    tableName: "BibleBookmarkToLabel",
                    entityID1: .blob(Self.uuidBlob(row.id)),
                    entityID2: .blob(Self.uuidBlob(link.labelID))
                )
                bibleLinkRowsByKey[linkKey] = linkRow
                fingerprintsByKey[linkKey] = Self.fingerprintHex(for: linkRow)
            }
        }

        for bookmark in genericBookmarks {
            let playbackJSON = Self.synthesizedPlaybackSettingsJSON(from: bookmark.playbackSettings)
                ?? playbackSettingsStore.playbackSettingsJSON(for: bookmark.id, kind: .generic)
            let primaryLabelID = bookmark.primaryLabelId.map { remoteLabelIDsByLocalID[$0] ?? $0 }
            let labelLinks = genericLinks.compactMap { link -> RemoteSyncAndroidBookmarkLabelLink? in
                guard link.bookmark?.id == bookmark.id,
                      let localLabelID = link.label?.id else {
                    return nil
                }
                let remoteLabelID = remoteLabelIDsByLocalID[localLabelID] ?? localLabelID
                return RemoteSyncAndroidBookmarkLabelLink(
                    labelID: remoteLabelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
            }.sorted(by: sortLabelLinks)

            let row = RemoteSyncAndroidGenericBookmark(
                id: bookmark.id,
                key: bookmark.key,
                createdAt: bookmark.createdAt,
                bookInitials: bookmark.bookInitials,
                ordinalStart: bookmark.ordinalStart,
                ordinalEnd: bookmark.ordinalEnd,
                startOffset: bookmark.startOffset,
                endOffset: bookmark.endOffset,
                primaryLabelID: primaryLabelID,
                notes: genericNotesByBookmarkID[bookmark.id]?.notes,
                notesContentType: genericNotesByBookmarkID[bookmark.id]?.contentType,
                lastUpdatedOn: bookmark.lastUpdatedOn,
                wholeVerse: bookmark.wholeVerse,
                playbackSettingsJSON: playbackJSON,
                customIcon: bookmark.customIcon,
                sourcePromptId: bookmark.sourcePromptId,
                notesSourcePromptId: genericNotesByBookmarkID[bookmark.id]?.sourcePromptId,
                editAction: bookmark.editAction,
                labelLinks: labelLinks
            )
            let key = logEntryStore.key(
                for: .bookmarks,
                tableName: "GenericBookmark",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            genericBookmarkRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)

            if let notes = row.notes {
                let noteRow = RemoteSyncCurrentBookmarkNoteRow(
                    bookmarkID: row.id,
                    notes: notes,
                    contentType: row.notesContentType,
                    sourcePromptId: row.notesSourcePromptId
                )
                let noteKey = logEntryStore.key(
                    for: .bookmarks,
                    tableName: "GenericBookmarkNotes",
                    entityID1: .blob(Self.uuidBlob(row.id)),
                    entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
                )
                genericNoteRowsByKey[noteKey] = noteRow
                fingerprintsByKey[noteKey] = Self.fingerprintHex(for: noteRow)
            }

            for link in row.labelLinks {
                let linkRow = RemoteSyncCurrentBookmarkLabelLinkRow(
                    bookmarkID: row.id,
                    labelID: link.labelID,
                    orderNumber: link.orderNumber,
                    indentLevel: link.indentLevel,
                    expandContent: link.expandContent
                )
                let linkKey = logEntryStore.key(
                    for: .bookmarks,
                    tableName: "GenericBookmarkToLabel",
                    entityID1: .blob(Self.uuidBlob(row.id)),
                    entityID2: .blob(Self.uuidBlob(link.labelID))
                )
                genericLinkRowsByKey[linkKey] = linkRow
                fingerprintsByKey[linkKey] = Self.fingerprintHex(for: linkRow)
            }
        }

        for entry in studyPadEntries {
            guard let localLabelID = entry.label?.id else {
                continue
            }
            let remoteLabelID = remoteLabelIDsByLocalID[localLabelID] ?? localLabelID
            let row = RemoteSyncAndroidStudyPadEntry(
                id: entry.id,
                labelID: remoteLabelID,
                orderNumber: entry.orderNumber,
                indentLevel: entry.indentLevel,
                contentType: entry.contentType,
                sourcePromptId: entry.sourcePromptId,
                text: studyPadTextsByEntryID[entry.id]
            )
            let key = logEntryStore.key(
                for: .bookmarks,
                tableName: "StudyPadTextEntry",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            studyPadEntryRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        for textRow in studyPadTexts {
            let row = RemoteSyncCurrentStudyPadTextRow(entryID: textRow.studyPadTextEntryId, text: textRow.text)
            let key = logEntryStore.key(
                for: .bookmarks,
                tableName: "StudyPadTextEntryText",
                entityID1: .blob(Self.uuidBlob(row.entryID)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            studyPadTextRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        return RemoteSyncBookmarkCurrentSnapshot(
            labelRowsByKey: labelRowsByKey,
            bibleBookmarkRowsByKey: bibleBookmarkRowsByKey,
            bibleNoteRowsByKey: bibleNoteRowsByKey,
            bibleLinkRowsByKey: bibleLinkRowsByKey,
            genericBookmarkRowsByKey: genericBookmarkRowsByKey,
            genericNoteRowsByKey: genericNoteRowsByKey,
            genericLinkRowsByKey: genericLinkRowsByKey,
            studyPadEntryRowsByKey: studyPadEntryRowsByKey,
            studyPadTextRowsByKey: studyPadTextRowsByKey,
            fingerprintsByKey: fingerprintsByKey,
            suppressedKeys: suppressedKeys
        )
    }

    /**
     Fetches one bookmark table under the selected projection error policy.

     - Parameters:
       - descriptor: SwiftData descriptor for one bookmark-category model type.
       - modelContext: Context that owns the requested table.
       - policy: Compatibility suppression or strict propagation behavior.
     - Returns: Fetched rows, or an empty collection after a compatibility-mode fetch failure.
     - Side effects: Reads one SwiftData table.
     - Failure modes: Rethrows SwiftData errors only when `policy` is `strict`.
     */
    private func fetch<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        from modelContext: ModelContext,
        policy: FetchPolicy
    ) throws -> [Model] {
        switch policy {
        case .compatibility:
            return (try? modelContext.fetch(descriptor)) ?? []
        case .strict:
            return try modelContext.fetch(descriptor)
        }
    }

    /**
     Creates the empty bookmark projection used only if compatibility projection unexpectedly throws.

     - Returns: Snapshot with no rows, fingerprints, or suppression keys.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func emptySnapshot() -> RemoteSyncBookmarkCurrentSnapshot {
        RemoteSyncBookmarkCurrentSnapshot(
            labelRowsByKey: [:],
            bibleBookmarkRowsByKey: [:],
            bibleNoteRowsByKey: [:],
            bibleLinkRowsByKey: [:],
            genericBookmarkRowsByKey: [:],
            genericNoteRowsByKey: [:],
            genericLinkRowsByKey: [:],
            studyPadEntryRowsByKey: [:],
            studyPadTextRowsByKey: [:],
            fingerprintsByKey: [:]
        )
    }

    /**
     Compatibility wrapper that replaces bookmark fingerprints from a fail-soft local snapshot.

     Existing non-destructive upload/export callers retain this API shape. Atomic initial restore and
     patch publication must use `refreshBaselineFingerprintsThrowing` so graph fetch failures abort
     rather than publishing an empty baseline.

     - Parameters:
       - modelContext: SwiftData context that owns the current bookmark graph.
       - settingsStore: Local-only settings store used by the fingerprint store.
     - Side effects:
       - rewrites fingerprint rows for current bookmark-category entries
       - removes stale fingerprint rows whose Android keys are no longer present locally
       - preserves baselines for quarantined rows omitted from the export snapshot
     - Failure modes:
       - fetch failures while reading the current bookmark graph are swallowed and treated as an empty snapshot
     */
    public func refreshBaselineFingerprints(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) {
        let snapshot = snapshotCurrentState(modelContext: modelContext, settingsStore: settingsStore)
        do {
            let previousBaseline = try storedAcceptedBaseline(settingsStore: settingsStore)
            let baseline = try acceptedBaselineThrowing(
                from: snapshot,
                preserving: previousBaseline
            )
            try acceptBaseline(baseline, settingsStore: settingsStore)
        } catch {
            return
        }
    }

    /**
     Replaces bookmark fingerprint baselines only after a complete strict graph projection succeeds.

     Initial restore and patch publication use this method inside their shared SwiftData transaction.
     A failed table fetch therefore aborts the caller before any existing fingerprint is removed.

     - Parameters:
       - modelContext: SwiftData context that owns the current bookmark graph.
       - settingsStore: Local-only settings store used by the fingerprint store.
     - Side effects: Replaces current bookmark fingerprint rows after successful projection.
     - Failure modes: Rethrows the strict checkpoint and any SwiftData fetch failure without
       mutating the fingerprint baseline.
     */
    public func refreshBaselineFingerprintsThrowing(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws {
        let snapshot = try snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let previousBaseline = try storedAcceptedBaseline(settingsStore: settingsStore)
        try acceptBaseline(
            acceptedBaselineThrowing(from: snapshot, preserving: previousBaseline),
            settingsStore: settingsStore
        )
    }

    /**
     Converts one complete bookmark projection into its immutable accepted-generation payload.

     - Parameter snapshot: Successfully projected bookmark rows and fingerprints.
     - Returns: Fingerprints, exportable row identities, and quarantine suppression keys for exactly
       the supplied projection.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    func acceptedBaseline(
        from snapshot: RemoteSyncBookmarkCurrentSnapshot
    ) -> RemoteSyncBookmarkAcceptedBaseline {
        RemoteSyncBookmarkAcceptedBaseline(
            fingerprintsByKey: snapshot.fingerprintsByKey,
            rowIdentities: acceptedRowIdentities(from: snapshot, preserving: nil),
            suppressedKeys: snapshot.suppressedKeys
        )
    }

    /**
     Builds a validated accepted bookmark generation while preserving quarantined prior identities.

     - Parameters:
       - snapshot: Complete strict bookmark projection.
       - previousBaseline: Previously accepted generation whose suppressed rows must remain known.
     - Returns: Validated immutable baseline for exactly the projected generation plus preserved
       quarantine state.
     - Side effects: none.
     - Failure modes: Throws `missingProjectedFingerprint` when any exportable row lacks a stable
       fingerprint.
     */
    func acceptedBaselineThrowing(
        from snapshot: RemoteSyncBookmarkCurrentSnapshot,
        preserving previousBaseline: RemoteSyncBookmarkAcceptedBaseline?
    ) throws -> RemoteSyncBookmarkAcceptedBaseline {
        let identities = acceptedRowIdentities(from: snapshot, preserving: previousBaseline)
        for identity in identities where !snapshot.suppressedKeys.contains(identity.key) {
            guard snapshot.fingerprintsByKey[identity.key] != nil else {
                throw RemoteSyncBookmarkAcceptedBaselineError.missingProjectedFingerprint(identity.key)
            }
        }

        var fingerprintsByKey = snapshot.fingerprintsByKey
        for key in snapshot.suppressedKeys {
            if fingerprintsByKey[key] == nil,
               let previousFingerprint = previousBaseline?.fingerprintsByKey[key] {
                fingerprintsByKey[key] = previousFingerprint
            }
        }

        return RemoteSyncBookmarkAcceptedBaseline(
            fingerprintsByKey: fingerprintsByKey,
            rowIdentities: identities,
            suppressedKeys: snapshot.suppressedKeys
        )
    }

    /**
     Collects accepted Android row identities, retaining prior quarantine rows during replacement.

     - Parameters:
       - snapshot: Current bookmark projection.
       - previousBaseline: Prior generation whose suppressed identities may be retained.
     - Returns: Deterministically sorted accepted row identities.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func acceptedRowIdentities(
        from snapshot: RemoteSyncBookmarkCurrentSnapshot,
        preserving previousBaseline: RemoteSyncBookmarkAcceptedBaseline?
    ) -> [RemoteSyncBookmarkAcceptedRowIdentity] {
        var identitiesByKey = Dictionary(
            uniqueKeysWithValues: (previousBaseline?.rowIdentities ?? [])
                .filter { snapshot.suppressedKeys.contains($0.key) }
                .map { ($0.key, $0) }
        )

        /** Appends one exportable Android identity while excluding quarantine-only rows. */
        func append(
            key: String,
            tableName: String,
            entityID1: RemoteSyncSQLiteValue,
            entityID2: RemoteSyncSQLiteValue
        ) {
            guard !snapshot.suppressedKeys.contains(key) else { return }
            identitiesByKey[key] = RemoteSyncBookmarkAcceptedRowIdentity(
                key: key,
                tableName: tableName,
                entityID1: entityID1,
                entityID2: entityID2
            )
        }

        for (key, row) in snapshot.labelRowsByKey {
            append(
                key: key,
                tableName: "Label",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
        }
        for (key, row) in snapshot.bibleBookmarkRowsByKey {
            append(
                key: key,
                tableName: "BibleBookmark",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
        }
        for (key, row) in snapshot.bibleNoteRowsByKey {
            append(
                key: key,
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(Self.uuidBlob(row.bookmarkID)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
        }
        for (key, row) in snapshot.bibleLinkRowsByKey {
            append(
                key: key,
                tableName: "BibleBookmarkToLabel",
                entityID1: .blob(Self.uuidBlob(row.bookmarkID)),
                entityID2: .blob(Self.uuidBlob(row.labelID))
            )
        }
        for (key, row) in snapshot.genericBookmarkRowsByKey {
            append(
                key: key,
                tableName: "GenericBookmark",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
        }
        for (key, row) in snapshot.genericNoteRowsByKey {
            append(
                key: key,
                tableName: "GenericBookmarkNotes",
                entityID1: .blob(Self.uuidBlob(row.bookmarkID)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
        }
        for (key, row) in snapshot.genericLinkRowsByKey {
            append(
                key: key,
                tableName: "GenericBookmarkToLabel",
                entityID1: .blob(Self.uuidBlob(row.bookmarkID)),
                entityID2: .blob(Self.uuidBlob(row.labelID))
            )
        }
        for (key, row) in snapshot.studyPadEntryRowsByKey {
            append(
                key: key,
                tableName: "StudyPadTextEntry",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
        }
        for (key, row) in snapshot.studyPadTextRowsByKey {
            append(
                key: key,
                tableName: "StudyPadTextEntryText",
                entityID1: .blob(Self.uuidBlob(row.entryID)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
        }

        return identitiesByKey.values.sorted { $0.key < $1.key }
    }

    /**
     Reads the durable bookmark accepted-generation manifest when one has been published.

     - Parameter settingsStore: Local settings store containing outbound synchronization metadata.
     - Returns: Stored accepted generation, or `nil` before the first baseline publication.
     - Side effects: Reads one settings row.
     - Failure modes: Throws `invalidStoredBaseline` when persisted JSON is malformed; when called
       inside `performAtomicBatch`, settings fetch failures also invalidate that batch.
     */
    func storedAcceptedBaseline(
        settingsStore: SettingsStore
    ) throws -> RemoteSyncBookmarkAcceptedBaseline? {
        guard let payload = settingsStore.getString(Self.acceptedBaselineKey) else {
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let baseline = try? JSONDecoder().decode(RemoteSyncBookmarkAcceptedBaseline.self, from: data) else {
            throw RemoteSyncBookmarkAcceptedBaselineError.invalidStoredBaseline
        }
        return baseline
    }

    /**
     Verifies that an outbox was projected from the currently accepted bookmark generation.

     - Parameters:
       - expectedRevision: Revision captured during strict preflight, including `nil` for legacy baselines.
       - expectedBaselineExists: Whether strict preflight observed an accepted baseline row.
       - settingsStore: Store containing the current accepted generation.
     - Side effects: Reads one settings row.
     - Failure modes: Throws `invalidStoredBaseline` for malformed state or `staleAcceptedBaseline`
       when another synchronization generation replaced the baseline.
     */
    func validateAcceptedBaselineRevision(
        expectedRevision: UUID?,
        expectedBaselineExists: Bool,
        settingsStore: SettingsStore
    ) throws {
        let currentBaseline = try storedAcceptedBaseline(settingsStore: settingsStore)
        guard (currentBaseline != nil) == expectedBaselineExists,
              currentBaseline?.revision == expectedRevision else {
            throw RemoteSyncBookmarkAcceptedBaselineError.staleAcceptedBaseline
        }
    }

    /**
     Publishes one already-projected bookmark generation without re-reading the live graph.

     - Parameters:
       - baseline: Immutable fingerprints and accepted Android row identities from the generation
         that was restored, replayed, or uploaded.
       - settingsStore: Store receiving fingerprint and identity-manifest mutations.
     - Side effects: Removes stale exportable fingerprints, preserves quarantine baselines, writes
       exact-generation fingerprints, and replaces the accepted-key manifest.
     - Failure modes: Throws when a supplied fingerprint key is outside the bookmark namespace or
       when the accepted manifest cannot be encoded. Settings failures invalidate an enclosing
       `SettingsStore.performAtomicBatch`.
     */
    func acceptBaseline(
        _ baseline: RemoteSyncBookmarkAcceptedBaseline,
        settingsStore: SettingsStore
    ) throws {
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintPrefix = fingerprintStore.prefix(for: .bookmarks)
        let logPrefix = logEntryStore.prefix(for: .bookmarks)

        for entry in settingsStore.entries(withPrefix: fingerprintPrefix) {
            let suffix = String(entry.key.dropFirst(fingerprintPrefix.count))
            let logKey = "\(logPrefix)\(suffix)"
            if !baseline.suppressedKeys.contains(logKey) {
                settingsStore.remove(entry.key)
            }
        }

        for (logKey, fingerprint) in baseline.fingerprintsByKey.sorted(by: { $0.key < $1.key }) {
            guard logKey.hasPrefix(logPrefix) else {
                throw RemoteSyncBookmarkAcceptedBaselineError.invalidFingerprintKey(logKey)
            }
            let suffix = String(logKey.dropFirst(logPrefix.count))
            settingsStore.setString("\(fingerprintPrefix)\(suffix)", value: fingerprint)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(baseline)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw RemoteSyncBookmarkAcceptedBaselineError.invalidStoredBaseline
        }
        settingsStore.setString(Self.acceptedBaselineKey, value: payload)
    }

    /**
     Converts one UUID into Android's raw 16-byte blob representation.

     - Parameter uuid: UUID to serialize.
     - Returns: Raw 16-byte UUID payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public static func uuidBlob(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one `Label` row.

     - Parameter value: Android-shaped current `Label` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncAndroidLabel) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                value.name,
                String(value.color),
                canonicalBool(value.markerStyle),
                canonicalBool(value.markerStyleWholeVerse),
                canonicalBool(value.underlineStyle),
                canonicalBool(value.underlineStyleWholeVerse),
                canonicalBool(value.hideStyle),
                canonicalBool(value.hideStyleWholeVerse),
                canonicalBool(value.favourite),
                value.type ?? "",
                value.customIcon ?? "",
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one `BibleBookmark` row.

     - Parameter value: Android-shaped current `BibleBookmark` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncAndroidBibleBookmark) -> String {
        let createdAtMillis = String(Int64(value.createdAt.timeIntervalSince1970 * 1000.0))
        let lastUpdatedMillis = String(Int64(value.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        let primaryLabelID = value.primaryLabelID?.uuidString.lowercased() ?? ""
        let editMode = value.editAction?.mode?.rawValue ?? ""
        let editContent = value.editAction?.content ?? ""
        let components: [String] = [
            value.id.uuidString.lowercased(),
            String(value.kjvOrdinalStart),
            String(value.kjvOrdinalEnd),
            String(value.ordinalStart),
            String(value.ordinalEnd),
            value.v11n,
            value.playbackSettingsJSON ?? "",
            createdAtMillis,
            value.book ?? "",
            canonicalOptionalInt(value.startOffset),
            canonicalOptionalInt(value.endOffset),
            primaryLabelID,
            lastUpdatedMillis,
            canonicalBool(value.wholeVerse),
            value.type ?? "",
            value.customIcon ?? "",
            value.sourcePromptId?.uuidString.lowercased() ?? "",
            editMode,
            editContent,
        ]
        return fingerprintHex(canonicalValue: components.joined(separator: "|"))
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one bookmark-note row.

     - Parameter value: Android-shaped current bookmark-note row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentBookmarkNoteRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.bookmarkID.uuidString.lowercased(),
                value.notes,
                value.contentType ?? "",
                value.sourcePromptId?.uuidString.lowercased() ?? "",
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one bookmark-to-label row.

     - Parameter value: Android-shaped current bookmark-to-label row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentBookmarkLabelLinkRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.bookmarkID.uuidString.lowercased(),
                value.labelID.uuidString.lowercased(),
                String(value.orderNumber),
                String(value.indentLevel),
                canonicalBool(value.expandContent),
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one `GenericBookmark` row.

     - Parameter value: Android-shaped current `GenericBookmark` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncAndroidGenericBookmark) -> String {
        let createdAtMillis = String(Int64(value.createdAt.timeIntervalSince1970 * 1000.0))
        let lastUpdatedMillis = String(Int64(value.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        let primaryLabelID = value.primaryLabelID?.uuidString.lowercased() ?? ""
        let editMode = value.editAction?.mode?.rawValue ?? ""
        let editContent = value.editAction?.content ?? ""
        let components = [
            value.id.uuidString.lowercased(),
            value.key,
            createdAtMillis,
            value.bookInitials,
            canonicalOptionalInt(value.ordinalStart),
            canonicalOptionalInt(value.ordinalEnd),
            canonicalOptionalInt(value.startOffset),
            canonicalOptionalInt(value.endOffset),
            primaryLabelID,
            lastUpdatedMillis,
            canonicalBool(value.wholeVerse),
            value.playbackSettingsJSON ?? "",
            value.customIcon ?? "",
            value.sourcePromptId?.uuidString.lowercased() ?? "",
            editMode,
            editContent,
        ]
        return fingerprintHex(canonicalValue: components.joined(separator: "|"))
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one `StudyPadTextEntry` row.

     - Parameter value: Android-shaped current `StudyPadTextEntry` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncAndroidStudyPadEntry) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                value.labelID.uuidString.lowercased(),
                String(value.orderNumber),
                String(value.indentLevel),
                value.contentType ?? "",
                value.sourcePromptId?.uuidString.lowercased() ?? "",
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one `StudyPadTextEntryText` row.

     - Parameter value: Android-shaped current `StudyPadTextEntryText` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentStudyPadTextRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.entryID.uuidString.lowercased(),
                value.text,
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one canonical row string.

     - Parameter canonicalValue: Canonical text representation of one Android row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the supplied string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func fingerprintHex(canonicalValue: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /**
     Encodes complete Android playback settings from the live native bookmark model.

     - Parameter playbackSettings: Current iOS bookmark playback settings.
     - Returns: Complete Android JSON, or `nil` when the bookmark has no playback metadata.
     - Side effects: none.
     - Failure modes:
       - encoding failures return `nil`
     */
    private static func synthesizedPlaybackSettingsJSON(from playbackSettings: PlaybackSettings?) -> String? {
        try? playbackSettings?.androidJSON()
    }

    /**
     Projects the local Bible bookmark source module into Android's `BibleBookmark.book` value.

     The SwiftData `book` field is display-facing on iOS. Android's column stores source module
     initials or NULL, so outbound snapshots must use the durable source-module field added for
     #356 instead of leaking display names such as `Genesis`.

     - Parameter bookmark: Local Bible bookmark being exported.
     - Returns: Module initials for Android, or `nil` when no source module is known.
     - Side effects: none.
     - Failure modes: Empty or whitespace-only initials export as NULL.
     */
    private static func androidBookColumnValue(for bookmark: BibleBookmark) -> String? {
        let initials = bookmark.bookInitials.trimmingCharacters(in: .whitespacesAndNewlines)
        return initials.isEmpty ? nil : initials
    }

    /**
     Sorts labels deterministically for stable snapshot projection.

     - Parameters:
       - lhs: First local label to compare.
       - rhs: Second local label to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortLabels(_ lhs: Label, _ rhs: Label) -> Bool {
        if lhs.name == rhs.name {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.name < rhs.name
    }

    /**
     Sorts Bible bookmarks deterministically for stable snapshot projection.

     - Parameters:
       - lhs: First local Bible bookmark to compare.
       - rhs: Second local Bible bookmark to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortBibleBookmarks(_ lhs: BibleBookmark, _ rhs: BibleBookmark) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    /**
     Sorts generic bookmarks deterministically for stable snapshot projection.

     - Parameters:
       - lhs: First local generic bookmark to compare.
       - rhs: Second local generic bookmark to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortGenericBookmarks(_ lhs: GenericBookmark, _ rhs: GenericBookmark) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    /**
     Sorts StudyPad entries deterministically for stable snapshot projection.

     - Parameters:
       - lhs: First local StudyPad entry to compare.
       - rhs: Second local StudyPad entry to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortStudyPadEntries(_ lhs: StudyPadTextEntry, _ rhs: StudyPadTextEntry) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Sorts bookmark-to-label links deterministically for stable snapshot projection.

     - Parameters:
       - lhs: First Android bookmark-to-label link to compare.
       - rhs: Second Android bookmark-to-label link to compare.
     - Returns: `true` when `lhs` should sort before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func sortLabelLinks(_ lhs: RemoteSyncAndroidBookmarkLabelLink, _ rhs: RemoteSyncAndroidBookmarkLabelLink) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.labelID.uuidString < rhs.labelID.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Returns the canonical text form for one optional integer field.

     - Parameter value: Optional integer value.
     - Returns: Decimal text when present; otherwise an empty string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func canonicalOptionalInt(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    /**
     Returns the canonical text form for one Boolean field.

     - Parameter value: Boolean value to encode.
     - Returns: `1` for `true` and `0` for `false`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func canonicalBool(_ value: Bool) -> String {
        value ? "1" : "0"
    }
}
