// SpeakTextProvider.swift -- Category-aware speech streams and transport

import Foundation
import SwordKit

/** Android transport distances used by the Speak widget. */
public enum SpeakRewindAmount: Sendable, Equatable {
    /// Keep the provider at its current stream unit.
    case none
    /// Move by exactly one provider unit.
    case oneUnit
    /// Move by a provider-defined semantic distance.
    case smart
}

/** Categories with distinct Android speech-provider behavior. */
public enum SpeakDocumentCategory: String, Codable, Sendable, Equatable {
    case bible
    case commentary
    case dictionary
    case generalBook
    case myDocument
    case memorization
    case selection
}

/** Content intentionally omitted by Android's OSIS speech handler. */
public enum SpeakExcludedContent: String, Sendable, Equatable {
    case crossReference
    case nonStudyNote
    case verseNumber
    case unsupportedMarkup
}

/**
 One semantic command in a provider stream.

 Text, heading, footnote, and announcement commands produce utterances. Pause and boundary commands
 preserve Android's command timing. Verse-number and excluded-content commands are retained for
 deterministic inspection but deliberately produce no speech.
 */
public enum SpeakCommand: Sendable, Equatable {
    case text(String)
    case heading(String)
    case footnote(String)
    case announcement(String)
    case pause(milliseconds: Int)
    case verseNumber(Int)
    case excluded(SpeakExcludedContent)

    /// Text sent to the platform speech engine, or `nil` for non-verbal commands.
    public var spokenText: String? {
        switch self {
        case .text(let value), .heading(let value), .footnote(let value), .announcement(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .pause, .verseNumber, .excluded:
            return nil
        }
    }
}

/**
 Stable position metadata owned by a speech provider.

 The position includes source-domain identity for transport and generic resume plus a verified KJVA
 boundary for Bible auto-bookmarks. It never derives generic keys from Bible coordinates.
 */
public struct SpeakStreamPosition: Sendable, Equatable, Hashable, Identifiable {
    /// Stable provider-local identity.
    public let id: String
    /// Provider category.
    public let category: SpeakDocumentCategory
    /// Exact source module initials.
    public let bookInitials: String
    /// Exact source key or OSIS reference.
    public let key: String
    /// Normalized OSIS verse reference when the source is verse keyed.
    public let osisRef: String?
    /// User-visible key title.
    public let keyName: String
    /// User-visible book/module name.
    public let bookName: String
    /// Inclusive source ordinal start when the document exposes ordinals.
    public let ordinalStart: Int?
    /// Inclusive source ordinal end when the document exposes ordinals.
    public let ordinalEnd: Int?
    /// One-based Bible chapter, when applicable.
    public let chapter: Int?
    /// One-based Bible verse, when applicable.
    public let verse: Int?
    /// Group identity used by chapter/key-aware smart transport.
    public let groupIdentifier: String
    /// BCP-47 source language.
    public let language: String
    /// Source versification for Bible positions.
    public let versification: String?
    /// Verified source-to-KJVA Bible bookmark coordinates.
    public let verifiedBibleRange: VerifiedKJVAOrdinalRange?

    /** Creates one provider position without performing persistence or module access. */
    public init(
        id: String,
        category: SpeakDocumentCategory,
        bookInitials: String,
        key: String,
        osisRef: String? = nil,
        keyName: String,
        bookName: String,
        ordinalStart: Int? = nil,
        ordinalEnd: Int? = nil,
        chapter: Int? = nil,
        verse: Int? = nil,
        groupIdentifier: String,
        language: String,
        versification: String? = nil,
        verifiedBibleRange: VerifiedKJVAOrdinalRange? = nil
    ) {
        self.id = id
        self.category = category
        self.bookInitials = bookInitials
        self.key = key
        self.osisRef = osisRef
        self.keyName = keyName
        self.bookName = bookName
        self.ordinalStart = ordinalStart
        self.ordinalEnd = ordinalEnd
        self.chapter = chapter
        self.verse = verse
        self.groupIdentifier = groupIdentifier
        self.language = language
        self.versification = versification
        self.verifiedBibleRange = verifiedBibleRange
    }
}

/** Persistable exact source cursor used for pause and stopped-play reconstruction. */
public struct SpeakStreamCursor: Codable, Sendable, Equatable, Hashable {
    /// Provider category owning the cursor.
    public let category: SpeakDocumentCategory
    /// Exact source module initials.
    public let bookInitials: String
    /// Exact document key.
    public let key: String
    /// Inclusive local source ordinal start.
    public let ordinalStart: Int?
    /// Inclusive local source ordinal end.
    public let ordinalEnd: Int?
    /// Source versification for Bible positions.
    public let versification: String?

    /** Creates an exact persisted cursor from source-domain values. */
    public init(
        category: SpeakDocumentCategory,
        bookInitials: String,
        key: String,
        ordinalStart: Int?,
        ordinalEnd: Int?,
        versification: String?
    ) {
        self.category = category
        self.bookInitials = bookInitials
        self.key = key
        self.ordinalStart = ordinalStart
        self.ordinalEnd = ordinalEnd
        self.versification = versification
    }

    /** Creates a stable cursor from provider-owned position metadata. */
    public init(position: SpeakStreamPosition) {
        category = position.category
        bookInitials = position.bookInitials
        key = position.key
        ordinalStart = position.ordinalStart
        ordinalEnd = position.ordinalEnd
        versification = position.versification
    }

    /**
     Returns whether this cursor identifies one exact provider position.

     Module initials use Java `String.equals` UTF-16 identity because Android persists and resolves
     speech cursors as Java strings; Swift's canonical Unicode equality must not authorize a
     composed spelling against a decomposed module owner.

     - Parameter position: Fresh provider-owned position to verify before reconstruction.
     - Returns: True only when category, Java-exact module initials, key, ordinals, and
       versification all match.
     - Side effects: None.
     - Failure modes: Any stale or Java-distinct field returns false without reading source text.
     */
    public func matches(_ position: SpeakStreamPosition) -> Bool {
        category == position.category
            && SwordJavaStringIdentity.equals(bookInitials, position.bookInitials)
            && key == position.key
            && ordinalStart == position.ordinalStart
            && ordinalEnd == position.ordinalEnd
            && versification == position.versification
    }
}

/**
 Exact progress within one audible provider command.

 Passage-list pause state records both the semantic command index and the UTF-16 position within its
 full text. The fraction mirrors Android's persisted legacy fraction and is validated against the
 exact offset before synthesis resumes.
 */
public struct SpeakPlaybackCursor: Codable, Sendable, Equatable, Hashable {
    /// Zero-based command index in the current `SpeakStreamUnit`.
    public let commandIndex: Int
    /// UTF-16 offset at which the current command must resume.
    public let characterOffset: Int
    /// Full UTF-16 length of the command text used to validate reconstruction.
    public let commandTextLength: Int
    /// Normalized progress through the full command text.
    public let characterFraction: Double

