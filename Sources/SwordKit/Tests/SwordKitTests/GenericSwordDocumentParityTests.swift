import Foundation
import XCTest
@testable import SwordKit

/**
 Raw OSIS, dictionary chooser, and generic bookmark parity tests.

 The suite combines a real RawLD module with deterministic processor fixtures. A failure means an
 iOS generic document can lose source structure, accept SWORD's nearest key, or emit bookmark
 coordinates Android cannot round-trip.
 */
final class GenericSwordDocumentParityTests: XCTestCase {
    /**
     Verifies the native RawLD path preserves exact OSIS, dictionary metadata, and source identity.

     - Setup: Writes a real two-entry RawLD module using SWORD's documented `.dat`/`.idx` format.
     - Expected result: Orthography drives the chooser row, links remain OSIS, Greek feature/source
       metadata is present, and an ambiguous key cannot snap to a neighboring definition.
     - Failure meaning: Dictionary browsing can show the wrong definition or lose Android payload
       semantics before the reader bridge receives the fragment.
     */
    func testRawLDDictionaryLoadsExactAnchoredOSISAndRejectsNearestKey() throws {
        let fixture = try makeRawLDFixture(entries: [
            (
                "G0001",
                """
                <entryFree n="G0001"><orth>λόγος</orth><orth>word</orth><p id="definition">First <reference osisRef="John.1.1">John</reference>.</p><note>hidden note</note></entryFree>
                """
            ),
            ("G0002", "<entryFree n=\"G0002\"><orth>second</orth><p>Second entry.</p></entryFree>"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let module = try XCTUnwrap(manager.module(named: "RAWDICT"))
        let fragment = try module.rawOSISFragment(forKey: "G0001")
        let presentation = fragment.dictionaryEntryPresentation()

        XCTAssertEqual(presentation.key, "G0001")
        XCTAssertEqual(presentation.snippet, "λόγος - word")
        XCTAssertEqual(presentation.displayText, "G0001 - λόγος - word")
        XCTAssertEqual(fragment.key, "G0001")
        XCTAssertEqual(fragment.fragmentKey, "RAWDICT--G0001")
        XCTAssertEqual(fragment.source.initials, "RAWDICT")
        XCTAssertEqual(fragment.source.name, "Raw Dictionary Fixture")
        XCTAssertEqual(fragment.source.abbreviation, "RDF")
        XCTAssertEqual(fragment.source.category, .dictionary)
        XCTAssertEqual(fragment.source.language, "grc")
        XCTAssertEqual(fragment.features, ["type": "greek", "keyName": "G0001"])
        XCTAssertTrue(fragment.originalXML.contains("<reference"))
        XCTAssertTrue(fragment.originalXML.contains("osisRef=\"John.1.1\""))
        XCTAssertTrue(fragment.xml.contains("<BVA"))
        XCTAssertTrue(fragment.xml.contains("id=\"definition\""))

        XCTAssertThrowsError(try module.rawOSISFragment(forKey: "G0001X")) { error in
            guard case SwordRawOSISFragmentError.keyNotFound(let requested, _) = error else {
                return XCTFail("Expected exact-key rejection, received \(error)")
            }
            XCTAssertEqual(requested, "G0001X")
        }
    }

    /**
     Verifies generic SWORD key access enumerates exact keys and rejects nearest-key normalization.

     - Setup: Opens a real three-entry RawLD module and performs exact and neighboring-key lookups.
     - Expected result: Throwing enumeration returns source-order keys, exact lookup succeeds, and a
       key that SWORD could normalize to a neighbor returns false.
     - Failure meaning: Module switching can retain a key the target module does not actually own or
       convert a key-list read failure into an empty list.
     - Side effects: Creates and removes one temporary SWORD module root.
     */
    func testGenericModuleKeyAccessEnumeratesAndValidatesExactKeys() throws {
        let fixture = try makeRawLDFixture(entries: [
            ("E\u{301}", "<entryFree><p>Decomposed key.</p></entryFree>"),
            ("G0001", "<entryFree><p>First.</p></entryFree>"),
            ("G0002", "<entryFree><p>Second.</p></entryFree>"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let module = try XCTUnwrap(manager.module(named: "RAWDICT"))

        XCTAssertEqual(try module.loadAllKeys(), ["E\u{301}", "G0001", "G0002"])
        XCTAssertTrue(try module.containsExactKey("G0001"))
        XCTAssertTrue(try module.containsExactKey("G0002"))
        XCTAssertTrue(try module.containsExactKey("E\u{301}"))
        XCTAssertFalse(try module.containsExactKey("É"))
        XCTAssertFalse(try module.containsExactKey("G0001X"))
        XCTAssertFalse(try module.containsExactKey(""))
    }

    /**
     Verifies a module with no declared source type follows JSword's plain-text filter.

     - Setup: Writes a real RawLD entry whose literal text looks like an OSIS `orth` element but
       omits `SourceType`, which libsword otherwise reports internally as GBF.
     - Expected result: The markup-looking bytes remain escaped visible text and do not become a
       structural dictionary orthography node.
     - Failure meaning: iOS invents semantic XML that Android's default `PlainTextFilter` does not,
       changing chooser snippets, links, anchors, and bookmark text.
     */
    func testRawLDWithoutSourceTypeUsesJSwordPlainTextSemantics() throws {
        let fixture = try makeRawLDFixture(
            entries: [("PLAIN", "<orth>literal markup-looking text</orth>")],
            sourceTypeLine: nil
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let module = try XCTUnwrap(manager.module(named: "RAWDICT"))
        let fragment = try module.rawOSISFragment(forKey: "PLAIN")

        XCTAssertTrue(fragment.originalXML.contains("&lt;orth&gt;literal markup-looking text&lt;/orth&gt;"))
        XCTAssertFalse(fragment.originalXML.contains("<orth>"))
        XCTAssertEqual(fragment.dictionaryEntryPresentation().snippet, "<orth>literal markup-looking text</orth> ")
    }

    /**
     Verifies fragment identities use Android's `Key.uniqueId` contract without changing reload keys.

     Generic punctuation must be sanitized only in the DOM identity, while commentary passage keys
     use their intro-inclusive ordinal bounds. Mutating the exact source key would break reload;
     leaving punctuation in the fragment identity would diverge from Android/Vue selectors.
     */
    func testFragmentIdentityMatchesAndroidGenericAndPassageKeys() {
        XCTAssertEqual(
            SwordRawOSISIdentity.uniqueID(key: "article/one β", keyOrdinalRange: nil),
            "article_one_β"
        )
        XCTAssertEqual(
            SwordRawOSISIdentity.uniqueID(key: "Gen.1.2", keyOrdinalRange: 17...19),
            "ordinal-17-19"
        )
    }

    /**
     Verifies generic OSIS anchors preserve internal navigation and exclude note descendants.

     - Setup: Processes multi-root general-book source containing an annotation target, internal
       anchor, OSIS reference, and a note.
     - Expected result: Source nodes survive unchanged semantically, visible text receives ordered
       BVA anchors, and note text receives none.
     - Failure meaning: General-book/map links or selected-text bookmark reload can break even when
       the rendered prose still looks plausible.
     */
    func testGeneralBookProcessorPreservesRawLinksAndAnchorSemantics() throws {
        let processed = try SwordOSISFragmentProcessor.process(
            sourceXML: """
            <div annotateRef="Gen.1.1"><p>Before <a href="#section">jump</a>. <reference osisRef="John.1.1">John</reference></p><note>Do not anchor me.</note><p id="section">After.</p></div>
            """,
            category: .generalBook
        )

        XCTAssertEqual(processed.annotateRef, "Gen.1.1")
        XCTAssertTrue(processed.hasRenderableContent)
        XCTAssertFalse(processed.originalXML.contains("<BVA"))
        XCTAssertTrue(processed.xml.contains("href=\"#section\""))
        XCTAssertTrue(processed.xml.contains("id=\"section\""))
        XCTAssertTrue(processed.xml.contains("osisRef=\"John.1.1\""))
        XCTAssertTrue(processed.xml.contains("<note>Do not anchor me.</note>"))
        XCTAssertFalse(processed.xml.contains("<note><BVA"))
        XCTAssertEqual(processed.contentOrdinalRange, 0...(processed.anchorTexts.count - 1))
        XCTAssertEqual(
            processed.anchorTexts.keys.sorted().compactMap { processed.anchorTexts[$0] }.joined(),
            "Before jump. JohnAfter."
        )
    }

    /**
     Verifies commentary processing unwraps a direct verse while retaining its semantic children.

     A regression here would make equal linked commentary entries compare differently from Android
     because iOS would include a synthetic verse wrapper or compare rendered HTML.
     */
    func testCommentaryProcessorUnwrapsDirectVerseAndComputesSemanticText() throws {
        let processed = try SwordOSISFragmentProcessor.process(
            sourceXML: "<verse osisID=\"Gen.1.2\"><title>Heading</title><p>Same <hi type=\"bold\">body</hi>.</p></verse>",
            category: .commentary
        )

        XCTAssertFalse(processed.originalXML.contains("<verse"))
        XCTAssertTrue(processed.originalXML.contains("<title>Heading</title>"))
        XCTAssertTrue(processed.originalXML.contains("<hi type=\"bold\">body</hi>"))
        XCTAssertEqual(processed.comparablePlainText, "## Heading\n\nSame **body**.")
    }

    /**
     Verifies Android dictionary snippet extraction uses direct orthography and UTF-16 key cleanup.

     The emoji key is intentionally one Swift grapheme but two UTF-16 code units. A failure catches
     a native `String.count` shortcut that would remove the wrong prefix compared with Kotlin.
     */
    func testDictionarySnippetMatchesAndroidOrthographyAndUTF16PrefixRules() throws {
        let orthography = try SwordOSISFragmentProcessor.dictionarySnippet(
            xml: "<div><title>Ignore</title><entryFree><orth>alpha</orth><orth>beta</orth><p>body</p></entryFree></div>",
            key: "A"
        )
        let fallback = try SwordOSISFragmentProcessor.dictionarySnippet(
            xml: "<div><title>Ignore</title>😀X alpha\nbeta</div>",
            key: "😀X"
        )
        let firstTitleOnly = try SwordOSISFragmentProcessor.dictionarySnippet(
            xml: "<div><title>Ignore first</title><title>Keep second</title>A body</div>",
            key: "A"
        )
        let canonicallyEquivalentButNotExact = try SwordOSISFragmentProcessor.dictionarySnippet(
            xml: "<div>e\u{301} rest</div>",
            key: "é"
        )

        XCTAssertEqual(orthography, "alpha - beta")
        XCTAssertEqual(fallback, " alpha beta ")
        XCTAssertEqual(firstTitleOnly, "Keep secondA body ")
        XCTAssertEqual(canonicallyEquivalentButNotExact, "e\u{301} rest ")
    }

    /**
     Verifies Android's no-namespace chooser and anchor queries do not reinterpret prefixed nodes.

     JSword's JDOM calls use `getChild`/`removeChild` without a namespace, and its anchor XPath
     excludes only no-namespace `note` ancestors. Matching by local name would silently change
     namespaced dictionary rows and selected-text anchor ordinals.
     */
    func testNamespacedSourceNodesRemainOutsideAndroidNoNamespaceQueries() throws {
        let snippet = try SwordOSISFragmentProcessor.dictionarySnippet(
            xml: """
            <div xmlns:x="urn:test"><x:title>Keep title. </x:title><x:entryFree><x:orth>Keep orth.</x:orth></x:entryFree></div>
            """,
            key: "KEY"
        )
        let processed = try SwordOSISFragmentProcessor.process(
            sourceXML: """
            <x:note xmlns:x="urn:test">Namespaced note.</x:note><note>Plain note.</note>
            """,
            category: .generalBook
        )

        XCTAssertEqual(snippet, "Keep title. Keep orth. ")
        XCTAssertTrue(processed.xml.contains("<x:note xmlns:x=\"urn:test\"><BVA"))
        XCTAssertTrue(processed.xml.contains("<note>Plain note.</note>"))
        XCTAssertFalse(processed.xml.contains("<note><BVA"))
    }

    /**
     Verifies selected-text and whole-entry bookmark seeds preserve Android's nullable contract.

     Selected text must retain local BVA ordinals and paired UTF-16 offsets. A whole-entry bookmark
     must emit explicit nil ordinal endpoints and no offset range while keeping the exact source.
     */
    func testGenericBookmarkSeedsPreserveSelectionAndWholeEntryNullability() throws {
        let fragment = try makeFragment(
            sourceXML: "<p>First sentence. Second sentence.</p>",
            key: "article/one"
        )
        let selected = try fragment.genericSelectedTextBookmark(
            ordinalRange: fragment.contentOrdinalRange,
            startOffset: 2,
            endOffset: 9
        )
        let wholeAnchorSelection = try fragment.genericSelectedTextBookmark(
            ordinalRange: fragment.contentOrdinalRange,
            startOffset: 2,
            endOffset: 9,
            wholeVerse: true
        )
        let wholeEntry = fragment.genericWholeEntryBookmark()

        XCTAssertEqual(selected.ordinalRange, [0, fragment.contentOrdinalRange.upperBound])
        XCTAssertEqual(selected.offsetRange, [2, 9])
        XCTAssertFalse(selected.wholeVerse)
        XCTAssertEqual(selected.text, selected.fullText)
        XCTAssertEqual(selected.source.bookInitials, "RAWGENBOOK")
        XCTAssertEqual(selected.source.bookName, "Raw General Book Fixture")
        XCTAssertEqual(selected.source.bookAbbreviation, "RGB")
        XCTAssertEqual(selected.source.key, "article/one")
        XCTAssertEqual(selected.source.keyName, "Article One")
        XCTAssertEqual(selected.source.osisFragment, fragment)

        XCTAssertEqual(wholeAnchorSelection.startOffset, 2)
        XCTAssertEqual(wholeAnchorSelection.endOffset, 9)
        XCTAssertNil(wholeAnchorSelection.offsetRange)
        XCTAssertTrue(wholeAnchorSelection.wholeVerse)

        XCTAssertEqual(wholeEntry.ordinalRange.count, 2)
        XCTAssertNil(wholeEntry.ordinalRange[0])
        XCTAssertNil(wholeEntry.ordinalRange[1])
        XCTAssertNil(wholeEntry.offsetRange)
        XCTAssertTrue(wholeEntry.wholeVerse)
        XCTAssertEqual(wholeEntry.source.osisFragment, fragment)
    }

    /**
     Verifies invalid generic selection coordinates fail instead of leaking into another entry.

     An out-of-range ordinal or reversed offset could otherwise create a bookmark that Vue cannot
     highlight and that Android cannot reload against the source key.
     */
    func testGenericBookmarkSelectionRejectsForeignOrdinalsAndInvalidOffsets() throws {
        let fragment = try makeFragment(sourceXML: "<p>Selectable.</p>", key: "entry")

        XCTAssertThrowsError(
            try fragment.genericSelectedTextBookmark(
                ordinalRange: 0...(fragment.contentOrdinalRange.upperBound + 1),
                startOffset: 0,
                endOffset: 1
            )
        ) { error in
            guard case SwordGenericBookmarkContractError.ordinalRangeOutsideFragment = error else {
                return XCTFail("Expected ordinal validation, received \(error)")
            }
        }
        XCTAssertThrowsError(
            try fragment.genericSelectedTextBookmark(
                ordinalRange: fragment.contentOrdinalRange,
                startOffset: 9,
                endOffset: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? SwordGenericBookmarkContractError,
                .invalidOffsetRange(start: 9, end: 2)
            )
        }
    }

    /**
     Verifies malformed source XML is rejected instead of converted from rendered text.

     A fallback here would preserve visible words while silently losing links, source elements, and
     stable generic bookmark anchors.
     */
    func testMalformedRawOSISFailsWithoutRenderedTextFallback() {
        XCTAssertThrowsError(
            try SwordOSISFragmentProcessor.process(
                sourceXML: "<entryFree><orth>broken</entryFree>",
                category: .dictionary
            )
        )
    }

    /**
     Verifies namespace declarations, CDATA, comments, and processing instructions survive parsing.

     - Setup: Processes namespaced OSIS with adjacent ordinary text and CDATA plus non-rendered XML
       nodes that Foundation's streaming parser reports through separate callbacks.
     - Expected result: Namespace/source nodes remain structural, and CDATA is not silently converted
       into escaped ordinary text when another text callback follows it.
     - Failure meaning: A generic module can lose source semantics despite still displaying similar
       rendered prose.
     */
    func testProcessorPreservesNamespaceAndNonElementSourceNodes() throws {
        let processed = try SwordOSISFragmentProcessor.process(
            sourceXML: """
            <?osis-test preserve?><osis:div xmlns:osis="urn:osis"><osis:p><![CDATA[A < B]]> tail<!--source-comment--></osis:p></osis:div>
            """,
            category: .generalBook
        )

        XCTAssertTrue(processed.originalXML.contains("xmlns:osis=\"urn:osis\""))
        XCTAssertTrue(processed.originalXML.contains("<?osis-test preserve?>"))
        XCTAssertTrue(processed.originalXML.contains("<![CDATA[A < B]]> tail"))
        XCTAssertTrue(processed.originalXML.contains("<!--source-comment-->"))
        XCTAssertTrue(processed.xml.contains("<BVA"))
    }

    /**
     Verifies payload serialization performs Android's post-anchor HTML 4 unescape.

     - Setup: Supplies double-encoded HTML 4, numeric, unknown, and HTML5-only entities.
     - Expected result: Payload XML and bookmark anchor text decode only Android's supported set,
       while original chooser XML and commentary comparison text retain pre-serialization values.
     - Failure meaning: iOS can display encoded literals, shift anchor splitting, or decode source
       text Android preserves.
     */
    func testPayloadSerializationMatchesAndroidHTML4EntityUnescapeOrder() throws {
        let processed = try SwordOSISFragmentProcessor.process(
            sourceXML: """
            <p>&amp;quot;quoted&amp;quot; &amp;copy; &amp;#169; &amp;apos; &amp;NotEqualTilde;</p>
            """,
            category: .generalBook
        )

        XCTAssertTrue(processed.originalXML.contains("&amp;quot;quoted&amp;quot;"))
        XCTAssertEqual(
            processed.anchorTexts[0],
            "\"quoted\" © © &apos; &NotEqualTilde;"
        )
        XCTAssertTrue(processed.xml.contains("\"quoted\" © © &amp;apos; &amp;NotEqualTilde;"))
        XCTAssertTrue(processed.comparablePlainText?.contains("&quot;quoted&quot;") == true)
    }

    /**
     Verifies iOS applies the exact malformed-table repair Android's pinned JSword uses for `MapM`.

     - Setup: Supplies an entry beginning inside closing cell/row/table tags, the historical MapM
       shape handled by `OSISFilter`.
     - Expected result: `MapM` receives balanced table structure and anchors; another map module
       rejects the same malformed source instead of receiving a broad heuristic repair.
     - Failure meaning: MapM works on Android but fails to open on iOS, or repair leaks into unrelated
       malformed modules and silently changes their source semantics.
     */
    func testMapMReceivesOnlyAndroidSourceSpecificStructuralRepair() throws {
        let malformed = "Map content</cell></row></table>"
        let processed = try SwordOSISFragmentProcessor.process(
            sourceXML: malformed,
            category: .map,
            moduleInitials: "MapM"
        )

        XCTAssertTrue(processed.originalXML.contains("<table><row><cell>Map content</cell></row></table>"))
        XCTAssertTrue(processed.xml.contains("<BVA"))
        XCTAssertThrowsError(
            try SwordOSISFragmentProcessor.process(
                sourceXML: malformed,
                category: .map,
                moduleInitials: "OtherMap"
            )
        )
    }

    /** Builds an immutable general-book fragment through the production processor. */
    private func makeFragment(sourceXML: String, key: String) throws -> SwordRawOSISFragment {
        let processed = try SwordOSISFragmentProcessor.process(
            sourceXML: sourceXML,
            category: .generalBook
        )
        let source = SwordRawOSISSource(
            initials: "RAWGENBOOK",
            name: "Raw General Book Fixture",
            abbreviation: "RGB",
            category: .generalBook,
            language: "en",
            direction: "ltr",
            versification: "KJV",
            hasStrongs: false,
            moduleFeatures: []
        )
        let uniqueID = SwordRawOSISIdentity.uniqueID(key: key, keyOrdinalRange: nil)
        return SwordRawOSISFragment(
            xml: processed.xml,
            originalXML: processed.originalXML,
            key: key,
            keyName: "Article One",
            fragmentKey: "RAWGENBOOK--\(uniqueID)",
            osisRef: key,
            source: source,
            isNewTestament: false,
            features: [:],
            contentOrdinalRange: processed.contentOrdinalRange,
            keyOrdinalRange: nil,
            annotateRef: processed.annotateRef,
            anchorTexts: processed.anchorTexts,
            comparablePlainText: processed.comparablePlainText,
            hasRenderableContent: processed.hasRenderableContent
        )
    }

    /**
     Writes one real RawLD dictionary fixture using SWORD's six-byte little-endian index entries.

     - Parameter entries: Exact key and raw OSIS pairs, already in lexical key order.
     - Returns: Temporary SWORD root and module data prefix.
     - Side effects: Creates config, data, and index files in a unique temporary directory.
     - Failure modes: Propagates filesystem errors and rejects oversized test records.
     */
    private func makeRawLDFixture(
        entries: [(String, String)],
        sourceTypeLine: String? = "SourceType=OSIS"
    ) throws -> RawLDFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modsDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/lexdict/rawld/rawdict",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        var data = Data()
        var index = Data()
        for (key, xml) in entries {
            let record = Data("\(key)\r\n\(xml)".utf8)
            guard record.count <= Int(UInt16.max), data.count <= Int(UInt32.max) else {
                throw RawLDFixtureError.recordTooLarge
            }
            index.appendLittleEndian(UInt32(data.count))
            index.appendLittleEndian(UInt16(record.count))
            data.append(record)
            data.append(0x0A)
        }

        let prefix = dataDirectory.appendingPathComponent("rawdict", isDirectory: false)
        try data.write(to: prefix.appendingPathExtension("dat"))
        try index.write(to: prefix.appendingPathExtension("idx"))
        let sourceTypeConfiguration = sourceTypeLine.map { "\($0)\n" } ?? ""
        try """
        [RAWDICT]
        Description=Raw Dictionary Fixture
        Abbreviation=RDF
        Category=Lexicons / Dictionaries
        DataPath=./modules/lexdict/rawld/rawdict/rawdict
        ModDrv=RawLD
        \(sourceTypeConfiguration)Encoding=UTF-8
        Lang=grc
        Feature=GreekDef
        """.write(
            to: modsDirectory.appendingPathComponent("rawdict.conf", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        return RawLDFixture(root: root)
    }
}

/** Temporary real-module fixture returned to one test. */
private struct RawLDFixture {
    /// SWORD root containing `mods.d` and module data.
    let root: URL
}

/** Deterministic fixture-construction failures. */
private enum RawLDFixtureError: Error {
    case recordTooLarge
}

private extension Data {
    /** Appends one fixed-width integer in the byte order used by SWORD module files. */
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
