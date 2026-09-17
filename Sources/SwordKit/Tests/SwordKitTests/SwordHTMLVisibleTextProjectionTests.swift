import XCTest

@testable import SwordKit

/** Protects the pinned Android 37 TagSoup/Html.fromHtml plain-visible projection boundary. */
final class SwordHTMLVisibleTextProjectionTests: XCTestCase {
    /** Verifies nested Android inline handlers emit composable UTF-16 spans over decoded text. */
    func testFormattedProjectionPreservesNestedStylesAndUTF16Offsets() {
        let projection = SwordHTMLVisibleTextProjection.projectFormatted(
            "😀<b>bold <i>and</i></b> <u>under</u> <s>gone</s>"
        )

        XCTAssertEqual(projection.text, "😀bold and under gone")
        XCTAssertEqual(
            projection.spans,
            [
                .init(startUTF16: 7, endUTF16: 10, style: .italic),
                .init(startUTF16: 2, endUTF16: 10, style: .bold),
                .init(startUTF16: 11, endUTF16: 16, style: .underline),
                .init(startUTF16: 17, endUTF16: 21, style: .strikethrough),
            ]
        )
    }

    /** Verifies link attributes use TagSoup entity decoding without changing visible entities. */
    func testFormattedProjectionDecodesLinkAndVisibleEntitiesOnce() {
        let projection = SwordHTMLVisibleTextProjection.projectFormatted(
            "<a href='https://example.test/?a=1&amp;b=2'>A&amp;B</a>"
        )

        XCTAssertEqual(projection.text, "A&B")
        XCTAssertEqual(
            projection.spans,
            [.init(
                startUTF16: 0,
                endUTF16: 3,
                style: .link("https://example.test/?a=1&b=2")
            )]
        )
    }

    /** Verifies Android legacy block margins and paragraph-style ranges share one parser pass. */
    func testFormattedProjectionPreservesLegacyBlockAndListRanges() {
        let projection = SwordHTMLVisibleTextProjection.projectFormatted(
            "<blockquote>Quote</blockquote><ul><li>One</li><li>Two</li></ul>"
        )

        XCTAssertEqual(projection.text, "Quote\n\nOne\n\nTwo\n\n")
        XCTAssertEqual(
            projection.spans,
            [
                .init(startUTF16: 0, endUTF16: 6, style: .quote),
                .init(startUTF16: 7, endUTF16: 11, style: .bullet),
                .init(startUTF16: 12, endUTF16: 16, style: .bullet),
            ]
        )
    }

    /** Verifies TagSoup's restartable inline repair closes and resumes semantic spans. */
    func testFormattedProjectionRestartsInlineStyleAcrossRepairedBlock() {
        let projection = SwordHTMLVisibleTextProjection.projectFormatted("<b>A<p>B</p>C</b>")

        XCTAssertEqual(projection.text, "A\n\nB\n\nC")
        XCTAssertEqual(
            projection.spans,
            [
                .init(startUTF16: 0, endUTF16: 1, style: .bold),
                .init(startUTF16: 3, endUTF16: 4, style: .bold),
                .init(startUTF16: 6, endUTF16: 7, style: .bold),
            ]
        )
    }

    /** Verifies Android font and CSS handlers preserve their exact nested span boundaries. */
    func testFormattedProjectionPreservesFontColorAndParagraphCSS() {
        let projection = SwordHTMLVisibleTextProjection.projectFormatted(
            "<p style='text-align:center;color:#102030;background-color:#405060;"
                + "text-decoration:line-through'><font face='serif' color='red'>"
                + "<big>A</big></font></p>"
        )

        XCTAssertEqual(projection.text, "A\n\n")
        XCTAssertEqual(
            projection.spans,
            [
                .init(startUTF16: 0, endUTF16: 1, style: .relativeSize(1.25)),
                .init(startUTF16: 0, endUTF16: 1, style: .fontFamily("serif")),
                .init(startUTF16: 0, endUTF16: 1, style: .foregroundARGB(0xFFFF_0000)),
                .init(startUTF16: 0, endUTF16: 1, style: .strikethrough),
                .init(startUTF16: 0, endUTF16: 1, style: .backgroundARGB(0xFF40_5060)),
                .init(startUTF16: 0, endUTF16: 1, style: .foregroundARGB(0xFF10_2030)),
                .init(startUTF16: 0, endUTF16: 2, style: .textAlignment(.center)),
            ]
        )
    }

    /** An unstyled nested span cannot prematurely close its outer Android font color. */
    func testFormattedProjectionKeepsOuterFontColorAcrossUnstyledNestedSpan() {
        let projection = SwordHTMLVisibleTextProjection.projectFormatted(
            "<font color='red'>A<span>B</span>C</font>"
        )

        XCTAssertEqual(projection.text, "ABC")
        XCTAssertEqual(
            projection.spans,
            [.init(startUTF16: 0, endUTF16: 3, style: .foregroundARGB(0xFFFF_0000))]
        )
    }

