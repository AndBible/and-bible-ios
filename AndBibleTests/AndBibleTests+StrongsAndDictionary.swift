import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import struct SwiftUI.Binding
import enum SwiftUI.ColorScheme
import struct SwiftUI.EdgeInsets
import struct SwiftUI.EmptyView
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

extension AndBibleTests {
    func testCSVSetEncodingAndDecodingRoundTrip() {
        let encoded = AppPreferenceRegistry.encodeCSVSet(["  KJV  ", "", "ESV", "KJV", "  "])
        XCTAssertEqual(encoded, "ESV,KJV,KJV")
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(encoded), ["ESV", "KJV", "KJV"])
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(nil), [])
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(""), [])
    }

    func testStrongsQueryNormalizationHandlesLeadingZeroes() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "H02022")
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./H02022", "Word//Lemma./H2022"]
        )
    }

    func testStrongsQueryNormalizationAcceptsDecoratedInput() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "lemma:strong:g00123")
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./G00123", "Word//Lemma./G0123", "Word//Lemma./G123"]
        )
    }

    func testStrongsQueryNormalizationIncludesIntermediateZeroTrimVariants() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "H00430")
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./H00430", "Word//Lemma./H0430", "Word//Lemma./H430"]
        )
    }

    func testParseVerseKeySupportsHumanReadableFormat() {
        let parsed = StrongsSearchSupport.parseVerseKey("I Samuel 2:3")
        XCTAssertEqual(parsed?.book, "I Samuel")
        XCTAssertEqual(parsed?.chapter, 2)
        XCTAssertEqual(parsed?.verse, 3)
    }

    func testParseVerseKeySupportsOsisFormat() {
        let parsed = StrongsSearchSupport.parseVerseKey("Gen.1.1")
        XCTAssertEqual(parsed?.book, "Genesis")
        XCTAssertEqual(parsed?.chapter, 1)
        XCTAssertEqual(parsed?.verse, 1)
    }

    func testParseVerseKeySupportsOsisFormatWithSuffix() {
        let parsed = StrongsSearchSupport.parseVerseKey("Gen.1.1!crossReference.a")
        XCTAssertEqual(parsed?.book, "Genesis")
        XCTAssertEqual(parsed?.chapter, 1)
        XCTAssertEqual(parsed?.verse, 1)
    }

    func testStrongsSearchFindAllOccurrencesReturnsBundledKJVMatches() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let installedModules = manager.installedModules()
        XCTAssertTrue(
            installedModules.contains(where: { $0.name == "KJV" && $0.features.contains(.strongsNumbers) }),
            "Expected bundled KJV module with Strong's support to be installed for regression testing"
        )

        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for Strong's regression testing"
        )
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H02022"),
            "Expected H02022 to normalize into entry-attribute Strong's search queries"
        )

        let hits = StrongsSearchSupport.searchVerseHits(in: module, queryOptions: queryOptions)

        XCTAssertFalse(
            hits.isEmpty,
            "Expected the bundled KJV Strong's search for H02022 to return at least one verse"
        )
        XCTAssertTrue(
            hits.allSatisfy { !$0.reference.isEmpty },
            "Expected Strong's hits to parse into verse references"
        )
    }

    func testStrongsSearchFindAllOccurrencesSupportsIntermediateZeroTrimVariant() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for Strong's regression testing"
        )
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H00430"),
            "Expected H00430 to normalize into Strong's search queries"
        )

        let hits = StrongsSearchSupport.searchVerseHits(in: module, queryOptions: queryOptions)

        XCTAssertFalse(
            hits.isEmpty,
            "Expected the bundled KJV Strong's search for H00430 to return at least one verse"
        )
    }

    func testBibleChapterDocumentBuilderPreservesSecondCorinthiansIntroAndChapterMarker() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleChapterDocumentBuilder(module: module, includeHeadings: true)

        let chapter = try XCTUnwrap(builder.loadChapter(osisBookId: "2Cor", chapter: 1))

        XCTAssertFalse(chapter.addChapter)
        XCTAssertGreaterThan(chapter.verseCount, 0)
        XCTAssertTrue(chapter.xml.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS"))
        XCTAssertTrue(chapter.xml.contains("<chapter"))
        XCTAssertTrue(chapter.xml.contains("CHAPTER 1."))
    }

    func testBibleChapterDocumentBuilderStillEmitsChapterMarkerWhenSectionTitlesAreDisabled() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleChapterDocumentBuilder(module: module, includeHeadings: false)

        let chapter = try XCTUnwrap(builder.loadChapter(osisBookId: "2Cor", chapter: 1))

        XCTAssertFalse(chapter.addChapter)
        XCTAssertTrue(chapter.xml.contains("<chapter osisID=\"2Cor.1\""))
        XCTAssertFalse(chapter.xml.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS"))
    }

    func testBibleChapterDocumentBuilderKeepsRenderableChapterStartMarkers() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleChapterDocumentBuilder(module: module, includeHeadings: true)

        let chapter = try XCTUnwrap(builder.loadChapter(osisBookId: "2Cor", chapter: 2))
        let hasOpeningMarker = chapter.xml.range(
            of: #"<chapter\b[^>]*osisID="2Cor\.2"[^>]*sID="#,
            options: .regularExpression
        ) != nil

        XCTAssertFalse(chapter.addChapter)
        XCTAssertTrue(
            hasOpeningMarker || chapter.xml.contains("<chapter n=\"2\""),
            "Expected a visible chapter start marker, not only a closing chapter tag. XML: \(chapter.xml)"
        )
        XCTAssertFalse(
            chapter.xml.contains("<chapter eID=") && !hasOpeningMarker,
            "A closing-only chapter tag suppresses Vue's synthetic chapter number without rendering a visible one. XML: \(chapter.xml)"
        )
    }

    func testSwordModuleRawChapterKeysExposeIntroStructure() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))

        module.setKey("=2Cor.0.0")
        _ = module.currentVerseKeyChildren()
        let bookIntro = module.rawEntry()

        module.setKey("=2Cor.1.0")
        let chapterIntroKey = module.currentVerseKeyChildren()
        let chapterIntro = module.rawEntry()

        module.setKey("=2Cor.2.0")
        let secondChapterIntroKey = module.currentVerseKeyChildren()
        let secondChapterIntro = module.rawEntry()

        module.setKey("2Cor 1")
        let chapterKeyRawEntry = module.rawEntry()

        XCTAssertFalse(bookIntro.isEmpty)
        XCTAssertFalse(chapterIntro.isEmpty)
        XCTAssertFalse(secondChapterIntro.isEmpty)
        XCTAssertEqual(chapterIntroKey?.chapter, 1)
        XCTAssertEqual(chapterIntroKey?.verse, 0)
        XCTAssertEqual(secondChapterIntroKey?.chapter, 2)
        XCTAssertEqual(secondChapterIntroKey?.verse, 0)
        XCTAssertTrue(
            bookIntro.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS")
                || chapterIntro.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS")
        )
        XCTAssertTrue(
            chapterIntro.contains("<chapter")
                || secondChapterIntro.contains("<chapter")
                || chapterKeyRawEntry.contains("<chapter"),
            "Expected libsword to expose a chapter marker somewhere in chapter-intro access paths"
        )
    }

    func testCanonicalStrongsKeyNameUsesResolvedEntryMetadataWhenCurrentKeyIsBlank() {
        let rawEntry = """
        <entryFree n="H6440"><title>H6440</title> <foreign xml:lang="he">פָּנֶה</foreign>, pl. <foreign xml:lang="he">פָּנִים</foreign> <hi rend="italic">face</hi>, also <hi rend="italic">faces</hi></entryFree>
        """

        let keyName = BibleReaderController.canonicalStrongsKeyName(
            requested: "H06440",
            actualKey: "",
            rawEntry: rawEntry
        )

        XCTAssertEqual(keyName, "06440")
    }

    func testDictionaryEntryKeyExtractsEntryFreeAttributeWithFlexibleWhitespace() {
        let rawEntry = #"<entryFree type="x" n = "430"><orth>אֱלֹהִים</orth></entryFree>"#

        XCTAssertEqual(
            BibleReaderController.dictionaryEntryKey(actualKey: "", rawEntry: rawEntry),
            "430"
        )
    }

    func testLinkifyRawDictionaryXMLLinksStructuredAndPlainStrongsReferences() {
        let rawEntry = """
        <entryFree n="6440"><def>From 6437; see HEBREW for 05774 and <ref target="StrongsHebrew/02421">2421</ref>.</def></entryFree>
        """

        let linkified = BibleReaderController.linkifyRawDictionaryXML(rawEntry, defaultPrefix: "H")

        XCTAssertTrue(linkified.contains("<entryFree"))
        XCTAssertTrue(linkified.contains("<a href=\"ab-w://?strong=H6437\">6437</a>"))
        XCTAssertTrue(linkified.contains("see HEBREW for <a href=\"ab-w://?strong=H05774\">05774</a>"))
        XCTAssertTrue(linkified.contains("<a href=\"ab-w://?strong=H02421\">2421</a>"))
    }

    func testStrongsLookupKeyOptionsIncludeIntermediateZeroTrimVariants() {
        XCTAssertEqual(
            BibleReaderController.strongsLookupKeyOptions(for: "H00430"),
            ["H00430", "00430", "00430\r", "0430", "0430\r", "H0430", "430", "430\r", "H430"]
        )
    }

    func testDictionaryLookupCandidateRejectsNearestEntryLeakForIntermediateZeroTrimKey() {
        let rawEntry = """
        <entryFree n="430"><orth>אֱלֹהִים</orth></entryFree>
        """
        let renderedText = """
        <div><p>8674 Tatnay tat-ten-ah'-ee of foreign derivation; Tattenai.</p></div>
        """

        XCTAssertEqual(
            BibleReaderController.dictionaryLookupCandidateRejectionReason(
                requested: "H00430",
                actualKey: "0430",
                rawEntry: rawEntry,
                renderedText: renderedText
            ),
            .renderedEntryMismatch
        )
        XCTAssertNil(
            BibleReaderController.dictionaryLookupCandidateRejectionReason(
                requested: "H00430",
                actualKey: "0430",
                rawEntry: rawEntry,
                renderedText: "<div><p>430 'elohiym gods in the ordinary sense.</p></div>"
            )
        )
    }

    func testRawDictionaryEntryMatchesRequestedKeyRejectsMisboundRawEntries() {
        let mismatchedRawEntry = """
        <entryFree n="8674"><orth>תּתּני</orth></entryFree>
        """
        let matchingRawEntry = """
        <entryFree n="5775"><orth>עוף</orth></entryFree>
        """

        XCTAssertFalse(
            BibleReaderController.rawDictionaryEntryMatchesRequestedKey(
                requested: "H05775",
                rawEntry: mismatchedRawEntry
            )
        )
        XCTAssertTrue(
            BibleReaderController.rawDictionaryEntryMatchesRequestedKey(
                requested: "05775\r",
                rawEntry: matchingRawEntry
            )
        )
    }

    func testRenderedDictionaryEntryKeyExtractsLeadingNumericHeadword() {
        let rendered = """
        <div><p>8674 Tatnay tat-ten-ah'-ee of foreign derivation; Tattenai.</p></div>
        """

        XCTAssertEqual(
            BibleReaderController.renderedDictionaryEntryKey(renderedText: rendered),
            "8674"
        )
    }

    func testRenderedDictionaryEntryMatchesRequestedKeyRejectsMismatchedRenderedHeadword() {
        let rendered = """
        <div><p>8674 Tatnay tat-ten-ah'-ee of foreign derivation; Tattenai.</p></div>
        """

        XCTAssertFalse(
            BibleReaderController.renderedDictionaryEntryMatchesRequestedKey(
                requested: "H00430",
                renderedText: rendered
            )
        )
        XCTAssertTrue(
            BibleReaderController.renderedDictionaryEntryMatchesRequestedKey(
                requested: "H00430",
                renderedText: "<div><p>430 'elohiym gods in the ordinary sense.</p></div>"
            )
        )
    }

    func testRenderedDictionaryEntryMatchesRequestedKeyIgnoresCrossReferenceOnlyNumbers() {
        let rendered = """
        <div><p>From 6437; see HEBREW for 05774 and 02421.</p></div>
        """

        XCTAssertTrue(
            BibleReaderController.renderedDictionaryEntryMatchesRequestedKey(
                requested: "H05774",
                renderedText: rendered
            )
        )
        XCTAssertNil(BibleReaderController.renderedDictionaryEntryKey(renderedText: rendered))
    }

    func testIsSupportedStrongsDictionaryModuleNameMatchesAndroidCuratedPolicy() {
        XCTAssertFalse(BibleReaderController.isSupportedStrongsDictionaryModuleName("BDBGlosses_Strongs"))
        XCTAssertTrue(BibleReaderController.isSupportedStrongsDictionaryModuleName("StrongsHebrew"))
        XCTAssertTrue(BibleReaderController.isSupportedStrongsDictionaryModuleName("InvStrongsRealHebrew"))
    }

    func testRenderedContentStateDefaultsToNeutralToken() {
        let controller = BibleReaderController(bridge: BibleBridge())

        XCTAssertEqual(
            controller.renderedContentState,
            BibleReaderController.emptyRenderedContentState
        )
    }
}
