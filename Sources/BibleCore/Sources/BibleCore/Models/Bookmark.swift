// Bookmark.swift -- Bookmark domain models

import Foundation
import SwiftData

/**
 Enumerates persisted bookmark type identifiers mirrored from Android parity data.

 The raw values are stored as strings on bookmark entities and interpreted by higher layers.
 This enum currently documents the known cases without adding additional behavior.
 */
public enum BookmarkType: String, Codable, Sendable, Equatable {
    case example = "EXAMPLE"
}

/**
 Enumerates the note-edit merge modes used by bookmark automation features.

 The raw values are stored in `EditAction` and interpreted by UI or import flows when
 appending or prepending generated content.
 */
public enum EditActionMode: String, Codable, Sendable, Equatable {
    case append = "APPEND"
    case prepend = "PREPEND"
}

/**
 Stores an optional bookmark note-edit instruction.

 The struct is embedded inside bookmark entities. It has no side effects on its own; any note
 mutation occurs when a caller interprets the stored configuration and writes bookmark notes.
 */
public struct EditAction: Codable, Sendable, Equatable {
    /// Selected edit mode that determines how new content should be merged into notes.
    public var mode: EditActionMode?

    /// Text payload to append or prepend when the action is executed.
    public var content: String?

    /**
     Creates an edit-action descriptor.

     - Parameters:
       - mode: Merge mode for the future note update.
       - content: Payload that should be written when the action is executed.
     */
    public init(mode: EditActionMode? = nil, content: String? = nil) {
        self.mode = mode
        self.content = content
    }
}

/**
 Android-compatible text-to-speech playback metadata stored on bookmarks and workspaces.

 Android serializes every field, including default values and explicit `null` bookmark metadata.
 `isMemorizationLoop` is runtime-only and intentionally omitted from JSON, matching Kotlin's
 `@Transient` field. Decoding historical iOS payloads supplies Android defaults for missing fields.
 */
public struct PlaybackSettings: Codable, Sendable, Equatable {
    /// Announces chapter transitions while a provider crosses chapter or generic-key boundaries.
    public var speakChapterChanges: Bool

    /// Includes OSIS headings in spoken output.
    public var speakTitles: Bool

    /// Includes study notes bracketed by footnote boundary commands.
    public var speakFootnotes: Bool

    /// Android speech rate percentage.
    public var speed: Int

    /// Module initials used by bookmark/widget resume.
    public var bookId: String?

    /// Whether the Speak provider created the owning bookmark automatically.
    public var bookmarkWasCreated: Bool?

    /// Primitive local representation kept compatible with SwiftData's Codable transform storage.
    private var verseRangeAndroidString: String?

    /// Optional repeated Bible passage serialized through Android's `VerseRangeSerializer`.
    public var verseRange: SpeakVerseRange? {
        get { verseRangeAndroidString.flatMap(SpeakVerseRange.init(androidString:)) }
        set { verseRangeAndroidString = newValue?.description }
    }

    /// Runtime-only memorization-loop state; never serialized.
    public var isMemorizationLoop: Bool

    /**
     Decoder-only signal used by an enclosing `SpeakSettings` payload to apply Android's
     whole-object fallback when a nested known field is malformed.
     */
    private(set) var decodedMalformedKnownField = false

    private enum CodingKeys: String, CodingKey {
        case speakChapterChanges
        case speakTitles
        case speakFootnotes
        case speed
        case bookId
        case bookmarkWasCreated
        case verseRange
    }

    /**
     Creates playback settings using Android defaults.

     - Parameters:
       - speakChapterChanges: Whether chapter/key transitions are announced.
       - speakTitles: Whether OSIS headings are spoken.
       - speakFootnotes: Whether study notes are spoken.
       - speed: Android rate percentage. Persisted values remain byte-for-byte compatible; the
         platform synthesizer applies its own supported rate bounds when speaking.
       - bookId: Optional source module initials for resume.
       - bookmarkWasCreated: Optional auto-bookmark ownership marker.
       - verseRange: Optional repeated Bible range.
       - isMemorizationLoop: Runtime-only memorization mode.
     - Side effects: none.
     - Failure modes: Construction cannot fail.
     */
    public init(
        speakChapterChanges: Bool = true,
        speakTitles: Bool = true,
        speakFootnotes: Bool = false,
        speed: Int = 100,
        bookId: String? = nil,
        bookmarkWasCreated: Bool? = nil,
        verseRange: SpeakVerseRange? = nil,
        isMemorizationLoop: Bool = false
    ) {
        self.speakChapterChanges = speakChapterChanges
        self.speakTitles = speakTitles
        self.speakFootnotes = speakFootnotes
        self.speed = speed
        self.bookId = bookId
        self.bookmarkWasCreated = bookmarkWasCreated
        verseRangeAndroidString = verseRange?.description
        self.isMemorizationLoop = isMemorizationLoop
        decodedMalformedKnownField = false
    }

