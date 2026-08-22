import XCTest

@testable import SwordKit

/** Protects Android's distinct canonical-index and structured-preview Bible Search contracts. */
final class SwordBibleSearchTextProjectionTests: XCTestCase {
    /**
     Reproduces FinRK II Peter 1:19 without allowing its cross-reference note into Search text.

     - Setup: Projects a leading heading, nested visible formatting, and the FinRK-shaped
       `crossReference`/`reference` subtree through the production structured projector.
     - Expected result: Both domains retain only verse prose; heading and reference targets vanish.
     - Failure meaning: SWORD annotations can again become indexed words or visible HTML-like text.
     - Side effects: Parses one in-memory OSIS fragment.
     */
    func testFinRKCrossReferenceNoteIsExcludedFromIndexAndPreview() {
        let projected = SwordBibleSearchTextProjection.project(
            sourceXML: """
            <title canonical="false" subType="x-preverse">Heading-only token</title>
            Verse prose with <hi type="italic">kointähti</hi> remains.
            <note type="crossReference"><reference osisRef="Ps.119.105">Ps.119.105</reference>, <reference osisRef="Rev.22.16">Rev.22.16</reference></note>
            """
        )

        XCTAssertEqual(projected.indexText, "Verse prose with kointähti remains.")
        XCTAssertEqual(projected.previewText, "Verse prose with kointähti remains. ")
        XCTAssertFalse(projected.indexText.contains("Ps.119.105"))
        XCTAssertFalse(projected.previewText.contains("reference"))
    }

    /**
     Pins the intentional difference between JSword canonical text and Android Search presentation.

     - Setup: Marks extra-biblical reference/note nodes canonical with mixed-case Boolean values and
       surrounds them with independent whitespace text nodes, matching JDOM's child-content shape.
     - Expected result: Canonical text indexes explicitly canonical content, while preview traversal
       omits both subtrees and post-`htmlToSpan` whitespace collapses to one visible space.
     - Failure meaning: The two domains have collapsed or preview no longer mirrors Android's raw
       child concatenation followed by one complete HTML-to-visible-text pass.
     - Side effects: Parses one in-memory OSIS fragment.
     */
    func testCanonicalAnnotationsRemainIndexableButNeverEnterPreview() {
        let projected = SwordBibleSearchTextProjection.project(
            sourceXML: "Body <reference canonical=\"TRUE\">canonical-only</reference> <note canonical=\"TrUe\">note-only</note> end"
        )

        XCTAssertEqual(projected.indexText, "Body canonical-only note-only end")
        XCTAssertEqual(projected.previewText, "Body end")
    }

    /**
     Pins JSword's token-boundary rule independently from Android preview's raw child text.

     - Setup: Places adjacent word fragments across ordinary formatting and an OSIS `seg` element.
     - Expected result: Index text separates ordinary adjacent nodes but honors `seg` word joining;
       preview text concatenates the original text nodes exactly as Android's recursive walker does.
     - Failure meaning: Search tokens or result-preview whitespace have diverged from Android.
     - Side effects: Parses one in-memory OSIS fragment.
     */
    func testIndexSeparatorsAndPreviewConcatenationMatchAndroid() {
        let projected = SwordBibleSearchTextProjection.project(
            sourceXML: "alpha<hi>beta</hi>gamma <seg>delta</seg>epsilon"
        )

        XCTAssertEqual(projected.indexText, "alpha beta gamma delta epsilon")
        XCTAssertEqual(projected.previewText, "alphabetagamma deltaepsilon")

        let joinedSegment = SwordBibleSearchTextProjection.project(
            sourceXML: "alpha<seg>beta</seg>gamma"
        )
        XCTAssertEqual(joinedSegment.indexText, "alphabeta gamma")
        XCTAssertEqual(joinedSegment.previewText, "alphabetagamma")
    }

