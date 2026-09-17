import Foundation
import XCTest
@testable import SwordKit

/** Commentary block and block-navigation parity tests backed by an exact native walker double. */
final class SwordCommentaryBlockResolverTests: XCTestCase {
    /**
     Verifies opening an interior verse expands to the complete semantically identical block.

     Each linked verse has different XML metadata but the same Android plain text. Comparing XML
     would incorrectly split the block; comparing rendered text could erase source semantics.
     */
    func testInteriorVerseResolvesContainingMultiVerseCommentaryBlock() throws {
        let fixture = try CommentaryFixture.make()
        let resolver = SwordCommentaryBlockResolver(walker: fixture.walker)

        let block = resolver.resolveBlock(containing: fixture.references[2])

        XCTAssertEqual(block.range.start, fixture.references[1])
        XCTAssertEqual(block.range.end, fixture.references[3])
        XCTAssertEqual(block.range.name, "Genesis 1:2-4")
        XCTAssertEqual(block.fragment?.key, "Gen.1.3")
        XCTAssertEqual(block.fragment?.keyOrdinalRange, 3...3)
        XCTAssertEqual(block.fragment?.comparablePlainText, "Shared commentary")
    }

    /**
     Verifies previous/next commentary navigation moves by blocks and skips empty/error verses.

     The fixture places a deliberate empty verse between blocks and a throwing entry at the end.
     A failure means navigation can stop on a blank page or move to the middle/end of a linked block.
     */
    func testCommentaryNavigationSkipsEmptyEntriesAndReturnsBlockStarts() throws {
        let fixture = try CommentaryFixture.make()
        let resolver = SwordCommentaryBlockResolver(walker: fixture.walker)

        XCTAssertEqual(
            resolver.nextBlockStart(after: fixture.references[3]),
            fixture.references[5]
        )
        XCTAssertEqual(
            resolver.previousBlockStart(before: fixture.references[5]),
            fixture.references[1]
        )
        XCTAssertNil(resolver.nextBlockStart(after: fixture.references[5]))
    }

    /**
     Verifies an explicitly selected empty verse remains exact instead of snapping to nearby text.

     Android returns a one-verse empty block for the selected key. Only navigation skips empties.
     */
    func testSelectedEmptyCommentaryVerseReturnsExactSingleVerseBlock() throws {
        let fixture = try CommentaryFixture.make()
        let resolver = SwordCommentaryBlockResolver(walker: fixture.walker)

        let block = resolver.resolveBlock(containing: fixture.references[4])

        XCTAssertEqual(block.range.start, fixture.references[4])
        XCTAssertEqual(block.range.end, fixture.references[4])
        XCTAssertNil(block.fragment)
    }

    /**
     Verifies successful adjacent reads are cached while empty/error reads remain retryable.

     Android uses Kotlin `HashMap.getOrPut` with nullable values: non-empty projections are retained,
     but null results invoke the loader again. Matching that detail prevents a transient empty/error
     read from being pinned for the lifetime of one navigation action.
     */
    func testCommentaryResolverCachesContentAndRetriesEmptyResults() throws {
        let fixture = try CommentaryFixture.make()
        let resolver = SwordCommentaryBlockResolver(walker: fixture.walker)

        _ = resolver.resolveBlock(containing: fixture.references[2])
        _ = resolver.nextBlockStart(after: fixture.references[3])
        _ = resolver.previousBlockStart(before: fixture.references[5])
        _ = resolver.resolveBlock(containing: fixture.references[4])
        _ = resolver.resolveBlock(containing: fixture.references[6])
        _ = resolver.resolveBlock(containing: fixture.references[6])

        XCTAssertEqual(fixture.walker.readCounts[1], 1)
        XCTAssertEqual(fixture.walker.readCounts[2], 1)
        XCTAssertEqual(fixture.walker.readCounts[3], 1)
        XCTAssertEqual(fixture.walker.readCounts[4], 1)
        XCTAssertGreaterThan(fixture.walker.readCounts[5] ?? 0, 1)
        XCTAssertEqual(fixture.walker.readCounts[6], 1)
        XCTAssertEqual(fixture.walker.readCounts[7], 2)
    }