    /** Nested block alignment closes only the matching style marker. */
    func testFormattedProjectionKeepsOuterAlignmentAcrossUnstyledNestedBlock() {
        let projection = SwordHTMLVisibleTextProjection.projectFormatted(
            "<div style='text-align:center'>A<div>B</div>C</div>"
        )

        XCTAssertEqual(projection.text, "A\n\nB\n\nC\n\n")
        XCTAssertEqual(
            projection.spans,
            [.init(startUTF16: 0, endUTF16: 8, style: .textAlignment(.center))]
        )
    }

    /** Verifies long multilingual formatting remains linear in text length and span count. */
    func testFormattedProjectionMaintainsUTF16RangesForLongMultilingualInput() {
        let unit = "😀e\u{0301}漢"
        let source = Array(repeating: "<b>\(unit)</b>", count: 2_000).joined()
        let projection = SwordHTMLVisibleTextProjection.projectFormatted(source)

        XCTAssertEqual(projection.text, String(repeating: unit, count: 2_000))
        XCTAssertEqual(projection.spans.count, 2_000)
        XCTAssertEqual(projection.spans.last?.endUTF16, projection.text.utf16.count)
        XCTAssertEqual(SwordHTMLVisibleTextProjection.project(source), projection.text)
    }

    /**
     Verifies every generated compatibility resource loads and pins Android's Unicode domain.

     - Setup: Reads the production bundles and compares case/whitespace values where Foundation,
       host OpenJDK 17, and Android 37 ICU 78.3 differ.
     - Expected result: Cardinalities match generation contracts; Java comparisons stay
       length-preserving, normalization-preserving, and aware of Android's modern simple mappings.
     - Side effects: Loads each cached resource once.
     - Failure meaning: Packaging drift or host Unicode behavior can change parser or module access.
     */
    func testBundledCompatibilityResourcesAndAndroidUnicodeOracles() {
        XCTAssertEqual(
            SwordTagSoupEntityDecoder.bundledEntityCount,
            SwordTagSoupEntityDecoder.expectedBundledEntityCount
        )
        XCTAssertEqual(
            SwordTagSoupHTMLSchema.bundledElementCount,
            SwordTagSoupHTMLSchema.expectedBundledElementCount
        )
        XCTAssertEqual(
            SwordJavaTextCompatibility.bundledCharacterRowCount,
            SwordJavaTextCompatibility.expectedBundledCharacterRowCount
        )

        XCTAssertFalse(SwordJavaTextCompatibility.equalsIgnoreCase("ß", "SS"))
        XCTAssertFalse(SwordJavaTextCompatibility.equalsIgnoreCase("é", "e\u{0301}"))
        XCTAssertTrue(SwordJavaTextCompatibility.equalsIgnoreCase("İMG", "img"))
        XCTAssertTrue(SwordJavaTextCompatibility.equalsIgnoreCase("ımg", "img"))
        XCTAssertTrue(SwordJavaTextCompatibility.equalsIgnoreCase("Ꟁ", "ꟁ"))
        XCTAssertFalse(SwordJavaStringIdentity.equalsIgnoreCase("𐐀", "𐐨"))
        XCTAssertFalse(SwordJavaTextCompatibility.isWhitespace(0x00A0))
        XCTAssertTrue(SwordJavaTextCompatibility.isWhitespace(0x2003))
        XCTAssertFalse(SwordJavaTextCompatibility.isWhitespace(0x2007))
    }

    /**
     Pins AOSP `HTMLScanner` named-entity termination and preclassification normalization.

     - Setup: Exercises semicolon omission, maximum-length names, UTF-16 body boundaries, a C1
       control inside an entity, and Unicode characters that do/do not satisfy Android predicates.
     - Expected result: Known references decode once; unknown bodies remain normalized and literal.
     - Side effects: Performs bounded in-memory scans.
     - Failure meaning: Search previews leak source syntax or decode a different prefix than Android.
     */
    func testNamedEntityScannerMatchesAndroid37() {
        assertProjection("A&copy B", equals: "A© B")
        assertProjection("A&CounterClockwiseContourIntegral B", equals: "A∳ B")
        assertProjection("A&copy²", equals: "A©²")
        assertProjection("A&copy𐐀", equals: "A©𐐀")
        assertProjection("A&copyé", equals: "A&copyé")
        assertProjection("A&amp\u{0301}B", equals: "A&\u{0301}B")
        assertProjection("A&copy\u{008A}B", equals: "A&copyŠB")
        assertProjection("A&Aacgr;B", equals: "AΆB")
        assertProjection("A&apos;B", equals: "A'B")
        assertProjection("\t&amp;A", equals: "&A")
        assertProjection("\u{2003}&amp;A", equals: "&A")
        assertProjection(String(repeating: "\t", count: 181) + "A", equals: "\tA")
    }