    /**
     Decodes historical or Android payloads without allowing transform failures to escape.

     Missing fields retain Kotlin serializer defaults, so sparse historical payloads remain valid.
     A present known field with the wrong type or an invalid verse range defaults the entire object,
     matching Android's `PlaybackSettings.fromJson` catch boundary. The initializer never rethrows,
     which keeps SwiftData's transform decoder away from its historical nested-optional trap.
     */
    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init()
            decodedMalformedKnownField = true
            return
        }

        var malformed = false
        func required<Value: Decodable>(
            _ type: Value.Type,
            forKey key: CodingKeys,
            default defaultValue: Value
        ) -> Value {
            guard container.contains(key) else { return defaultValue }
            do {
                return try container.decode(type, forKey: key)
            } catch {
                malformed = true
                return defaultValue
            }
        }
        func optional<Value: Decodable>(_ type: Value.Type, forKey key: CodingKeys) -> Value? {
            guard container.contains(key) else { return nil }
            do {
                if try container.decodeNil(forKey: key) { return nil }
                return try container.decode(type, forKey: key)
            } catch {
                malformed = true
                return nil
            }
        }

        let speakChapterChanges = required(Bool.self, forKey: .speakChapterChanges, default: true)
        let speakTitles = required(Bool.self, forKey: .speakTitles, default: true)
        let speakFootnotes = required(Bool.self, forKey: .speakFootnotes, default: false)
        let speed = required(Int.self, forKey: .speed, default: 100)
        let bookId = optional(String.self, forKey: .bookId)
        let bookmarkWasCreated = optional(Bool.self, forKey: .bookmarkWasCreated)
        let verseRange: SpeakVerseRange?
        if !container.contains(.verseRange) || (try? container.decodeNil(forKey: .verseRange)) == true {
            verseRange = nil
        } else {
            let candidate: SpeakVerseRange?
            if let rawValue = try? container.decode(String.self, forKey: .verseRange) {
                guard let separator = rawValue.range(of: "::") else {
                    self.init()
                    decodedMalformedKnownField = true
                    return
                }
                let versification = String(rawValue[..<separator.lowerBound])
                let osisRef = String(rawValue[separator.upperBound...])
                guard !versification.isEmpty, VersificationMapper.supports(versification) else {
                    self.init()
                    decodedMalformedKnownField = true
                    return
                }
                candidate = osisRef.isEmpty
                    ? nil
                    : SpeakVerseRange(versification: versification, osisRef: osisRef)
            } else if let keyedValue = try? container.decode(
                SpeakVerseRange.self,
                forKey: .verseRange
            ) {
                guard VersificationMapper.supports(keyedValue.versification) else {
                    self.init()
                    decodedMalformedKnownField = true
                    return
                }
                candidate = keyedValue
            } else {
                malformed = true
                candidate = nil
            }
            verseRange = candidate?.validatedReferences() == nil ? nil : candidate
        }

        guard !malformed else {
            self.init()
            decodedMalformedKnownField = true
            return
        }
        self.init(
            speakChapterChanges: speakChapterChanges,
            speakTitles: speakTitles,
            speakFootnotes: speakFootnotes,
            speed: speed,
            bookId: bookId,
            bookmarkWasCreated: bookmarkWasCreated,
            verseRange: verseRange,
            isMemorizationLoop: false
        )
    }

    /**
     Encodes the SwiftData-safe local representation and omits runtime-only memorization state.

     Optional values are omitted instead of explicitly encoded as null because SwiftData's Codable
     transform decoder cannot reliably round-trip a null optional nested value. `verseRange` remains
     Android's primitive string on disk; `androidJSON()` supplies the explicit nulls required on the
     Android wire.
     */
    public func encode(to encoder: Encoder) throws {
        let value = normalized
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.speakChapterChanges, forKey: .speakChapterChanges)
        try container.encode(value.speakTitles, forKey: .speakTitles)
        try container.encode(value.speakFootnotes, forKey: .speakFootnotes)
        try container.encode(value.speed, forKey: .speed)
        try container.encodeIfPresent(value.bookId, forKey: .bookId)
        try container.encodeIfPresent(value.bookmarkWasCreated, forKey: .bookmarkWasCreated)
        if let verseRange = value.verseRange {
            try container.encode(verseRange.description, forKey: .verseRange)
        }
    }

    /// Playback value retained exactly as Android serialized it.
    public var normalized: PlaybackSettings {
        self
    }

    /** Compares persisted and runtime playback behavior while ignoring decoder bookkeeping. */
    public static func == (lhs: PlaybackSettings, rhs: PlaybackSettings) -> Bool {
        lhs.speakChapterChanges == rhs.speakChapterChanges
            && lhs.speakTitles == rhs.speakTitles
            && lhs.speakFootnotes == rhs.speakFootnotes
            && lhs.speed == rhs.speed
            && lhs.bookId == rhs.bookId
            && lhs.bookmarkWasCreated == rhs.bookmarkWasCreated
            && lhs.verseRange == rhs.verseRange
            && lhs.isMemorizationLoop == rhs.isMemorizationLoop
    }

    /**
     Decodes Android bookmark playback JSON with Kotlin-compatible fallback semantics.

     - Parameter json: Raw `PlaybackSettings` JSON.
     - Returns: Sparse valid fields plus defaults for omissions, or complete defaults when any known
       field or the root JSON is malformed.
     - Side effects: none.
     - Failure modes: Malformed known fields, malformed JSON, or a non-object root become complete
       defaults instead of throwing into SwiftData or restore callers.
     */
    public static func fromAndroidJSON(_ json: String) -> PlaybackSettings {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(PlaybackSettings.self, from: data) else {
            return PlaybackSettings()
        }
        return value.normalized
    }

    /**
     Encodes this playback payload for Android bookmark sync.

     - Returns: UTF-8 JSON with every persisted Android field.
     - Side effects: none.
     - Failure modes: Rethrows JSON encoding or UTF-8 conversion failures.
     */
    public func androidJSON() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: androidJSONObject, options: [.sortedKeys])
        guard let value = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: [], debugDescription: "PlaybackSettings JSON was not UTF-8")
            )
        }
        return value
    }

    /**
     Projects every persisted Android playback field into its exact JSON object representation.

     This shared projection keeps bookmark and workspace payloads aligned, including Android's
     explicit nullable metadata keys, while the ordinary `Codable` encoder remains SwiftData-safe.
     */
    var androidJSONObject: [String: Any] {
        let value = normalized
        return [
            CodingKeys.speakChapterChanges.rawValue: value.speakChapterChanges,
            CodingKeys.speakTitles.rawValue: value.speakTitles,
            CodingKeys.speakFootnotes.rawValue: value.speakFootnotes,
            CodingKeys.speed.rawValue: value.speed,
            CodingKeys.bookId.rawValue: value.bookId ?? NSNull(),
            CodingKeys.bookmarkWasCreated.rawValue: value.bookmarkWasCreated ?? NSNull(),
            CodingKeys.verseRange.rawValue: value.verseRange?.description ?? NSNull(),
        ]
    }

}

