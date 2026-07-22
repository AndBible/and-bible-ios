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
        guard let index = references.firstIndex(of: verse), references.indices.contains(index + 1) else {
            return nil
        }
        return references[index + 1]
    }

    /** Returns the previous fixture verse. */
    func previous(before verse: SwordCommentaryVerseReference) -> SwordCommentaryVerseReference? {
        guard let index = references.firstIndex(of: verse), index > references.startIndex else {
            return nil
        }
        return references[index - 1]
    }

    /** Reads only the requested fixture verse, recording cache evidence. */
    func fragment(for verse: SwordCommentaryVerseReference) throws -> SwordRawOSISFragment {
        readCounts[verse.ordinal, default: 0] += 1
        if failingOrdinals.contains(verse.ordinal) {
            throw CommentaryWalkerDoubleError.fixtureReadFailure(verse.ordinal)
        }
        guard let fragment = fragmentsByOrdinal[verse.ordinal] else {
            throw CommentaryWalkerDoubleError.missingFixture(verse.ordinal)
        }
        return fragment
    }
}

/** Explicit native-double failures treated as empty commentary by the production resolver. */
private enum CommentaryWalkerDoubleError: Error {
    case fixtureReadFailure(Int)
    case missingFixture(Int)
}
