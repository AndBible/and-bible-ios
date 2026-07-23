import Foundation
import SQLite3
import XCTest
@testable import BibleCore

/**
 End-to-end EPUB package and Android general-book adapter contract tests.

 Every fixture is a real central-directory ZIP installed into an isolated library root. The suite
 intentionally exercises structured OCF/OPF/navigation/XHTML parsing, numeric fragment keys,
 package-contained resources, anchor search, identity isolation, and staged publication.
 */
final class EpubReaderParityTests: XCTestCase {
    /// Temporary directories and archives removed after each test.
    private var temporaryURLs: [URL] = []

    /**
     Removes all package fixtures created by the current test.

     - Side effects: Deletes recorded temporary directories and archives.
     - Failure modes: Cleanup errors are ignored so they do not hide the assertion that failed.
     */
    override func tearDown() {
        for url in temporaryURLs.reversed() {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    /**
     Proves the built BibleCore bundle contains the pinned JSword locale catalogs used by Android.

     The German name `Johannes` is absent from the English fallback, so resolving it with an
     English UI locale and German document language can succeed only when
     `Resources/jsword-bible-names/BibleNames_de.properties` was packaged and loaded. A failure
     indicates a SwiftPM/Xcode resource declaration or catalog-loading regression, not merely a
     parsing mismatch. The test performs no persistent writes.
     */
    func testBundledJSwordBookNamesResolveDocumentLanguageReference() {
        XCTAssertEqual(
            ScriptureReferenceLinker.resolve(
                "Johannes 3:16",
                documentLanguage: "de",
                userLocale: Locale(identifier: "en")
            ),
            "John.3.16"
        )
    }

    /**
     Verifies Android candidate splitting and KJVA passage normalization independently of XML.

     The fixture covers an en dash, discontiguous continuations, a one-chapter book, and an invalid
     verse. Resolved fragments must retain exact source text while producing JSword-style compacted
     OSIS ranges; an invalid candidate must remain ordinary text. A failure means the shared native
     HTML resolver has drifted from `SwordContentFacade.bibleRefSplit/resolveRef`.
     */
    func testScriptureReferenceLinkerMatchesAndroidCandidateAndKJVAContract() {
        let source = "Read John 3:16–18, 20 and Jude 4-6; ignore John 3:999."
        let segments = ScriptureReferenceLinker.segments(
            in: source,
            documentLanguage: "en",
            userLocale: Locale(identifier: "en")
        )

        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertEqual(
            segments.compactMap(\.osisRef),
            ["John.3.16-John.3.18 John.3.20", "Jude.1.4-Jude.1.6"]
        )
        XCTAssertTrue(segments.contains {
            $0.text == "John 3:16–18, 20"
                && $0.osisRef == "John.3.16-John.3.18 John.3.20"
        })
        XCTAssertTrue(segments.contains { $0.text == "John 3:999" && $0.osisRef == nil })
        XCTAssertEqual(
            ScriptureReferenceLinker.resolve(
                "John 3",
                documentLanguage: "en",
                userLocale: Locale(identifier: "en")
            ),
            "John.3"
        )
        XCTAssertEqual(
            ScriptureReferenceLinker.resolve(
                "John 3; 5",
                documentLanguage: "en",
                userLocale: Locale(identifier: "en")
            ),
            "John.3 John.5"
        )
    }

    /**
     Verifies EPUB transformation inserts localized `reference` nodes only in Android-eligible text.

     A German package is imported while the simulated UI locale is English. The ordinary paragraph
     reference must resolve through package-language fallback and remain inside its BVA; identical
     text under `note` must remain unanchored and unlinked. Failure breaks Android EPUB link parity
     or changes non-Bible bookmark ordinals. Temporary package state is removed by `tearDown`.
     */
    func testEPUBTransformLinksSourceLanguageReferencesAndExcludesNotes() throws {
        let library = try makeTemporaryDirectory(named: "epub-reference-library")
        let archive = try writeArchive(named: "Verweise.epub", entries: epub3Entries(
            title: "Verweise",
            language: "de",
            firstBody: """
            <section id="start">
              <p>Siehe Johannes 3:16-18.</p>
              <note>Johannes 3:16</note>
            </section>
            """,
            secondBody: #"<section id="target"><p>Weiter.</p></section>"#
        ))

        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
        let content = try XCTUnwrap(reader.content(forKey: "1"))

        XCTAssertEqual(reader.language, "de")
        XCTAssertTrue(content.html.contains(
            #"<reference osisRef="John.3.16-John.3.18">Johannes 3:16-18</reference>"#
        ))
        XCTAssertTrue(content.html.contains("<note>Johannes 3:16</note>"))
        XCTAssertEqual(content.html.components(separatedBy: "<reference ").count - 1, 1)
    }

    /**
     Verifies an EPUB 3 package becomes a complete Android-shaped general book.

     Setup:
     - installs namespaced container/OPF/nav/XHTML documents with nested navigation
     - includes an internal anchor link, an external link, an image, and linked CSS/font resources

     Expected result:
     - initials, numeric TOC keys, hierarchy depth, native HTML, BVA range, search ordinal,
       next/previous navigation, CSS sanitization, and contained resources all resolve exactly

     Failure meaning:
     - iOS has regressed to filename/regex parsing, href-only identity, whole-document search, or
       resource loading that depends on the active EPUB.
     */
    func testEPUB3PackageProvidesGeneralBookNavigationLinksResourcesAndSearch() throws {
        let library = try makeTemporaryDirectory(named: "epub3-library")
        let archive = try writeArchive(named: "Alpha Book.epub", entries: epub3Entries(
            title: "Alpha Book",
            firstBodyAttributes: #"class="chapter-layout" onload="blocked()" style="color:red; font-weight:600; background-image:url('https://tracker.invalid/body.png')""#,
            firstBody: """
            <section id="start">
              <p>Opening sentence. Another searchable thought.</p>
              <a href="chapter2.xhtml#target">Continue</a>
              <a href="https://example.com/reference">External</a>
              <a href="../../../outside.txt">Unsafe local</a>
              <a href="%2Fetc/passwd">Unsafe encoded</a>
              <img src="../images/cover%20art.png" alt="Cover"/>
              <img srcset="data:image/png;base64,AAAA 1x, ../images/cover%20art.png 2x" alt="Responsive"/>
              <img src="../images/icons.svg#mark" alt="SVG fragment"/>
              <img src="https://tracker.invalid/remote.png" alt="Remote"/>
              <script>alert('blocked')</script>
            </section>
            """,
            secondBody: #"<section id="target"><p>Second searchable chapter content.</p></section>"#
        ))

        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))

        XCTAssertTrue(identifier.hasPrefix("Alpha_Book-"))
        XCTAssertEqual(reader.initials, "Epub-Alpha_Book_epub")
        XCTAssertEqual(reader.sourceFileName, "Alpha Book.epub")
        XCTAssertEqual(reader.title, "Alpha Book")
        XCTAssertEqual(reader.author, "Ada Reader")
        XCTAssertEqual(reader.language, "en")

        let toc = reader.tableOfContents()
        XCTAssertEqual(toc.map(\.title), ["Opening", "Second"])
        XCTAssertEqual(toc.map(\.depth), [0, 1])
        XCTAssertTrue(toc[0].key.hasPrefix("1#start"))
        XCTAssertTrue(toc[1].key.hasSuffix("#target"))

        let first = try XCTUnwrap(reader.content(forKey: toc[0].key))
        XCTAssertEqual(first.persistedKey, "1")
        XCTAssertEqual(first.href, "OPS/text/chapter1.xhtml")
        XCTAssertEqual(first.fragment, "start")
        XCTAssertEqual(first.ordinalRange.lowerBound, 0)
        XCTAssertGreaterThan(first.ordinalRange.upperBound, 0)
        XCTAssertTrue(first.html.contains(#"<epubRef to-id="target" to-key="chapter-2""#))
        XCTAssertTrue(first.html.contains(#"<epubA href="https://example.com/reference""#))
        XCTAssertTrue(first.html.contains("Unsafe local"))
        XCTAssertTrue(first.html.contains("Unsafe encoded"))
        XCTAssertFalse(first.html.contains("../../../outside.txt"))
        XCTAssertFalse(first.html.contains("%2Fetc/passwd"))
        let generationRoute = "andbible-resource://epub/\(reader.initials)/\(reader.generationIdentifier)"
        XCTAssertTrue(first.html.contains("\(generationRoute)/OPS/images/cover%20art.png"))
        XCTAssertTrue(first.html.contains("data:image/png;base64,AAAA 1x"))
        XCTAssertTrue(first.html.contains("\(generationRoute)/OPS/images/cover%20art.png 2x"))
        XCTAssertTrue(first.html.contains("\(generationRoute)/OPS/images/icons.svg#mark"))
        XCTAssertTrue(first.html.contains("chapter-layout epub-native-document"))
        XCTAssertTrue(first.html.contains("font-weight:600"))
        XCTAssertFalse(first.html.contains("onload"))
        XCTAssertFalse(first.html.contains("script"))
        XCTAssertFalse(first.html.contains("tracker.invalid"))
        XCTAssertFalse(first.html.contains("color:red"))
        XCTAssertFalse(first.html.contains("background-image"))
        XCTAssertEqual(reader.nextKey(after: first.key), "2")
        XCTAssertNil(reader.previousKey(before: first.key))

        let linked = try XCTUnwrap(reader.content(originalKey: "chapter-2", htmlID: "target"))
        XCTAssertEqual(linked.key, "2")
        XCTAssertEqual(linked.fragment, "target")
        XCTAssertNil(reader.content(originalKey: "chapter-2", htmlID: "missing"))

        let results = reader.searchResults(query: "searchable")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].key, "1")
        XCTAssertGreaterThanOrEqual(results[0].ordinal, first.ordinalRange.lowerBound)
        XCTAssertLessThanOrEqual(results[0].ordinal, first.ordinalRange.upperBound)
        XCTAssertEqual(results[1].key, linked.key)

        let imageURL = try XCTUnwrap(reader.resourceURL(for: "OPS/images/cover art.png"))
        XCTAssertEqual(try Data(contentsOf: imageURL), Data([0x89, 0x50, 0x4e, 0x47]))
        let css = try XCTUnwrap(String(data: reader.styleSheetData(forKey: first.key), encoding: .utf8))
        XCTAssertFalse(css.lowercased().contains("body{"))
        XCTAssertFalse(css.lowercased().contains("color:"))
        XCTAssertTrue(css.contains("font-weight:bold"))
        XCTAssertTrue(css.contains("\(generationRoute)/OPS/fonts/reader.woff2"))
        XCTAssertTrue(css.contains("\(generationRoute)/OPS/styles/nested.css"))
        let nestedCSS = try XCTUnwrap(String(
            data: reader.styleSheetData(forCanonicalPath: "OPS/styles/nested.css"),
            encoding: .utf8
        ))
        XCTAssertTrue(nestedCSS.contains("font-style:italic"))
        XCTAssertFalse(nestedCSS.contains("tracker.invalid"))
        XCTAssertFalse(nestedCSS.lowercased().contains("color:"))
    }

    /**
     Verifies EPUB search consumes Android FTS5 modes and exposes only trusted hit emphasis.

     The installed German fixture proves Android EPUB search uses raw SQLite FTS text rather than
     JSword's Bible analyzers, then covers all/any/phrase modes and Android's raw advanced FTS path,
     malformed advanced syntax, and authored literal `<b>` text. A failure means EPUB indexing has
     drifted from the shared mode contract, search errors are being swallowed, or untrusted source
     markup can influence result styling. Temporary package state is removed by `tearDown`.
     */
    func testEPUBSearchUsesSharedModesLanguageAnalyzerAndTrustedEmphasis() throws {
        let library = try makeTemporaryDirectory(named: "epub-search-contract")
        let archive = try writeArchive(named: "Suche.epub", entries: epub3Entries(
            title: "Suche",
            language: "de",
            firstBody: """
            <section id="start">
              <p>Häusern stehen am Weg.</p>
              <p>faith hope together.</p>
              <p>faith alone.</p>
              <p>&lt;b&gt;authored&lt;/b&gt; literal marker.</p>
            </section>
            """,
            secondBody: #"<section id="target"><p>Kein Treffer.</p></section>"#
        ))

        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))

        XCTAssertEqual(reader.language, "de")
        let germanBibleAnalyzer = SearchTextAnalyzer.profile(for: reader.language)
        XCTAssertEqual(
            try SearchTextAnalyzer.analyzedTokens("Häuser", profile: germanBibleAnalyzer),
            try SearchTextAnalyzer.analyzedTokens("Häusern", profile: germanBibleAnalyzer),
            "The Bible analyzer must retain German stemming independently of EPUB raw FTS"
        )
        XCTAssertEqual(
            try SearchQueryCompiler.compile(
                query: "Häuser",
                epubMode: .allWords,
                languageCode: reader.language
            ),
            "Häuser"
        )
        XCTAssertTrue(
            try reader.searchResults(query: "Häuser", epubMode: .allWords).isEmpty,
            "Android's raw unicode61 EPUB index does not stem Häuser to Häusern"
        )

        let exactGerman = try reader.searchResults(query: "Häusern", epubMode: .allWords)
        let exactGermanHit = try XCTUnwrap(exactGerman.first)
        XCTAssertEqual(exactGerman.count, 1)
        XCTAssertEqual(
            exactGermanHit.snippetSegments.filter(\.isEmphasized).map(\.text),
            ["Häusern"]
        )

        XCTAssertEqual(
            try reader.searchResults(query: "faith hope", epubMode: .allWords).count,
            1
        )
        XCTAssertEqual(
            try reader.searchResults(query: "faith hope", epubMode: .anyWords).count,
            2
        )
        XCTAssertEqual(
            try reader.searchResults(query: "faith hope", epubMode: .phrase).count,
            1
        )
        let advanced = try reader.searchResults(
            query: #""faith" NOT "hope""#,
            epubMode: .fullTextQuery
        )
        XCTAssertEqual(advanced.map(\.snippet), ["faith alone."])
        XCTAssertEqual(
            advanced.flatMap(\.snippetSegments).filter(\.isEmphasized).map(\.text),
            ["faith"]
        )

        XCTAssertThrowsError(
            try reader.searchResults(query: #""unterminated"#, epubMode: .fullTextQuery)
        ) { error in
            guard case SearchIndexError.invalidQuery = error else {
                return XCTFail("Expected invalidQuery, got \(error)")
            }
        }

        let authored = try XCTUnwrap(
            reader.searchResults(query: "authored", epubMode: .allWords).first
        )
        XCTAssertEqual(authored.snippet, "<b>authored</b> literal marker.")
        XCTAssertEqual(authored.snippetSegments.map(\.text).joined(), authored.snippet)
        XCTAssertEqual(
            authored.snippetSegments.filter(\.isEmphasized).map(\.text),
            ["authored"]
        )
        XCTAssertTrue(authored.snippetSegments.contains { $0.text.contains("<b>") && !$0.isEmphasized })
    }

    /**
     Verifies EPUB 2 NCX hierarchy is parsed without EPUB 3 navigation markup.

     Setup:
     - installs an EPUB 2 package whose spine declares a nested NCX table of contents

     Expected result:
     - NCX labels, source order, depths, numeric keys, and HTML ids match the EPUB 3 projection

     Failure meaning:
     - the importer supports only EPUB 3 nav or flattens nested NCX content incorrectly.
     */
    func testEPUB2NCXNavigationPreservesNestedTargets() throws {
        let library = try makeTemporaryDirectory(named: "epub2-library")
        let archive = try writeArchive(named: "Legacy.epub", entries: epub2Entries())

        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
        let toc = reader.tableOfContents()

        XCTAssertEqual(reader.initials, "Epub-Legacy_epub")
        XCTAssertEqual(toc.map(\.title), ["Legacy Start", "Nested Topic"])
        XCTAssertEqual(toc.map(\.depth), [0, 1])
        XCTAssertEqual(reader.content(forKey: toc[0].key)?.fragment, "legacy-start")
        XCTAssertEqual(reader.content(forKey: toc[1].key)?.fragment, "nested")
    }

    /**
     Verifies CSS resource rewriting recognizes syntax instead of matching text fragments.

     Setup:
     - processes local `@import` and `url(...)` tokens alongside identical text inside a block
       comment and a quoted `content` value
     - includes an SVG fragment and reader-owned color declarations

     Expected result:
     - executable local resources become contained URLs, comments/strings remain byte-equivalent,
       the SVG fragment survives, and blocked color declarations are removed

     Failure meaning:
     - a valid stylesheet can be corrupted by incidental token text or can lose a resource anchor.
     */
    func testCSSProcessorRewritesOnlySyntacticResourceTokens() throws {
        let packageRoot = try makeTemporaryDirectory(named: "css-package")
        let css = """
        /* url('../ignored.png'); @import "../ignored.css"; */
        @import "print/reader.css" print;
        @import "https://tracker.invalid/remote.css";
        .literal::before { content: "url('../literal.png')"; color: red; }
        @font-face { font-family: Reader; src: url('../fonts/icons.svg#mark'); }
        @font-face { font-family: Remote; src: url('https://tracker.invalid/font.woff2'); }
        .embedded { mask-image: url(data:image/png;base64,AAAA); }
        """

        let processed = EpubCSSProcessor.process(
            css,
            styleSheetPath: "OPS/styles/book.css",
            packageRootURL: packageRoot,
            resourceIdentity: EpubResourceIdentity(
                bookInitials: "Epub-CSS",
                generationIdentifier: "11111111-2222-3333-4444-555555555555"
            )
        )

        XCTAssertTrue(processed.contains(#"/* url('../ignored.png'); @import "../ignored.css"; */"#))
        XCTAssertTrue(processed.contains(#"content: "url('../literal.png')""#))
        XCTAssertTrue(processed.contains(
            "andbible-resource://epub/Epub-CSS/11111111-2222-3333-4444-555555555555/OPS/styles/print/reader.css"
        ))
        XCTAssertTrue(processed.contains(
            "andbible-resource://epub/Epub-CSS/11111111-2222-3333-4444-555555555555/OPS/fonts/icons.svg#mark"
        ))
        XCTAssertTrue(processed.contains("data:image/png;base64,AAAA"))
        XCTAssertFalse(processed.contains("tracker.invalid"))
        XCTAssertFalse(processed.contains("color: red"))
    }

    /**
     Verifies Android's 500-ordinal fragmentation keeps source ids mapped to numeric page keys.

     Setup:
     - installs one spine XHTML containing 1,002 paragraph anchors

     Expected result:
     - the document splits into multiple ordered numeric keys and an id near the end resolves to
       the owning fragment rather than the first fragment

     Failure meaning:
     - large EPUB chapters cannot restore/search/link to the same fragment key Android uses.
     */
    func testLargeSpineDocumentMapsAnchorsAcrossNumericFragments() throws {
        let library = try makeTemporaryDirectory(named: "fragment-library")
        let paragraphs = (0..<1_002).map { #"<p id="p\#($0)">Sentence \#($0).</p>"# }.joined()
        let archive = try writeArchive(named: "Long.epub", entries: epub3Entries(
            title: "Long Book",
            firstBody: paragraphs,
            secondBody: #"<p id="end">The end.</p>"#
        ))

        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
        let first = try XCTUnwrap(reader.content(originalKey: "chapter-1", htmlID: "p0"))
        let boundaryBefore = try XCTUnwrap(reader.content(originalKey: "chapter-1", htmlID: "p500"))
        let second = try XCTUnwrap(reader.content(originalKey: "chapter-1", htmlID: "p501"))
        let last = try XCTUnwrap(reader.content(originalKey: "chapter-1", htmlID: "p1001"))

        XCTAssertEqual(first.key, "1")
        XCTAssertEqual(boundaryBefore.key, first.key)
        XCTAssertNotEqual(second.key, first.key)
        XCTAssertNotEqual(last.key, first.key)
        XCTAssertEqual(last.key, second.key)
        XCTAssertEqual(reader.nextKey(after: first.key), second.key)
        XCTAssertEqual(reader.previousKey(before: last.key), first.key)
        let numericHit = try XCTUnwrap(reader.searchResults(query: "1001").first)
        XCTAssertEqual(numericHit.key, last.key)
        XCTAssertEqual(
            numericHit.snippetSegments.filter(\.isEmphasized).map(\.text),
            ["1001"]
        )
    }

    /**
     Verifies two EPUBs with identical internal hrefs remain identity- and resource-isolated.

     Setup:
     - installs two differently named packages that both use `OPS/text/chapter1.xhtml`

     Expected result:
     - each adapter has distinct stable initials and transformed URLs carry those exact initials

     Failure meaning:
     - links or media can be resolved through whichever EPUB happens to be active, reproducing the
       cross-book ambiguity that durable EPUB source identity is intended to remove.
     */
    func testOverlappingPackageHrefsRemainIsolatedByStableInitials() throws {
        let library = try makeTemporaryDirectory(named: "identity-library")
        var alphaEntries = epub3Entries(
            title: "Alpha",
            firstBody: #"<p>Alpha only.</p><img src="../images/cover%20art.png"/>"#,
            secondBody: #"<p>Alpha two.</p>"#
        )
        var betaEntries = epub3Entries(
            title: "Beta",
            firstBody: #"<p>Beta only.</p><img src="../images/cover%20art.png"/>"#,
            secondBody: #"<p>Beta two.</p>"#
        )
        let alphaImageIndex = try XCTUnwrap(alphaEntries.firstIndex(where: { $0.0 == "OPS/images/cover art.png" }))
        let betaImageIndex = try XCTUnwrap(betaEntries.firstIndex(where: { $0.0 == "OPS/images/cover art.png" }))
        alphaEntries[alphaImageIndex].1 = Data("alpha-image".utf8)
        betaEntries[betaImageIndex].1 = Data("beta-image".utf8)
        let alphaArchive = try writeArchive(named: "Alpha.epub", entries: alphaEntries)
        let betaArchive = try writeArchive(named: "Beta.epub", entries: betaEntries)

        let alphaID = try EpubReader.install(epubURL: alphaArchive, libraryRootURL: library)
        let betaID = try EpubReader.install(epubURL: betaArchive, libraryRootURL: library)
        let alpha = try XCTUnwrap(EpubReader(identifier: alphaID, libraryRootURL: library))
        let beta = try XCTUnwrap(EpubReader(identifier: betaID, libraryRootURL: library))

        XCTAssertEqual(alpha.content(forKey: "chapter-1")?.href, beta.content(forKey: "chapter-1")?.href)
        XCTAssertNotEqual(alpha.initials, beta.initials)
        XCTAssertTrue(alpha.content(forKey: "chapter-1")?.html.contains(alpha.initials) == true)
        XCTAssertFalse(alpha.content(forKey: "chapter-1")?.html.contains(beta.initials) == true)
        XCTAssertTrue(beta.content(forKey: "chapter-1")?.html.contains(beta.initials) == true)
        XCTAssertEqual(
            Set(EpubReader.installedEpubs(libraryRootURL: library).map(\.initials)),
            Set([alpha.initials, beta.initials])
        )
        let sharedPath = "OPS/images/cover art.png"
        let alphaResource = try XCTUnwrap(alpha.resourceURL(for: sharedPath))
        let betaResource = try XCTUnwrap(beta.resourceURL(for: sharedPath))
        XCTAssertEqual(try Data(contentsOf: alphaResource), Data("alpha-image".utf8))
        XCTAssertEqual(try Data(contentsOf: betaResource), Data("beta-image".utf8))
        XCTAssertNotEqual(alphaResource.standardizedFileURL, betaResource.standardizedFileURL)
    }

    /**
     Verifies unsafe/colliding ZIP paths fail before publication and failed updates preserve live data.

     Setup:
     - installs a valid package, then attempts same-identifier updates with case-colliding members
       and a malformed spine reference

     Expected result:
     - both updates throw and the original indexed title/content remain readable

     Failure meaning:
     - extraction can overwrite files nondeterministically or staged validation can destroy a
       previously working EPUB.
     */
    func testInvalidArchiveUpdateDoesNotReplaceInstalledPackage() throws {
        let library = try makeTemporaryDirectory(named: "rollback-library")
        let validArchive = try writeArchive(named: "Stable.epub", entries: epub3Entries(
            title: "Stable Original",
            firstBody: #"<p>Original content.</p>"#,
            secondBody: #"<p>Second.</p>"#
        ))
        let stableIdentifier = try EpubReader.install(epubURL: validArchive, libraryRootURL: library)

        var collidingEntries = epub3Entries(
            title: "Replacement",
            firstBody: #"<p>Replacement.</p>"#,
            secondBody: #"<p>Second.</p>"#
        )
        collidingEntries.append(("ops/TEXT/chapter1.xhtml", Data("collision".utf8)))
        let collidingArchive = try writeArchive(named: "Stable.epub", entries: collidingEntries)
        XCTAssertThrowsError(try EpubReader.install(epubURL: collidingArchive, libraryRootURL: library))

        var malformedEntries = epub3Entries(
            title: "Malformed Replacement",
            firstBody: #"<p>Replacement.</p>"#,
            secondBody: #"<p>Second.</p>"#
        )
        let opfIndex = try XCTUnwrap(malformedEntries.firstIndex(where: { $0.0 == "OPS/package.opf" }))
        malformedEntries[opfIndex].1 = Data(
            String(decoding: malformedEntries[opfIndex].1, as: UTF8.self)
                .replacingOccurrences(of: #"idref="chapter-1""#, with: #"idref="missing""#)
                .utf8
        )
        let malformedArchive = try writeArchive(named: "Stable.epub", entries: malformedEntries)
        XCTAssertThrowsError(try EpubReader.install(epubURL: malformedArchive, libraryRootURL: library))

        let surviving = try XCTUnwrap(EpubReader(identifier: stableIdentifier, libraryRootURL: library))
        XCTAssertEqual(surviving.title, "Stable Original")
        XCTAssertTrue(surviving.content(forKey: "chapter-1")?.html.contains("Original content") == true)
    }

    /**
     Verifies a package member with a mismatched central-directory checksum is never published.

     Setup:
     - creates a structurally valid EPUB ZIP and corrupts matching local/central CRC fields

     Expected result:
     - installation reports the mismatched member and leaves the library empty

     Failure meaning:
     - damaged non-XML resources can pass extraction and become a seemingly successful install.
     */
    func testChecksumMismatchFailsBeforePublication() throws {
        let library = try makeTemporaryDirectory(named: "checksum-library")
        let archive = try writeArchive(named: "Damaged.epub", entries: epub3Entries(
            title: "Damaged",
            firstBody: #"<p>Readable metadata.</p>"#,
            secondBody: #"<p>Second.</p>"#
        ))
        var bytes = try Data(contentsOf: archive)
        let centralHeaderOffset = try XCTUnwrap(firstSignatureOffset(0x0201_4b50, in: bytes))
        let invalidChecksum: [UInt8] = [0xde, 0xad, 0xbe, 0xef]
        bytes.replaceSubrange(14..<18, with: invalidChecksum)
        bytes.replaceSubrange(
            (centralHeaderOffset + 16)..<(centralHeaderOffset + 20),
            with: invalidChecksum
        )
        try bytes.write(to: archive, options: .atomic)

        XCTAssertThrowsError(try EpubReader.install(epubURL: archive, libraryRootURL: library)) { error in
            guard case let EpubError.invalidEpub(message) = error else {
                return XCTFail("Expected invalidEpub, got \(error)")
            }
            XCTAssertTrue(message.contains("checksum mismatch"))
            XCTAssertTrue(message.contains("mimetype"))
        }
        XCTAssertTrue(EpubReader.installedEpubs(libraryRootURL: library).isEmpty)
    }

    /**
     Verifies an exact-name reinstall cannot make an existing reader span package generations.

     The first reader stays open while a second archive with the same Android/stable identity is
     installed. Its HTML, search rows, image bytes, and exact-generation resource reopen must remain
     on generation one; a new reader must see only generation two. Failure recreates PR-2's mixed
     old-index/new-resource state. Temporary generations are removed by `tearDown`.
     */
    func testExactReinstallKeepsOpenReaderOnImmutableGeneration() throws {
        let library = try makeTemporaryDirectory(named: "generation-isolation-library")
        var firstEntries = epub3Entries(
            title: "Generation One",
            firstBody: #"<p>generationone searchable.</p><img src="../images/cover%20art.png"/>"#,
            secondBody: #"<p>First second page.</p>"#
        )
        let firstImage = try XCTUnwrap(firstEntries.firstIndex { $0.0 == "OPS/images/cover art.png" })
        firstEntries[firstImage].1 = Data("generation-one-image".utf8)
        let firstArchive = try writeArchive(named: "Stable.epub", entries: firstEntries)
        let identifier = try EpubReader.install(epubURL: firstArchive, libraryRootURL: library)
        let firstReader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
        let firstGeneration = firstReader.generationIdentifier
        let firstContent = try XCTUnwrap(firstReader.content(forKey: "1"))

        var secondEntries = epub3Entries(
            title: "Generation Two",
            firstBody: #"<p>generationtwo searchable.</p><img src="../images/cover%20art.png"/>"#,
            secondBody: #"<p>Second second page.</p>"#
        )
        let secondImage = try XCTUnwrap(secondEntries.firstIndex { $0.0 == "OPS/images/cover art.png" })
        secondEntries[secondImage].1 = Data("generation-two-image".utf8)
        let secondArchive = try writeArchive(named: "Stable.epub", entries: secondEntries)
        XCTAssertEqual(
            try EpubReader.install(epubURL: secondArchive, libraryRootURL: library),
            identifier
        )
        let secondReader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))

        XCTAssertNotEqual(firstGeneration, secondReader.generationIdentifier)
        XCTAssertEqual(firstReader.title, "Generation One")
        XCTAssertTrue(firstReader.content(forKey: "1")?.html.contains("generationone") == true)
        XCTAssertEqual(firstReader.searchResults(query: "generationone").count, 1)
        XCTAssertTrue(firstReader.searchResults(query: "generationtwo").isEmpty)
        XCTAssertTrue(firstContent.html.contains("/\(firstGeneration)/"))
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(firstReader.resourceURL(for: "OPS/images/cover art.png"))),
            Data("generation-one-image".utf8)
        )
        XCTAssertEqual(secondReader.title, "Generation Two")
        XCTAssertTrue(secondReader.content(forKey: "1")?.html.contains("generationtwo") == true)
        XCTAssertEqual(
            try Data(contentsOf: XCTUnwrap(secondReader.resourceURL(for: "OPS/images/cover art.png"))),
            Data("generation-two-image".utf8)
        )

        let exactResourceReader = try XCTUnwrap(EpubReader(
            initials: firstReader.initials,
            generationIdentifier: firstGeneration,
            libraryRootURL: library
        ))
        XCTAssertEqual(exactResourceReader.title, "Generation One")
        XCTAssertEqual(exactResourceReader.extractedPath, firstReader.extractedPath)
    }

    /**
     Verifies Android's explicit EPUB Rebuild index action publishes a new immutable generation.

     A real EPUB is installed and kept open while `rebuildSearchIndex` constructs the replacement.
     The old reader must retain its generation-qualified content and search database, the returned
     reader and subsequent stable-id opens must use the new generation, and both readers must
     return the same source hit. Failure means Search could mutate a live reader in place, publish a
     partial index, or claim success while future opens still select the old generation.
     */
    func testExplicitSearchIndexRebuildPublishesNewGenerationWithoutInvalidatingLiveReader() throws {
        let library = try makeTemporaryDirectory(named: "explicit-search-rebuild-library")
        let archive = try writeArchive(named: "Rebuild.epub", entries: epub3Entries(
            title: "Rebuild Search",
            firstBody: #"<p>immutable rebuild target.</p><img src="../images/cover%20art.png"/>"#,
            secondBody: #"<p>Second.</p>"#
        ))
        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let originalReader = try XCTUnwrap(EpubReader(
            identifier: identifier,
            libraryRootURL: library
        ))
        let originalGeneration = originalReader.generationIdentifier
        let originalContent = try XCTUnwrap(originalReader.content(forKey: "1"))

        let rebuiltReader = try EpubReader.rebuildSearchIndex(
            identifier: identifier,
            libraryRootURL: library
        )
        let reopenedReader = try XCTUnwrap(EpubReader(
            identifier: identifier,
            libraryRootURL: library
        ))

        XCTAssertNotEqual(rebuiltReader.generationIdentifier, originalGeneration)
        XCTAssertEqual(reopenedReader.generationIdentifier, rebuiltReader.generationIdentifier)
        XCTAssertEqual(originalReader.generationIdentifier, originalGeneration)
        XCTAssertEqual(originalReader.content(forKey: "1"), originalContent)
        XCTAssertEqual(originalReader.searchResults(query: "immutable").count, 1)
        XCTAssertEqual(rebuiltReader.searchResults(query: "immutable").count, 1)
        XCTAssertTrue(originalContent.html.contains("/\(originalGeneration)/"))
        XCTAssertTrue(
            rebuiltReader.content(forKey: "1")?.html.contains(
                "/\(rebuiltReader.generationIdentifier)/"
            ) == true
        )
    }

    /**
     Verifies Android's Delete search index action preserves the EPUB and supports later rebuilding.

     A live reader remains searchable on its leased generation while the stable identity switches to
     a replacement with an empty FTS table. The replacement must still browse and render content,
     and Rebuild index must publish a third generation that restores the same hit. Failure means
     Delete Index either mutates live readers, deletes the document itself, or cannot be reversed by
     Android's paired Rebuild action.
     */
    func testDeleteSearchIndexPublishesIndexFreeGenerationAndRebuildRestoresHits() throws {
        let library = try makeTemporaryDirectory(named: "explicit-search-delete-library")
        let archive = try writeArchive(named: "DeleteIndex.epub", entries: epub3Entries(
            title: "Delete Search Index",
            firstBody: #"<p>retained searchable content.</p>"#,
            secondBody: #"<p>Second.</p>"#
        ))
        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let originalReader = try XCTUnwrap(EpubReader(
            identifier: identifier,
            libraryRootURL: library
        ))
        let originalGeneration = originalReader.generationIdentifier
        let originalContent = try XCTUnwrap(originalReader.content(forKey: "1"))
        XCTAssertEqual(originalReader.description, "DeleteIndex.epub")
        XCTAssertEqual(originalReader.searchResults(query: "retained").count, 1)

        let indexFreeReader = try EpubReader.deleteSearchIndex(
            identifier: identifier,
            libraryRootURL: library
        )
        let reopenedIndexFreeReader = try XCTUnwrap(EpubReader(
            identifier: identifier,
            libraryRootURL: library
        ))

        XCTAssertNotEqual(indexFreeReader.generationIdentifier, originalGeneration)
        XCTAssertEqual(
            reopenedIndexFreeReader.generationIdentifier,
            indexFreeReader.generationIdentifier
        )
        XCTAssertEqual(originalReader.searchResults(query: "retained").count, 1)
        XCTAssertEqual(indexFreeReader.searchResults(query: "retained").count, 0)
        XCTAssertEqual(indexFreeReader.content(forKey: "1")?.key, originalContent.key)
        XCTAssertEqual(indexFreeReader.content(forKey: "1")?.title, originalContent.title)
        XCTAssertTrue(indexFreeReader.content(forKey: "1")?.html.contains("retained searchable content") == true)

        let rebuiltReader = try EpubReader.rebuildSearchIndex(
            identifier: identifier,
            libraryRootURL: library
        )
        XCTAssertNotEqual(rebuiltReader.generationIdentifier, indexFreeReader.generationIdentifier)
        XCTAssertEqual(rebuiltReader.searchResults(query: "retained").count, 1)
        XCTAssertEqual(originalReader.searchResults(query: "retained").count, 1)
    }

    /**
     Verifies failure to switch the stable pointer cannot publish or retain a replacement generation.

     A complete prepared generation is renamed inside its writable container while the library root
     is read-only, forcing the subsequent atomic manifest write to fail. The old pointer bytes and
     current reader remain unchanged, and the unreferenced final generation is removed. Failure
     means a filesystem error can expose a replacement the stable identity never selected.
     */
    func testGenerationPointerWriteFailurePreservesCurrentGeneration() throws {
        let library = try makeTemporaryDirectory(named: "generation-pointer-rollback-library")
        let archive = try writeArchive(named: "Stable.epub", entries: epub3Entries(
            title: "Stable Original",
            firstBody: #"<p>Original generation.</p>"#,
            secondBody: #"<p>Second.</p>"#
        ))
        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let originalManifestURL = EpubReader.generationManifestURL(
            identifier: identifier,
            libraryRootURL: library
        )
        let originalManifestData = try Data(contentsOf: originalManifestURL)
        let replacementGeneration = EpubReader.newGenerationIdentifier()
        let container = EpubReader.generationContainerURL(identifier: identifier, libraryRootURL: library)
        let staging = container.appendingPathComponent(".staging-pointer-failure", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("package", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("replacement-index".utf8).write(to: staging.appendingPathComponent("index.sqlite3"))

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: library.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: library.path)
        }
        XCTAssertThrowsError(try EpubReader.publishPreparedGeneration(
            stagingGenerationURL: staging,
            manifest: EpubGenerationManifest(
                schemaVersion: EpubReader.generationManifestVersion,
                identifier: identifier,
                generationIdentifier: replacementGeneration
            ),
            libraryRootURL: library,
            fileManager: .default
        ))

        XCTAssertEqual(try Data(contentsOf: originalManifestURL), originalManifestData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: EpubReader.generationURL(
            identifier: identifier,
            generationIdentifier: replacementGeneration,
            libraryRootURL: library
        ).path))
        XCTAssertEqual(EpubReader(identifier: identifier, libraryRootURL: library)?.title, "Stable Original")
    }

    /**
     Verifies deletion hides a book immediately while an existing reader retains its generation.

     The stable pointer is removed with a reader open. Listing and new stable-id opens must fail,
     while the reader and its generation-qualified resource route remain usable until lease release.
     Failure either resurrects a deleted book or breaks media in a still-visible reader.
     */
    func testDeleteRetainsGenerationForActiveReaderOnly() throws {
        let library = try makeTemporaryDirectory(named: "generation-delete-library")
        let archive = try writeArchive(named: "Delete.epub", entries: epub3Entries(
            title: "Delete Me",
            firstBody: #"<p>Still visible.</p><img src="../images/cover%20art.png"/>"#,
            secondBody: #"<p>Second.</p>"#
        ))
        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))

        try EpubReader.delete(identifier: identifier, libraryRootURL: library)

        XCTAssertTrue(EpubReader.installedEpubs(libraryRootURL: library).isEmpty)
        XCTAssertNil(EpubReader(identifier: identifier, libraryRootURL: library))
        XCTAssertTrue(reader.content(forKey: "1")?.html.contains("Still visible") == true)
        XCTAssertNotNil(reader.resourceURL(for: "OPS/images/cover art.png"))
        XCTAssertNotNil(EpubReader(
            initials: reader.initials,
            generationIdentifier: reader.generationIdentifier,
            libraryRootURL: library
        ))
    }