    /**
     Verifies JSword entity cleanup makes Latin-1 source parseable without creating markup.

     - Setup: Combines `nbsp`, encoded angle brackets, and one real note element.
     - Expected result: Canonical text retains encoded-tag text verbatim; preview's later HTML pass
       consumes those tag characters but retains their child text, and the real note stays excluded.
     - Failure meaning: Real module entities can abort indexing, canonical terms can be HTML-decoded,
       or preview can skip its post-concatenation `htmlToSpan` behavior.
     - Side effects: Parses one in-memory OSIS fragment.
     */
    func testJSwordEntityCleanupPreservesNBSPAndEncodedMarkup() {
        let projected = SwordBibleSearchTextProjection.project(
            sourceXML: "Alpha&nbsp;beta &lt;note&gt;literal&lt;/note&gt; <note>hidden</note>"
        )
        XCTAssertEqual(projected.indexText, "Alpha\u{00A0}beta <note>literal</note>")
        XCTAssertEqual(projected.previewText, "Alpha\u{00A0}beta literal ")
    }

    /**
     Pins the separate entity domains of JSword's canonical writer and Android Search preview.

     - Setup: Repairs an unknown HTML entity after a leading title while retaining a double-encoded
       XML quote entity in parsed text.
     - Expected result: Canonical text retains literal `&quot;`, the unknown entity becomes one space,
       and preview-only HTML decoding presents a quotation mark; the leading title remains omitted.
     - Failure meaning: The analyzer can silently HTML-decode terms that pinned Lucene indexes
       verbatim, or presentation can leak source entity syntax.
     - Side effects: Parses one in-memory OSIS fragment through the shared compatibility ladder.
     */
    func testCanonicalEntityTextIsVerbatimWhilePreviewUsesTagSoupEntityDomain() {
        let projected = SwordBibleSearchTextProjection.project(
            sourceXML: "<title subType=\"x-preverse\">heading-only</title>A&amp;quot;B&alpha;C"
        )

        XCTAssertEqual(projected.indexText, "A&quot;B C")
        XCTAssertEqual(projected.previewText, "A\"B C")
    }

    /**
     Pins Java's non-breaking-whitespace behavior at canonical node and trim boundaries.

     - Setup: Places NBSP between adjacent OSIS nodes and at both fragment edges.
     - Expected result: Canonical traversal treats NBSP as content, inserts the ordinary separator
       Java adds before a following node, and preserves edge NBSP under `String.trim()` semantics;
       preview preserves NBSP while concatenating child text without a node separator.
     - Failure meaning: Swift/Foundation whitespace rules have replaced the JSword contract and can
       merge analyzer terms or remove visible non-breaking spaces from stored results.
     - Side effects: Parses two bounded in-memory OSIS fragments.
     */
    func testCanonicalUsesJavaWhitespaceAndTrimSemanticsForNBSP() {
        let nodeBoundary = SwordBibleSearchTextProjection.project(
            sourceXML: "alpha&nbsp;<hi>beta</hi>"
        )
        XCTAssertEqual(nodeBoundary.indexText, "alpha\u{00A0} beta")
        XCTAssertEqual(nodeBoundary.previewText, "alpha\u{00A0}beta")

        let edgeNBSP = SwordBibleSearchTextProjection.project(
            sourceXML: "&nbsp;edge&nbsp;"
        )
        XCTAssertEqual(edgeNBSP.indexText, "\u{00A0}edge\u{00A0}")
        XCTAssertEqual(edgeNBSP.previewText, "\u{00A0}edge\u{00A0}")
    }

    /**
     Pins independent outer whitespace rules after the shared source boundary became lossless.

     - Setup: Projects an ASCII trailing space, edge tabs, and a combining mark attached to a
       node-leading ASCII space.
     - Expected result: Canonical Java trim removes ordinary edges but not semantic node content;
       preview drops leading ASCII space, retains one trailing space, and preserves tabs/combining.
     - Failure meaning: A shared pre-trim or Swift grapheme boundary has collapsed distinct domains.
     - Side effects: Parses bounded in-memory fragments.
     */
    func testCanonicalAndPreviewApplyIndependentOuterWhitespaceRules() {
        let trailingSpace = SwordBibleSearchTextProjection.project(sourceXML: "word ")
        XCTAssertEqual(trailingSpace.indexText, "word")
        XCTAssertEqual(trailingSpace.previewText, "word ")

        let edgeTabs = SwordBibleSearchTextProjection.project(sourceXML: "\tword\t")
        XCTAssertEqual(edgeTabs.indexText, "word")
        XCTAssertEqual(edgeTabs.previewText, "\tword\t")

        let combiningBoundary = SwordBibleSearchTextProjection.project(
            sourceXML: "alpha<hi> \u{0301}beta</hi>"
        )
        XCTAssertEqual(combiningBoundary.indexText, "alpha \u{0301}beta")
        XCTAssertEqual(combiningBoundary.previewText, "alpha \u{0301}beta")
        XCTAssertTrue(SwordJavaTextCompatibility.isWhitespace(0x000D))
        XCTAssertTrue(SwordJavaTextCompatibility.isWhitespace(0x000A))
    }