    /**
     Creates one exact command cursor without normalizing malformed values.

     - Parameters describe the command index, UTF-16 offset and length, and equivalent fraction.
     - Side effects: None.
     - Failure modes: Construction deliberately does not clamp values; version-2 reconstruction
       rejects inconsistent or out-of-range cursors before playback.
     */
    public init(
        commandIndex: Int,
        characterOffset: Int,
        commandTextLength: Int,
        characterFraction: Double
    ) {
        self.commandIndex = commandIndex
        self.characterOffset = characterOffset
        self.commandTextLength = commandTextLength
        self.characterFraction = characterFraction
    }
}

/**
 One semantic passage boundary persisted for Android legacy key-list reconstruction.

 Each passage retains the source range, its exact expanded target-module cursors, and the title that
 precedes its content. Keeping passages separate prevents overlapping or duplicated ranges from
 being widened into one first-to-last interval.
 */
public struct SpeakPassageCheckpoint: Codable, Sendable, Equatable, Hashable {
    /// Exact installed module initials used to materialize this passage.
    public let bookInitials: String
    /// Original source-versification range supplied by the caller.
    public let sourceRange: SpeakVerseRange
    /// Android-equivalent range title spoken before passage content.
    public let title: String
    /// Exact target-module positions belonging to this passage, in playback order.
    public let positions: [SpeakStreamCursor]

    /**
     Creates one semantic passage checkpoint without changing source or target identity.

     - Parameters:
       - bookInitials: Installed Bible used to materialize this passage.
       - sourceRange: Original range and versification supplied by the caller.
       - title: Range title emitted before passage content.
       - positions: Exact ordered target cursors belonging to this passage occurrence.
     - Side effects: None.
     - Failure modes: Construction does not normalize malformed metadata; version-2 reconstruction
       validates every field and fails closed.
     */
    public init(
        bookInitials: String,
        sourceRange: SpeakVerseRange,
        title: String,
        positions: [SpeakStreamCursor]
    ) {
        self.bookInitials = bookInitials
        self.sourceRange = sourceRange
        self.title = title
        self.positions = positions
    }
}

/** Complete provider checkpoint persisted when Android pauses or records the last Speak position. */
public struct SpeakProviderCheckpoint: Codable, Sendable, Equatable {
    /// Schema version: `0` is Android legacy state, `1` is one indexed stream, and `2` preserves semantic passages and playback progress.
    public let version: Int
    /// Exact current source cursor.
    public let current: SpeakStreamCursor
    /// Inclusive lower stream bound.
    public let lowerBound: SpeakStreamCursor
    /// Inclusive upper stream bound.
    public let upperBound: SpeakStreamCursor
    /// Whether exhaustion stops at `upperBound` instead of wrapping the whole collection.
    public let isBounded: Bool
    /// Whether the reconstructed provider must preserve memorization behavior.
    public let isMemorizationLoop: Bool
    /// Exact provider-order cursors for a bounded discontiguous stream, or `nil` for ordinary streams.
    public let orderedPositions: [SpeakStreamCursor]?
    /// Current zero-based index in `orderedPositions`, or `nil` when no ordered list is persisted.
    public let orderedPositionIndex: Int?
    /// Semantic ordered passage boundaries for version 2, or `nil` for legacy checkpoints.
    public let orderedPassages: [SpeakPassageCheckpoint]?
    /// Current passage occurrence in `orderedPassages`.
    public let currentPassageIndex: Int?
    /// Current verse occurrence within the selected passage.
    public let currentPositionIndexInPassage: Int?
    /// Exact audible command and character progress for version-2 pause reconstruction.
    public let playbackCursor: SpeakPlaybackCursor?

    /**
     Creates a versioned provider checkpoint.

     - Parameters:
       - version: Persisted schema version matching the supplied stream identity.
       - current: Exact current source cursor.
       - lowerBound: Inclusive lower stream bound.
       - upperBound: Inclusive upper stream bound.
       - isBounded: Whether playback stops at the upper bound.
       - isMemorizationLoop: Whether playback repeats as a memorization range.
       - orderedPositions: Deprecated pre-release queue shape retained only for backward decoding.
       - orderedPositionIndex: Deprecated pre-release flat queue index retained for decoding.
       - orderedPassages: Ordered semantic passage boundaries for version 2.
       - currentPassageIndex: Current passage occurrence for version 2.
       - currentPositionIndexInPassage: Current position occurrence within that passage.
       - playbackCursor: Exact command and character progress for version 2.
     - Side effects: None.
     - Failure modes: Construction does not validate cross-field consistency; provider-specific
       reconstruction validates the complete checkpoint before playback.
     */
    public init(
        version: Int = 1,
        current: SpeakStreamCursor,
        lowerBound: SpeakStreamCursor,
        upperBound: SpeakStreamCursor,
        isBounded: Bool,
        isMemorizationLoop: Bool,
        orderedPositions: [SpeakStreamCursor]? = nil,
        orderedPositionIndex: Int? = nil,
        orderedPassages: [SpeakPassageCheckpoint]? = nil,
        currentPassageIndex: Int? = nil,
        currentPositionIndexInPassage: Int? = nil,
        playbackCursor: SpeakPlaybackCursor? = nil
    ) {
        self.version = version
        self.current = current
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.isBounded = isBounded
        self.isMemorizationLoop = isMemorizationLoop
        self.orderedPositions = orderedPositions
        self.orderedPositionIndex = orderedPositionIndex
        self.orderedPassages = orderedPassages
        self.currentPassageIndex = currentPassageIndex
        self.currentPositionIndexInPassage = currentPositionIndexInPassage
        self.playbackCursor = playbackCursor
    }

