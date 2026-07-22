import Foundation

/**
 Exact commentary verse identity in the module's own versification.
 */
public struct SwordCommentaryVerseReference: Hashable, Sendable {
    /// OSIS book identifier.
    public let osisBookId: String
    /// One-based chapter.
    public let chapter: Int
    /// One-based verse.
    public let verse: Int
    /// Intro-inclusive SWORD/JSword ordinal.
    public let ordinal: Int
    /// Human-readable SWORD key name.
    public let name: String

    /// Canonical OSIS verse reference.
    public var osisRef: String { "\(osisBookId).\(chapter).\(verse)" }

    /**
     Creates an exact commentary verse value.

     - Parameters describe one verse in the commentary's own versification.
     - Side effects: None.
     - Failure modes: None; production callers construct values from validated SWORD metadata.
     */
    public init(
        osisBookId: String,
        chapter: Int,
        verse: Int,
        ordinal: Int,
        name: String
    ) {
        self.osisBookId = osisBookId
        self.chapter = chapter
        self.verse = verse
        self.ordinal = ordinal
        self.name = name
    }
}

/**
 Start/end metadata Android emits when commentary content spans consecutive verses.
 */
public struct SwordCommentaryRangeMetadata: Equatable, Sendable {
    /// First verse represented by the linked commentary block.
    public let start: SwordCommentaryVerseReference
    /// Last verse represented by the linked commentary block.
    public let end: SwordCommentaryVerseReference
    /// Human-readable range name.
    public let name: String
}

/**
 A run of consecutive verses with semantically identical commentary content.

 Empty selected verses remain a one-verse block with `fragment == nil`; they never snap to a
 neighboring entry. This is the behavior Android relies on for deterministic no-content rendering.
 */
public struct SwordCommentaryBlock: Equatable, Sendable {
    /// Inclusive source verse range.
    public let range: SwordCommentaryRangeMetadata
    /// Exact selected-entry fragment, or `nil` when the selected verse has no content.
    public let fragment: SwordRawOSISFragment?
}

/**
 Verse traversal and raw-fragment boundary used by the commentary block resolver.

 The protocol permits deterministic native doubles while production uses
 `SwordModuleCommentaryWalker`. All reads are exact-key reads; implementations must not return a
 nearest entry for a missing verse.
 */
public protocol SwordCommentaryWalking {
    /// Returns the next traversable verse, or `nil` at the Android document boundary.
    func next(after verse: SwordCommentaryVerseReference) -> SwordCommentaryVerseReference?
    /// Returns the previous traversable verse, or `nil` at the Android document boundary.
    func previous(before verse: SwordCommentaryVerseReference) -> SwordCommentaryVerseReference?
    /// Returns the exact verse's raw OSIS fragment, or throws if the module read fails.
    func fragment(for verse: SwordCommentaryVerseReference) throws -> SwordRawOSISFragment
}

/**
 Resolves linked/multi-verse commentary blocks and block-wise navigation exactly like Android's
 `CommentaryBlockResolver`.

 Comparison uses Android-compatible semantic plain text, not XML bytes, so per-verse OSIS metadata
 cannot split one linked block. Empty entries delimit blocks and are skipped only by previous/next
 navigation, never while resolving the currently selected verse.
 */
public final class SwordCommentaryBlockResolver {
    /// Production or test walker.
    private let walker: any SwordCommentaryWalking
    /// Per-resolver cache of non-empty rendered fragments.
    private var cache: [SwordCommentaryVerseReference: CachedEntry] = [:]

    /**
     Creates a resolver for one commentary navigation action.

     - Parameter walker: Exact verse traversal and raw-fragment provider.
     - Side effects: None.
     - Failure modes: None; per-verse read failures are treated as empty separators during use.
     */
    public init(walker: any SwordCommentaryWalking) {
        self.walker = walker
    }

    /**
     Expands the content block containing an interior verse.

     - Parameter verse: Selected commentary verse.
     - Returns: Inclusive block range and selected verse's fragment. Empty selections return a
       single-verse block with no fragment.
     - Side effects: Lazily reads and caches adjacent verse fragments.
     - Failure modes: Read/parsing failures are isolated as empty block separators, matching
       Android's per-verse exception handling.
     */
    public func resolveBlock(containing verse: SwordCommentaryVerseReference) -> SwordCommentaryBlock {
        guard case .content(let selectedFragment, let comparison) = cachedEntry(for: verse) else {
            return SwordCommentaryBlock(
                range: rangeMetadata(start: verse, end: verse),
                fragment: nil
            )
        }

        var start = verse
        while let candidate = walker.previous(before: start),
              cachedEntry(for: candidate).comparisonText == comparison {
            start = candidate
        }

        var end = verse
        while let candidate = walker.next(after: end),
              cachedEntry(for: candidate).comparisonText == comparison {
            end = candidate
        }

        return SwordCommentaryBlock(
            range: rangeMetadata(start: start, end: end),
            fragment: selectedFragment
        )
    }