/**
 Enumerates the sort orders supported by bookmark queries and list UI.

 The raw values mirror Android parity strings so stored preferences and bridge state can be
 shared without translation.
 */
public enum BookmarkSortOrder: String, Codable, Sendable {
    case bibleOrder = "BIBLE_ORDER"
    case bibleOrderDesc = "BIBLE_ORDER_DESC"
    case createdAt = "CREATED_AT"
    case createdAtDesc = "CREATED_AT_DESC"
    case lastUpdated = "LAST_UPDATED"
    case orderNumber = "ORDER_NUMBER"
}

/**
 Persists a bookmark that targets Bible text using verse ordinals.

 Bible bookmarks store both module-local ordinals and KJVA ordinals. The module-local values
 preserve the exact original range in the source versification, while the KJVA values provide
 a stable cross-module comparison key for queries, labels, and sync. Related note and label
 junction rows are cascade-deleted with the bookmark.
 */
@Model
public final class BibleBookmark {
    /// Stable identifier used for persistence, label linking, and sync reconciliation.
    public var id: UUID = UUID()

    /// Start ordinal normalized into KJVA versification for cross-module queries.
    public var kjvOrdinalStart: Int = 0

    /// End ordinal normalized into KJVA versification for cross-module queries.
    public var kjvOrdinalEnd: Int = 0

