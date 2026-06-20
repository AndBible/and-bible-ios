import Foundation
import BibleCore
import SwordKit

/**
 Encodes the reader's current rendered document identity for compact native state export.

 The encoded form is intentionally a small semicolon-delimited token string because UI tests and
 tab labels need stable state without inspecting the full Vue document. The field names and order
 preserve the legacy `BibleReaderController.renderedContentState` contract.
 */
struct BibleReaderRenderedContentState: Equatable {
    /// Neutral state used before the WebView has rendered any reader document.
    static let empty = BibleReaderRenderedContentState(
        encodedValue: "category=none;module=none;book=none;chapter=none;key=none"
    )

    /// Serialized key/value token consumed by reader UI tests and bottom tab label logic.
    let encodedValue: String

    /**
     Creates a rendered-content token from the reader's document identity.
    
     - Parameters:
       - category: Document category that owns the displayed content.
       - moduleName: Optional module or synthetic document label; `nil` is encoded as `none`.
       - book: Book, label, dictionary key, or document title to show in compact state.
       - chapter: Optional chapter number; `nil` is encoded as `none`.
       - key: Optional durable or transient content key; `nil` is encoded as `none`.
     - Side effects: None.
     - Failure modes: None; delimiter characters are sanitized so parsing remains deterministic.
     */
    init(
        category: DocumentCategory,
        moduleName: String?,
        book: String,
        chapter: Int? = nil,
        key: String? = nil
    ) {
        self.encodedValue = [
            "category=\(category.pageManagerKey)",
            "module=\(Self.token(moduleName))",
            "book=\(Self.token(book))",
            "chapter=\(chapter.map(String.init) ?? "none")",
            "key=\(Self.token(key))",
        ].joined(separator: ";")
    }

    /**
     Creates a state from an already-serialized token.
    
     - Parameter encodedValue: Existing semicolon-delimited state string.
     - Side effects: None.
     - Failure modes: The initializer does not validate fields so callers can preserve legacy
       neutral and malformed states for fail-closed consumers.
     */
    private init(encodedValue: String) {
        self.encodedValue = encodedValue
    }

    /**
     Escapes semantically important content-state tokens for accessibility export and tests.
    
     - Parameter raw: Optional raw token value.
     - Returns: A sanitized token, or `none` for `nil`.
     - Side effects: None.
     - Failure modes: None.
     */
    static func token(_ raw: String?) -> String {
        (raw ?? "none")
            .replacingOccurrences(of: ";", with: "_")
            .replacingOccurrences(of: ",", with: "_")
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: "=", with: "_")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /**
     Parses a semicolon-delimited rendered-content token into field values.
    
     - Parameter encodedValue: Token string produced by `encodedValue` or a legacy controller value.
     - Returns: Dictionary of parsed key/value pairs.
     - Side effects: None.
     - Failure modes: Malformed fields are ignored; duplicate keys keep Swift's dictionary behavior
       from the previous inline implementation.
     */
    static func tokens(from encodedValue: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: encodedValue
            .split(separator: ";")
            .compactMap { part -> (String, String)? in
                let pieces = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pieces.count == 2 else { return nil }
                return (pieces[0], pieces[1])
            })
    }
}

/// One compact My Notes row token emitted for detailed UI-test accessibility state.
struct MyNotesAccessibilityNoteToken: Equatable {
    /// Stable verse-reference token for the note row.
    let referenceToken: String

    /// Sanitized note body token.
    let noteToken: String

    /// Encoded row fragment consumed by UI tests.
    var encodedValue: String {
        "|\(referenceToken)=\(noteToken)|"
    }
}

/// Compact My Notes state emitted for UI automation after the real document is visible.
struct MyNotesAccessibilitySnapshot: Equatable {
    /// Whether the reader is currently showing My Notes.
    let isVisible: Bool

    /// Whether the WebView editor is active.
    let isEditing: Bool

    /// Monotonic mutation marker updated when My Notes content changes.
    let revision: Int

    /// Full count of current-chapter notes before row-token truncation.
    let totalCount: Int

    /// Stable row reference tokens for the exported prefix.
    let rowReferenceTokens: [String]

    /// Stable note-content tokens for the exported prefix.
    let noteTokens: [MyNotesAccessibilityNoteToken]

    /// Neutral snapshot used when no controller is available to the reader view.
    static let empty = MyNotesAccessibilitySnapshot(
        isVisible: false,
        isEditing: false,
        revision: 0,
        totalCount: 0,
        rowReferenceTokens: [],
        noteTokens: []
    )

    /// Encoded state consumed by the hidden UI-test export label.
    var encodedValue: String {
        let rowTokens = rowReferenceTokens.map { "|\($0)|" }.joined(separator: ",")
        let notes = noteTokens.map(\.encodedValue).joined(separator: ",")
        return [
            "myNotesVisible=\(isVisible)",
            "myNotesEditing=\(isEditing)",
            "myNotesRevision=\(revision)",
            "myNotesCount=\(totalCount)",
            "myNotesRows=\(rowTokens)",
            "myNotesNotes=\(notes)",
        ].joined(separator: ";")
    }
}

