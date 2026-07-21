import Foundation

/**
 Validation failures for generic bookmark coordinates derived from one raw SWORD fragment.
 */
public enum SwordGenericBookmarkContractError: Error, Equatable, LocalizedError, Sendable {
    /// A selected-text ordinal lies outside the fragment's local `BVA` domain.
    case ordinalRangeOutsideFragment(requested: ClosedRange<Int>, available: ClosedRange<Int>)
    /// A selected-text offset pair is negative or reversed.
    case invalidOffsetRange(start: Int, end: Int)
    /// The fragment has no anchored text from which a selected-text bookmark can be created.
    case fragmentHasNoSelectableText

    /// Human-readable validation diagnostic.
    public var errorDescription: String? {
        switch self {
        case .ordinalRangeOutsideFragment(let requested, let available):
            return "Generic bookmark ordinals \(requested) are outside fragment range \(available)."
        case .invalidOffsetRange(let start, let end):
            return "Generic bookmark offsets must be nonnegative and ordered; received \(start)...\(end)."
        case .fragmentHasNoSelectableText:
            return "The generic document entry has no selectable anchored text."
        }
    }
}

/**
 Android-equivalent source identity attached to a selected-text or whole-entry generic bookmark.

 This value deliberately carries the immutable raw fragment. A later bridge/persistence adapter can
 project it into `ClientGenericBookmark` without consulting the active Bible or reloading a nearest
 SWORD key.
 */
public struct SwordGenericBookmarkSource: Equatable, Sendable {
    /// Originating module initials.
    public let bookInitials: String
    /// Originating module display name.
    public let bookName: String
    /// Originating module abbreviation.
    public let bookAbbreviation: String
    /// Exact module key used to reload the entry.
    public let key: String
    /// Human-readable key name.
    public let keyName: String
    /// Immutable raw OSIS and anchor metadata for rendering/reload.
    public let osisFragment: SwordRawOSISFragment
}

/**
 Generic bookmark creation data matching Android's nullable Room and client payload contract.

 Selected-text bookmarks contain local `BVA` ordinals and a complete persisted UTF-16 offset pair.
 Their client `offsetRange` is null when `wholeVerse` is true, matching Android without discarding the
 stored selection. Whole-entry bookmarks contain nil ordinal endpoints, nil offsets, and `wholeVerse`
 true. Source identity always comes from the exact loaded fragment.
 */
public struct SwordGenericBookmarkSeed: Equatable, Sendable {
    /// Android `GenericBookmark.ordinalStart` value.
    public let ordinalStart: Int?
    /// Android `GenericBookmark.ordinalEnd` value.
    public let ordinalEnd: Int?
    /// Android `GenericBookmark.startOffset` value.
    public let startOffset: Int?
    /// Android `GenericBookmark.endOffset` value.
    public let endOffset: Int?
    /// Android whole-range flag, named `wholeVerse` for schema compatibility across document types.
    public let wholeVerse: Bool
    /// Text covered by the selected local ordinals, or all anchored text for a whole entry.
    public let text: [String]
    /// All anchored text in the exact source entry.
    public let fullText: [String]
    /// Exact source module, key, and raw fragment metadata.
    public let source: SwordGenericBookmarkSource

    /// Client `ordinalRange`, retaining explicit nil endpoints for whole-entry bookmarks.
    public var ordinalRange: [Int?] { [ordinalStart, ordinalEnd] }

    /// Client `offsetRange`; Android emits null when whole-range or when no complete text range exists.
    public var offsetRange: [Int?]? {
        guard !wholeVerse, let startOffset, let endOffset else { return nil }
        return [startOffset, endOffset]
    }
}

public extension SwordRawOSISFragment {
    /**
     Builds an Android generic bookmark for a selected span in this exact fragment.

     - Parameters:
       - ordinalRange: Inclusive local `BVA` range emitted by the rendered fragment.
       - startOffset: UTF-16 start offset emitted by the client.
       - endOffset: UTF-16 end offset emitted by the client.
       - wholeVerse: Whether styling should cover complete anchors rather than the offset span.
     - Returns: Nullable persistence/client coordinates plus exact source metadata.
     - Side effects: None.
     - Failure modes: Throws when the fragment has no selectable text, ordinals escape this exact
       entry, or offsets are negative/reversed.
     */
    func genericSelectedTextBookmark(
        ordinalRange: ClosedRange<Int>,
        startOffset: Int,
        endOffset: Int,
        wholeVerse: Bool = false
    ) throws -> SwordGenericBookmarkSeed {
        guard !anchorTexts.isEmpty else {
            throw SwordGenericBookmarkContractError.fragmentHasNoSelectableText
        }
        guard contentOrdinalRange.contains(ordinalRange.lowerBound),
              contentOrdinalRange.contains(ordinalRange.upperBound),
              ordinalRange.allSatisfy({ anchorTexts[$0] != nil }) else {
            throw SwordGenericBookmarkContractError.ordinalRangeOutsideFragment(
                requested: ordinalRange,
                available: contentOrdinalRange
            )
        }
        guard startOffset >= 0, endOffset >= startOffset else {
            throw SwordGenericBookmarkContractError.invalidOffsetRange(
                start: startOffset,
                end: endOffset
            )
        }

        return SwordGenericBookmarkSeed(
            ordinalStart: ordinalRange.lowerBound,
            ordinalEnd: ordinalRange.upperBound,
            startOffset: startOffset,
            endOffset: endOffset,
            wholeVerse: wholeVerse,
            text: text(in: ordinalRange),
            fullText: text(in: contentOrdinalRange),
            source: genericBookmarkSource
        )
    }

    /**
     Builds Android's whole-page generic bookmark for this exact module key.

     - Returns: A bookmark seed with `[nil, nil]` ordinals, null offsets, `wholeVerse` true, and
       exact source metadata.
     - Side effects: None.
     - Failure modes: None; Android permits whole-page bookmarks for empty keyed entries.
     */
    func genericWholeEntryBookmark() -> SwordGenericBookmarkSeed {
        SwordGenericBookmarkSeed(
            ordinalStart: nil,
            ordinalEnd: nil,
            startOffset: nil,
            endOffset: nil,
            wholeVerse: true,
            text: text(in: contentOrdinalRange),
            fullText: text(in: contentOrdinalRange),
            source: genericBookmarkSource
        )
    }

    /// Exact source projection shared by both Android bookmark creation modes.
    private var genericBookmarkSource: SwordGenericBookmarkSource {
        SwordGenericBookmarkSource(
            bookInitials: source.initials,
            bookName: source.name,
            bookAbbreviation: source.abbreviation,
            key: key,
            keyName: keyName,
            osisFragment: self
        )
    }
}