    /**
     Returns the same semantic checkpoint with service-owned utterance progress attached.

     - Parameter cursor: Exact active command progress, or `nil` for legacy providers.
     - Returns: A value preserving every provider-owned identity and boundary field.
     - Side effects: None.
     - Failure modes: The method does not validate the cursor; version-2 reconstruction validates it
       against freshly materialized command text before speaking.
     */
    public func withPlaybackCursor(_ cursor: SpeakPlaybackCursor?) -> SpeakProviderCheckpoint {
        SpeakProviderCheckpoint(
            version: version,
            current: current,
            lowerBound: lowerBound,
            upperBound: upperBound,
            isBounded: isBounded,
            isMemorizationLoop: isMemorizationLoop,
            orderedPositions: orderedPositions,
            orderedPositionIndex: orderedPositionIndex,
            orderedPassages: orderedPassages,
            currentPassageIndex: currentPassageIndex,
            currentPositionIndexInPassage: currentPositionIndexInPassage,
            playbackCursor: cursor
        )
    }
}

/**
 One resolved passage segment supplied to the bounded Android key-list provider.

 Positions remain grouped by their original range so append, title emission, duplicate handling, and
 checkpoint reconstruction retain the caller's exact passage boundaries.
 */
public struct SpeakPassageSegment: Sendable, Equatable {
    /// Original source-versification passage range.
    public let sourceRange: SpeakVerseRange
    /// Android-equivalent title spoken before the segment.
    public let title: String
    /// Exact target-module positions for this segment.
    public let positions: [SpeakStreamPosition]

    /**
     Creates one semantic passage segment without flattening its original boundary.

     - Parameters:
       - sourceRange: Original range and versification represented by this segment.
       - title: Title emitted once before the segment's first position.
       - positions: Exact target positions in playback order.
     - Side effects: None.
     - Failure modes: Construction accepts empty input so callers can fail atomically; the passage
       provider rejects any empty segment during initialization and preparation.
     */
    public init(sourceRange: SpeakVerseRange, title: String, positions: [SpeakStreamPosition]) {
        self.sourceRange = sourceRange
        self.title = title
        self.positions = positions
    }
}

/** Typed native selection request preserving Android's source and ordinal domains. */
public struct SpeakSelectionRequest: Sendable, Equatable {
    /// Concrete source category selected in the reader.
    public let category: SpeakDocumentCategory
    /// Exact selected source module or MyDocument initials.
    public let bookInitials: String
    /// Exact source key or OSIS reference.
    public let key: String
    /// Inclusive source ordinal start.
    public let startOrdinal: Int
    /// Inclusive source ordinal end.
    public let endOrdinal: Int
    /// Source versification for Bible selections.
    public let versification: String?

    /** Creates a typed selection request without flattening it to display text. */
    public init(
        category: SpeakDocumentCategory,
        bookInitials: String,
        key: String,
        startOrdinal: Int,
        endOrdinal: Int,
        versification: String? = nil
    ) {
        self.category = category
        self.bookInitials = bookInitials
        self.key = key
        self.startOrdinal = startOrdinal
        self.endOrdinal = endOrdinal
        self.versification = versification
    }
}

/** Fully materialized provider unit ready for command playback. */
public struct SpeakStreamUnit: Sendable, Equatable {
    /// Stable source position represented by the unit.
    public let position: SpeakStreamPosition
    /// Ordered Android-style commands.
    public let commands: [SpeakCommand]

    /** Creates a materialized stream unit. */
    public init(position: SpeakStreamPosition, commands: [SpeakCommand]) {
        self.position = position
        self.commands = commands
    }
}

/** A bookmark shown by Android's "Speak from bookmark" picker. */
public struct SpeakResumeBookmark: Sendable, Equatable, Identifiable {
    /// Persisted bookmark identifier.
    public let id: UUID
    /// Provider position that must be reconstructed by the reader.
    public let position: SpeakStreamPosition
    /// Playback settings stored on the bookmark.
    public let playbackSettings: PlaybackSettings

    /** Creates one resume-picker row. */
    public init(id: UUID, position: SpeakStreamPosition, playbackSettings: PlaybackSettings) {
        self.id = id
        self.position = position
        self.playbackSettings = playbackSettings
    }
}

/**
 Bookmark persistence boundary used by `SpeakService`.

 Implementations own Android's Speak-label lifecycle. The service supplies only the provider's
 current source identity and complete playback settings, keeping persistence out of audio callbacks.
 */
public protocol SpeakBookmarkManaging: AnyObject {
    func playbackSettingsForSpeakBookmark(at position: SpeakStreamPosition) -> PlaybackSettings?
    func updateSpeakBookmarkPlaybackSettings(at position: SpeakStreamPosition, settings: PlaybackSettings)
    func persistSpeakBookmark(
        at position: SpeakStreamPosition,
        settings: PlaybackSettings,
        autoBookmark: Bool
    )
    func speakResumeBookmarks() -> [SpeakResumeBookmark]
}

/**
 Provider contract for Android-equivalent streaming and transport.

 Providers own stream position and semantic movement. `SpeakService` owns audio, timing, settings,
 and persistence callbacks. This split ensures commentary and generic transport never falls through
 Bible chapter navigation.
 */
public protocol SpeakTextProviding: AnyObject {
    var category: SpeakDocumentCategory { get }
    var currentPosition: SpeakStreamPosition? { get }
    var canAutoBookmark: Bool { get }
    var isMemorizationLoop: Bool { get }
    var supportsVerseRangeEditing: Bool { get }
    var resumePlaybackCursor: SpeakPlaybackCursor? { get }
    var availablePositions: [SpeakStreamPosition] { get }
    func prepare(settings: SpeakSettings) -> Bool
    func checkpoint() -> SpeakProviderCheckpoint?
    func didStart(command: SpeakCommand)
    func currentUnit(settings: SpeakSettings) -> SpeakStreamUnit?
    @discardableResult func advance(settings: SpeakSettings) -> Bool
    @discardableResult func rewind(_ amount: SpeakRewindAmount) -> Bool
    @discardableResult func forward(_ amount: SpeakRewindAmount) -> Bool
}

/** Optional provider capabilities default to disabled for non-Bible and historical providers. */
public extension SpeakTextProviding {
    /// Whether the active provider accepts Android's repeated Bible range mutation.
    var supportsVerseRangeEditing: Bool { false }

    /// Exact command progress supplied by a reconstructed semantic checkpoint, when applicable.
    var resumePlaybackCursor: SpeakPlaybackCursor? { nil }
}

/** Lazy unit loader used to keep large Bible and dictionary streams memory-bounded. */
public typealias SpeakStreamUnitLoader = (
    _ position: SpeakStreamPosition,
    _ settings: SpeakSettings,
    _ advancedSettings: AdvancedSpeakSettings
) -> [SpeakCommand]

/**
 Shared indexed provider implementation.

 It stores only position metadata and materializes text lazily. Subclasses override smart transport,
 transition announcements, and repetition without changing service or bridge behavior.
 */
open class IndexedSpeakTextProvider: SpeakTextProviding {
    public let category: SpeakDocumentCategory
    public let canAutoBookmark: Bool
    public let isMemorizationLoop: Bool
    public let supportsVerseRangeEditing: Bool