    /**
     Cancellation observed after one exact fragment read prevents every adjacent traversal/read.

     A native read already in progress completes and flips the operation-owned query. The resolver
     must then return an incomplete local value without walking either neighbor; the preparation
     coordinator remains responsible for discarding that value as cancellation.
     */
    func testCancellationAfterSelectedFragmentStopsAdjacentBlockReads() throws {
        let fixture = try CommentaryFixture.make()
        let cancellation = CommentaryCancellationFlag()
        let selectedOrdinal = fixture.references[2].ordinal
        fixture.walker.onFragmentRead = { ordinal in
            if ordinal == selectedOrdinal {
                cancellation.cancel()
            }
        }
        let resolver = SwordCommentaryBlockResolver(
            walker: fixture.walker,
            cancellationRequested: { cancellation.isCancelled }
        )

        let block = resolver.resolveBlock(containing: fixture.references[2])

        XCTAssertNil(block.fragment)
        XCTAssertEqual(block.range.start, fixture.references[2])
        XCTAssertEqual(block.range.end, fixture.references[2])
        XCTAssertEqual(fixture.walker.readCounts, [3: 1])
        XCTAssertEqual(fixture.walker.nextCount, 0)
        XCTAssertEqual(fixture.walker.previousCount, 0)
    }

    /** Sparse forward and reverse scans stop before a second entry after cancellation. */
    func testCancellationDuringSparseNavigationStopsBothScanDirections() throws {
        let forward = try CommentaryFixture.make()
        let forwardCancellation = CommentaryCancellationFlag()
        let forwardCancelOrdinal = forward.references[4].ordinal
        forward.walker.onFragmentRead = { ordinal in
            if ordinal == forwardCancelOrdinal {
                forwardCancellation.cancel()
            }
        }
        let forwardResolver = SwordCommentaryBlockResolver(
            walker: forward.walker,
            cancellationRequested: { forwardCancellation.isCancelled }
        )

        XCTAssertNil(forwardResolver.nextBlockStart(after: forward.references[3]))
        XCTAssertEqual(forward.walker.readCounts, [5: 1])
        XCTAssertEqual(forward.walker.nextCount, 1)

        let reverse = try CommentaryFixture.make()
        let reverseCancellation = CommentaryCancellationFlag()
        let reverseCancelOrdinal = reverse.references[4].ordinal
        reverse.walker.onFragmentRead = { ordinal in
            if ordinal == reverseCancelOrdinal {
                reverseCancellation.cancel()
            }
        }
        let reverseResolver = SwordCommentaryBlockResolver(
            walker: reverse.walker,
            cancellationRequested: { reverseCancellation.isCancelled }
        )

        XCTAssertNil(reverseResolver.previousBlockStart(before: reverse.references[5]))
        XCTAssertEqual(reverse.walker.readCounts, [5: 1])
        XCTAssertEqual(reverse.walker.previousCount, 1)
    }

    /** A current operation query preserves ordinary linked-block and navigation behavior. */
    func testCurrentCancellationQueryPreservesResolverOutput() throws {
        let fixture = try CommentaryFixture.make()
        let resolver = SwordCommentaryBlockResolver(
            walker: fixture.walker,
            cancellationRequested: { false }
        )

        let block = resolver.resolveBlock(containing: fixture.references[2])
        let previous = resolver.previousBlockStart(before: block.range.start)
        let next = resolver.nextBlockStart(after: block.range.end)

        XCTAssertEqual(block.range.start, fixture.references[1])
        XCTAssertEqual(block.range.end, fixture.references[3])
        XCTAssertEqual(previous, fixture.references[0])
        XCTAssertEqual(next, fixture.references[5])
    }
}

/** Deterministic seven-verse commentary fixture with linked, empty, and failed entries. */
private struct CommentaryFixture {
    /// Ordered exact references.
    let references: [SwordCommentaryVerseReference]
    /// Native walker double used by the resolver.
    let walker: CommentaryWalkerDouble

    /** Builds all raw fragments through the production OSIS processor. */
    static func make() throws -> CommentaryFixture {
        let references = (1...7).map { verse in
            SwordCommentaryVerseReference(
                osisBookId: "Gen",
                chapter: 1,
                verse: verse,
                ordinal: verse,
                name: "Genesis 1:\(verse)"
            )
        }
        let fragments: [Int: SwordRawOSISFragment] = [
            1: try fragment(for: references[0], body: "First block", marker: "first"),
            2: try fragment(for: references[1], body: "Shared commentary", marker: "start"),
            3: try fragment(for: references[2], body: "Shared commentary", marker: "interior"),
            4: try fragment(for: references[3], body: "Shared commentary", marker: "end"),
            5: try fragment(for: references[4], body: "", marker: "empty"),
            6: try fragment(for: references[5], body: "Next block", marker: "next"),
        ]
        return CommentaryFixture(
            references: references,
            walker: CommentaryWalkerDouble(
                references: references,
                fragmentsByOrdinal: fragments,
                failingOrdinals: [7]
            )
        )
    }