    /**
     Verifies canonical and preview title ownership follows pinned `SwordBook.addOSIS`.

     - Setup: Projects ordinary, canonical ordinary, explicit x-preverse, and repaired Psalm titles.
     - Expected result: Ordinary titles stay in preview but only canonical titles reach the index;
       x-preverse/Psalm titles stay outside preview while remaining canonical index content.
     - Failure meaning: The source boundary is lifting every title or discarding superscriptions.
     - Side effects: Parses and repairs bounded in-memory fragments.
     */
    func testTitleOwnershipMatchesSwordBookAndCanonicalText() {
        let ordinary = SwordBibleSearchTextProjection.project(
            sourceXML: "<title>Heading</title>Verse"
        )
        XCTAssertEqual(ordinary.indexText, "Verse")
        XCTAssertEqual(ordinary.previewText, "HeadingVerse")

        let canonical = SwordBibleSearchTextProjection.project(
            sourceXML: "<title canonical=\"true\">Superscription</title>Verse"
        )
        XCTAssertEqual(canonical.indexText, "Superscription Verse")
        XCTAssertEqual(canonical.previewText, "SuperscriptionVerse")

        let preVerse = SwordBibleSearchTextProjection.project(
            sourceXML: "<title canonical=\"true\" subType=\"x-preverse\">Superscription</title>Verse"
        )
        XCTAssertEqual(preVerse.indexText, "Superscription Verse")
        XCTAssertEqual(preVerse.previewText, "Verse")

        let psalm = SwordBibleSearchTextProjection.project(
            sourceXML: "<title type=\"psalm\">Psalm-token</title>Verse"
        )
        XCTAssertEqual(psalm.indexText, "Psalm-token Verse")
        XCTAssertEqual(psalm.previewText, "Verse")
    }