    /// Runtime advanced settings supplied by the coordinator when the provider was created.
    public var advancedSettings: AdvancedSpeakSettings

    internal var positions: [SpeakStreamPosition]
    internal let loader: SpeakStreamUnitLoader
    internal var configuredBounds: ClosedRange<Int>?
    internal var lowerBound: Int
    internal var upperBound: Int
    internal var activeBoundsAreBounded: Bool
    internal var currentIndex: Int
    internal var transitionOriginIndex: Int?
    internal var lastTitleIndex: Int?

    /** Positions in provider order, exposed for Android's Bible range editor and reconstruction. */
    public var availablePositions: [SpeakStreamPosition] { positions }

    /** Current provider position, or `nil` for an empty stream. */
    public var currentPosition: SpeakStreamPosition? {
        guard positions.indices.contains(currentIndex) else { return nil }
        return positions[currentIndex]
    }

    /// Ordinary indexed providers start at their current unit rather than a partial utterance cursor.
    open var resumePlaybackCursor: SpeakPlaybackCursor? { nil }

    /**
     Creates an indexed lazy provider.

     - Parameters:
       - category: Concrete document category.
       - positions: Stable source positions in provider order.
       - startIndex: Initial position index.
       - bounds: Optional inclusive bounded selection.
       - canAutoBookmark: Whether pause/stop may move the Speak bookmark.
       - isMemorizationLoop: Whether the stream always repeats and suppresses bookmarks.
       - supportsVerseRangeEditing: Whether repeated-range controls may mutate this provider.
       - advancedSettings: Global advanced settings used during command materialization.
       - loader: Lazy content-to-command adapter.
     - Side effects: none.
     - Failure modes: Empty or invalid bounds produce an empty provider rather than indexing out of range.
     */
    public init(
        category: SpeakDocumentCategory,
        positions: [SpeakStreamPosition],
        startIndex: Int,
        bounds: ClosedRange<Int>? = nil,
        canAutoBookmark: Bool,
        isMemorizationLoop: Bool = false,
        supportsVerseRangeEditing: Bool = false,
        advancedSettings: AdvancedSpeakSettings,
        loader: @escaping SpeakStreamUnitLoader
    ) {
        self.category = category
        self.positions = positions
        self.loader = loader
        self.canAutoBookmark = canAutoBookmark
        self.isMemorizationLoop = isMemorizationLoop
        self.supportsVerseRangeEditing = supportsVerseRangeEditing
        self.advancedSettings = advancedSettings
        configuredBounds = bounds
        activeBoundsAreBounded = bounds != nil
        lastTitleIndex = nil

        if positions.isEmpty {
            lowerBound = 0
            upperBound = -1
            currentIndex = 0
        } else {
            let requestedLower = bounds?.lowerBound ?? positions.startIndex
            let requestedUpper = bounds?.upperBound ?? (positions.endIndex - 1)
            lowerBound = min(max(requestedLower, positions.startIndex), positions.endIndex - 1)
            upperBound = min(max(requestedUpper, lowerBound), positions.endIndex - 1)
            currentIndex = min(max(startIndex, lowerBound), upperBound)
        }
    }

    /** Applies settings before playback or transport and restores configured stream bounds. */
    open func prepare(settings: SpeakSettings) -> Bool {
        _ = settings
        guard !positions.isEmpty else {
            lowerBound = 0
            upperBound = -1
            activeBoundsAreBounded = configuredBounds != nil
            return false
        }
        let requestedLower = configuredBounds?.lowerBound ?? positions.startIndex
        let requestedUpper = configuredBounds?.upperBound ?? (positions.endIndex - 1)
        guard setActiveBounds(
            requestedLower...requestedUpper,
            isBounded: configuredBounds != nil
        ) else {
            return false
        }
        return true
    }

    /** Captures exact current and bound identities for pause or stopped-play reconstruction. */
    open func checkpoint() -> SpeakProviderCheckpoint? {
        guard positions.indices.contains(currentIndex),
              positions.indices.contains(lowerBound),
              positions.indices.contains(upperBound) else {
            return nil
        }
        return SpeakProviderCheckpoint(
            current: SpeakStreamCursor(position: positions[currentIndex]),
            lowerBound: SpeakStreamCursor(position: positions[lowerBound]),
            upperBound: SpeakStreamCursor(position: positions[upperBound]),
            isBounded: activeBoundsAreBounded,
            isMemorizationLoop: isMemorizationLoop
        )
    }

    /** Records the source position of a title when its command actually starts. */
    open func didStart(command: SpeakCommand) {
        if case .heading = command {
            lastTitleIndex = currentIndex
        }
    }

    /** Lazily materializes the current unit and consumes any pending transition announcement. */
    open func currentUnit(settings: SpeakSettings) -> SpeakStreamUnit? {
        guard let position = currentPosition else { return nil }
        let origin = transitionOriginIndex.flatMap { positions.indices.contains($0) ? positions[$0] : nil }
        transitionOriginIndex = nil
        let content = loader(position, settings, advancedSettings)
        return SpeakStreamUnit(
            position: position,
            commands: transitionCommands(from: origin, to: position, settings: settings) + content
        )
    }

    /** Advances by one unit, wrapping unbounded collections and explicit repeating ranges. */
    @discardableResult
    open func advance(settings: SpeakSettings) -> Bool {
        guard upperBound >= lowerBound else { return false }
        let previous = currentIndex
        if currentIndex < upperBound {
            currentIndex += 1
            transitionOriginIndex = previous
            return true
        }
        guard shouldRepeat(settings: settings) || !activeBoundsAreBounded else { return false }
        currentIndex = lowerBound
        transitionOriginIndex = previous
        return true
    }

    /** Moves backward by one unit or the provider's smart distance. */
    @discardableResult
    open func rewind(_ amount: SpeakRewindAmount) -> Bool {
        let target: Int
        switch amount {
        case .none:
            target = currentIndex
        case .oneUnit:
            target = max(currentIndex - 1, lowerBound)
        case .smart:
            target = smartRewindIndex()
        }
        return move(to: target)
    }

    /** Moves forward by one unit or the provider's smart distance. */
    @discardableResult
    open func forward(_ amount: SpeakRewindAmount) -> Bool {
        let target: Int
        switch amount {
        case .none:
            target = currentIndex
        case .oneUnit:
            target = min(currentIndex + 1, upperBound)
        case .smart:
            target = smartForwardIndex()
        }
        return move(to: target)
    }

