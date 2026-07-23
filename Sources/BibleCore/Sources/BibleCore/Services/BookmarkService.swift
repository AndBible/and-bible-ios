// BookmarkService.swift — Bookmark business logic

import Foundation
import Observation
import SwordKit

/**
 Result of applying Android-style initial labels to a bookmark.

 The result lets reader-side callers persist workspace cursor movement without coupling the UI layer
 to bookmark-to-label insertion or StudyPad order maintenance.
 */
public struct BookmarkInitialLabelAssignmentResult {
    /// Label identifiers that existed locally and were applied to the bookmark.
    public let appliedLabelIds: [UUID]
    /// Updated workspace settings when StudyPad cursors advanced, otherwise the unchanged input.
    public let updatedWorkspaceSettings: WorkspaceSettings?
    /// Whether the caller should persist the owning workspace after cursor changes.
    public let changedWorkspaceSettings: Bool

    /**
     Creates an initial-label assignment result.

     - Parameters:
       - appliedLabelIds: Valid label identifiers applied to the bookmark.
       - updatedWorkspaceSettings: Workspace settings after cursor changes, if settings were supplied.
       - changedWorkspaceSettings: Whether cursor updates changed the workspace settings.
     */
    public init(
        appliedLabelIds: [UUID],
        updatedWorkspaceSettings: WorkspaceSettings?,
        changedWorkspaceSettings: Bool
    ) {
        self.appliedLabelIds = appliedLabelIds
        self.updatedWorkspaceSettings = updatedWorkspaceSettings
        self.changedWorkspaceSettings = changedWorkspaceSettings
    }
}

/**
 Immutable preview of bookmarks that would become unlabeled after deleting one label.

 Android presents this count before it asks whether to delete only the label or both the label and
 its orphaned bookmarks. Keeping stable identifiers instead of model objects lets the same contract
 serve app UI, AI tools, and persistence tests without leaking SwiftData graph ownership.
 */
public struct BookmarkLabelDeletionImpact: Sendable, Equatable {
    /// Bible bookmarks whose only live label is the deletion target.
    public let bibleBookmarkIDs: [UUID]

    /// Generic bookmarks whose only live label is the deletion target.
    public let genericBookmarkIDs: [UUID]

    /// Combined Android confirmation count.
    public var orphanedBookmarkCount: Int {
        bibleBookmarkIDs.count + genericBookmarkIDs.count
    }

    /** Creates a deterministic deletion preview. */
    public init(bibleBookmarkIDs: [UUID], genericBookmarkIDs: [UUID]) {
        self.bibleBookmarkIDs = bibleBookmarkIDs
        self.genericBookmarkIDs = genericBookmarkIDs
    }
}

// MARK: - Speak Bookmark Lifecycle

extension BookmarkService: SpeakBookmarkManaging {
    /**
     Activates Android's Speak bookmark at a provider's start position.

     Android retains the matched bookmark even when restore-from-bookmark is disabled because pause,
     stop, and settings updates still relocate or update that exact row. Bible matching uses the
     verified KJVA start ordinal; generic matching uses module, key, and source start ordinal.

     - Parameter position: Exact provider position at which playback will start.
     - Returns: Persisted playback settings, or `nil` when no Speak-labeled bookmark starts there.
     - Side effects: Replaces the in-memory active Speak-bookmark identity for this service.
     - Failure modes: Unverified Bible positions and incomplete generic identities fail closed.
     */
    public func playbackSettingsForSpeakBookmark(at position: SpeakStreamPosition) -> PlaybackSettings? {
        activeSpeakBibleBookmarkID = nil
        activeSpeakGenericBookmarkID = nil

        switch position.category {
        case .bible:
            guard let range = position.verifiedBibleRange else { return nil }
            let bookmark = store.bibleBookmarks(withLabel: Label.speakLabelId).first {
                $0.kjvOrdinalStart == range.kjvaOrdinalStart
            }
            activeSpeakBibleBookmarkID = bookmark?.id
            return bookmark?.playbackSettings

        case .commentary, .dictionary, .generalBook, .myDocument:
            guard let ordinalStart = position.ordinalStart else { return nil }
            let bookmark = store.genericBookmarks(withLabel: Label.speakLabelId).first {
                $0.bookInitials == position.bookInitials &&
                    $0.key == position.key &&
                    $0.ordinalStart == ordinalStart
            }
            activeSpeakGenericBookmarkID = bookmark?.id
            return bookmark?.playbackSettings

        case .memorization, .selection:
            return nil
        }
    }

    /**
     Updates the active Speak bookmark with changed structured playback settings.

     Android preserves `bookId` and `bookmarkWasCreated` from the owning bookmark while applying
     all user-editable settings. That prevents a settings panel from corrupting resume identity or
     changing whether the row may be deleted as an auto-created bookmark.

     When speech is stopped, Android targets only the Speak bookmark at the visible Bible verse.
     The supplied position therefore also acts as an exact lookup when no Bible session bookmark is
     active; stale generic-session identity is never reused for that branch.

     - Parameters:
       - position: Active provider position, or the visible Bible position while stopped.
       - settings: Complete replacement playback settings from the active Speak session.
     - Side effects: Mutates and saves the category-matching Bible or generic bookmark when one
       exists.
     - Failure modes: Stale identifiers, missing Speak labels, and positions without verified Bible
       coordinates are ignored.
     */
    public func updateSpeakBookmarkPlaybackSettings(
        at position: SpeakStreamPosition,
        settings: PlaybackSettings
    ) {
        switch position.category {
        case .bible:
            if activeSpeakBibleBookmarkID == nil,
               let range = position.verifiedBibleRange {
                let candidateOrdinal: Int
                if let reference = JSwordKJVAVersification.referenceIncludingIntroductions(
                    ordinal: range.kjvaOrdinalStart
                ), reference.chapter > 0, reference.verse == 0,
                   let firstVerseOrdinal = JSwordKJVAVersification.verseOrdinal(
                       osisId: reference.osisId,
                       chapter: reference.chapter,
                       verse: 1
                   ) {
                    candidateOrdinal = firstVerseOrdinal
                } else {
                    candidateOrdinal = range.kjvaOrdinalStart
                }
                activeSpeakBibleBookmarkID = store
                    .bibleBookmarks(withLabel: Label.speakLabelId)
                    .first {
                        $0.kjvOrdinalStart == candidateOrdinal && $0.playbackSettings != nil
                    }?
                    .id
            }
            guard let id = activeSpeakBibleBookmarkID else { return }
            guard let bookmark = store.bibleBookmark(id: id) else {
                activeSpeakBibleBookmarkID = nil
                return
            }
            bookmark.playbackSettings = mergedSpeakPlaybackSettings(
                settings,
                preservingIdentityFrom: bookmark.playbackSettings
            )
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
        case .commentary, .dictionary, .generalBook, .myDocument:
            guard let id = activeSpeakGenericBookmarkID else { return }
            guard let bookmark = store.genericBookmark(id: id) else {
                activeSpeakGenericBookmarkID = nil
                return
            }
            bookmark.playbackSettings = mergedSpeakPlaybackSettings(
                settings,
                preservingIdentityFrom: bookmark.playbackSettings
            )
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
        case .memorization, .selection:
            return
        }
    }