    /**
     Protects Android's recursive JDOM child policy and already-wrapped verse selection.

     - Setup: Supplies direct/descendant comments and PIs, a nested excluded note, and an outside
       sibling beside an already-wrapped verse.
     - Expected result: JDOM descriptions appear only where Android reaches non-Text content;
       nested note stays excluded and outside siblings never enter an existing verse's preview.
     - Failure meaning: Search snippets can leak annotations or omit Android-visible diagnostics.
     - Side effects: Parses bounded in-memory fragments.
     */
    func testPreviewJDOMTraversalAndExistingVerseSelectionMatchAndroid() {
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A<!--top--><?pi data?>B"
            ).previewText,
            "A[Comment: ][ProcessingInstruction: ]B"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "<hi>A<!--leaf-->B</hi>"
            ).previewText,
            "AB"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "<hi>A<seg>X</seg><!--nested--><?pi x?>B<note>hidden</note></hi>"
            ).previewText,
            "AX[Comment: ][ProcessingInstruction: ]B"
        )

        let wrapped = SwordBibleSearchTextProjection.project(
            sourceXML: "<title canonical=\"true\">outside</title><verse>inside</verse>"
        )
        XCTAssertEqual(wrapped.indexText, "outside inside")
        XCTAssertEqual(wrapped.previewText, "inside")
    }

    /**
     Ensures isolated Unicode spaces remain verse body rather than formatting preamble.

     - Setup: Projects isolated NBSP and NBSP after an explicit preverse title.
     - Expected result: Both canonical and preview retain the NBSP exactly.
     - Failure meaning: Broad Foundation whitespace classification can erase meaningful content.
     - Side effects: Parses bounded in-memory fragments.
     */
    func testIsolatedNBSPRemainsVerseBody() {
        let isolated = SwordBibleSearchTextProjection.project(sourceXML: "&nbsp;")
        XCTAssertEqual(isolated.indexText, "\u{00A0}")
        XCTAssertEqual(isolated.previewText, "\u{00A0}")

        let afterTitle = SwordBibleSearchTextProjection.project(
            sourceXML: "<title subType=\"x-preverse\">Heading</title>&nbsp;"
        )
        XCTAssertEqual(afterTitle.indexText, "\u{00A0}")
        XCTAssertEqual(afterTitle.previewText, "\u{00A0}")
    }

    /**
     Pins Android's one post-concatenation `Html.fromHtml` pass for Search preview text.

     - Setup: Splits one quote entity across OSIS nodes, supplies single/double-encoded tag text,
       crossed HTML, and complete TagSoup scanner cases including omitted semicolons and controls.
     - Expected result: The split entity assembles, only the single-encoded tag layer is consumed,
       crossed tags retain text without separators, and Android line-break margins remain exact.
     - Failure meaning: Per-node entity decoding or plain XML text walking can leak entity syntax,
       flatten Android line breaks, or preserve whitespace Android removes.
     - Side effects: Performs bounded in-memory OSIS and HTML-like fragment parsing.
     */
    func testPreviewRunsOneHTMLProjectionAfterRawChildConcatenation() {
        let splitEntity = SwordBibleSearchTextProjection.project(
            sourceXML: "A&amp;<hi>quot;</hi>B"
        )

        XCTAssertEqual(splitEntity.previewText, "A\"B")
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A &lt;b&gt;bold&lt;/b&gt; B"
            ).previewText,
            "A bold B"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A &amp;lt;b&amp;gt; B"
            ).previewText,
            "A <b> B"
        )
        XCTAssertEqual(
            SwordHTMLVisibleTextProjection.project("x <b>y<i>z</b>w</i>"),
            "x yzw"
        )
        XCTAssertEqual(
            SwordHTMLVisibleTextProjection.project("A  <br>B<div>C</div>D"),
            "A \nB\n\nC\n\nD"
        )
        XCTAssertEqual(
            SwordHTMLVisibleTextProjection.project("A&lt;br&gt;B"),
            "A<br>B"
        )
        let apostrophe = SwordBibleSearchTextProjection.project(
            sourceXML: "A&amp;apos;B"
        )
        XCTAssertEqual(apostrophe.indexText, "A&apos;B")
        XCTAssertEqual(apostrophe.previewText, "A'B")
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A&amp;NewLine;B&amp;NoBreak;C&amp;Tab;D"
            ).previewText,
            "AB\u{2060}CD"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A&amp;Aacgr;B"
            ).previewText,
            "A\u{0386}B"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A&amp;amp;apos;B"
            ).previewText,
            "A&apos;B"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A&amp;copy B"
            ).previewText,
            "A© B"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A&amp;CounterClockwiseContourIntegral B"
            ).previewText,
            "A\u{2233} B"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A&amp;copy²"
            ).previewText,
            "A©²"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A&amp;copy𐐀"
            ).previewText,
            "A©𐐀"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A&amp;copyé"
            ).previewText,
            "A&copyé"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A&amp;#128;B"
            ).previewText,
            "A€B"
        )
        XCTAssertEqual(
            SwordBibleSearchTextProjection.project(
                sourceXML: "A&#128;B"
            ).previewText,
            "A€B"
        )
        XCTAssertEqual(
            SwordHTMLVisibleTextProjection.project("A&#55296;B"),
            "AB"
        )
        XCTAssertEqual(
            SwordTagSoupEntityDecoder.bundledEntityCount,
            SwordTagSoupEntityDecoder.expectedBundledEntityCount
        )
    }

    /**
     Covers pinned `XMLUtil.cleanAllEntities` retry behavior independently from text projection.

     - Setup: Parses valid XML entities, Latin-1 `nbsp`, unknown `alpha`, numeric references, the
       historical `apos` omission, and adjacent invalid/known ampersands through the repair ladder.
     - Expected result: Ampersand and numeric references parse normally, `nbsp` becomes NBSP,
       unknown/`apos` entities become one space, numeric content survives note reclosure, and the
       mutable-index adjacent-amp quirk remains irreparable instead of decoding a skipped entity.
     - Failure meaning: iOS source repair has drifted from the JSword version that builds Android's
       canonical Search documents.
     - Side effects: Performs bounded in-memory fragment parses only.
     */
    func testPinnedParserEntityRepairOracles() {
        XCTAssertEqual(
            SwordJSwordOSISFragmentParser.parse("A&nbsp;B").stringValue,
            "A\u{00A0}B"
        )
        XCTAssertEqual(SwordJSwordOSISFragmentParser.parse("A&amp;B").stringValue, "A&B")
        XCTAssertEqual(SwordJSwordOSISFragmentParser.parse("A&alpha;B").stringValue, "A B")
        XCTAssertEqual(SwordJSwordOSISFragmentParser.parse("A&#65;B").stringValue, "AAB")
        XCTAssertEqual(
            SwordJSwordOSISFragmentParser.parse("A&#65;<note>hidden").serializedChildXML,
            "AA<note>hidden</note>"
        )
        XCTAssertEqual(
            SwordJSwordOSISFragmentParser.parse("A&apos;B<note>hidden").serializedChildXML,
            "A B<note>hidden</note>"
        )
        XCTAssertTrue(
            SwordJSwordOSISFragmentParser.parse("&foo&copy;").children.isEmpty,
            "Pinned XMLUtil skips the adjacent terminator ampersand after escaping &foo"
        )
    }

    /**
     Covers pinned `recloseTags` and destructive `cleanAllTags` stages without UI fallbacks.

     - Setup: Parses an ordinary open `br`, nested unclosed tags, mismatched nesting, UTF-16
       whitespace boundaries, MapM orphan closes, and one irreparable XML control character.
     - Expected result: Open tags close in LIFO order, mismatches become tagless plain text, and
       Java-char boundaries control tag repair, only exact MapM initials reopen cell/row/table
       structure, and irreparable input becomes empty.
     - Failure meaning: One backend can skip recoverable verses or reinterpret malformed OSIS through
       rendered/escaped text instead of the shared structural policy.
     - Side effects: Performs bounded in-memory fragment parses only.
     */
    func testPinnedParserTagRepairOracles() {
        XCTAssertEqual(
            SwordJSwordOSISFragmentParser.parse("Left<br>Right").serializedChildXML,
            "Left<br>Right</br>"
        )
        XCTAssertEqual(
            SwordJSwordOSISFragmentParser.parse("<hi><seg>word").serializedChildXML,
            "<hi><seg>word</seg></hi>"
        )
        XCTAssertEqual(
            SwordJSwordOSISFragmentParser.parse("<hi>one<seg>two</hi>tail").stringValue,
            " one two tail"
        )
        XCTAssertEqual(
            SwordJSwordOSISFragmentParser.parse("<x \u{0301} word").serializedChildXML,
            " word",
            "cleanAllTags must observe the ASCII space before a combining mark as one Java char"
        )
        XCTAssertEqual(
            SwordJSwordOSISFragmentParser.parse("<hi/\u{00A0}>text").serializedChildXML,
            " text ",
            "NBSP is not Java whitespace when recloseTags decides whether a tag is self-closing"
        )
        let mapOrphans = "map text</cell></row></table>"
        XCTAssertEqual(
            SwordJSwordOSISFragmentParser.parse(
                mapOrphans,
                moduleInitials: "MapM"
            ).serializedChildXML,
            "<table><row><cell>map text</cell></row></table>"
        )
        XCTAssertEqual(
            SwordJSwordOSISFragmentParser.parse(
                mapOrphans,
                moduleInitials: "Other"
            ).serializedChildXML,
            "map text"
        )
        XCTAssertTrue(SwordJSwordOSISFragmentParser.parse("\u{0001}").children.isEmpty)
    }

    /**
     Ensures a repairable malformed annotation remains a verse without leaking its note text.

     - Setup: Supplies an unclosed OSIS note matching the native SWORD adapter regression fixture.
     - Expected result: The note is structurally reclosed and omitted from both text domains while
       visible verse prose remains.
     - Failure meaning: iOS can skip a verse Android retains or select an HTML-producing fallback.
     - Side effects: Parses one bounded in-memory OSIS fragment.
     */
    func testMalformedNoteIsReclosedWithoutRenderedFallback() {
        let projected = SwordBibleSearchTextProjection.project(
            sourceXML: "Visible <note>broken"
        )

        XCTAssertEqual(projected.indexText, "Visible")
        XCTAssertEqual(projected.previewText, "Visible ")
    }
}

private extension SwordXMLNode {
    /// Deterministic serialized content below the synthetic fragment root for repair assertions.
    var serializedChildXML: String {
        children.map { $0.serializedXML() }.joined()
    }
}