    /** Whether advancing past the upper bound wraps to the lower bound. */
    open func shouldRepeat(settings: SpeakSettings) -> Bool { false }

    /** Provider-specific commands emitted before content after a natural transition. */
    open func transitionCommands(
        from previous: SpeakStreamPosition?,
        to current: SpeakStreamPosition,
        settings: SpeakSettings
    ) -> [SpeakCommand] { [] }

    /** Default smart rewind prefers the most recently spoken title, then moves ten generic units. */
    open func smartRewindIndex() -> Int {
        if let lastTitleIndex,
           lastTitleIndex >= lowerBound,
           lastTitleIndex <= upperBound,
           lastTitleIndex != currentIndex {
            return lastTitleIndex
        }
        return max(currentIndex - 10, lowerBound)
    }

    /** Default smart forward mirrors Android's ten-unit generic forward. */
    open func smartForwardIndex() -> Int { min(currentIndex + 10, upperBound) }

    /** Applies one validated active range and clamps the current position into it. */
    @discardableResult
    internal func setActiveBounds(_ bounds: ClosedRange<Int>, isBounded: Bool) -> Bool {
        guard !positions.isEmpty else { return false }
        let normalizedLower = max(bounds.lowerBound, positions.startIndex)
        let normalizedUpper = min(bounds.upperBound, positions.endIndex - 1)
        guard normalizedLower <= normalizedUpper else {
            lowerBound = 0
            upperBound = -1
            return false
        }
        lowerBound = normalizedLower
        upperBound = normalizedUpper
        activeBoundsAreBounded = isBounded
        if currentIndex < lowerBound || currentIndex > upperBound {
            currentIndex = lowerBound
            transitionOriginIndex = nil
        }
        if let lastTitleIndex,
           lastTitleIndex < lowerBound || lastTitleIndex > upperBound {
            self.lastTitleIndex = nil
        }
        return true
    }

    @discardableResult
    private func move(to target: Int) -> Bool {
        guard upperBound >= lowerBound else { return false }
        let normalized = min(max(target, lowerBound), upperBound)
        let changed = normalized != currentIndex
        currentIndex = normalized
        transitionOriginIndex = nil
        if let lastTitleIndex, normalized < lastTitleIndex {
            self.lastTitleIndex = nil
        }
        return changed
    }
}

/** Bible provider with chapter-aware transport, announcements, and verse-range repetition. */
public final class BibleSpeakTextProvider: IndexedSpeakTextProvider {
    private let verseRangeResolver: (SpeakVerseRange) -> ClosedRange<Int>?

    /** Creates a Bible provider over lazily loaded verse positions. */
    public init(
        positions: [SpeakStreamPosition],
        startIndex: Int,
        bounds: ClosedRange<Int>? = nil,
        advancedSettings: AdvancedSpeakSettings,
        verseRangeResolver: @escaping (SpeakVerseRange) -> ClosedRange<Int>?,
        loader: @escaping SpeakStreamUnitLoader
    ) {
        self.verseRangeResolver = verseRangeResolver
        super.init(
            category: .bible,
            positions: positions,
            startIndex: startIndex,
            bounds: bounds,
            canAutoBookmark: bounds == nil,
            supportsVerseRangeEditing: true,
            advancedSettings: advancedSettings,
            loader: loader
        )
    }

    /** Applies an Android verse range as the provider's actual repeat boundary. */
    public override func prepare(settings: SpeakSettings) -> Bool {
        guard super.prepare(settings: settings) else { return false }
        guard let range = settings.playbackSettings.verseRange else { return true }
        guard let resolved = verseRangeResolver(range),
              setActiveBounds(resolved, isBounded: true) else {
            return false
        }
        return true
    }

    /**
     Tests the provider's requested start against one authoritative repeated range.

     - Parameter range: Android verse range in its declared source versification.
     - Returns: `true` only when strict range resolution succeeds and contains the requested start.
     - Side effects: Resolves range endpoints but does not mutate provider position or settings.
     - Failure modes: Unsupported, unmappable, or unaddressable ranges return `false` so default
       page Speak can clear stale repeated-passage state instead of jumping to it.
     */
    public func requestedStartIsInside(_ range: SpeakVerseRange) -> Bool {
        guard positions.indices.contains(currentIndex),
              let resolved = verseRangeResolver(range) else {
            return false
        }
        return resolved.contains(currentIndex)
    }

    public override func shouldRepeat(settings: SpeakSettings) -> Bool {
        settings.playbackSettings.verseRange != nil
    }

    public override func smartRewindIndex() -> Int {
        if let lastTitleIndex,
           lastTitleIndex >= lowerBound,
           lastTitleIndex <= upperBound,
           lastTitleIndex != currentIndex {
            return lastTitleIndex
        }
        guard positions.indices.contains(currentIndex) else { return currentIndex }
        let group = positions[currentIndex].groupIdentifier
        var firstInGroup = currentIndex
        while firstInGroup > lowerBound,
              positions[firstInGroup - 1].groupIdentifier == group {
            firstInGroup -= 1
        }
        if currentIndex > firstInGroup { return firstInGroup }
        guard firstInGroup > lowerBound else { return lowerBound }
        let previousGroup = positions[firstInGroup - 1].groupIdentifier
        var previousStart = firstInGroup - 1
        while previousStart > lowerBound,
              positions[previousStart - 1].groupIdentifier == previousGroup {
            previousStart -= 1
        }
        return previousStart
    }

    public override func smartForwardIndex() -> Int {
        guard positions.indices.contains(currentIndex) else { return currentIndex }
        let group = positions[currentIndex].groupIdentifier
        var next = currentIndex + 1
        while next <= upperBound, positions[next].groupIdentifier == group {
            next += 1
        }
        return min(next, upperBound)
    }