    /// Start ordinal in the originating module's own versification.
    public var ordinalStart: Int = 0

    /// End ordinal in the originating module's own versification.
    public var ordinalEnd: Int = 0

    /// Raw versification identifier for the originating module.
    public var v11n: String = "KJVA"

    /// Module initials for the originating Bible document.
    public var bookInitials: String = ""

    /// Raw durable ordinal-trust state; old SwiftData rows default to pending migration.
    public var ordinalTrustStateRaw: String = PersistedOrdinalTrustState.legacyPendingModule.rawValue

    /// Mapping contract version that produced the persisted KJVA coordinates.
    public var ordinalMappingVersion: Int = 0

    /// Raw provenance identifier for the persisted KJVA coordinates.
    public var ordinalProvenanceRaw: String = PersistedOrdinalProvenance.unknown.rawValue

    /// Exact source versification retained for future mapping revisions.
    public var ordinalSourceVersification: String?

    /// Exact source-domain start ordinal retained for future mapping revisions.
    public var ordinalSourceStart: Int?

    /// Exact source-domain end ordinal retained for future mapping revisions.
    public var ordinalSourceEnd: Int?

    /// Optional book name captured at creation time for display and legacy lookup paths.
    public var book: String?

    /// Optional text-to-speech playback metadata for this bookmark.
    public var playbackSettings: PlaybackSettings?

    /// Creation timestamp used by sorting and export flows.
    public var createdAt: Date = Date()

    /// Character offset recorded for the start of a sub-verse selection, if any.
    public var startOffset: Int?

    /// Character offset recorded for the end of a sub-verse selection, if any.
    public var endOffset: Int?

    /// Cached primary label identifier used by fast list and renderer lookups.
    public var primaryLabelId: UUID?

    /// Timestamp of the last bookmark mutation.
    public var lastUpdatedOn: Date = Date()

    /// Indicates whether the bookmark covers a whole verse instead of a text span.
    public var wholeVerse: Bool = true

    /// Optional raw bookmark type string used by specialized features.
    public var type: String?

    /// Optional Android canonical icon name or older native icon identifier.
    public var customIcon: String?

    /// Optional AI prompt identifier that produced this bookmark on Android.
    public var sourcePromptId: UUID?

    /// Optional note-edit automation configuration.
    public var editAction: EditAction?

    /// Separate note payload entity owned by this bookmark and cascade-deleted with it.
    @Relationship(deleteRule: .cascade, inverse: \BibleBookmarkNotes.bookmark)
    public var notes: BibleBookmarkNotes?

    /// Many-to-many label junction rows owned by this bookmark.
    @Relationship(deleteRule: .cascade, inverse: \BibleBookmarkToLabel.bookmark)
    public var bookmarkToLabels: [BibleBookmarkToLabel]?

    /// Durable trust state decoded fail-closed from its persisted raw value.
    public var ordinalTrustState: PersistedOrdinalTrustState {
        get { PersistedOrdinalTrustState(rawValue: ordinalTrustStateRaw) ?? .legacyUnresolved }
        set { ordinalTrustStateRaw = newValue.rawValue }
    }

    /// Durable provenance decoded fail-closed from its persisted raw value.
    public var ordinalProvenance: PersistedOrdinalProvenance {
        get { PersistedOrdinalProvenance(rawValue: ordinalProvenanceRaw) ?? .unknown }
        set { ordinalProvenanceRaw = newValue.rawValue }
    }