    /** Creates one exact commentary fragment with varying non-semantic XML metadata. */
    private static func fragment(
        for reference: SwordCommentaryVerseReference,
        body: String,
        marker: String
    ) throws -> SwordRawOSISFragment {
        let sourceXML = body.isEmpty
            ? "<verse osisID=\"\(reference.osisRef)\"/>"
            : "<verse osisID=\"\(reference.osisRef)\"><p type=\"\(marker)\">\(body)</p></verse>"
        let processed = try SwordOSISFragmentProcessor.process(
            sourceXML: sourceXML,
            category: .commentary
        )
        let source = SwordRawOSISSource(
            initials: "BLOCKCOMM",
            name: "Block Commentary Fixture",
            abbreviation: "BCF",
            category: .commentary,
            language: "en",
            direction: "ltr",
            versification: "KJV",
            hasStrongs: false,
            moduleFeatures: []
        )
        return SwordRawOSISFragment(
            xml: processed.xml,
            originalXML: processed.originalXML,
            key: reference.osisRef,
            keyName: reference.name,
            fragmentKey: "BLOCKCOMM--\(reference.osisRef)",
            osisRef: reference.osisRef,
            source: source,
            isNewTestament: false,
            features: [:],
            contentOrdinalRange: processed.contentOrdinalRange,
            keyOrdinalRange: reference.ordinal...reference.ordinal,
            annotateRef: processed.annotateRef,
            anchorTexts: processed.anchorTexts,
            comparablePlainText: processed.comparablePlainText,
            hasRenderableContent: processed.hasRenderableContent
        )
    }
}

/** Exact in-memory commentary walker used to isolate resolver behavior from binary module data. */
private final class CommentaryWalkerDouble: SwordCommentaryWalking {
    /// Ordered traversal domain.
    private let references: [SwordCommentaryVerseReference]
    /// Exact raw fragments keyed by source ordinal.
    private let fragmentsByOrdinal: [Int: SwordRawOSISFragment]
    /// Ordinals whose source read throws.
    private let failingOrdinals: Set<Int>
    /// Number of reads issued for each exact ordinal.
    private(set) var readCounts: [Int: Int] = [:]
    /// Number of forward traversal calls.
    private(set) var nextCount = 0
    /// Number of reverse traversal calls.
    private(set) var previousCount = 0
    /// Optional deterministic callback issued after one exact fragment read begins.
    var onFragmentRead: ((Int) -> Void)?

    /** Creates a deterministic exact-key walker. */
    init(
        references: [SwordCommentaryVerseReference],
        fragmentsByOrdinal: [Int: SwordRawOSISFragment],
        failingOrdinals: Set<Int>
    ) {
        self.references = references
        self.fragmentsByOrdinal = fragmentsByOrdinal
        self.failingOrdinals = failingOrdinals
    }

    /** Returns the next fixture verse. */
    func next(after verse: SwordCommentaryVerseReference) -> SwordCommentaryVerseReference? {
        nextCount += 1
        guard let index = references.firstIndex(of: verse), references.indices.contains(index + 1) else {
            return nil
        }
        return references[index + 1]
    }

    /** Returns the previous fixture verse. */
    func previous(before verse: SwordCommentaryVerseReference) -> SwordCommentaryVerseReference? {
        previousCount += 1
        guard let index = references.firstIndex(of: verse), index > references.startIndex else {
            return nil
        }
        return references[index - 1]
    }

    /** Reads only the requested fixture verse, recording cache evidence. */
    func fragment(for verse: SwordCommentaryVerseReference) throws -> SwordRawOSISFragment {
        readCounts[verse.ordinal, default: 0] += 1
        onFragmentRead?(verse.ordinal)
        if failingOrdinals.contains(verse.ordinal) {
            throw CommentaryWalkerDoubleError.fixtureReadFailure(verse.ordinal)
        }
        guard let fragment = fragmentsByOrdinal[verse.ordinal] else {
            throw CommentaryWalkerDoubleError.missingFixture(verse.ordinal)
        }
        return fragment
    }
}

/** Lock-backed cancellation state used by the resolver's cross-executor query contract. */
private final class CommentaryCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

/** Explicit native-double failures treated as empty commentary by the production resolver. */
private enum CommentaryWalkerDoubleError: Error {
    case fixtureReadFailure(Int)
    case missingFixture(Int)
}