    public override func transitionCommands(
        from previous: SpeakStreamPosition?,
        to current: SpeakStreamPosition,
        settings: SpeakSettings
    ) -> [SpeakCommand] {
        var commands: [SpeakCommand] = []
        if let verse = current.verse {
            commands.append(.verseNumber(verse))
        }
        guard let previous else { return commands }
        let movedBackward = (current.ordinalStart ?? 0) < (previous.ordinalStart ?? 0)
        if !SwordJavaStringIdentity.equals(previous.bookInitials, current.bookInitials)
            || previous.bookName != current.bookName {
            let book = String(localized: "speak_book_changed", defaultValue: "Book")
            let chapter = String(localized: "speak_chapter_changed", defaultValue: "Chapter")
            commands.insert(.pause(milliseconds: 500), at: 0)
            commands.insert(.announcement("\(book) \(current.bookName) \(chapter) \(current.chapter ?? 1)."), at: 0)
        } else if previous.groupIdentifier != current.groupIdentifier {
            if settings.playbackSettings.speakChapterChanges {
                let chapter = String(localized: "speak_chapter_changed", defaultValue: "Chapter")
                commands.insert(.pause(milliseconds: 500), at: 0)
                commands.insert(.announcement("\(chapter) \(current.chapter ?? 1)."), at: 0)
            }
        } else if movedBackward {
            let chapter = String(localized: "speak_chapter_changed", defaultValue: "Chapter")
            commands.insert(.pause(milliseconds: 500), at: 0)
            commands.insert(.announcement("\(current.bookName) \(chapter) \(current.chapter ?? 1)."), at: 0)
        }
        return commands
    }
}

/**
 Mutable loader registry shared with the base provider's immutable loader closure.

 Registration occurs during provider construction or synchronous queue append; command lookup runs
 on the same serialized speech-service path. The unchecked sendability annotation permits capture by
 provider closures but does not make concurrent reads and writes safe.

 - Important: Callers must keep construction, append, and playback access serialized.
 - Failure modes: Unknown occurrence identifiers produce no commands and therefore fail as no
   speakable content rather than selecting a loader from another passage.
 */
private final class SpeakPassageLoaderRegistry: @unchecked Sendable {
    /// Position-specific loaders keyed by queue-occurrence identity.
    private var loaders: [String: SpeakStreamUnitLoader] = [:]

    /**
     Registers one loader for one unique queue occurrence.

     - Parameters:
       - loader: Passage-owned lazy command loader.
       - positionID: Occurrence-specific provider identifier.
     - Side effects: Replaces any existing in-memory loader under the same identifier.
     - Failure modes: No validation is performed; passage construction guarantees unique IDs before
       playback can access the registry.
     */
    func register(_ loader: @escaping SpeakStreamUnitLoader, for positionID: String) {
        loaders[positionID] = loader
    }

    /**
     Materializes commands through the loader that owns the supplied queue occurrence.

     - Parameters:
       - position: Exact queue occurrence whose loader must be selected.
       - settings: Effective playback settings supplied by the service.
       - advancedSettings: Current global speech behavior.
     - Returns: Ordered commands from the registered passage loader, or an empty list when the
       occurrence is unknown.
     - Side effects: The selected loader may read module text; registry state is not mutated.
     - Failure modes: Missing identifiers fail closed as no content instead of using another
       passage's loader.
     */
    func commands(
        for position: SpeakStreamPosition,
        settings: SpeakSettings,
        advancedSettings: AdvancedSpeakSettings
    ) -> [SpeakCommand] {
        loaders[position.id]?(position, settings, advancedSettings) ?? []
    }
}

/** Runtime passage metadata mapping one semantic segment to its flattened provider positions. */
private struct SpeakPassageRuntime {
    /// Original semantic segment used for checkpoint reconstruction and append.
    let segment: SpeakPassageSegment
    /// Inclusive flattened provider indexes owned by the segment.
    let positionRange: ClosedRange<Int>
}

/**
 Bounded Bible provider for Android reading-plan and legacy key-list speech.

 Unlike a normal Bible provider, the supplied semantic passages are the complete ordered playback
 queue and may contain gaps, overlaps, duplicates, or different source modules. Queue append retains
 every original boundary and loader while the current passage continues to own active playback.
 */
public final class BiblePassageListSpeakTextProvider: IndexedSpeakTextProvider {
    private var passageRuntimes: [SpeakPassageRuntime]
    private var passageLoaders: [SpeakStreamUnitLoader]
    private let loaderRegistry: SpeakPassageLoaderRegistry
    private let restoredPlaybackCursor: SpeakPlaybackCursor?

    /// Exact reconstructed command progress consumed by `SpeakService` on first playback.
    public override var resumePlaybackCursor: SpeakPlaybackCursor? { restoredPlaybackCursor }

    /**
     Creates one exact bounded Bible passage queue.

     - Parameters:
       - passages: Semantic target-module passage segments in playback order.
       - loaders: One lazy content loader per passage; loaders may belong to different modules.
       - startPassageIndex: Current semantic passage occurrence during reconstruction.
       - startPositionIndexInPassage: Current verse occurrence within that passage.
       - resumePlaybackCursor: Exact command/character progress restored from a version-2 checkpoint.
       - advancedSettings: Global speech behavior used during command materialization.
     - Side effects: Registers in-memory lazy loaders but performs no module reads or synthesis.
     - Failure modes: Count mismatches, empty passages, or invalid start indexes produce an empty
       provider that fails preparation rather than widening or partially accepting the queue.
     */
    public init(
        passages: [SpeakPassageSegment],
        loaders: [SpeakStreamUnitLoader],
        startPassageIndex: Int = 0,
        startPositionIndexInPassage: Int = 0,
        resumePlaybackCursor: SpeakPlaybackCursor? = nil,
        advancedSettings: AdvancedSpeakSettings
    ) {
        let registry = SpeakPassageLoaderRegistry()
        loaderRegistry = registry
        restoredPlaybackCursor = resumePlaybackCursor
        passageRuntimes = []
        passageLoaders = []

        let isValid = passages.count == loaders.count
            && !passages.isEmpty
            && passages.allSatisfy { !$0.positions.isEmpty }
            && passages.indices.contains(startPassageIndex)
            && passages[startPassageIndex].positions.indices.contains(startPositionIndexInPassage)
        var flattened: [SpeakStreamPosition] = []
        var runtimes: [SpeakPassageRuntime] = []
        if isValid {
            for (passageIndex, pair) in zip(passages.indices, zip(passages, loaders)) {
                let (segment, passageLoader) = pair
                let lowerBound = flattened.count
                for (positionIndex, position) in segment.positions.enumerated() {
                    let queued = Self.queueOccurrence(
                        position,
                        passageIndex: passageIndex,
                        positionIndex: positionIndex
                    )
                    flattened.append(queued)
                    registry.register(passageLoader, for: queued.id)
                }
                runtimes.append(
                    SpeakPassageRuntime(
                        segment: segment,
                        positionRange: lowerBound...(flattened.count - 1)
                    )
                )
            }
            passageRuntimes = runtimes
            passageLoaders = loaders
        }

        let startIndex = isValid
            ? runtimes[startPassageIndex].positionRange.lowerBound + startPositionIndexInPassage
            : 0
        let bounds = flattened.isEmpty ? nil : flattened.startIndex...(flattened.endIndex - 1)
        super.init(
            category: .bible,
            positions: flattened,
            startIndex: startIndex,
            bounds: bounds,
            canAutoBookmark: false,
            supportsVerseRangeEditing: false,
            advancedSettings: advancedSettings,
            loader: { position, settings, advancedSettings in
                registry.commands(
                    for: position,
                    settings: settings,
                    advancedSettings: advancedSettings
                )
            }
        )
    }