    /**
     Relocates Android's Speak bookmark to the provider's current stream unit.

     A user bookmark carrying other labels, or explicitly marked as user-created, loses only its
     Speak label and playback metadata. A Speak-only auto-created row is deleted. A new row is then
     written when auto-bookmarking is enabled or an existing Speak bookmark was removed, preserving
     Android's quit-and-resume behavior even when auto-bookmarking is subsequently disabled.

     - Parameters:
       - position: Current provider position at pause or stop.
       - settings: Complete playback settings to persist with the relocated bookmark.
       - autoBookmark: Android's global `speak_autoBookmark` setting.
     - Side effects: May remove a Speak label, delete an old bookmark, insert a new bookmark, attach
       the canonical Speak label, and save SwiftData.
     - Failure modes: Memorization, selections, unverified Bible positions, and generic positions
       without an ordinal are intentionally not persisted.
     */
    public func persistSpeakBookmark(
        at position: SpeakStreamPosition,
        settings: PlaybackSettings,
        autoBookmark: Bool
    ) {
        guard position.category != .memorization, position.category != .selection else { return }
        let wasRemoved = removeActiveSpeakBookmark()
        guard autoBookmark || wasRemoved else { return }

        var playback = settings.normalized
        playback.bookId = position.bookInitials
        playback.bookmarkWasCreated = true
        playback.isMemorizationLoop = false

        switch position.category {
        case .bible:
            guard let range = position.verifiedBibleRange else { return }
            let bookmark = addBibleBookmark(ordinalRange: range)
            bookmark.book = position.bookName
            bookmark.playbackSettings = playback
            bookmark.lastUpdatedOn = Date()
            attachSpeakLabel(to: bookmark)
            activeSpeakBibleBookmarkID = bookmark.id

        case .commentary, .dictionary, .generalBook, .myDocument:
            guard let ordinalStart = position.ordinalStart else { return }
            let bookmark = addGenericBookmark(
                bookInitials: position.bookInitials,
                key: position.key,
                startOrdinal: ordinalStart,
                endOrdinal: position.ordinalEnd ?? ordinalStart
            )
            bookmark.playbackSettings = playback
            bookmark.lastUpdatedOn = Date()
            attachSpeakLabel(to: bookmark)
            activeSpeakGenericBookmarkID = bookmark.id

        case .memorization, .selection:
            return
        }
        store.saveChanges()
    }

    /**
     Returns all Android Speak-label bookmarks for the resume picker.

     Bible rows are ordered by KJVA verse position before generic rows, matching Android's widget.
     Generic rows retain exact module/key/ordinal identity and are reclassified by the reader when
     the provider is reconstructed.

     - Returns: Verified Bible rows followed by generic rows, each carrying structured settings.
     - Side effects: Ensures canonical system-label identities before querying.
     - Failure modes: Bible rows whose persisted ordinal provenance cannot be revalidated are
       omitted; generic rows without a source ordinal are not resumable and are omitted.
     */
    public func speakResumeBookmarks() -> [SpeakResumeBookmark] {
        ensureSystemLabels()

        let bible = store.bibleBookmarks(withLabel: Label.speakLabelId)
            .sorted { $0.kjvOrdinalStart < $1.kjvOrdinalStart }
            .compactMap(makeBibleSpeakResumeBookmark)
        let generic = store.genericBookmarks(withLabel: Label.speakLabelId)
            .compactMap(makeGenericSpeakResumeBookmark)
        return bible + generic
    }

    /** Combines editable settings with identity fields owned by the persisted bookmark. */
    private func mergedSpeakPlaybackSettings(
        _ settings: PlaybackSettings,
        preservingIdentityFrom existing: PlaybackSettings?
    ) -> PlaybackSettings {
        var merged = settings.normalized
        if let existing {
            merged.bookId = existing.bookId
            merged.bookmarkWasCreated = existing.bookmarkWasCreated
        }
        merged.isMemorizationLoop = false
        return merged
    }

    /** Removes the active Speak bookmark using Android's auto-created ownership rules. */
    private func removeActiveSpeakBookmark() -> Bool {
        defer {
            activeSpeakBibleBookmarkID = nil
            activeSpeakGenericBookmarkID = nil
        }

        if let id = activeSpeakBibleBookmarkID,
           let bookmark = store.bibleBookmark(id: id) {
            let speakLinks = (bookmark.bookmarkToLabels ?? []).filter {
                $0.label?.id == Label.speakLabelId
            }
            guard !speakLinks.isEmpty else { return false }
            let hasOtherLabel = (bookmark.bookmarkToLabels ?? []).contains {
                guard let labelID = $0.label?.id else { return false }
                return labelID != Label.speakLabelId
            }
            if hasOtherLabel || bookmark.playbackSettings?.bookmarkWasCreated == false {
                speakLinks.forEach(store.delete)
                bookmark.playbackSettings = nil
                if bookmark.primaryLabelId == Label.speakLabelId {
                    bookmark.primaryLabelId = bookmark.bookmarkToLabels?.first {
                        $0.label?.id != Label.speakLabelId
                    }?.label?.id
                }
                bookmark.lastUpdatedOn = Date()
                store.saveChanges()
            } else {
                store.delete(bookmark)
            }
            return true
        }

        if let id = activeSpeakGenericBookmarkID,
           let bookmark = store.genericBookmark(id: id) {
            let speakLinks = (bookmark.bookmarkToLabels ?? []).filter {
                $0.label?.id == Label.speakLabelId
            }
            guard !speakLinks.isEmpty else { return false }
            let hasOtherLabel = (bookmark.bookmarkToLabels ?? []).contains {
                guard let labelID = $0.label?.id else { return false }
                return labelID != Label.speakLabelId
            }
            if hasOtherLabel || bookmark.playbackSettings?.bookmarkWasCreated == false {
                speakLinks.forEach(store.delete)
                bookmark.playbackSettings = nil
                if bookmark.primaryLabelId == Label.speakLabelId {
                    bookmark.primaryLabelId = bookmark.bookmarkToLabels?.first {
                        $0.label?.id != Label.speakLabelId
                    }?.label?.id
                }
                bookmark.lastUpdatedOn = Date()
                store.saveChanges()
            } else {
                store.delete(bookmark)
            }
            return true
        }

        return false
    }

    /** Attaches only Android's canonical Speak label to a Bible bookmark. */
    private func attachSpeakLabel(to bookmark: BibleBookmark) {
        ensureSystemLabels()
        guard let label = store.label(id: Label.speakLabelId) else { return }
        bookmark.primaryLabelId = label.id
        let link = BibleBookmarkToLabel()
        link.bookmark = bookmark
        link.label = label
        store.insert(link)
    }

    /** Attaches only Android's canonical Speak label to a generic bookmark. */
    private func attachSpeakLabel(to bookmark: GenericBookmark) {
        ensureSystemLabels()
        guard let label = store.label(id: Label.speakLabelId) else { return }
        bookmark.primaryLabelId = label.id
        let link = GenericBookmarkToLabel()
        link.bookmark = bookmark
        link.label = label
        store.insert(link)
    }