    /**
     Verifies a file-system failure restores every path moved before the failed delete step.

     The fixture adds a legacy companion index so deletion has two published paths, then injects a
     failure on the second move. The current-generation pointer must be restored byte-for-byte, the
     original error must escape, and both listing and a fresh reader open must still find the book.
     A failure means the UI could keep a row after an error while storage silently hid its EPUB.
     */
    func testDeleteFailureRestoresPublishedBookAndPropagatesFilesystemError() throws {
        let library = try makeTemporaryDirectory(named: "generation-delete-rollback-library")
        let archive = try writeArchive(named: "DeleteRollback.epub", entries: epub3Entries(
            title: "Delete Rollback",
            firstBody: #"<p>Stable content.</p>"#,
            secondBody: #"<p>Second.</p>"#
        ))
        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let manifestURL = EpubReader.generationManifestURL(
            identifier: identifier,
            libraryRootURL: library
        )
        let originalManifest = try Data(contentsOf: manifestURL)
        let legacyIndexURL = EpubReader.legacyIndexURL(
            identifier: identifier,
            libraryRootURL: library
        )
        try Data("legacy index".utf8).write(to: legacyIndexURL)
        let fileManager = FailingEpubDeletionFileManager(failingMoveNumber: 2)

        XCTAssertThrowsError(try EpubReader.delete(
            identifier: identifier,
            libraryRootURL: library,
            fileManager: fileManager
        )) { error in
            XCTAssertEqual(error as? EpubDeletionTestError, .injectedMoveFailure)
        }

        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyIndexURL.path))
        XCTAssertEqual(EpubReader.installedEpubs(libraryRootURL: library).map(\.identifier), [identifier])
        XCTAssertNotNil(EpubReader(identifier: identifier, libraryRootURL: library))
    }

    /**
     Verifies a pre-commit file-system failure leaves an EPUB installed and reports the error.

     A regular file blocks creation of the same-volume deletion staging directory. Deletion must
     throw before moving the stable pointer, and both listing and stable-identifier open must still
     resolve the original package. A failure means the library can silently hide a book after an
     operation the UI reports as unsuccessful.
     */
    func testDeleteFailurePreservesPublishedEpub() throws {
        let library = try makeTemporaryDirectory(named: "generation-delete-failure-library")
        let archive = try writeArchive(named: "Delete Failure.epub", entries: epub3Entries(
            title: "Keep Me",
            firstBody: "<p>Preserved.</p>",
            secondBody: "<p>Second.</p>"
        ))
        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let deletionRoot = library.appendingPathComponent(".epub-deletions")
        try Data("not a directory".utf8).write(to: deletionRoot)

        XCTAssertThrowsError(try EpubReader.delete(identifier: identifier, libraryRootURL: library))

        XCTAssertEqual(EpubReader.installedEpubs(libraryRootURL: library).map(\.identifier), [identifier])
        XCTAssertEqual(EpubReader(identifier: identifier, libraryRootURL: library)?.title, "Keep Me")

        try FileManager.default.removeItem(at: deletionRoot)
        try EpubReader.delete(identifier: identifier, libraryRootURL: library)
    }

    /**
     Verifies legacy layouts and stale indexes publish new generation-scoped indexes, never mutate
     an existing generation in place.

     A current install is projected into the old top-level package/index layout, then reopened to
     trigger migration. Its current index version is subsequently invalidated with SQLite and
     reopened again. Both operations must select new tokens and generated HTML must carry only the
     selected token. Failure permits old/new package state to mix during migration or reindexing.
     */
    func testLegacyMigrationAndStaleIndexRebuildPublishNewGenerations() throws {
        let library = try makeTemporaryDirectory(named: "generation-migration-library")
        let archive = try writeArchive(named: "Legacy.epub", entries: epub3Entries(
            title: "Legacy Generation",
            firstBody: #"<p>Legacy content.</p><img src="../images/cover%20art.png"/>"#,
            secondBody: #"<p>Second.</p>"#
        ))
        let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
        let firstManifest = try XCTUnwrap(EpubReader.generationManifest(
            identifier: identifier,
            libraryRootURL: library
        ))
        let firstGenerationURL = EpubReader.generationURL(
            identifier: identifier,
            generationIdentifier: firstManifest.generationIdentifier,
            libraryRootURL: library
        )
        let legacyPackage = library.appendingPathComponent(identifier, isDirectory: true)
        let legacyIndex = EpubReader.legacyIndexURL(identifier: identifier, libraryRootURL: library)
        try FileManager.default.copyItem(
            at: firstGenerationURL.appendingPathComponent("package", isDirectory: true),
            to: legacyPackage
        )
        try FileManager.default.copyItem(
            at: firstGenerationURL.appendingPathComponent("index.sqlite3"),
            to: legacyIndex
        )
        try FileManager.default.removeItem(at: EpubReader.generationManifestURL(
            identifier: identifier,
            libraryRootURL: library
        ))
        try FileManager.default.removeItem(at: EpubReader.generationContainerURL(
            identifier: identifier,
            libraryRootURL: library
        ))

        var migratedReader: EpubReader? = try XCTUnwrap(EpubReader(
            identifier: identifier,
            libraryRootURL: library
        ))
        let migratedGeneration = try XCTUnwrap(migratedReader?.generationIdentifier)
        XCTAssertNotEqual(migratedGeneration, firstManifest.generationIdentifier)
        XCTAssertTrue(migratedReader?.content(forKey: "1")?.html.contains("/\(migratedGeneration)/") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPackage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyIndex.path))
        migratedReader = nil

        let migratedManifest = try XCTUnwrap(EpubReader.generationManifest(
            identifier: identifier,
            libraryRootURL: library
        ))
        let migratedIndex = EpubReader.generationURL(
            identifier: identifier,
            generationIdentifier: migratedManifest.generationIdentifier,
            libraryRootURL: library
        ).appendingPathComponent("index.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(
            migratedIndex.path,
            &database,
            SQLITE_OPEN_READWRITE,
            nil
        ), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            database,
            "UPDATE metadata SET value = 'stale' WHERE key = 'index_version'",
            nil,
            nil,
            nil
        ), SQLITE_OK)
        sqlite3_close(database)

        let rebuiltReader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
        XCTAssertNotEqual(rebuiltReader.generationIdentifier, migratedGeneration)
        XCTAssertTrue(rebuiltReader.content(forKey: "1")?.html.contains(
            "/\(rebuiltReader.generationIdentifier)/"
        ) == true)
    }

    /**
     Verifies private collision-resistant paths do not alter Android-visible EPUB initials.

     Setup installs a normal filename, punctuation/Unicode, Android's unusual `A-z` punctuation,
     and case-only variants, then reinstalls the normal filename with replacement content. Initials
     must be Android's exact sanitized full display filename (including `.epub`), case variants must
     remain distinct on case-insensitive filesystems, and exact-name reinstall must retain its
     private id. The `A-z` fixture must also read a packaged resource successfully. A failure breaks
     portable workspace/bookmark/link identity or creates a filename-based overwrite regression.
     */
    func testDisplayFilenamesProduceAndroidInitialsAndStablePrivateIdentifiers() throws {
        let library = try makeTemporaryDirectory(named: "filename-identity-library")
        XCTAssertEqual(
            EpubReader.initials(forDisplayFileName: "[x]\\^.epub"),
            "Epub-[x]\\^_epub"
        )
        let fixtures = [
            ("book.epub", "Book", "Epub-book_epub"),
            ("Tést!.epub", "Unicode", "Epub-T_st__epub"),
            ("[x]\\^.epub", "Android Regex Range", "Epub-[x]\\^_epub"),
            ("Case.epub", "Upper Case", "Epub-Case_epub"),
            ("case.epub", "Lower Case", "Epub-case_epub")
        ]
        var identifiers: [String: String] = [:]
        for (fileName, title, expectedInitials) in fixtures {
            let archive = try writeArchive(named: fileName, entries: epub3Entries(
                title: title,
                firstBody: "<p>\(title) content.</p>",
                secondBody: "<p>Second.</p>"
            ))
            let identifier = try EpubReader.install(epubURL: archive, libraryRootURL: library)
            identifiers[fileName] = identifier
            let reader = try XCTUnwrap(EpubReader(identifier: identifier, libraryRootURL: library))
            XCTAssertEqual(reader.initials, expectedInitials)
            XCTAssertEqual(reader.sourceFileName, fileName)
        }

        XCTAssertEqual(Set(identifiers.values).count, fixtures.count)
        XCTAssertEqual(Set(identifiers.values.map { $0.lowercased() }).count, fixtures.count)
        let replacement = try writeArchive(named: "book.epub", entries: epub3Entries(
            title: "Book Replacement",
            firstBody: "<p>Replacement content.</p>",
            secondBody: "<p>Second.</p>"
        ))
        let replacementID = try EpubReader.install(epubURL: replacement, libraryRootURL: library)
        XCTAssertEqual(replacementID, identifiers["book.epub"])
        let replacementReader = try XCTUnwrap(EpubReader(identifier: replacementID, libraryRootURL: library))
        XCTAssertEqual(replacementReader.initials, "Epub-book_epub")
        XCTAssertEqual(replacementReader.title, "Book Replacement")

        let androidRangeID = try XCTUnwrap(identifiers["[x]\\^.epub"])
        let androidRangeReader = try XCTUnwrap(
            EpubReader(identifier: androidRangeID, libraryRootURL: library)
        )
        let resourceURL = try XCTUnwrap(androidRangeReader.resourceURL(for: "OPS/images/cover art.png"))
        XCTAssertEqual(try Data(contentsOf: resourceURL), Data([0x89, 0x50, 0x4e, 0x47]))
    }

    /**
     Verifies distinct filenames that collapse to one Android initials value fail without aliasing.

     Space/underscore and punctuation-only pairs first prove their private path ids are distinct in
     isolated libraries. Installing either pair together must reject the second source with a typed
     identity conflict and leave the first package readable. A failure either silently overwrites a
     book or invents non-Android initials that cannot round-trip through Android state.
     */
    func testCollidingAndroidInitialsRejectSecondDistinctSourceWithoutOverwrite() throws {
        let spaceArchive = try writeArchive(named: "a b.epub", entries: epub3Entries(
            title: "Space",
            firstBody: "<p>Space content.</p>",
            secondBody: "<p>Second.</p>"
        ))
        let underscoreArchive = try writeArchive(named: "a_b.epub", entries: epub3Entries(
            title: "Underscore",
            firstBody: "<p>Underscore content.</p>",
            secondBody: "<p>Second.</p>"
        ))
        let isolatedSpaceID = try EpubReader.install(
            epubURL: spaceArchive,
            libraryRootURL: makeTemporaryDirectory(named: "space-isolated")
        )
        let isolatedUnderscoreID = try EpubReader.install(
            epubURL: underscoreArchive,
            libraryRootURL: makeTemporaryDirectory(named: "underscore-isolated")
        )
        XCTAssertNotEqual(isolatedSpaceID.lowercased(), isolatedUnderscoreID.lowercased())

        let library = try makeTemporaryDirectory(named: "initials-conflict-library")
        let spaceID = try EpubReader.install(epubURL: spaceArchive, libraryRootURL: library)
        XCTAssertThrowsError(
            try EpubReader.install(epubURL: underscoreArchive, libraryRootURL: library)
        ) { error in
            XCTAssertEqual(
                error as? EpubError,
                .identityConflict(
                    initials: "Epub-a_b_epub",
                    existingFileName: "a b.epub",
                    incomingFileName: "a_b.epub"
                )
            )
        }
        XCTAssertEqual(EpubReader.installedEpubs(libraryRootURL: library).count, 1)
        XCTAssertEqual(EpubReader(identifier: spaceID, libraryRootURL: library)?.title, "Space")

        let punctuationOne = try writeArchive(named: "!!!.epub", entries: epub3Entries(
            title: "Punctuation One",
            firstBody: "<p>One.</p>",
            secondBody: "<p>Second.</p>"
        ))
        let punctuationTwo = try writeArchive(named: "???.epub", entries: epub3Entries(
            title: "Punctuation Two",
            firstBody: "<p>Two.</p>",
            secondBody: "<p>Second.</p>"
        ))
        let punctuationLibrary = try makeTemporaryDirectory(named: "punctuation-conflict-library")
        _ = try EpubReader.install(epubURL: punctuationOne, libraryRootURL: punctuationLibrary)
        XCTAssertThrowsError(try EpubReader.install(epubURL: punctuationTwo, libraryRootURL: punctuationLibrary))
    }

    /**
     Verifies URI resolution rejects encoded traversal/separators and does not decode canonical
     resource paths a second time.

     The resolver is attacked with plain and percent-encoded root escapes, encoded slash/backslash,
     and NUL input. A double-encoded separator represents a literal percent-bearing filename and is
     expected to remain contained and addressable. A failure means crafted EPUB markup or a custom
     resource URL can escape the package root or resolve a different member than the indexed path.
     */
    func testPackageURIResolutionRejectsEncodedTraversalAndSeparatorAmbiguity() throws {
        let packageRoot = try makeTemporaryDirectory(named: "uri-containment-root")
        let resolver = EpubPackagePathResolver(packageRootURL: packageRoot)
        let escapingHrefs = [
            "../../../outside.txt",
            "%2e%2e/%2e%2e/%2e%2e/outside.txt",
            "%2Fetc/passwd",
            "images%2F..%2F..%2Foutside.txt",
            "%5C..%5Coutside.txt",
            "images/%00.png"
        ]
        for href in escapingHrefs {
            XCTAssertThrowsError(try resolver.resolve(href, relativeTo: "OPS/text/chapter.xhtml"), href)
        }

        let literal = try XCTUnwrap(
            resolver.resolve("images/literal%252Fname.png", relativeTo: "OPS/chapter.xhtml")
        )
        XCTAssertEqual(literal.path, "OPS/images/literal%2Fname.png")
        let literalURL = try resolver.fileURL(for: literal.path)
        try FileManager.default.createDirectory(
            at: literalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("literal-percent-name".utf8).write(to: literalURL)
        XCTAssertEqual(try Data(contentsOf: literalURL), Data("literal-percent-name".utf8))
        XCTAssertThrowsError(try resolver.fileURL(for: "../outside.txt"))
        let encodedLiteralURL = try resolver.fileURL(for: "OPS/%2e%2e/outside.txt")
        XCTAssertTrue(encodedLiteralURL.path.hasPrefix(packageRoot.standardizedFileURL.path + "/"))
        XCTAssertTrue(encodedLiteralURL.path.contains("%2e%2e"))
    }

    /// Creates and records an isolated temporary directory.
    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    /// Writes one real stored ZIP fixture and records it for cleanup.
    private func writeArchive(named name: String, entries: [(String, Data)]) throws -> URL {
        let directory = try makeTemporaryDirectory(named: "epub-archive")
        let url = directory.appendingPathComponent(name)
        let data = try ZipArchiveWriter.storedArchive(entries: entries.map {
            ZipArchiveWriterEntry(name: $0.0, data: $0.1)
        })
        try data.write(to: url, options: .atomic)
        return url
    }

    /**
     Finds the first little-endian ZIP signature in fixture data.

     - Parameters:
       - signature: Four-byte ZIP signature value.
       - data: Archive bytes to inspect.
     - Returns: Signature byte offset, or `nil` when absent.
     - Side effects: None.
     - Failure modes: None.
     */
    private func firstSignatureOffset(_ signature: UInt32, in data: Data) -> Int? {
        let bytes: [UInt8] = [
            UInt8(signature & 0xff),
            UInt8((signature >> 8) & 0xff),
            UInt8((signature >> 16) & 0xff),
            UInt8((signature >> 24) & 0xff)
        ]
        guard data.count >= bytes.count else { return nil }
        return (0...(data.count - bytes.count)).first { offset in
            data[offset..<(offset + bytes.count)].elementsEqual(bytes)
        }
    }

    /// Builds a namespaced EPUB 3 fixture with nav, resources, and two XHTML spine items.
    private func epub3Entries(
        title: String,
        language: String = "en",
        firstBodyAttributes: String = "",
        firstBody: String,
        secondBody: String
    ) -> [(String, Data)] {
        stringEntries([
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>
                <rootfile media-type="application/oebps-package+xml" full-path="OPS/package.opf"/>
              </rootfiles>
            </container>
            """),
            ("OPS/package.opf", """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="book-id">urn:test:\(title)</dc:identifier>
                <dc:title>\(title)</dc:title>
                <dc:creator>Ada Reader</dc:creator>
                <dc:language>\(language)</dc:language>
              </metadata>
              <manifest>
                <item media-type="application/xhtml+xml" properties="nav" href="nav.xhtml" id="nav"/>
                <item id="chapter-1" href="text/chapter1.xhtml" media-type="application/xhtml+xml"/>
                <item href="text/chapter2.xhtml" media-type="application/xhtml+xml" id="chapter-2"/>
                <item id="style" href="styles/book.css" media-type="text/css"/>
                <item id="nested-style" href="styles/nested.css" media-type="text/css"/>
                <item id="cover" href="images/cover%20art.png" media-type="image/png"/>
                <item id="font" href="fonts/reader.woff2" media-type="font/woff2"/>
              </manifest>
              <spine>
                <itemref idref="chapter-1"/>
                <itemref idref="chapter-2"/>
              </spine>
            </package>
            """),
            ("OPS/nav.xhtml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <body><nav epub:type="toc"><ol>
                <li><a href="text/chapter1.xhtml#start">Opening</a><ol>
                  <li><a href="text/chapter2.xhtml#target">Second</a></li>
                </ol></li>
              </ol></nav></body>
            </html>
            """),
            ("OPS/text/chapter1.xhtml", xhtml(body: firstBody, bodyAttributes: firstBodyAttributes)),
            ("OPS/text/chapter2.xhtml", xhtml(body: secondBody)),
            ("OPS/styles/book.css", """
            @import "nested.css";
            body { color: red; line-height: 1.8; }
            .reader { color: blue; font-weight:bold; }
            @font-face { font-family: Reader; src: url('../fonts/reader.woff2'); }
            """),
            ("OPS/styles/nested.css", """
            .nested { color: purple; font-style:italic; background-image:url('https://tracker.invalid/nested.png'); }
            """),
            ("OPS/images/cover art.png", String(decoding: Data([0x89, 0x50, 0x4e, 0x47]), as: UTF8.self)),
            ("OPS/images/icons.svg", #"<svg xmlns="http://www.w3.org/2000/svg"><path id="mark"/></svg>"#),
            ("OPS/fonts/reader.woff2", "font-bytes")
        ], binaryOverrides: ["OPS/images/cover art.png": Data([0x89, 0x50, 0x4e, 0x47])])
    }

    /// Builds a minimal EPUB 2 fixture with nested NCX points.
    private func epub2Entries() -> [(String, Data)] {
        stringEntries([
            ("mimetype", "application/epub+zip"),
            ("META-INF/container.xml", """
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """),
            ("OEBPS/content.opf", """
            <package xmlns="http://www.idpf.org/2007/opf" version="2.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Legacy Book</dc:title><dc:language>en</dc:language>
              </metadata>
              <manifest>
                <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
                <item id="legacy" href="text/legacy.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine toc="ncx"><itemref idref="legacy"/></spine>
            </package>
            """),
            ("OEBPS/toc.ncx", """
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
              <navPoint id="one"><navLabel><text>Legacy Start</text></navLabel>
                <content src="text/legacy.xhtml#legacy-start"/>
                <navPoint id="two"><navLabel><text>Nested Topic</text></navLabel>
                  <content src="text/legacy.xhtml#nested"/>
                </navPoint>
              </navPoint>
            </navMap></ncx>
            """),
            ("OEBPS/text/legacy.xhtml", xhtml(body: """
            <h1 id="legacy-start">Legacy Start</h1><p id="nested">Nested topic.</p>
            """))
        ])
    }

    /**
     Wraps fixture markup in well-formed XHTML with a linked stylesheet.

     - Parameters:
       - body: Markup inserted inside the XHTML body.
       - bodyAttributes: Optional body attributes used to verify native-wrapper preservation.
     - Returns: Deterministic XHTML fixture text.
     - Side effects: None.
     */
    private func xhtml(body: String, bodyAttributes: String = "") -> String {
        let renderedAttributes = bodyAttributes.isEmpty ? "" : " \(bodyAttributes)"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>Fixture</title><link rel="stylesheet" href="../styles/book.css"/></head>
          <body\(renderedAttributes)>\(body)</body>
        </html>
        """
    }

    /// Converts UTF-8 fixture strings to ZIP entries, with optional exact binary replacements.
    private func stringEntries(
        _ entries: [(String, String)],
        binaryOverrides: [String: Data] = [:]
    ) -> [(String, Data)] {
        entries.map { name, value in
            (name, binaryOverrides[name] ?? Data(value.utf8))
        }
    }
}

/** Deterministic file-system failure injected into the EPUB deletion transaction. */
private enum EpubDeletionTestError: Error, Equatable {
    /// One configured `moveItem` call fails before mutating the source path.
    case injectedMoveFailure
}

/**
 File manager that fails exactly one numbered move while delegating every other operation to
 Foundation.

 The EPUB deletion rollback test fails the second commit move and allows the subsequent reverse move
 to succeed. It records no global state and affects only calls made through this instance.
 */
private final class FailingEpubDeletionFileManager: FileManager, @unchecked Sendable {
    /// One-based move invocation that should throw the injected error.
    private let failingMoveNumber: Int

    /// Number of move requests observed by this instance.
    private var moveCount = 0

    /** Creates a manager that fails one one-based move invocation. */
    init(failingMoveNumber: Int) {
        self.failingMoveNumber = failingMoveNumber
        super.init()
    }

    /**
     Throws before the configured move and delegates all other moves to `FileManager`.

     - Parameters:
       - srcURL: Existing path that would be moved.
       - dstURL: Destination path for successful calls.
     - Side effects: Increments `moveCount`; successful calls mutate the real test filesystem.
     - Throws: `EpubDeletionTestError.injectedMoveFailure` for the configured invocation, otherwise
       Foundation file-system errors from `super.moveItem`.
     */
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        moveCount += 1
        if moveCount == failingMoveNumber {
            throw EpubDeletionTestError.injectedMoveFailure
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