    /**
     Appends every semantic segment from another passage-list provider to the remaining queue.

     - Parameter provider: Newly resolved queue whose passages must follow the existing remainder.
     - Returns: `true` when at least one complete passage was appended.
     - Side effects: Extends provider positions and bounds without moving the current index, replacing
       the active loader, or changing the current speech generation.
     - Failure modes: Empty or internally inconsistent incoming providers are rejected atomically.
     */
    @discardableResult
    public func append(_ provider: BiblePassageListSpeakTextProvider) -> Bool {
        guard !provider.passageRuntimes.isEmpty,
              provider.passageRuntimes.count == provider.passageLoaders.count else {
            return false
        }
        let originalPositionCount = positions.count
        let originalPassageCount = passageRuntimes.count
        var appendedPositions: [SpeakStreamPosition] = []
        var appendedRuntimes: [SpeakPassageRuntime] = []

        for (offset, pair) in zip(
            provider.passageRuntimes.indices,
            zip(provider.passageRuntimes, provider.passageLoaders)
        ) {
            let (runtime, passageLoader) = pair
            guard !runtime.segment.positions.isEmpty else { return false }
            let passageIndex = originalPassageCount + offset
            let lowerBound = originalPositionCount + appendedPositions.count
            for (positionIndex, position) in runtime.segment.positions.enumerated() {
                let queued = Self.queueOccurrence(
                    position,
                    passageIndex: passageIndex,
                    positionIndex: positionIndex
                )
                appendedPositions.append(queued)
                loaderRegistry.register(passageLoader, for: queued.id)
            }
            appendedRuntimes.append(
                SpeakPassageRuntime(
                    segment: runtime.segment,
                    positionRange: lowerBound...(originalPositionCount + appendedPositions.count - 1)
                )
            )
        }
        guard !appendedPositions.isEmpty else { return false }
        positions.append(contentsOf: appendedPositions)
        passageRuntimes.append(contentsOf: appendedRuntimes)
        passageLoaders.append(contentsOf: provider.passageLoaders)
        configuredBounds = positions.startIndex...(positions.endIndex - 1)
        upperBound = positions.endIndex - 1
        activeBoundsAreBounded = true
        return true
    }

    /**
     Materializes one position while retaining its original passage boundary commands.

     - Parameter settings: Effective speech settings forwarded to the passage-owned content loader.
     - Returns: The base content with one title prepended at the passage start and a terminal
       500-millisecond separator appended at the passage end, or `nil` for invalid runtime state.
     - Side effects: Consumes any inherited transition state and may lazily read module text.
     - Failure modes: A missing position-to-passage mapping fails closed instead of emitting content
       without its semantic boundary.
     */
    public override func currentUnit(settings: SpeakSettings) -> SpeakStreamUnit? {
        guard let base = super.currentUnit(settings: settings),
              let runtime = passageRuntimes.first(where: { $0.positionRange.contains(currentIndex) }) else {
            return nil
        }
        var commands = base.commands
        if currentIndex == runtime.positionRange.lowerBound {
            commands.insert(.announcement(Self.punctuatedTitle(runtime.segment.title)), at: 0)
        }
        if currentIndex == runtime.positionRange.upperBound {
            commands.append(.pause(milliseconds: 500))
        }
        return SpeakStreamUnit(position: base.position, commands: commands)
    }

    /**
     Persists semantic passages and the exact current occurrence without flattening their boundaries.

     - Returns: Version-2 checkpoint without service-owned utterance progress, or `nil` for invalid
       runtime state. `SpeakService` attaches the exact command cursor before persistence.
     - Side effects: None.
     - Failure modes: Any empty passage, missing current occurrence, or invalid bounds fails closed.
     */
    public override func checkpoint() -> SpeakProviderCheckpoint? {
        guard let base = super.checkpoint(),
              let passageIndex = passageRuntimes.firstIndex(where: {
                  $0.positionRange.contains(currentIndex)
              }) else {
            return nil
        }
        let runtime = passageRuntimes[passageIndex]
        let positionIndex = currentIndex - runtime.positionRange.lowerBound
        let passages = passageRuntimes.map { runtime -> SpeakPassageCheckpoint in
            let passagePositions = Array(positions[runtime.positionRange])
            return SpeakPassageCheckpoint(
                bookInitials: passagePositions.first?.bookInitials ?? "",
                sourceRange: runtime.segment.sourceRange,
                title: runtime.segment.title,
                positions: passagePositions.map(SpeakStreamCursor.init(position:))
            )
        }
        guard passages.allSatisfy({ !$0.bookInitials.isEmpty && !$0.positions.isEmpty }) else {
            return nil
        }
        return SpeakProviderCheckpoint(
            version: 2,
            current: base.current,
            lowerBound: base.lowerBound,
            upperBound: base.upperBound,
            isBounded: true,
            isMemorizationLoop: false,
            orderedPassages: passages,
            currentPassageIndex: passageIndex,
            currentPositionIndexInPassage: positionIndex
        )
    }

    /**
     Creates a queue-occurrence identity while preserving every source-domain field.

     - Parameters:
       - position: Resolved source position to copy.
       - passageIndex: Zero-based semantic passage occurrence.
       - positionIndex: Zero-based position occurrence inside the passage.
     - Returns: A position whose unique ID distinguishes duplicates while all persistence and display
       fields remain unchanged.
     - Side effects: None.
     - Failure modes: Index validation belongs to provider construction; this helper performs no
       clamping or inference.
     */
    private static func queueOccurrence(
        _ position: SpeakStreamPosition,
        passageIndex: Int,
        positionIndex: Int
    ) -> SpeakStreamPosition {
        SpeakStreamPosition(
            id: "passage:\(passageIndex):\(positionIndex):\(position.id)",
            category: position.category,
            bookInitials: position.bookInitials,
            key: position.key,
            osisRef: position.osisRef,
            keyName: position.keyName,
            bookName: position.bookName,
            ordinalStart: position.ordinalStart,
            ordinalEnd: position.ordinalEnd,
            chapter: position.chapter,
            verse: position.verse,
            groupIdentifier: position.groupIdentifier,
            language: position.language,
            versification: position.versification,
            verifiedBibleRange: position.verifiedBibleRange
        )
    }