/// One compact StudyPad text-entry token emitted for detailed UI-test accessibility state.
struct StudyPadAccessibilityTextToken: Equatable {
    /// Current StudyPad order number for the text entry.
    let orderNumber: Int

    /// Sanitized text body token.
    let textToken: String

    /// Encoded row fragment consumed by UI tests.
    var encodedValue: String {
        "|\(orderNumber)=\(textToken)|"
    }
}

/// Compact StudyPad state emitted for UI automation after the real document is visible.
struct StudyPadAccessibilitySnapshot: Equatable {
    /// Whether the reader is currently showing a StudyPad document.
    let isVisible: Bool

    /// Whether the WebView editor is active.
    let isEditing: Bool

    /// Monotonic mutation marker updated when StudyPad content changes.
    let revision: Int

    /// Sanitized label token for the active StudyPad.
    let labelToken: String

    /// Full count of StudyPad text entries before row-token truncation.
    let textEntryCount: Int

    /// Stable text-entry tokens for the exported prefix.
    let textTokens: [StudyPadAccessibilityTextToken]

    /// Neutral snapshot used when no controller is available to the reader view.
    static let empty = StudyPadAccessibilitySnapshot(
        isVisible: false,
        isEditing: false,
        revision: 0,
        labelToken: "none",
        textEntryCount: 0,
        textTokens: []
    )

    /// Encoded state consumed by the hidden UI-test export label.
    var encodedValue: String {
        let texts = textTokens.map(\.encodedValue).joined(separator: ",")
        return [
            "studyPadVisible=\(isVisible)",
            "studyPadEditing=\(isEditing)",
            "studyPadRevision=\(revision)",
            "studyPadLabel=\(labelToken)",
            "studyPadTextEntryCount=\(textEntryCount)",
            "studyPadTexts=\(texts)",
        ].joined(separator: ";")
    }
}

/**
 Builds compact reader accessibility snapshots for My Notes and StudyPad document state.

 `BibleReaderController` owns the live reader state and SWORD ordinal resolution. This factory owns
 only the deterministic export assembly so tests and UI automation tokens do not remain embedded in
 the controller's bridge/navigation responsibilities.
 */
struct BibleReaderAccessibilitySnapshotFactory {
    /// Resolves the current chapter's ordinal range using the reader's active versification.
    typealias ChapterOrdinalRangeResolver = () -> (start: Int, end: Int, verseCount: Int)?

    /// Resolves a persisted bookmark ordinal into a chapter/verse reference.
    typealias VerseReferenceResolver = (_ book: String, _ ordinal: Int) -> VerseKeyReference?

    private let bookmarkService: BookmarkService?
    private let currentBook: String
    private let currentChapter: Int
    private let showingMyNotes: Bool
    private let showingStudyPad: Bool
    private let editingInWebView: Bool
    private let myNotesMutationRevision: Int
    private let studyPadMutationRevision: Int
    private let activeStudyPadLabelId: UUID?
    private let activeStudyPadLabelName: String?
    private let rowLimit: Int
    private let chapterOrdinalRange: ChapterOrdinalRangeResolver
    private let verseReference: VerseReferenceResolver

    /**
     Creates a snapshot factory from the controller state needed for compact exports.
    
     - Parameters:
       - bookmarkService: Bookmark service supplying notes and StudyPad entries.
       - currentBook: Current reader book name used for note lookup and reference tokens.
       - currentChapter: Current reader chapter used when ordinal resolution falls back.
       - showingMyNotes: Whether the visible document is My Notes.
       - showingStudyPad: Whether the visible document is StudyPad.
       - editingInWebView: Whether the Vue editor is active.
       - myNotesMutationRevision: Mutation revision for My Notes state.
       - studyPadMutationRevision: Mutation revision for StudyPad state.
       - activeStudyPadLabelId: Active StudyPad label id, if any.
       - activeStudyPadLabelName: Active StudyPad label name, if any.
       - rowLimit: Maximum detailed rows exported for UI tests.
       - chapterOrdinalRange: Closure that resolves the visible chapter ordinal range.
       - verseReference: Closure that resolves ordinals using the active reader versification.
     - Side effects: None during initialization.
     - Failure modes: Missing services or failed ordinal resolution produce empty snapshots rather
       than throwing so UI automation exports stay safe in no-module states.
     */
    init(
        bookmarkService: BookmarkService?,
        currentBook: String,
        currentChapter: Int,
        showingMyNotes: Bool,
        showingStudyPad: Bool,
        editingInWebView: Bool,
        myNotesMutationRevision: Int,
        studyPadMutationRevision: Int,
        activeStudyPadLabelId: UUID?,
        activeStudyPadLabelName: String?,
        rowLimit: Int = UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit,
        chapterOrdinalRange: @escaping ChapterOrdinalRangeResolver,
        verseReference: @escaping VerseReferenceResolver
    ) {
        self.bookmarkService = bookmarkService
        self.currentBook = currentBook
        self.currentChapter = currentChapter
        self.showingMyNotes = showingMyNotes
        self.showingStudyPad = showingStudyPad
        self.editingInWebView = editingInWebView
        self.myNotesMutationRevision = myNotesMutationRevision
        self.studyPadMutationRevision = studyPadMutationRevision
        self.activeStudyPadLabelId = activeStudyPadLabelId
        self.activeStudyPadLabelName = activeStudyPadLabelName
        self.rowLimit = rowLimit
        self.chapterOrdinalRange = chapterOrdinalRange
        self.verseReference = verseReference
    }