    /// Complete trust metadata projected from the flattened SwiftData fields.
    public var ordinalTrustMetadata: PersistedOrdinalTrustMetadata {
        get {
            PersistedOrdinalTrustMetadata(
                state: ordinalTrustState,
                mappingVersion: ordinalMappingVersion,
                provenance: ordinalProvenance,
                sourceBookInitials: bookInitials.isEmpty ? nil : bookInitials,
                sourceVersification: ordinalSourceVersification,
                sourceOrdinalStart: ordinalSourceStart,
                sourceOrdinalEnd: ordinalSourceEnd
            )
        }
        set {
            ordinalTrustState = newValue.state
            ordinalMappingVersion = newValue.mappingVersion
            ordinalProvenance = newValue.provenance
            ordinalSourceVersification = newValue.sourceVersification
            ordinalSourceStart = newValue.sourceOrdinalStart
            ordinalSourceEnd = newValue.sourceOrdinalEnd
        }
    }

    /// Whether consumers may use this bookmark's persisted KJVA coordinates.
    public var hasTrustedPersistedOrdinals: Bool {
        PersistedOrdinalTrustPolicy.isTrustedKJVARange(
            metadata: ordinalTrustMetadata,
            start: kjvOrdinalStart,
            end: kjvOrdinalEnd
        )
    }

    /**
     Creates a Bible bookmark persistence record.

     - Parameters:
       - id: Stable identifier for persistence and sync.
       - kjvOrdinalStart: KJVA-normalized start ordinal.
       - kjvOrdinalEnd: KJVA-normalized end ordinal.
       - ordinalStart: Source-versification start ordinal.
       - ordinalEnd: Source-versification end ordinal.
       - v11n: Raw source versification identifier.
       - bookInitials: Source Bible module initials.
       - createdAt: Bookmark creation timestamp.
       - lastUpdatedOn: Timestamp of the latest mutation.
       - wholeVerse: Whether the bookmark covers an entire verse.
       - ordinalTrustMetadata: Explicit provenance supplied by a validated import, migration, or
         native mapping boundary. Omission classifies the row as legacy pending or unresolved.
     - Note: Optional metadata such as notes, labels, offsets, and playback settings are added
       after insertion by the owning service layer.
     - Failure modes: Raw numeric coordinates are retained for migration when trust is omitted,
       but consumers quarantine the row until exact source metadata is verified.
     */
    public init(
        id: UUID = UUID(),
        kjvOrdinalStart: Int = 0,
        kjvOrdinalEnd: Int = 0,
        ordinalStart: Int = 0,
        ordinalEnd: Int = 0,
        v11n: String = "KJVA",
        bookInitials: String = "",
        createdAt: Date = Date(),
        lastUpdatedOn: Date = Date(),
        wholeVerse: Bool = true,
        ordinalTrustMetadata: PersistedOrdinalTrustMetadata? = nil
    ) {
        self.id = id
        self.kjvOrdinalStart = kjvOrdinalStart
        self.kjvOrdinalEnd = kjvOrdinalEnd
        self.ordinalStart = ordinalStart
        self.ordinalEnd = ordinalEnd
        self.v11n = v11n
        self.bookInitials = bookInitials
        self.createdAt = createdAt
        self.lastUpdatedOn = lastUpdatedOn
        self.wholeVerse = wholeVerse
        self.ordinalTrustMetadata = ordinalTrustMetadata ?? PersistedOrdinalTrustPolicy.legacyMetadata(
            sourceBookInitials: bookInitials,
            sourceOrdinalStart: ordinalStart,
            sourceOrdinalEnd: ordinalEnd
        )
    }
}

/**
 Stores the note body for a `BibleBookmark` in a separate entity.

 The split keeps bookmark list queries lighter because note text does not need to be loaded
 unless the caller explicitly requests it. `contentType` mirrors Android's nullable
 `TextContentType` column so legacy rows can continue inheriting the current app setting while
 newly saved rows preserve whether their note text is HTML or Markdown.
 */
@Model
public final class BibleBookmarkNotes {
    /// Identifier mirroring the owning bookmark for the intended 1:1 relationship.
    public var bookmarkId: UUID = UUID()

    /// Back-reference to the owning Bible bookmark.
    public var bookmark: BibleBookmark?