    /**
     Finds the first non-empty commentary block after an inclusive block end.

     - Parameter blockEnd: End verse of the current resolved block.
     - Returns: Start verse of the next non-empty block, or `nil` at the document boundary.
     - Side effects: Lazily reads and caches traversed verses.
     - Failure modes: Read/parsing failures are treated as empty and skipped.
     */
    public func nextBlockStart(
        after blockEnd: SwordCommentaryVerseReference
    ) -> SwordCommentaryVerseReference? {
        var current = blockEnd
        while let candidate = walker.next(after: current) {
            if cachedEntry(for: candidate).comparisonText != nil { return candidate }
            current = candidate
        }
        return nil
    }

    /**
     Finds the start of the previous non-empty commentary block.

     - Parameter blockStart: Start verse of the current resolved block.
     - Returns: Previous block's first verse, or `nil` at the document boundary.
     - Side effects: Lazily reads and caches traversed verses.
     - Failure modes: Read/parsing failures are treated as empty and skipped.
     */
    public func previousBlockStart(
        before blockStart: SwordCommentaryVerseReference
    ) -> SwordCommentaryVerseReference? {
        var current = blockStart
        while let candidate = walker.previous(before: current) {
            if cachedEntry(for: candidate).comparisonText != nil {
                return resolveBlock(containing: candidate).range.start
            }
            current = candidate
        }
        return nil
    }

    /**
     Reads or returns the cached semantic entry for one verse.

     - Parameter verse: Exact verse.
     - Returns: Content only when the fragment's Android plain text is non-blank.
     - Side effects: Successful non-empty reads are cached. Empty/error reads are retried when a
       later walk revisits them, matching Kotlin `HashMap.getOrPut` with nullable values.
     - Failure modes: Any thrown read/parsing error becomes `.empty` for the current walk.
     */
    private func cachedEntry(for verse: SwordCommentaryVerseReference) -> CachedEntry {
        if let cached = cache[verse] { return cached }
        let entry: CachedEntry
        do {
            let fragment = try walker.fragment(for: verse)
            if let comparison = fragment.comparablePlainText, !comparison.isEmpty {
                entry = .content(fragment, comparison)
            } else {
                entry = .empty
            }
        } catch {
            entry = .empty
        }
        if case .content = entry {
            cache[verse] = entry
        }
        return entry
    }

    /**
     Builds a compact Android-style display name for a commentary range.

     - Parameters:
       - start: Inclusive start verse.
       - end: Inclusive end verse.
     - Returns: Single-verse name or a compact same-chapter/same-book range.
     - Side effects: None.
     - Failure modes: None.
     */
    private func rangeMetadata(
        start: SwordCommentaryVerseReference,
        end: SwordCommentaryVerseReference
    ) -> SwordCommentaryRangeMetadata {
        let name: String
        if start == end {
            name = start.name
        } else if start.osisBookId == end.osisBookId, start.chapter == end.chapter {
            name = "\(start.name)-\(end.verse)"
        } else if start.osisBookId == end.osisBookId {
            name = "\(start.name)-\(end.chapter):\(end.verse)"
        } else {
            name = "\(start.name)-\(end.name)"
        }
        return SwordCommentaryRangeMetadata(start: start, end: end, name: name)
    }
}

/** Cached content state that can retain a deliberate nil result. */
private enum CachedEntry {
    case empty
    case content(SwordRawOSISFragment, String)

    var comparisonText: String? {
        guard case .content(_, let text) = self else { return nil }
        return text
    }
}

/**
 Production commentary walker backed by one installed SWORD commentary module.

 Traversal mirrors Android's `BibleTraverser`: verses move within the active versification, book
 transitions are restricted to books detected in this document, and canonical Scripture is never
 crossed into or out of deuterocanonical material implicitly.
 */
public final class SwordModuleCommentaryWalker: SwordCommentaryWalking {
    /// Commentary module used for exact reads.
    private let module: SwordModule
    /// Android-compatible included-book inventory.
    private let books: [BookInfo]

    /**
     Creates a module-backed walker.

     - Parameter module: Installed commentary module.
     - Side effects: Computes the module's Android-compatible book inventory once.
     - Failure modes: None during initialization; non-commentary reads fail through
       `rawOSISFragment(forKey:)`.
     */
    public init(module: SwordModule) {
        self.module = module
        self.books = module.getBookList()
    }

    /**
     Resolves an exact initial commentary key.

     - Parameter keyText: OSIS or SWORD verse key.
     - Returns: Exact verse metadata.
     - Side effects: Performs one exact raw-fragment read.
     - Failure modes: Rethrows raw OSIS key/category/parsing errors.
     */
    public func reference(forKey keyText: String) throws -> SwordCommentaryVerseReference {
        let fragment = try module.rawOSISFragment(forKey: keyText)
        guard let range = fragment.keyOrdinalRange,
              let address = CommentaryAddress(osisRef: fragment.osisRef) else {
            throw SwordRawOSISFragmentError.invalidKey(keyText)
        }
        return SwordCommentaryVerseReference(
            osisBookId: address.osisBookId,
            chapter: address.chapter,
            verse: address.verse,
            ordinal: range.lowerBound,
            name: fragment.keyName
        )
    }