    /**
     Builds the compact My Notes snapshot for the current reader chapter.
    
     - Returns: Snapshot containing visibility, editor state, revision, full note count, and limited
       detailed note tokens.
     - Side effects: Reads bookmarks from `BookmarkService`.
     - Failure modes: Missing service or unresolved chapter range returns an empty note list while
       preserving visibility and revision state.
     */
    func myNotesAccessibilitySnapshot() -> MyNotesAccessibilitySnapshot {
        let bookmarks = currentChapterMyNotesBookmarks()
        let exportedBookmarks = bookmarks.prefix(rowLimit)
        let noteTokens = exportedBookmarks.map { bookmark in
            MyNotesAccessibilityNoteToken(
                referenceToken: myNotesReferenceToken(for: bookmark),
                noteToken: BibleReaderRenderedContentState.token(bookmark.notes?.notes)
            )
        }
        return MyNotesAccessibilitySnapshot(
            isVisible: showingMyNotes,
            isEditing: editingInWebView,
            revision: myNotesMutationRevision,
            totalCount: bookmarks.count,
            rowReferenceTokens: noteTokens.map(\.referenceToken),
            noteTokens: noteTokens
        )
    }

    /**
     Builds the compact StudyPad snapshot for the active StudyPad label.
    
     - Returns: Snapshot containing visibility, editor state, revision, active label, full text-entry
       count, and limited detailed text tokens.
     - Side effects: Reads StudyPad entries from `BookmarkService`.
     - Failure modes: Missing label or service returns an empty text-entry list while preserving
       visibility and label state.
     */
    func studyPadAccessibilitySnapshot() -> StudyPadAccessibilitySnapshot {
        guard showingStudyPad,
              let labelId = activeStudyPadLabelId,
              let service = bookmarkService else {
            return StudyPadAccessibilitySnapshot(
                isVisible: showingStudyPad,
                isEditing: editingInWebView,
                revision: studyPadMutationRevision,
                labelToken: BibleReaderRenderedContentState.token(activeStudyPadLabelName),
                textEntryCount: 0,
                textTokens: []
            )
        }

        let entries = service.studyPadEntries(labelId: labelId)
        let exportedEntries = entries.prefix(rowLimit)
        let textTokens = exportedEntries.map { entry in
            StudyPadAccessibilityTextToken(
                orderNumber: entry.orderNumber,
                textToken: BibleReaderRenderedContentState.token(entry.textEntry?.text)
            )
        }
        return StudyPadAccessibilitySnapshot(
            isVisible: showingStudyPad,
            isEditing: editingInWebView,
            revision: studyPadMutationRevision,
            labelToken: BibleReaderRenderedContentState.token(activeStudyPadLabelName),
            textEntryCount: entries.count,
            textTokens: textTokens
        )
    }

    /**
     Returns notes with non-empty payloads that belong to the currently visible chapter.
    
     - Returns: Sorted Bible bookmarks with non-empty note content for the current chapter.
     - Side effects: Reads bookmarks from `BookmarkService`.
     - Failure modes: Missing service or unresolved chapter range returns an empty list.
     */
    func currentChapterMyNotesBookmarks() -> [BibleBookmark] {
        guard let service = bookmarkService,
              let range = chapterOrdinalRange() else { return [] }
        return service.bookmarks(for: range.start, endOrdinal: range.end, book: currentBook)
            .filter { bookmark in
                guard let note = bookmark.notes?.notes else { return false }
                return !note.isEmpty
            }
            .sorted {
                if $0.ordinalStart != $1.ordinalStart {
                    return $0.ordinalStart < $1.ordinalStart
                }
                return $0.createdAt < $1.createdAt
            }
    }

    /// Stable row token for the My Notes accessibility export.
    private func myNotesReferenceToken(for bookmark: BibleBookmark) -> String {
        let startReference = verseReference(currentBook, bookmark.ordinalStart)
        let endReference = verseReference(currentBook, bookmark.ordinalEnd)
        let startVerse = startReference?.verse ?? 1
        let endVerse = max(startVerse, endReference?.verse ?? startVerse)
        let verseToken = startVerse == endVerse ? "\(startVerse)" : "\(startVerse)_\(endVerse)"
        let chapter = startReference?.chapter ?? currentChapter
        return "\(BibleReaderRenderedContentState.token(currentBook))_\(chapter)_\(verseToken)"
    }
}