    /** Projects one trusted Bible bookmark into provider-neutral resume metadata. */
    private func makeBibleSpeakResumeBookmark(_ bookmark: BibleBookmark) -> SpeakResumeBookmark? {
        guard let range = VerifiedKJVAOrdinalRange(
            revalidatingKJVAOrdinalStart: bookmark.kjvOrdinalStart,
            kjvaOrdinalEnd: bookmark.kjvOrdinalEnd,
            ordinalTrust: bookmark.ordinalTrustMetadata
        ),
        let reference = JSwordKJVAVersification.verseReference(ordinal: bookmark.kjvOrdinalStart) else {
            return nil
        }
        let playback = bookmark.playbackSettings ?? PlaybackSettings()
        let bookName = JSwordKJVAVersification.longBookName(osisId: reference.osisId) ?? reference.osisId
        let sourceVersification = bookmark.ordinalSourceVersification?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let position = SpeakStreamPosition(
            id: "speak-bible-\(bookmark.id.uuidString)",
            category: .bible,
            bookInitials: playback.bookId ?? bookmark.bookInitials,
            key: reference.osisRef,
            keyName: reference.osisRef,
            bookName: bookName,
            ordinalStart: bookmark.ordinalStart,
            ordinalEnd: bookmark.ordinalEnd,
            chapter: reference.chapter,
            verse: reference.verse,
            groupIdentifier: "\(reference.osisId).\(reference.chapter)",
            language: "en",
            versification: sourceVersification?.isEmpty == false
                ? sourceVersification
                : bookmark.v11n,
            verifiedBibleRange: range
        )
        return SpeakResumeBookmark(id: bookmark.id, position: position, playbackSettings: playback)
    }

    /** Projects one generic bookmark into exact module/key/ordinal resume metadata. */
    private func makeGenericSpeakResumeBookmark(_ bookmark: GenericBookmark) -> SpeakResumeBookmark? {
        guard let ordinalStart = bookmark.ordinalStart else { return nil }
        let playback = bookmark.playbackSettings ?? PlaybackSettings()
        let position = SpeakStreamPosition(
            id: "speak-generic-\(bookmark.id.uuidString)",
            category: .generalBook,
            bookInitials: playback.bookId ?? bookmark.bookInitials,
            key: bookmark.key,
            keyName: bookmark.key,
            bookName: bookmark.bookInitials,
            ordinalStart: ordinalStart,
            ordinalEnd: bookmark.ordinalEnd ?? ordinalStart,
            groupIdentifier: bookmark.key,
            language: "en"
        )
        return SpeakResumeBookmark(id: bookmark.id, position: position, playbackSettings: playback)
    }
}

/**
 Business logic for bookmark operations, coordinating between
 BookmarkStore and the bridge layer.
 */
@Observable
public final class BookmarkService {
    private let store: BookmarkStore

    /// Speak bookmark activated when a Bible provider starts, retained until pause/stop relocation.
    private var activeSpeakBibleBookmarkID: UUID?

    /// Speak bookmark activated when a generic provider starts, retained until pause/stop relocation.
    private var activeSpeakGenericBookmarkID: UUID?

    /**
     Normalizes nullable note content-type inputs to Android's accepted `TextContentType` values.

     - Parameter contentType: Optional raw value from settings, bridge calls, or restored rows.
     - Returns: `HTML` or `MARKDOWN`, falling back to Android's default `HTML`.
     - Side effects: none.
     - Failure modes: none; invalid values are intentionally coerced by the app preference normalizer.
     */
    private static func normalizedNotesContentType(_ contentType: String?) -> String {
        AppPreferenceValueNormalizer.notesContentType(contentType ?? "HTML")
    }

    /**
     Checks whether a bridge note payload should be persisted instead of deleting the note row.

     Android's JavaScript bridge converts `null` and trim-empty strings to a deleted bookmark note,
     but it preserves the original text for nonblank payloads. Matching that contract keeps iOS from
     retaining invisible notes that Android would remove while avoiding unintended whitespace edits
     for user-authored content.

     - Parameter note: Optional note payload from reader JavaScript, tests, or service callers.
     - Returns: `true` when the payload has at least one non-whitespace/newline character.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func shouldPersistNote(_ note: String?) -> Bool {
        guard let note else {
            return false
        }
        return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /**
     Creates a bookmark service backed by the given persistence store.
     - Parameter store: Store responsible for all bookmark, label, and StudyPad persistence.
     */
    public init(store: BookmarkStore) {
        self.store = store
    }

    // MARK: - Bible Bookmarks

    /**
     Creates a new Bible bookmark from an explicitly verified source-to-KJVA mapping.

     - Parameters:
       - ordinalRange: Typed boundary containing exact source coordinates and their validated KJVA
         projection.
       - wholeVerse: Whether the bookmark covers whole verses instead of a text range.
       - startOffset: Optional text-range start offset.
       - endOffset: Optional text-range end offset.
       - addNote: Legacy bridge flag retained for call-site compatibility; note rows are created
         by the caller when note text is saved.
     - Returns: Inserted Bible bookmark.
     - Side effects: Inserts the bookmark.
     - Failure modes: An unverified range cannot be passed to this API; SwiftData save failures are
       handled by `BookmarkStore` and do not throw.
     */
    @discardableResult
    public func addBibleBookmark(
        ordinalRange: VerifiedKJVAOrdinalRange,
        wholeVerse: Bool = true,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        addNote: Bool = false
    ) -> BibleBookmark {
        let bookmark = BibleBookmark(
            kjvOrdinalStart: ordinalRange.kjvaOrdinalStart,
            kjvOrdinalEnd: ordinalRange.kjvaOrdinalEnd,
            ordinalStart: ordinalRange.sourceOrdinalStart,
            ordinalEnd: ordinalRange.sourceOrdinalEnd,
            v11n: ordinalRange.sourceVersification,
            bookInitials: ordinalRange.sourceBookInitials,
            wholeVerse: wholeVerse,
            ordinalTrustMetadata: ordinalRange.ordinalTrust
        )
        bookmark.startOffset = startOffset
        bookmark.endOffset = endOffset
        store.insert(bookmark)
        return bookmark
    }

    /**
     Updates one explicitly identified Bible bookmark from a verified source-to-KJVA mapping.

     - Parameters:
       - id: Stable bookmark identity selected by an edit workflow.
       - ordinalRange: Exact source coordinates and validated KJVA projection.
       - wholeVerse: Whether the bookmark covers whole verses.
       - startOffset: Optional UTF-16 selection start offset.
       - endOffset: Optional UTF-16 selection end offset.
     - Returns: The updated bookmark, or `nil` when `id` is stale or quarantined.
     - Side effects: Mutates only the identified bookmark and saves the context.
     - Failure modes: Unverified ranges cannot reach this API; save failures are handled by
       `BookmarkStore` and do not throw.
     */
    @discardableResult
    public func updateBibleBookmark(
        id: UUID,
        ordinalRange: VerifiedKJVAOrdinalRange,
        wholeVerse: Bool,
        startOffset: Int?,
        endOffset: Int?
    ) -> BibleBookmark? {
        guard let bookmark = store.bibleBookmark(id: id) else { return nil }
        bookmark.kjvOrdinalStart = ordinalRange.kjvaOrdinalStart
        bookmark.kjvOrdinalEnd = ordinalRange.kjvaOrdinalEnd
        bookmark.ordinalStart = ordinalRange.sourceOrdinalStart
        bookmark.ordinalEnd = ordinalRange.sourceOrdinalEnd
        bookmark.v11n = ordinalRange.sourceVersification
        bookmark.bookInitials = ordinalRange.sourceBookInitials
        bookmark.ordinalTrustMetadata = ordinalRange.ordinalTrust
        bookmark.wholeVerse = wholeVerse
        bookmark.startOffset = startOffset
        bookmark.endOffset = endOffset
        bookmark.lastUpdatedOn = Date()
        store.saveChanges()
        return bookmark
    }

