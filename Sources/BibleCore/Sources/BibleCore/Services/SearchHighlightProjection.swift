// SearchHighlightProjection.swift -- analyzer-bound visible Search emphasis

import Foundation

/** One emphasized half-open UTF-16 range inside a Search hit's plain preview. */
public struct SearchTextHighlightRange: Sendable, Equatable, Hashable {
    /// Zero-based UTF-16 offset into the unmodified preview.
    public let location: Int

    /// Positive UTF-16 length of the emphasized source range.
    public let length: Int

    /**
     Creates one plain-text emphasis range.

     - Parameters:
       - location: Zero-based UTF-16 offset in the source preview.
       - length: UTF-16 length; callers normally supply a positive value.
     - Side effects: None.
     - Failure modes: Values are retained verbatim; presentation validates them against the actual
       preview and ignores invalid ranges rather than slicing outside the string.
     */
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/** One source-preserving Search preview run with explicit query-derived emphasis. */
public struct SearchSnippetSegment: Sendable, Equatable {
    /// Original annotation-free preview text for this run.
    public let text: String

    /// Whether the active query matched this source run.
    public let isEmphasized: Bool

    /**
     Creates one immutable source-preserving preview run.

     - Parameters:
       - text: Exact annotation-free source substring for this run.
       - isEmphasized: Whether the active parsed query owns this complete source run.
     - Side effects: None.
     - Failure modes: None; empty text is retained so callers control segmentation policy.
     */
    public init(text: String, isEmphasized: Bool) {
        self.text = text
        self.isEmphasized = isEmphasized
    }
}

/** Positive Lucene clause retained for query-aware visible-text projection. */
enum SearchTextHighlightClause: Sendable, Equatable {
    /// One analyzer-normalized exact term.
    case term(String)

    /// One analyzer-normalized prefix term emitted by Lucene multi-term handling.
    case prefix(String)

    /// Ordered analyzer terms whose complete visible source span is emphasized.
    case phrase([String])
}

/**
 Immutable query presentation plan compiled by the same Lucene parser as the FTS expression.

 Prohibited clauses are absent. Exact terms and prefixes match the module's analyzer output, while
 phrases emphasize the complete source range spanning consecutive matching analyzer tokens.
 */
struct SearchTextHighlightPlan: Sendable, Equatable {
    /// Positive clauses in parsed query order.
    let clauses: [SearchTextHighlightClause]

    /**
     Resolves emphasized ranges in one annotation-free preview.

     - Parameters:
       - preview: Exact stored plain preview returned with the Search hit.
       - analyzer: Same persisted analyzer profile that authorized the FTS query.
     - Returns: Sorted, non-overlapping UTF-16 ranges; phrase ranges retain intervening source
       punctuation/spacing and overlapping clauses are merged.
     - Side effects: Lazily loads immutable analyzer resources.
     - Failure modes: Propagates analyzer resource failures. Empty/no-match previews return no
       ranges, and no substring is guessed outside analyzer token boundaries.
     */
    func ranges(
        in preview: String,
        analyzer: SearchAnalyzerProfile
    ) throws -> [SearchTextHighlightRange] {
        guard !preview.isEmpty, !clauses.isEmpty else { return [] }
        let tokens = try LuceneSearchAnalyzer.tokenSpans(preview, profile: analyzer)
        guard !tokens.isEmpty else { return [] }

        var ranges: [Range<Int>] = []
        for clause in clauses {
            switch clause {
            case .term(let term):
                ranges.append(contentsOf: tokens.lazy.filter { $0.term == term }.map(\.range))
            case .prefix(let prefix):
                ranges.append(contentsOf: tokens.lazy.filter { $0.term.hasPrefix(prefix) }.map(\.range))
            case .phrase(let phrase):
                guard !phrase.isEmpty, phrase.count <= tokens.count else { continue }
                for start in 0...(tokens.count - phrase.count) {
                    let candidate = tokens[start..<(start + phrase.count)]
                    guard candidate.map(\.term).elementsEqual(phrase) else { continue }
                    ranges.append(tokens[start].range.lowerBound..<tokens[start + phrase.count - 1].range.upperBound)
                }
            }
        }
        return Self.merged(ranges).map {
            SearchTextHighlightRange(location: $0.lowerBound, length: $0.count)
        }
    }

    /**
     Coalesces overlapping query ranges without joining separately matched adjacent words.

     - Parameter ranges: Unordered half-open UTF-16 ranges emitted by term/prefix/phrase clauses.
     - Returns: Sorted valid ranges with overlaps merged; empty and inverted ranges are omitted.
     - Side effects: None.
     - Failure modes: None; integer values are compared without touching source strings.
     */
    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges
            .filter { !$0.isEmpty && $0.lowerBound >= 0 }
            .sorted {
                $0.lowerBound == $1.lowerBound
                    ? $0.upperBound < $1.upperBound
                    : $0.lowerBound < $1.lowerBound
            }
        var result: [Range<Int>] = []
        for range in sorted {
            guard let last = result.last else {
                result.append(range)
                continue
            }
            if range.lowerBound < last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