    /// User-authored note text associated with the bookmark.
    public var notes: String = ""

    /// Optional Android `TextContentType` raw value (`HTML` or `MARKDOWN`) for the note body.
    public var contentType: String?

    /// Optional AI prompt identifier that produced this detached note on Android.
    public var sourcePromptId: UUID?

    /**
     Creates a note payload for a Bible bookmark.

     - Parameters:
       - bookmarkId: Identifier of the owning bookmark.
       - notes: Stored note body.
       - contentType: Optional Android `TextContentType` raw value; invalid non-nil row values are
         stored as `nil` so they keep Android's nullable inheritance semantics instead of becoming
         the app default.
     */
    public init(bookmarkId: UUID, notes: String = "", contentType: String? = nil) {
        self.bookmarkId = bookmarkId
        self.notes = notes
        self.contentType = AppPreferenceValueNormalizer.notesContentTypeRow(contentType)
    }
}

/**
 Joins a `BibleBookmark` to a `Label` for many-to-many bookmark labeling.

 The row also stores StudyPad ordering metadata so label-based bookmark views can preserve the
 user-defined outline order without mutating the bookmark itself.
 */
@Model
public final class BibleBookmarkToLabel {
    /// Owning bookmark side of the many-to-many label relationship.
    public var bookmark: BibleBookmark?

    /// Label side of the many-to-many bookmark relationship.
    public var label: Label?

    /// Display order within label-focused lists and StudyPad views.
    public var orderNumber: Int = -1

    /// Nesting level used by label/StudyPad outline rendering.
    public var indentLevel: Int = 0

    /// Whether child content for this row is expanded in StudyPad-like views.
    public var expandContent: Bool = true

    /**
     Creates a Bible bookmark-to-label junction row.

     - Parameters:
       - orderNumber: Display order within the label context.
       - indentLevel: Outline indentation level.
       - expandContent: Whether the row's content starts expanded.
     */
    public init(
        orderNumber: Int = -1,
        indentLevel: Int = 0,
        expandContent: Bool = true
    ) {
        self.orderNumber = orderNumber
        self.indentLevel = indentLevel
        self.expandContent = expandContent
    }
}

/**
 Persists a bookmark that targets non-Bible documents by module key rather than Bible ordinals.

 Generic bookmarks are used for dictionaries, commentaries, maps, EPUB content, and other
 keyed documents. They still keep ordinal and offset metadata when available so list ordering
 and partial-selection behavior can remain consistent across document categories.
 */
@Model
public final class GenericBookmark {
    /// Stable identifier used for persistence, label linking, and sync reconciliation.
    public var id: UUID = UUID()

    /// Canonical document key or OSIS-style reference for the bookmarked entry.
    public var key: String = ""

    /// Module initials for the bookmarked document.
    public var bookInitials: String = ""

    /// Creation timestamp used by sorting and export flows.
    public var createdAt: Date = Date()

    /// Start ordinal within the target document, or `nil` when Android stored no ordinal.
    public var ordinalStart: Int?

    /// End ordinal within the target document, or `nil` when Android stored no ordinal.
    public var ordinalEnd: Int?

    /// Inclusive character offset at the start of a partial selection, if any.
    public var startOffset: Int?

    /// Exclusive or terminal character offset at the end of a partial selection, if any.
    public var endOffset: Int?

    /// Cached primary label identifier used by fast list and renderer lookups.
    public var primaryLabelId: UUID?

    /// Timestamp of the last bookmark mutation.
    public var lastUpdatedOn: Date = Date()

    /// Indicates whether the bookmark covers the entire keyed entry instead of a text span.
    public var wholeVerse: Bool = true

    /// Optional text-to-speech playback metadata for this bookmark.
    public var playbackSettings: PlaybackSettings?

    /// Optional Android canonical icon name or older native icon identifier.
    public var customIcon: String?

    /// Optional AI prompt identifier that produced this bookmark on Android.
    public var sourcePromptId: UUID?

    /// Optional note-edit automation configuration.
    public var editAction: EditAction?

    /// Separate note payload entity owned by this bookmark and cascade-deleted with it.
    @Relationship(deleteRule: .cascade, inverse: \GenericBookmarkNotes.bookmark)
    public var notes: GenericBookmarkNotes?