    /**
     Pins AOSP numeric entity scanning, unchecked Java-int UTF-16 synthesis, and control quirks.

     - Setup: Uses raw/numeric C1 values, Unicode decimal digits, rejected fullwidth hex letters,
       controls, surrogate values, out-of-Unicode Java ints, and overflow.
     - Expected result: Scanner-approved references follow Android's exact UTF-16 output; invalid
       references remain literal and recognized entity controls are dropped.
     - Side effects: Performs bounded in-memory scans.
     - Failure meaning: Preview Unicode can diverge, disappear, or become silently sanitized.
     */
    func testNumericEntityScannerMatchesAndroid37() {
        assertProjection("A&#128;B", equals: "A€B")
        assertProjection("A\u{0080}B", equals: "A€B")
        assertProjection("A&#٦٥;B", equals: "AAB")
        assertProjection("A&#x٤١;B", equals: "AAB")
        assertProjection("A&#xＡ;B", equals: "A&#xＡ;B")
        assertProjection("A&NewLine;B&Tab;C&#10;D", equals: "ABCD")
        assertProjection("A\tB", equals: "A\tB")
        assertProjection("A&#0;B", equals: "A&#0;B")
        assertProjection("A&#55296;B", equals: "AB")
        assertProjection("A&#x10FFFF;B", equals: "A\u{10FFFF}B")
        assertProjection("A&#x110000;B", equals: "A\u{FFFD}\u{FFFD}B")
        assertProjection("A&#x7FFFFFFF;B", equals: "A\u{D7BF}\u{FFFD}B")
        assertProjection("A&#2147483648;B", equals: "A&#2147483648;B")
    }

    /**
     Verifies malformed scanner constructs follow TagSoup states rather than strict HTML/XML rules.

     - Setup: Supplies repaired digit/Unicode/bogon names, declarations, CDATA, comments, PIs,
       incomplete GIs, a lone less-than, BOM, combining-mark whitespace boundaries, and a long
       declaration that grows the scanner buffer before a whitespace-heavy PCDATA callback.
     - Expected result: Committed markup is omitted, CDATA payload remains, incomplete scanner
       states disappear at EOF, and visible character spacing matches Android UTF-16 callbacks.
     - Side effects: Performs bounded in-memory scans.
     - Failure meaning: Malformed literal HTML can reappear in Search snippets or lose text.
     */
    func testMalformedScannerStatesMatchAndroid37() {
        assertProjection("A<1>B</1>C", equals: "ABC")
        assertProjection("A<é>B</é>C", equals: "ABC")
        assertProjection("A<foo>B</foo>C", equals: "ABC")
        assertProjection("A<![CDATA[word]]>B", equals: "AwordB")
        assertProjection("A<!foo>B", equals: "AB")
        assertProjection("A<?pi data>B", equals: "AB")
        assertProjection("A<!--x", equals: "A")
        assertProjection("A<b", equals: "A")
        assertProjection("A<!", equals: "A")
        assertProjection("A<?", equals: "A")
        assertProjection("A<", equals: "A<")
        assertProjection("\u{FEFF}A", equals: "A")
        assertProjection(" \u{0301}A", equals: "\u{0301}A")
        assertProjection("A  \u{0301}B", equals: "A \u{0301}B")
        let longDeclaration = "<!\(String(repeating: "a", count: 181))>"
        let leadingTabs = String(repeating: "\t", count: 181)
        assertProjection(longDeclaration + leadingTabs + "A", equals: leadingTabs + "A")
        let malformedSlashTag = "<\(String(repeating: "a", count: 170))/"
            + String(repeating: "b", count: 20) + ">"
        assertProjection(malformedSlashTag + leadingTabs + "A", equals: leadingTabs + "A")
    }

    /**
     Verifies Parser.makeName and Android handler comparison remain separate compatibility domains.

     - Setup: Repairs invalid QName characters into known handlers, uses namespace-local names, and
       compares dotted/dotless-I spellings through Android `equalsIgnoreCase`.
     - Expected result: Repaired block/br/img tags produce exact visible effects; other bogons strip.
     - Side effects: Performs bounded in-memory scans and schema rectification.
     - Failure meaning: Unknown markup leaks or recognized tags lose Android margins/objects.
     */
    func testRepairedAndNamespaceTagNamesMatchAndroid37() {
        assertProjection("<d@iv>A", equals: "A\n\n")
        assertProjection("<@br>A", equals: "\nA")
        assertProjection("<x:img>A", equals: "\u{FFFC}A")
        assertProjection("<x:İMG>A", equals: "\u{FFFC}A")
        assertProjection("<x:ımg>A", equals: "\u{FFFC}A")
        assertProjection("<x:dİv>A", equals: "A\n\n")
        assertProjection("<x:lı>A", equals: "A\n\n")
        assertProjection("<p:>A", equals: "A")
        assertProjection("<_p>A", equals: "A")
    }