    /**
     Rejects the legacy raw-number native bookmark write boundary at compile time.

     The declaration remains solely to provide a migration diagnostic to callers. Numeric source
     and KJVA values cannot prove that both domains refer to the same verses.

     - Parameters:
       - bookInitials: Unverified source module initials.
       - startOrdinal: Unverified source start ordinal.
       - endOrdinal: Unverified source end ordinal.
       - kjvOrdinalStart: Unverified candidate KJVA start ordinal.
       - kjvOrdinalEnd: Unverified candidate KJVA end ordinal.
       - v11n: Unverified source versification.
       - wholeVerse: Requested whole-verse flag.
       - startOffset: Requested text-range start offset.
       - endOffset: Requested text-range end offset.
       - addNote: Legacy note-editor flag.
     - Returns: No value; the overload is unavailable.
     - Side effects: none.
     - Failure modes: Compilation fails and directs callers to the typed overload.
     */
    @available(*, unavailable, message: "Use addBibleBookmark(ordinalRange:) with VerifiedKJVAOrdinalRange.")
    @discardableResult
    public func addBibleBookmark(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int,
        kjvOrdinalStart: Int,
        kjvOrdinalEnd: Int,
        v11n: String = "KJVA",
        wholeVerse: Bool = true,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        addNote: Bool = false
    ) -> BibleBookmark {
        fatalError("Unavailable raw-number bookmark write boundary")
    }

    /**
     Creates a paragraph-break bookmark from an explicitly verified source-to-KJVA mapping.

     - Parameters:
       - ordinalRange: Typed boundary containing exact source coordinates and their validated KJVA
         projection.
       - book: Optional display book fallback for legacy list paths.
     - Returns: Inserted paragraph-break bookmark.
     - Side effects: Ensures the paragraph-break system label exists, inserts the bookmark, and
       attaches that system label.
     - Failure modes: SwiftData save failures are handled by `BookmarkStore` and do not throw.
     */
    @discardableResult
    public func addParagraphBreakBibleBookmark(
        ordinalRange: VerifiedKJVAOrdinalRange,
        book: String? = nil
    ) -> BibleBookmark {
        ensureSystemLabels()
        let bookmark = BibleBookmark(
            kjvOrdinalStart: ordinalRange.kjvaOrdinalStart,
            kjvOrdinalEnd: ordinalRange.kjvaOrdinalEnd,
            ordinalStart: ordinalRange.sourceOrdinalStart,
            ordinalEnd: ordinalRange.sourceOrdinalEnd,
            v11n: ordinalRange.sourceVersification,
            bookInitials: ordinalRange.sourceBookInitials,
            wholeVerse: false,
            ordinalTrustMetadata: ordinalRange.ordinalTrust
        )
        bookmark.book = book
        store.insert(bookmark)
        attachParagraphBreakLabel(to: bookmark)
        return bookmark
    }

    /**
     Rejects the legacy raw-number paragraph-break write boundary at compile time.

     - Parameters:
       - bookInitials: Unverified source module initials.
       - startOrdinal: Unverified source start ordinal.
       - endOrdinal: Unverified source end ordinal.
       - kjvOrdinalStart: Unverified candidate KJVA start ordinal.
       - kjvOrdinalEnd: Unverified candidate KJVA end ordinal.
       - v11n: Unverified source versification.
       - book: Optional display book value.
     - Returns: No value; the overload is unavailable.
     - Side effects: none.
     - Failure modes: Compilation fails and directs callers to the typed overload.
     */
    @available(*, unavailable, message: "Use addParagraphBreakBibleBookmark(ordinalRange:) with VerifiedKJVAOrdinalRange.")
    @discardableResult
    public func addParagraphBreakBibleBookmark(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int,
        kjvOrdinalStart: Int,
        kjvOrdinalEnd: Int,
        v11n: String = "KJVA",
        book: String? = nil
    ) -> BibleBookmark {
        fatalError("Unavailable raw-number paragraph-break bookmark write boundary")
    }

    /**
     Saves, updates, or removes a bookmark note for Bible and generic bookmarks.

     - Parameters:
       - bookmarkId: Identifier of the Bible or generic bookmark whose note should change.
       - note: New note body. `nil` or whitespace-only text deletes the detached note row.
       - defaultContentType: Current global notes-content-type setting used only when creating a
         row or backfilling a legacy row that has no stored type.
     - Side effects: mutates SwiftData bookmark/note rows and saves the backing context.
     - Failure modes: returns without side effects when no matching bookmark exists; store save
       failures are handled by `BookmarkStore.saveChanges`.
     */
    public func saveBibleBookmarkNote(
        bookmarkId: UUID,
        note: String?,
        defaultContentType: String = "HTML"
    ) {
        let normalizedDefaultContentType = Self.normalizedNotesContentType(defaultContentType)
        // Try Bible bookmark first
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            if let note, Self.shouldPersistNote(note) {
                if let existing = bookmark.notes ?? store.bibleBookmarkNotes(bookmarkId: bookmarkId) {
                    bookmark.notes = existing
                    existing.notes = note
                    existing.contentType = existing.contentType.map(Self.normalizedNotesContentType)
                        ?? normalizedDefaultContentType
                } else {
                    let notes = BibleBookmarkNotes(
                        bookmarkId: bookmarkId,
                        notes: note,
                        contentType: normalizedDefaultContentType
                    )
                    bookmark.notes = notes
                }
            } else {
                if let existing = bookmark.notes ?? store.bibleBookmarkNotes(bookmarkId: bookmarkId) {
                    bookmark.notes = nil
                    store.delete(existing)
                }
                bookmark.notes = nil
            }
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
            return
        }