    /// Returns the next verse using Android's within-chapter and included-book traversal rules.
    public func next(
        after verse: SwordCommentaryVerseReference
    ) -> SwordCommentaryVerseReference? {
        guard let bookIndex = books.firstIndex(where: { $0.osisId == verse.osisBookId }),
              let verseMaximum = module.verseCount(
                osisBookId: verse.osisBookId,
                chapter: verse.chapter
              ) else {
            return nil
        }
        if verse.verse < verseMaximum {
            return reference(
                osisBookId: verse.osisBookId,
                chapter: verse.chapter,
                verse: verse.verse + 1
            )
        }
        if verse.chapter < books[bookIndex].chapterCount {
            return reference(osisBookId: verse.osisBookId, chapter: verse.chapter + 1, verse: 1)
        }

        let scripture = Self.isCanonicalScripture(verse.osisBookId)
        for candidate in books.dropFirst(bookIndex + 1)
            where Self.isCanonicalScripture(candidate.osisId) == scripture {
            if let reference = reference(osisBookId: candidate.osisId, chapter: 1, verse: 1) {
                return reference
            }
        }
        return nil
    }

    /// Returns the previous verse using Android's within-chapter and included-book traversal rules.
    public func previous(
        before verse: SwordCommentaryVerseReference
    ) -> SwordCommentaryVerseReference? {
        guard let bookIndex = books.firstIndex(where: { $0.osisId == verse.osisBookId }) else {
            return nil
        }
        if verse.verse > 1 {
            return reference(
                osisBookId: verse.osisBookId,
                chapter: verse.chapter,
                verse: verse.verse - 1
            )
        }
        if verse.chapter > 1,
           let previousChapterMaximum = module.verseCount(
            osisBookId: verse.osisBookId,
            chapter: verse.chapter - 1
           ) {
            return reference(
                osisBookId: verse.osisBookId,
                chapter: verse.chapter - 1,
                verse: previousChapterMaximum
            )
        }

        let scripture = Self.isCanonicalScripture(verse.osisBookId)
        for candidate in books[..<bookIndex].reversed()
            where Self.isCanonicalScripture(candidate.osisId) == scripture {
            guard let verseMaximum = module.verseCount(
                osisBookId: candidate.osisId,
                chapter: candidate.chapterCount
            ) else {
                continue
            }
            if let reference = reference(
                osisBookId: candidate.osisId,
                chapter: candidate.chapterCount,
                verse: verseMaximum
            ) {
                return reference
            }
        }
        return nil
    }

    /// Reads canonical raw OSIS for one exact commentary verse.
    public func fragment(
        for verse: SwordCommentaryVerseReference
    ) throws -> SwordRawOSISFragment {
        try module.rawOSISFragment(forKey: verse.osisRef)
    }

    /**
     Resolves one generated verse address without reading commentary content.

     - Parameters identify an exact verse.
     - Returns: Copied SWORD metadata, or `nil` if normalization/error occurs.
     - Side effects: Temporarily moves and restores the module cursor through the atomic inspector.
     - Failure modes: Returns `nil` for invalid or normalized keys.
     */
    private func reference(
        osisBookId: String,
        chapter: Int,
        verse: Int
    ) -> SwordCommentaryVerseReference? {
        let inspection = module.inspectVerseKeyAndRawEntryRestoringPrevious(
            "=\(osisBookId).\(chapter).\(verse)"
        )
        guard let children = inspection.verseKey,
              children.osisBookName == osisBookId,
              children.chapter == chapter,
              children.verse == verse else {
            return nil
        }
        return SwordCommentaryVerseReference(
            osisBookId: osisBookId,
            chapter: chapter,
            verse: verse,
            ordinal: children.index,
            name: children.shortText.isEmpty ? children.osisRef : children.shortText
        )
    }

    /**
     Matches Android `Scripture.isScripture` against the KJV 66-book canon.

     - Parameter osisBookId: Candidate OSIS book identifier.
     - Returns: `true` only for a KJV canonical book.
     - Side effects: None.
     - Failure modes: Unknown identifiers are treated as non-scriptural.
     */
    private static func isCanonicalScripture(_ osisBookId: String) -> Bool {
        AndroidScriptureBookScope.isScripture(osisBookId: osisBookId)
    }
}

/** Minimal OSIS parser for exact commentary references copied from fragment metadata. */
private struct CommentaryAddress {
    let osisBookId: String
    let chapter: Int
    let verse: Int

    init?(osisRef: String) {
        let components = osisRef.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let chapter = Int(components[1]),
              let verse = Int(components[2]),
              chapter > 0,
              verse > 0 else {
            return nil
        }
        self.osisBookId = String(components[0])
        self.chapter = chapter
        self.verse = verse
    }
}
