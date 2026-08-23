import XCTest
@testable import BibleCore
@testable import SwordKit

/** Protects analyzer-bound, source-preserving Search preview emphasis. */
final class SearchHighlightProjectionTests: XCTestCase {
    /**
     Verifies adding source offsets does not change any pinned analyzer term stream.

     - Setup: Runs representative simple, stemmed, Arabic/Persian, Greek/Hebrew, Thai, and CJK
       source through both production analyzer entry points.
     - Expected result: Terms remain identical and every emitted range selects nonempty source text.
     - Failure meaning: Highlight support changed indexed/query tokens or emitted unsafe UTF-16 spans.
     - Side effects: Lazily loads the same pinned analyzer resources used by Search indexing.
     */
    func testAnalyzerTokenSpansPreserveTermsAcrossEveryProfileFamily() throws {
        let fixtures: [(String, String)] = [
            ("en", "Étoile created"),
            ("de", "Häusern laufen"),
            ("ar", "السَّلَام"),
            ("fa", "کتاب‌ها"),
            ("el", "Λόγος ἀρχή"),
            ("he", "בְּרֵאשִׁית ברא"),
            ("th", "พระเจ้าทรงรักโลก"),
            ("zh", "起初神创造天地"),
        ]

        for (language, source) in fixtures {
            let profile = SearchTextAnalyzer.profile(for: language)
            let spans = try LuceneSearchAnalyzer.tokenSpans(source, profile: profile)
            XCTAssertEqual(
                spans.map(\.term),
                try SearchTextAnalyzer.analyzedTokens(source, profile: profile),
                "Analyzer terms changed for \(language)"
            )
            let units = Array(source.utf16)
            XCTAssertTrue(spans.allSatisfy {
                $0.range.lowerBound >= 0
                    && $0.range.upperBound <= units.count
                    && !$0.range.isEmpty
                    && !String(decoding: units[$0.range], as: UTF16.self).isEmpty
            })
        }
    }

    /**
     Verifies ordinary, prefix, Unicode-folded, and repeated matches use analyzer token boundaries.

     - Setup: Compiles the production any-word query `etoile crea*` for the simple analyzer and
       applies it to accented/mixed-case visible text with two prefix matches.
     - Expected result: `Étoile`, `CREATURE`, and `created` are emphasized from original source.
     - Failure meaning: UI emphasis drifted from FTS analyzer normalization or guesses substrings.
     - Side effects: Lazily loads pinned simple-analyzer tables.
     */
    func testOrdinaryAndPrefixClausesEmphasizeOriginalUnicodeSource() throws {
        let analyzer = SearchTextAnalyzer.profile(for: "en")
        let compiled = try SearchQueryCompiler.compileWithHighlightPlan(
            query: "etoile crea*",
            wordMode: .anyWord,
            analyzer: analyzer
        )
        let preview = "Étoile and CREATURE; created twice, created."
        let ranges = try compiled.highlightPlan.ranges(in: preview, analyzer: analyzer)
        let units = Array(preview.utf16)

        XCTAssertEqual(
            ranges.map {
                String(decoding: units[$0.location..<($0.location + $0.length)], as: UTF16.self)
            },
            ["Étoile", "CREATURE", "created", "created"]
        )
    }

    /**
     Verifies phrases retain punctuation while prohibited and absent clauses stay unstyled.

     - Setup: Compiles a phrase across an em dash, a Boolean query containing `NOT`, and an absent
       ordinary term.
     - Expected result: The phrase is one complete visible range; only the positive Boolean term is
       emphasized; the absent term produces no range.
     - Failure meaning: Phrase presentation is fragmented or unmatched/negative terms are bolded.
     - Side effects: Lazily loads pinned simple-analyzer tables.
     */
    func testPhraseAndProhibitedClausePresentationMatchesParsedLuceneTree() throws {
        let analyzer = SearchTextAnalyzer.profile(for: "en")
        let preview = "a burning—bush grows; faith without works"
        let units = Array(preview.utf16)
        let phrase = try SearchQueryCompiler.compileWithHighlightPlan(
            query: "burning bush",
            wordMode: .phrase,
            analyzer: analyzer
        )
        let phraseRanges = try phrase.highlightPlan.ranges(in: preview, analyzer: analyzer)
        XCTAssertEqual(phraseRanges.count, 1)
        XCTAssertEqual(
            phraseRanges.map {
                String(decoding: units[$0.location..<($0.location + $0.length)], as: UTF16.self)
            },
            ["burning—bush"]
        )

        let boolean = try SearchQueryCompiler.compileWithHighlightPlan(
            query: "faith NOT works",
            wordMode: .anyWord,
            analyzer: analyzer
        )
        let booleanRanges = try boolean.highlightPlan.ranges(in: preview, analyzer: analyzer)
        XCTAssertEqual(
            booleanRanges.map {
                String(decoding: units[$0.location..<($0.location + $0.length)], as: UTF16.self)
            },
            ["faith"]
        )

        let noMatch = try SearchQueryCompiler.compileWithHighlightPlan(
            query: "unseen",
            wordMode: .allWords,
            analyzer: analyzer
        )
        XCTAssertEqual(try noMatch.highlightPlan.ranges(in: preview, analyzer: analyzer), [])
    }

    /**
     Verifies Search hit segmentation preserves supplementary Unicode and accessibility identity.

     - Setup: Places a matched word after an emoji and supplies its UTF-16 range.
     - Expected result: Runs reconstruct the exact preview and emphasize only the requested word.
     - Failure meaning: Swift character indexing was mixed with Android/SQLite UTF-16 offsets.
     - Side effects: None.
     */
    func testHitSegmentsPreserveUTF16RangesAfterSupplementaryScalars() {
        let preview = "✨ God created"
        let location = (preview as NSString).range(of: "God").location
        let hit = SearchModuleHit(
            moduleName: "KJV",
            key: "Gen.1.1",
            displayBook: "Genesis",
            snippet: preview,
            highlightRanges: [SearchTextHighlightRange(location: location, length: 3)],
            identity: SearchVerseIdentity(
                osisBookId: "Gen",
                canonicalBookOrder: 0,
                chapter: 1,
                verse: 1
            )
        )

        XCTAssertEqual(hit.snippetSegments.map(\.text).joined(), preview)
        XCTAssertEqual(
            hit.snippetSegments.filter(\.isEmphasized).map(\.text),
            ["God"]
        )

        let malformed = SearchModuleHit(
            moduleName: "KJV",
            key: "Gen.1.1",
            displayBook: "Genesis",
            snippet: preview,
            highlightRanges: [SearchTextHighlightRange(location: Int.max, length: 1)],
            identity: hit.identity
        )
        XCTAssertEqual(malformed.snippetSegments, [
            SearchSnippetSegment(text: preview, isEmphasized: false),
        ])
    }
}