        // Try generic bookmark
        if let bookmark = store.genericBookmark(id: bookmarkId) {
            if let note, Self.shouldPersistNote(note) {
                if let existing = bookmark.notes ?? store.genericBookmarkNotes(bookmarkId: bookmarkId) {
                    bookmark.notes = existing
                    existing.notes = note
                    existing.contentType = existing.contentType.map(Self.normalizedNotesContentType)
                        ?? normalizedDefaultContentType
                } else {
                    let notes = GenericBookmarkNotes(
                        bookmarkId: bookmarkId,
                        notes: note,
                        contentType: normalizedDefaultContentType
                    )
                    bookmark.notes = notes
                }
            } else {
                if let existing = bookmark.notes ?? store.genericBookmarkNotes(bookmarkId: bookmarkId) {
                    bookmark.notes = nil
                    store.delete(existing)
                }
                bookmark.notes = nil
            }
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
        }
    }

    /// Remove a Bible bookmark.
    public func removeBibleBookmark(id: UUID) {
        store.deleteBibleBookmark(id: id)
    }

    /**
     Get bookmarks overlapping a KJVA verse range for rendering highlights.

     Android persists bookmark membership in KJVA-compatible ordinals. The optional `book` argument
     is retained for source compatibility with older callers, but it is intentionally ignored because
     Android backups store module initials or NULL in `BibleBookmark.book`.
     */
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

    /**
     Returns generic bookmarks for one exact Android document identity.

     - Parameters:
       - bookInitials: Source document or generated-book initials.
       - key: Exact source key within `bookInitials`.
     - Returns: Matching rows ordered by creation time and UUID for deterministic bridge payloads.
     - Side effects: Reads bookmark persistence only.
     - Failure modes: Store fetch failures return an empty array; no module-only or nearest-key
       fallback is attempted.
     */
    public func genericBookmarks(bookInitials: String, key: String) -> [GenericBookmark] {
        store.genericBookmarks()
            .filter { $0.bookInitials == bookInitials && $0.key == key }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    // MARK: - Generic Bookmarks

    /**
     Creates a generic bookmark while preserving Android's nullable ordinal and UTF-16 selection
     contract.

     - Parameters:
       - bookInitials: Stored source document initials.
       - key: Stored source document key.
       - startOrdinal: Optional first document ordinal; `nil` denotes a whole-page bookmark.
       - endOrdinal: Optional last document ordinal; `nil` denotes a whole-page bookmark.
       - wholeVerse: Whether the bookmark covers the full keyed range rather than text offsets.
       - startOffset: Optional UTF-16 start offset for a partial selection.
       - endOffset: Optional UTF-16 end offset for a partial selection.
     - Returns: Inserted generic bookmark.
     - Side effects: Inserts and saves the bookmark.
     - Failure modes: Save failures are handled by `BookmarkStore` and do not throw.
     */
    @discardableResult
    public func addGenericBookmark(
        bookInitials: String,
        key: String,
        startOrdinal: Int?,
        endOrdinal: Int?,
        wholeVerse: Bool = true,
        startOffset: Int? = nil,
        endOffset: Int? = nil
    ) -> GenericBookmark {
        let bookmark = GenericBookmark(
            key: key,
            bookInitials: bookInitials,
            ordinalStart: startOrdinal,
            ordinalEnd: endOrdinal,
            wholeVerse: wholeVerse
        )
        bookmark.startOffset = startOffset
        bookmark.endOffset = endOffset
        store.insert(bookmark)
        return bookmark
    }

    /**
     Persists one validated generic SWORD bookmark seed in Android's Room-v12 shape.

     Android stores source identity as `bookInitials` plus `key`; category and raw OSIS remain
     properties of the installed source resolved by that identity rather than extra bookmark
     columns. Keeping this adapter on the existing service prevents seed consumers from
     reassembling nullable ordinals, paired UTF-16 offsets, or whole-entry flags independently.

     - Parameter seed: Exact source and selection contract produced by `SwordRawOSISFragment`.
     - Returns: Inserted generic bookmark containing every Android-persisted seed field.
     - Side effects: Inserts and saves one generic bookmark through `BookmarkStore`.
     - Failure modes: Save failures are handled by `BookmarkStore` and do not throw. The adapter
       assumes the seed passed generic SWORD source validation and performs no nearest-source fallback.
     */
    @discardableResult
    public func addGenericBookmark(seed: SwordGenericBookmarkSeed) -> GenericBookmark {
        addGenericBookmark(
            bookInitials: seed.source.bookInitials,
            key: seed.source.key,
            startOrdinal: seed.ordinalStart,
            endOrdinal: seed.ordinalEnd,
            wholeVerse: seed.wholeVerse,
            startOffset: seed.startOffset,
            endOffset: seed.endOffset
        )
    }

    /// Create a generic bookmark that renders as a paragraph break in the web reader.
    @discardableResult
    public func addParagraphBreakGenericBookmark(
        bookInitials: String,
        key: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> GenericBookmark {
        ensureSystemLabels()
        let bookmark = GenericBookmark(
            key: key,
            bookInitials: bookInitials,
            ordinalStart: startOrdinal,
            ordinalEnd: endOrdinal,
            wholeVerse: false
        )
        store.insert(bookmark)
        attachParagraphBreakLabel(to: bookmark)
        return bookmark
    }

    /// Remove a generic bookmark.
    public func removeGenericBookmark(id: UUID) {
        if let bookmark = store.genericBookmark(id: id) {
            store.delete(bookmark)
        }
    }

    // MARK: - Labels

    /**
     Ensures one label is attached to a Bible or generic bookmark and repairs its primary label.

     Existing relationships are retained. Repair uses Android StudyPad order, followed by UUID for
     deterministic ties, so an invalid or absent primary label resolves to a live assignment.

     - Parameters:
       - bookmarkId: Exact Bible or generic bookmark identifier.
       - labelId: Existing label identifier to attach.
     - Returns: `"bible"` or `"generic"` for the matched bookmark table, or `nil` when the label or
       bookmark does not exist.
     - Side effects: May insert one relationship row, updates the bookmark timestamp and primary
       label, and saves the bookmark graph.
     - Failure modes: Missing labels or bookmarks return `nil`; persistence failures retain
       `BookmarkStore`'s logged, non-throwing behavior.
     */
    @discardableResult
    public func assignLabel(bookmarkId: UUID, labelId: UUID) -> String? {
        guard let label = store.label(id: labelId) else { return nil }

        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            if bookmark.bookmarkToLabels?.contains(where: { $0.label?.id == labelId }) != true {
                let link = BibleBookmarkToLabel()
                link.bookmark = bookmark
                link.label = label
                store.insert(link)
            }
            let validLabelIds = orderedLabelIDs(bookmark.bookmarkToLabels)
            repairPrimaryLabel(validLabelIds: validLabelIds, primaryLabelId: &bookmark.primaryLabelId)
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
            return "bible"
        }

        if let bookmark = store.genericBookmark(id: bookmarkId) {
            if bookmark.bookmarkToLabels?.contains(where: { $0.label?.id == labelId }) != true {
                let link = GenericBookmarkToLabel()
                link.bookmark = bookmark
                link.label = label
                store.insert(link)
            }
            let validLabelIds = orderedLabelIDs(bookmark.bookmarkToLabels)
            repairPrimaryLabel(validLabelIds: validLabelIds, primaryLabelId: &bookmark.primaryLabelId)
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
            return "generic"
        }

        return nil
    }

    /**
     Toggle a label on a bookmark (Bible or generic).
     Returns "bible" or "generic" to indicate which type was toggled, or nil on failure.
     */
    @discardableResult
    public func toggleLabel(bookmarkId: UUID, labelId: UUID) -> String? {
        guard store.label(id: labelId) != nil else { return nil }

        // Try Bible bookmark first
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            let matchingLinks = bookmark.bookmarkToLabels?.filter { $0.label?.id == labelId } ?? []
            if matchingLinks.isEmpty {
                return assignLabel(bookmarkId: bookmarkId, labelId: labelId)
            }
            matchingLinks.forEach(store.delete)
            let validLabelIds = orderedLabelIDs(bookmark.bookmarkToLabels)
            repairPrimaryLabel(validLabelIds: validLabelIds, primaryLabelId: &bookmark.primaryLabelId)
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
            return "bible"
        }

        // Try generic bookmark
        if let bookmark = store.genericBookmark(id: bookmarkId) {
            let matchingLinks = bookmark.bookmarkToLabels?.filter { $0.label?.id == labelId } ?? []
            if matchingLinks.isEmpty {
                return assignLabel(bookmarkId: bookmarkId, labelId: labelId)
            }
            matchingLinks.forEach(store.delete)
            let validLabelIds = orderedLabelIDs(bookmark.bookmarkToLabels)
            repairPrimaryLabel(validLabelIds: validLabelIds, primaryLabelId: &bookmark.primaryLabelId)
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
            return "generic"
        }

        return nil
    }

    /// Set the primary label for a bookmark (Bible or generic).
    public func setPrimaryLabel(bookmarkId: UUID, labelId: UUID) {
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            bookmark.primaryLabelId = labelId
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
        } else if let bookmark = store.genericBookmark(id: bookmarkId) {
            bookmark.primaryLabelId = labelId
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
        }
    }

    /// Remove a label from a bookmark (Bible or generic).
    public func removeLabel(bookmarkId: UUID, labelId: UUID) {
        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            let matchingLinks = bookmark.bookmarkToLabels?.filter { $0.label?.id == labelId } ?? []
            matchingLinks.forEach(store.delete)
            let validLabelIds = orderedLabelIDs(bookmark.bookmarkToLabels)
            repairPrimaryLabel(validLabelIds: validLabelIds, primaryLabelId: &bookmark.primaryLabelId)
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
        } else if let bookmark = store.genericBookmark(id: bookmarkId) {
            let matchingLinks = bookmark.bookmarkToLabels?.filter { $0.label?.id == labelId } ?? []
            matchingLinks.forEach(store.delete)
            let validLabelIds = orderedLabelIDs(bookmark.bookmarkToLabels)
            repairPrimaryLabel(validLabelIds: validLabelIds, primaryLabelId: &bookmark.primaryLabelId)
            bookmark.lastUpdatedOn = Date()
            store.saveChanges()
        }
    }

    /**
     Applies Android's initial bookmark-label assignment semantics to a newly-created bookmark.

     For newly-created bookmarks, Android validates requested labels, inserts bookmark-to-label rows
     at the workspace StudyPad cursor position clamped to the current StudyPad item count, bumps later
     StudyPad rows, advances any used cursor, and repairs `primaryLabelId` so it points at one of the
     assigned labels. Existing bookmark label replacement stays with the dedicated label-management
     flows.

     - Parameters:
       - bookmarkId: Bible or generic bookmark identifier.
       - labelIds: Desired initial label set for the new bookmark.
       - workspaceSettings: Workspace settings that may contain StudyPad cursor positions.
     - Returns: Assignment details, or `nil` when no matching bookmark exists.
     - Side effects: Inserts bookmark-to-label rows, mutates affected StudyPad order numbers,
       bookmark timestamps, primary-label state, and returned workspace settings.
     - Failure modes: Missing labels are ignored; missing bookmarks return `nil`.
     */
    @discardableResult
    public func applyInitialLabels(
        bookmarkId: UUID,
        labelIds: Set<UUID>,
        workspaceSettings: WorkspaceSettings?
    ) -> BookmarkInitialLabelAssignmentResult? {
        let validLabelIds = labelIds
            .compactMap { store.label(id: $0)?.id }
            .filter { $0 != Label.unlabeledId }
            .sorted { $0.uuidString < $1.uuidString }
        var updatedWorkspaceSettings = workspaceSettings
        var changedWorkspaceSettings = false

        if let bookmark = store.bibleBookmark(id: bookmarkId) {
            applyBibleLabels(
                validLabelIds,
                to: bookmark,
                workspaceSettings: &updatedWorkspaceSettings,
                changedWorkspaceSettings: &changedWorkspaceSettings
            )
            return BookmarkInitialLabelAssignmentResult(
                appliedLabelIds: validLabelIds,
                updatedWorkspaceSettings: updatedWorkspaceSettings,
                changedWorkspaceSettings: changedWorkspaceSettings
            )
        }

        if let bookmark = store.genericBookmark(id: bookmarkId) {
            applyGenericLabels(
                validLabelIds,
                to: bookmark,
                workspaceSettings: &updatedWorkspaceSettings,
                changedWorkspaceSettings: &changedWorkspaceSettings
            )
            return BookmarkInitialLabelAssignmentResult(
                appliedLabelIds: validLabelIds,
                updatedWorkspaceSettings: updatedWorkspaceSettings,
                changedWorkspaceSettings: changedWorkspaceSettings
            )
        }

        return nil
    }

    /**
     Persists whole-range mode for one Bible or generic bookmark before returning.

     - Parameters:
       - bookmarkId: Exact bookmark identifier to update.
       - value: Whether the bookmark covers the complete verse or keyed entry.
     - Side effects: Delegates one timestamped, journaled database mutation to `BookmarkStore`.
     - Failure modes: Missing bookmarks and store save failures retain the store's non-throwing
       behavior and produce no service-level error.
     */
    public func setWholeVerse(bookmarkId: UUID, value: Bool) {
        store.setWholeVerse(bookmarkId: bookmarkId, value: value)
    }

    /**
     Persists a custom icon for one Bible or generic bookmark before returning.

     - Parameters:
       - bookmarkId: Exact bookmark identifier to update.
       - value: Android icon name to store, or `nil` to clear the icon.
     - Side effects: Delegates one timestamped, journaled database mutation to `BookmarkStore`.
     - Failure modes: Missing bookmarks and store save failures retain the store's non-throwing
       behavior and produce no service-level error.
     */
    public func setCustomIcon(bookmarkId: UUID, value: String?) {
        store.setCustomIcon(bookmarkId: bookmarkId, value: value)
    }

    // MARK: - Labels CRUD

    /**
     Ensures reserved labels use Android's fixed identities and repairs pre-parity iOS rows.

     Speak, Unlabeled, and Paragraph Break are runtime-required and are created when missing.
     Android creates the AI label lazily, so iOS only canonicalizes it when an AI row already
     exists. Duplicate legacy rows are merged without dropping bookmark or StudyPad relationships.

     - Side effects: May create, rename, re-identify, merge, or delete reserved label rows and
       remap scalar primary-label references.
     - Failure modes: Store fetch/save failures are handled by `BookmarkStore` and do not throw.
     */
    public func ensureSystemLabels() {
        let systemLabels: [(name: String, id: UUID, legacyID: UUID?, createIfMissing: Bool)] = [
            (Label.speakLabelName, Label.speakLabelId, Label.legacySpeakLabelId, true),
            (Label.unlabeledName, Label.unlabeledId, Label.legacyUnlabeledId, true),
            (Label.paragraphBreakLabelName, Label.paragraphBreakLabelId, Label.legacyParagraphBreakLabelId, true),
            (Label.aiLabelName, Label.aiLabelId, nil, false),
        ]

        let allLabels = store.labels(includeSystem: true)

        for definition in systemLabels {
            let candidates = allLabels.filter {
                $0.name == definition.name ||
                    $0.id == definition.id ||
                    $0.id == definition.legacyID
            }
            var canonical = candidates.first(where: { $0.id == definition.id })
            if canonical == nil, let existing = candidates.first {
                let oldID = existing.id
                existing.id = definition.id
                existing.name = definition.name
                store.remapPrimaryLabelIdentifier(from: oldID, to: definition.id)
                canonical = existing
            } else if canonical == nil, definition.createIfMissing {
                let label = Label(id: definition.id, name: definition.name)
                store.insert(label)
                canonical = label
            }
            guard let canonical else { continue }
            canonical.name = definition.name
            for duplicate in candidates where duplicate !== canonical {
                store.mergeLabel(duplicate, into: canonical)
            }
        }
        store.saveChanges()
    }

    private func attachParagraphBreakLabel(to bookmark: BibleBookmark) {
        guard let label = store.label(id: Label.paragraphBreakLabelId) else { return }
        bookmark.primaryLabelId = label.id
        let link = BibleBookmarkToLabel()
        link.bookmark = bookmark
        link.label = label
        store.insert(link)
    }

    private func attachParagraphBreakLabel(to bookmark: GenericBookmark) {
        guard let label = store.label(id: Label.paragraphBreakLabelId) else { return }
        bookmark.primaryLabelId = label.id
        let link = GenericBookmarkToLabel()
        link.bookmark = bookmark
        link.label = label
        store.insert(link)
    }

    private func applyBibleLabels(
        _ validLabelIds: [UUID],
        to bookmark: BibleBookmark,
        workspaceSettings: inout WorkspaceSettings?,
        changedWorkspaceSettings: inout Bool
    ) {
        let existingLinks = bookmark.bookmarkToLabels ?? []
        let existingLabelIds = Set(existingLinks.compactMap { $0.label?.id })

        for labelId in validLabelIds where !existingLabelIds.contains(labelId) {
            guard let label = store.label(id: labelId) else { continue }
            let orderNumber = studyPadInsertionOrder(
                labelId: labelId,
                workspaceSettings: &workspaceSettings,
                changedWorkspaceSettings: &changedWorkspaceSettings
            )
            _ = incrementOrderNumbers(labelId: labelId, fromOrder: orderNumber, excludingEntryId: nil)
            let link = BibleBookmarkToLabel(orderNumber: orderNumber)
            link.bookmark = bookmark
            link.label = label
            store.insert(link)
        }

        repairPrimaryLabel(validLabelIds: validLabelIds, primaryLabelId: &bookmark.primaryLabelId)
        bookmark.lastUpdatedOn = Date()
        store.saveChanges()
    }

    private func applyGenericLabels(
        _ validLabelIds: [UUID],
        to bookmark: GenericBookmark,
        workspaceSettings: inout WorkspaceSettings?,
        changedWorkspaceSettings: inout Bool
    ) {
        let existingLinks = bookmark.bookmarkToLabels ?? []
        let existingLabelIds = Set(existingLinks.compactMap { $0.label?.id })

        for labelId in validLabelIds where !existingLabelIds.contains(labelId) {
            guard let label = store.label(id: labelId) else { continue }
            let orderNumber = studyPadInsertionOrder(
                labelId: labelId,
                workspaceSettings: &workspaceSettings,
                changedWorkspaceSettings: &changedWorkspaceSettings
            )
            _ = incrementOrderNumbers(labelId: labelId, fromOrder: orderNumber, excludingEntryId: nil)
            let link = GenericBookmarkToLabel(orderNumber: orderNumber)
            link.bookmark = bookmark
            link.label = label
            store.insert(link)
        }

        repairPrimaryLabel(validLabelIds: validLabelIds, primaryLabelId: &bookmark.primaryLabelId)
        bookmark.lastUpdatedOn = Date()
        store.saveChanges()
    }

    private func studyPadInsertionOrder(
        labelId: UUID,
        workspaceSettings: inout WorkspaceSettings?,
        changedWorkspaceSettings: inout Bool
    ) -> Int {
        let itemCount = studyPadItemCount(labelId: labelId)
        guard let cursor = workspaceSettings?.studyPadCursors[labelId] else {
            return itemCount
        }
        let orderNumber = min(cursor, itemCount)
        workspaceSettings?.studyPadCursors[labelId] = orderNumber + 1
        changedWorkspaceSettings = true
        return orderNumber
    }

    private func studyPadItemCount(labelId: UUID) -> Int {
        store.bibleBookmarkToLabels(labelId: labelId).count
            + store.genericBookmarkToLabels(labelId: labelId).count
            + store.studyPadEntries(labelId: labelId).count
    }

    /**
     Returns attached Bible label IDs in Android StudyPad order for primary-label repair.

     - Parameter links: Current Bible bookmark junction rows after a label mutation.
     - Returns: Live label IDs sorted by `orderNumber`, then UUID for deterministic ties.
     - Side effects: none.
     - Failure modes: Missing labels and deleted relationship rows are omitted.
     */
    private func orderedLabelIDs(_ links: [BibleBookmarkToLabel]?) -> [UUID] {
        (links ?? [])
            .compactMap { link -> (id: UUID, orderNumber: Int)? in
                guard let label = link.label, !label.isDeleted else { return nil }
                return (label.id, link.orderNumber)
            }
            .sorted {
                if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map(\.id)
    }

    /**
     Returns attached generic label IDs in Android StudyPad order for primary-label repair.

     - Parameter links: Current generic bookmark junction rows after a label mutation.
     - Returns: Live label IDs sorted by `orderNumber`, then UUID for deterministic ties.
     - Side effects: none.
     - Failure modes: Missing labels and deleted relationship rows are omitted.
     */
    private func orderedLabelIDs(_ links: [GenericBookmarkToLabel]?) -> [UUID] {
        (links ?? [])
            .compactMap { link -> (id: UUID, orderNumber: Int)? in
                guard let label = link.label, !label.isDeleted else { return nil }
                return (label.id, link.orderNumber)
            }
            .sorted {
                if $0.orderNumber != $1.orderNumber { return $0.orderNumber < $1.orderNumber }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map(\.id)
    }

    private func repairPrimaryLabel(validLabelIds: [UUID], primaryLabelId: inout UUID?) {
        if let primaryLabelId, validLabelIds.contains(primaryLabelId) {
            return
        }
        primaryLabelId = validLabelIds.first
    }

    /**
     Seed default highlight labels on first launch (matches Android).
     Only creates labels if no user labels exist yet.
     */
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

    /**
     Previews the bookmarks that would be orphaned by deleting one label.

     - Parameter id: Target label identifier.
     - Returns: Deterministically ordered orphan identifiers, or `nil` when the label is missing.
     - Side effects: none.
     - Failure modes: Store fetch failures follow the store's empty-result contract.
     */
    public func labelDeletionImpact(id: UUID) -> BookmarkLabelDeletionImpact? {
        guard store.label(id: id) != nil else { return nil }

        let bibleBookmarkIDs = store.bibleBookmarks(withLabel: id)
            .filter { bookmark in
                liveLabelIDs(bookmark.bookmarkToLabels).subtracting([id]).isEmpty
            }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        let genericBookmarkIDs = store.genericBookmarks(withLabel: id)
            .filter { bookmark in
                liveLabelIDs(bookmark.bookmarkToLabels).subtracting([id]).isEmpty
            }
            .map(\.id)
            .sorted { $0.uuidString < $1.uuidString }

        return BookmarkLabelDeletionImpact(
            bibleBookmarkIDs: bibleBookmarkIDs,
            genericBookmarkIDs: genericBookmarkIDs
        )
    }

    /**
     Deletes one label while retaining every bookmark, preserving the historical public API.

     Callers that expose Android's orphan choice use the overload accepting
     `deleteOrphanedBookmarks`.
     */
    public func deleteLabel(id: UUID) {
        _ = deleteLabel(id: id, deleteOrphanedBookmarks: false)
    }

    /**
     Applies Android's label deletion choice through one bookmark graph transaction.

     - Parameters:
       - id: Target non-system label identifier.
       - deleteOrphanedBookmarks: Whether bookmarks identified by the deletion preview should also
         be removed.
     - Returns: The preview used for deletion, or `nil` when the label no longer exists.
     - Side effects: Deletes the label and optionally its orphaned bookmark graphs.
     - Failure modes: Missing labels return `nil`; store persistence retains its logged
       best-effort failure contract.
     */
    @discardableResult
    public func deleteLabel(
        id: UUID,
        deleteOrphanedBookmarks: Bool
    ) -> BookmarkLabelDeletionImpact? {
        guard let label = store.label(id: id),
              let impact = labelDeletionImpact(id: id) else {
            return nil
        }
        store.delete(
            label,
            deletingBibleBookmarkIDs: deleteOrphanedBookmarks ? Set(impact.bibleBookmarkIDs) : [],
            deletingGenericBookmarkIDs: deleteOrphanedBookmarks ? Set(impact.genericBookmarkIDs) : []
        )
        return impact
    }

    /** Returns the live label identifiers from one optional Bible bookmark junction collection. */
    private func liveLabelIDs(_ links: [BibleBookmarkToLabel]?) -> Set<UUID> {
        Set((links ?? []).compactMap { link in
            guard let label = link.label, !label.isDeleted else { return nil }
            return label.id
        })
    }

    /** Returns the live label identifiers from one optional generic bookmark junction collection. */
    private func liveLabelIDs(_ links: [GenericBookmarkToLabel]?) -> Set<UUID> {
        Set((links ?? []).compactMap { link in
            guard let label = link.label, !label.isDeleted else { return nil }
            return label.id
        })
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

    /**
     Create a new StudyPad text entry for a label, inserted after the given order number.
     Returns (newEntry, bumpedBibleBtls, bumpedGenericBtls, bumpedEntries).
     */
    @discardableResult
    public func createStudyPadEntry(
        labelId: UUID,
        afterOrderNumber: Int,
        contentType: String = "HTML"
    ) -> (StudyPadTextEntry, [BibleBookmarkToLabel], [GenericBookmarkToLabel], [StudyPadTextEntry])? {
        guard let label = store.label(id: labelId) else { return nil }

        let newOrder = afterOrderNumber + 1

        // Bump all items at or above the new position
        let bumped = incrementOrderNumbers(labelId: labelId, fromOrder: newOrder, excludingEntryId: nil)

        // Create the entry
        let entry = StudyPadTextEntry(
            orderNumber: newOrder,
            indentLevel: 0,
            contentType: Self.normalizedNotesContentType(contentType)
        )
        entry.label = label
        store.insert(entry)

        // Create empty text content
        store.upsertStudyPadEntryText(entryId: entry.id, text: "")

        return (entry, bumped.bibleBtls, bumped.genericBtls, bumped.entries)
    }

    /**
     Deletes one StudyPad text entry and durably normalizes the remaining mixed item order.

     - Parameter id: Exact StudyPad entry identifier to delete.
     - Returns: Deleted identifiers plus every Bible junction, generic junction, and text entry whose
       order changed, or `nil` when the entry or label is missing.
     - Side effects: Delegates deletion and contiguous renumbering to one atomic store save.
     - Failure modes: Missing entries or labels return `nil`; store persistence failures retain the
       store's non-throwing behavior.
     */
    public func deleteStudyPadEntry(
        id: UUID
    ) -> (UUID, UUID, [BibleBookmarkToLabel], [GenericBookmarkToLabel], [StudyPadTextEntry])? {
        store.deleteStudyPadEntryAndNormalizeOrder(id: id)
    }

    /**
     Persists ordering metadata for one StudyPad text entry before returning.

     - Parameters:
       - id: Exact StudyPad entry identifier.
       - orderNumber: Replacement display order, or `nil` to retain the current value.
       - indentLevel: Replacement nesting depth, or `nil` to retain the current value.
     - Side effects: Delegates one journaled database mutation to `BookmarkStore`.
     - Failure modes: Missing entries and store save failures retain the store's non-throwing
       behavior.
     */
    public func updateStudyPadTextEntry(id: UUID, orderNumber: Int?, indentLevel: Int?) {
        store.updateStudyPadEntryMetadata(
            id: id,
            orderNumber: orderNumber,
            indentLevel: indentLevel
        )
    }

    /// Update the text content of a StudyPad text entry.
    public func updateStudyPadTextEntryText(id: UUID, text: String) {
        store.upsertStudyPadEntryText(entryId: id, text: text)
    }

    /**
     Persists StudyPad metadata for one Bible-bookmark-to-label relationship before returning.

     - Parameters:
       - bookmarkId: Exact Bible bookmark identifier.
       - labelId: Exact label identifier for the junction row.
       - orderNumber: Replacement display order, or `nil` to retain the current value.
       - indentLevel: Replacement nesting depth, or `nil` to retain the current value.
       - expandContent: Replacement expanded state, or `nil` to retain the current value.
     - Side effects: Delegates one timestamped, journaled relationship mutation to `BookmarkStore`.
     - Failure modes: Missing relationships and store save failures retain the store's non-throwing
       behavior.
     */
    public func updateBibleBookmarkToLabel(
        bookmarkId: UUID,
        labelId: UUID,
        orderNumber: Int?,
        indentLevel: Int?,
        expandContent: Bool?
    ) {
        store.updateBibleBookmarkToLabelMetadata(
            bookmarkId: bookmarkId,
            labelId: labelId,
            orderNumber: orderNumber,
            indentLevel: indentLevel,
            expandContent: expandContent
        )
    }

    /**
     Persists StudyPad metadata for one generic-bookmark-to-label relationship before returning.

     - Parameters:
       - bookmarkId: Exact generic bookmark identifier.
       - labelId: Exact label identifier for the junction row.
       - orderNumber: Replacement display order, or `nil` to retain the current value.
       - indentLevel: Replacement nesting depth, or `nil` to retain the current value.
       - expandContent: Replacement expanded state, or `nil` to retain the current value.
     - Side effects: Delegates one timestamped, journaled relationship mutation to `BookmarkStore`.
     - Failure modes: Missing relationships and store save failures retain the store's non-throwing
       behavior.
     */
    public func updateGenericBookmarkToLabel(
        bookmarkId: UUID,
        labelId: UUID,
        orderNumber: Int?,
        indentLevel: Int?,
        expandContent: Bool?
    ) {
        store.updateGenericBookmarkToLabelMetadata(
            bookmarkId: bookmarkId,
            labelId: labelId,
            orderNumber: orderNumber,
            indentLevel: indentLevel,
            expandContent: expandContent
        )
    }

    /**
     Persists one mixed StudyPad drag-and-drop reorder as a single database batch.

     - Parameters:
       - labelId: Label whose bookmark junctions are addressed by the payload.
       - bibleBookmarkOrders: Bible bookmark identifiers and replacement order numbers.
       - genericBookmarkOrders: Generic bookmark identifiers and replacement order numbers.
       - studyPadEntryOrders: StudyPad entry identifiers and replacement order numbers.
     - Side effects: Delegates the complete payload to one journaled `BookmarkStore` save.
     - Failure modes: Missing rows are ignored and store save failures retain the store's
       non-throwing behavior.
     */
    public func updateOrderNumbers(
        labelId: UUID,
        bibleBookmarkOrders: [(bookmarkId: UUID, orderNumber: Int)],
        genericBookmarkOrders: [(bookmarkId: UUID, orderNumber: Int)],
        studyPadEntryOrders: [(entryId: UUID, orderNumber: Int)]
    ) {
        store.updateStudyPadOrderNumbers(
            labelId: labelId,
            bibleBookmarkOrders: bibleBookmarkOrders,
            genericBookmarkOrders: genericBookmarkOrders,
            studyPadEntryOrders: studyPadEntryOrders
        )
    }

    /**
     Persists one note-edit action for a Bible or generic bookmark before returning.

     - Parameters:
       - bookmarkId: Exact bookmark identifier to update.
       - editAction: Append/prepend action to store, or `nil` to clear the action.
     - Side effects: Delegates one timestamped, journaled database mutation to `BookmarkStore`.
     - Failure modes: Missing bookmarks and store save failures retain the store's non-throwing
       behavior.
     */
    public func setBookmarkEditAction(bookmarkId: UUID, editAction: EditAction?) {
        store.setBookmarkEditAction(bookmarkId: bookmarkId, editAction: editAction)
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

}