    /**
     Adds terminal punctuation once so range titles remain distinct utterances.

     - Parameter title: Caller-preserved original passage title.
     - Returns: A whitespace-trimmed title ending in sentence punctuation, or an empty string when
       the supplied title is empty.
     - Side effects: None.
     - Failure modes: Empty titles remain empty; strict resolver and provider construction prevent
       them from reaching persisted playback.
     */
    private static func punctuatedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?".contains(last) else { return trimmed }
        return trimmed + "."
    }
}

/** Android general-provider behavior shared by commentary, dictionary, and keyed documents. */
open class GeneralSpeakTextProvider: IndexedSpeakTextProvider {
    /** Creates a category-correct generic provider. */
    public init(
        category: SpeakDocumentCategory,
        positions: [SpeakStreamPosition],
        startIndex: Int,
        bounds: ClosedRange<Int>? = nil,
        advancedSettings: AdvancedSpeakSettings,
        loader: @escaping SpeakStreamUnitLoader
    ) {
        super.init(
            category: category,
            positions: positions,
            startIndex: startIndex,
            bounds: bounds,
            canAutoBookmark: bounds == nil,
            advancedSettings: advancedSettings,
            loader: loader
        )
    }

    public override func transitionCommands(
        from previous: SpeakStreamPosition?,
        to current: SpeakStreamPosition,
        settings: SpeakSettings
    ) -> [SpeakCommand] {
        guard let previous,
              previous.groupIdentifier != current.groupIdentifier,
              settings.playbackSettings.speakChapterChanges else { return [] }
        let chapter = String(localized: "speak_chapter_changed", defaultValue: "Chapter")
        return [.announcement("\(chapter) \(current.keyName)."), .pause(milliseconds: 500)]
    }
}

/** Commentary provider using Android's generic `BookAndKey` stream. */
public final class CommentarySpeakTextProvider: GeneralSpeakTextProvider {
    public init(
        positions: [SpeakStreamPosition],
        startIndex: Int,
        bounds: ClosedRange<Int>? = nil,
        advancedSettings: AdvancedSpeakSettings,
        loader: @escaping SpeakStreamUnitLoader
    ) {
        super.init(
            category: .commentary,
            positions: positions,
            startIndex: startIndex,
            bounds: bounds,
            advancedSettings: advancedSettings,
            loader: loader
        )
    }
}

/** Dictionary provider using exact dictionary keys and generic ordinals. */
public final class DictionarySpeakTextProvider: GeneralSpeakTextProvider {
    public init(
        positions: [SpeakStreamPosition],
        startIndex: Int,
        bounds: ClosedRange<Int>? = nil,
        advancedSettings: AdvancedSpeakSettings,
        loader: @escaping SpeakStreamUnitLoader
    ) {
        super.init(
            category: .dictionary,
            positions: positions,
            startIndex: startIndex,
            bounds: bounds,
            advancedSettings: advancedSettings,
            loader: loader
        )
    }
}

/** SWORD general-book or EPUB provider using exact persisted keys. */
public final class GeneralBookSpeakTextProvider: GeneralSpeakTextProvider {
    public init(
        positions: [SpeakStreamPosition],
        startIndex: Int,
        bounds: ClosedRange<Int>? = nil,
        advancedSettings: AdvancedSpeakSettings,
        loader: @escaping SpeakStreamUnitLoader
    ) {
        super.init(
            category: .generalBook,
            positions: positions,
            startIndex: startIndex,
            bounds: bounds,
            advancedSettings: advancedSettings,
            loader: loader
        )
    }
}

/** My Documents provider using persisted document initials and page keys. */
public final class MyDocumentSpeakTextProvider: GeneralSpeakTextProvider {
    public init(
        positions: [SpeakStreamPosition],
        startIndex: Int,
        bounds: ClosedRange<Int>? = nil,
        advancedSettings: AdvancedSpeakSettings,
        loader: @escaping SpeakStreamUnitLoader
    ) {
        super.init(
            category: .myDocument,
            positions: positions,
            startIndex: startIndex,
            bounds: bounds,
            advancedSettings: advancedSettings,
            loader: loader
        )
    }
}

/** Memorization provider that always repeats its bounded Bible stream and never bookmarks. */
public final class MemorizationSpeakTextProvider: IndexedSpeakTextProvider {
    public init(
        positions: [SpeakStreamPosition],
        startIndex: Int,
        bounds: ClosedRange<Int>,
        advancedSettings: AdvancedSpeakSettings,
        loader: @escaping SpeakStreamUnitLoader
    ) {
        super.init(
            category: .memorization,
            positions: positions,
            startIndex: startIndex,
            bounds: bounds,
            canAutoBookmark: false,
            isMemorizationLoop: true,
            advancedSettings: advancedSettings,
            loader: loader
        )
    }

    public override func shouldRepeat(settings: SpeakSettings) -> Bool { true }

    public override func transitionCommands(
        from previous: SpeakStreamPosition?,
        to current: SpeakStreamPosition,
        settings: SpeakSettings
    ) -> [SpeakCommand] {
        guard let previous,
              (current.ordinalStart ?? 0) < (previous.ordinalStart ?? 0) else {
            return current.verse.map { [.verseNumber($0)] } ?? []
        }
        return [.pause(milliseconds: 500), .pause(milliseconds: 500)]
            + (current.verse.map { [.verseNumber($0)] } ?? [])
    }
}

/** Single-selection provider retained for native text-selection speech. */
public final class SelectionSpeakTextProvider: IndexedSpeakTextProvider {
    /** Creates one non-bookmarking text-selection provider. */
    public init(text: String, language: String, repeatPlayback: Bool = false) {
        let position = SpeakStreamPosition(
            id: UUID().uuidString,
            category: .selection,
            bookInitials: "",
            key: "selection",
            keyName: "",
            bookName: "",
            groupIdentifier: "selection",
            language: language
        )
        super.init(
            category: .selection,
            positions: [position],
            startIndex: 0,
            bounds: 0...0,
            canAutoBookmark: false,
            isMemorizationLoop: repeatPlayback,
            advancedSettings: AdvancedSpeakSettings(),
            loader: { _, _, _ in [.text(text)] }
        )
    }

    public override func shouldRepeat(settings: SpeakSettings) -> Bool { isMemorizationLoop }
}