    /**
     Pins schema-derived implicit closes, ignored unmatched ends, and synthetic EOF callbacks.

     - Setup: Exercises paragraph/list auto-close, non-visible schema containers, a no-force form,
       a table that does not close p, runtime root bogons, unmatched ends, and open blocks at EOF.
     - Expected result: Visible legacy margins occur at the exact repaired structural boundaries.
     - Side effects: Performs bounded in-memory parser-stack mutation.
     - Failure meaning: A hand-curated tag list has replaced TagSoup's containment contract.
     */
    func testSchemaRectificationMatchesAndroid37() {
        assertProjection("A</p>B", equals: "AB")
        assertProjection("<p>A</>B", equals: "A\n\nB")
        assertProjection("A<p>B", equals: "A\n\nB\n\n")
        assertProjection("<p>A<p>B", equals: "A\n\nB\n\n")
        assertProjection("<ul><li>A<li>B", equals: "A\n\nB\n\n")
        assertProjection("<p>A<form>B", equals: "A\n\nB")
        assertProjection("<p>A<form>B<p>C</form>D", equals: "A\n\nB\n\nC\n\nD")
        assertProjection("<p>A<center>B", equals: "A\n\nB")
        assertProjection("<p>A<noframes>B", equals: "A\n\nB")
        assertProjection("<p>A<title>B", equals: "A\n\nB")
        assertProjection("<p>A<table>B", equals: "AB\n\n")
        assertProjection("<foo><p>A</foo>B", equals: "AB\n\n")
        assertProjection("<x:p/>A", equals: "A\n\n")
        assertProjection("<x:br/>A", equals: "A\n")
        assertProjection("X<AΣ:p>A</Aσ:p>B", equals: "X\n\nAB\n\n")
        assertProjection("X<AΣ:p>A</Aς:p>B", equals: "X\n\nA\n\nB")
        assertProjection("X<AΣ-X:p>A</Aς-X:p>B", equals: "X\n\nA\n\nB")
    }

    /**
     Pins scanner attribute commitment plus TagSoup CDATA-element transitions.

     - Setup: Varies slash placement, incomplete/quoted attributes, quotes inside unquoted values,
       exact script/style raw text, ordinary xmp, unmatched closes, and empty CDATA elements.
     - Expected result: Only committed tags affect structure; script/style bodies remain raw until
       an exact schema close while ordinary text continues entity decoding.
     - Side effects: Performs bounded in-memory scans and schema parsing.
     - Failure meaning: Trailing verse text can be swallowed or decoded in the wrong scanner state.
     */
    func testAttributeAndCDATAStatesMatchAndroid37() {
        assertProjection("A<p/ >B", equals: "AB")
        assertProjection("A<p / >B", equals: "A\n\nB\n\n")
        assertProjection("A<p title='x", equals: "A\n\n")
        assertProjection("A<p x=a'b>B", equals: "A\n\nB\n\n")
        assertProjection("A<br x=a'b>B", equals: "A\nB")
        assertProjection("A<img x=a\"b>B", equals: "A\u{FFFC}B")
        assertProjection("<script>A&amp;B<b>C</script>D", equals: "A&amp;B<b>CD")
        assertProjection("<style>A&amp;B<b>C</style>D", equals: "A&amp;B<b>CD")
        assertProjection("<xmp>A&amp;B<b>C</xmp>D", equals: "A&BCD")
        assertProjection("A</style>B&amp;C", equals: "AB&C")
        assertProjection("A<script/>B&amp;C", equals: "AB&amp;C")
        assertProjection("<x:script>A&amp;B</x:script>C", equals: "A&BC")
        assertProjection("<script>A</ſcript>B", equals: "A</ſcript>B")
        assertProjection("<script>A<", equals: "A")
        assertProjection("<script>A</", equals: "A</>")
    }

    /**
     Performs one production projection and reports the source alongside any mismatch.

     - Parameters:
       - source: Complete Android-oracle input passed through the production scanner/parser.
       - expected: Exact post-`Html.fromHtml` visible string from the pinned Android harness.
       - file: XCTest call-site file retained for actionable failures.
       - line: XCTest call-site line retained for actionable failures.
     - Side effects: Loads generated resources on first call and records an XCTest assertion.
     - Failure meaning: Scanner, schema repair, entity, or visible-handler parity has regressed.
     */
    private func assertProjection(
        _ source: String,
        equals expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            SwordHTMLVisibleTextProjection.project(source),
            expected,
            "Android 37 TagSoup mismatch for \(String(reflecting: source))",
            file: file,
            line: line
        )
    }
}