    /// Many-to-many label junction rows owned by this bookmark.
    @Relationship(deleteRule: .cascade, inverse: \GenericBookmarkToLabel.bookmark)
    public var bookmarkToLabels: [GenericBookmarkToLabel]?

    /**
     Creates a generic bookmark persistence record.

     - Parameters:
       - id: Stable identifier for persistence and sync.
       - key: Canonical document key or OSIS-style reference.
       - bookInitials: Module initials for the target document.
       - createdAt: Bookmark creation timestamp.
       - ordinalStart: Start ordinal when the document exposes one.
       - ordinalEnd: End ordinal when the document exposes one.
       - lastUpdatedOn: Timestamp of the latest mutation.
       - wholeVerse: Whether the bookmark covers the entire entry.
     - Note: Optional metadata such as notes, labels, offsets, and playback settings are added
       after insertion by the owning service layer.
     */
    public init(
        id: UUID = UUID(),
        key: String = "",
        bookInitials: String = "",
        createdAt: Date = Date(),
        ordinalStart: Int? = nil,
        ordinalEnd: Int? = nil,
        lastUpdatedOn: Date = Date(),
        wholeVerse: Bool = true
    ) {
        self.id = id
        self.key = key
        self.bookInitials = bookInitials
        self.createdAt = createdAt
        self.ordinalStart = ordinalStart
        self.ordinalEnd = ordinalEnd
        self.lastUpdatedOn = lastUpdatedOn
        self.wholeVerse = wholeVerse
    }
}

/**
 Stores the note body for a `GenericBookmark` in a separate entity.

 Splitting the note payload keeps generic-bookmark list queries lighter until the caller needs
 the note body. The nullable `contentType` field mirrors Android so imported or synced notes
 retain the editor/rendering mode that was active when the note was first created.
 */
@Model
public final class GenericBookmarkNotes {
    /// Identifier mirroring the owning bookmark for the intended 1:1 relationship.
    public var bookmarkId: UUID = UUID()

    /// Back-reference to the owning generic bookmark.
    public var bookmark: GenericBookmark?

    /// User-authored note text associated with the bookmark.
    public var notes: String = ""

    /// Optional Android `TextContentType` raw value (`HTML` or `MARKDOWN`) for the note body.
    public var contentType: String?

    /// Optional AI prompt identifier that produced this detached note on Android.
    public var sourcePromptId: UUID?

    /**
     Creates a note payload for a generic bookmark.

     - Parameters:
       - bookmarkId: Identifier of the owning bookmark.
       - notes: Stored note body.
       - contentType: Optional Android `TextContentType` raw value; invalid non-nil row values are
         stored as `nil` so they keep Android's nullable inheritance semantics instead of becoming
         the app default.
     */
    public init(bookmarkId: UUID, notes: String = "", contentType: String? = nil) {
        self.bookmarkId = bookmarkId
        self.notes = notes
        self.contentType = AppPreferenceValueNormalizer.notesContentTypeRow(contentType)
    }
}

/**
 Joins a `GenericBookmark` to a `Label` for many-to-many bookmark labeling.

 The row mirrors `BibleBookmarkToLabel` so label-focused screens can sort and nest generic and
 Bible bookmarks using the same outline metadata.
 */
@Model
public final class GenericBookmarkToLabel {
    /// Owning bookmark side of the many-to-many label relationship.
    public var bookmark: GenericBookmark?

    /// Label side of the many-to-many bookmark relationship.
    public var label: Label?

    /// Display order within label-focused lists and StudyPad views.
    public var orderNumber: Int = -1

    /// Nesting level used by label/StudyPad outline rendering.
    public var indentLevel: Int = 0

    /// Whether child content for this row is expanded in StudyPad-like views.
    public var expandContent: Bool = true

    /**
     Creates a generic bookmark-to-label junction row.

     - Parameters:
       - orderNumber: Display order within the label context.
       - indentLevel: Outline indentation level.
       - expandContent: Whether the row's content starts expanded.
     */
    public init(
        orderNumber: Int = -1,
        indentLevel: Int = 0,
        expandContent: Bool = true
    ) {
        self.orderNumber = orderNumber
        self.indentLevel = indentLevel
        self.expandContent = expandContent
    }
}
