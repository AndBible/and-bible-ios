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
import struct SwiftUI.EmptyView
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

/**
 Package-level reader navigation and bridge integration tests migrated from the app-host bundle.

 The suite exercises BibleUI reader controller, link-routing, multi-document, selection,
 synchronized-scroll, and navigation-coordinator contracts using package fixtures. It intentionally
 avoids app delegate, scene, or installed app bootstrap behavior so the coverage runs in the
 app-host-free BibleUI package lane.
 */
final class ReaderNavigationTests: BibleUISwordFixtureTestCase {

    @MainActor
    func testBridgeSendResponseEmitsCallIdResponseJavaScript() {
        let bridge = BibleBridge()
        var scripts: [String] = []
        bridge.javaScriptEvaluationObserver = { script in
            scripts.append(script)
        }

        bridge.sendResponse(callId: 54, value: "null")
        bridge.sendResponse(callId: 55, value: ["osisRef": "Gen.1.1"])

        XCTAssertEqual(
            scripts,
            [
                "bibleView.response(54, null);",
                #"bibleView.response(55, {"osisRef":"Gen.1.1"});"#,
            ]
        )
    }

    /**
     Protects the Swift-to-Vue bridge payload key contract for core client objects.

     The OSIS fragment fixture mirrors `bibleview-js/src/types/client-objects.ts` so
     regressions in required web-client fields, including Strong's-capability metadata,
     fail in unit tests before malformed bridge JSON reaches the reader.
     */
    func testBridgePayloadKeysMatchWebClientContracts() throws {
        let fragment = OsisFragment(
            xml: "<div>In the beginning...</div>",
            key: "Gen.1",
            keyName: "Genesis 1",
            v11n: "KJVA",
            bookCategory: "BIBLE",
            bookInitials: "KJV",
            bookAbbreviation: "Gen",
            osisRef: "Gen.1",
            isNewTestament: false,
            features: OsisFeatures(type: "hebrew", keyName: "H00430"),
            hasStrongs: true,
            ordinalRange: [1, 31],
            language: "en",
            direction: "ltr"
        )
        let fragmentObject = try bridgeJSONObject(fragment)
        assertJSONKeys(
            fragmentObject,
            [
                "xml",
                "key",
                "keyName",
                "v11n",
                "bookCategory",
                "bookInitials",
                "bookAbbreviation",
                "osisRef",
                "isNewTestament",
                "features",
                "hasStrongs",
                "ordinalRange",
                "language",
                "direction",
                "isNativeHtml",
            ]
        )
        XCTAssertEqual(fragmentObject["hasStrongs"] as? Bool, true)
        XCTAssertEqual(fragmentObject["isNativeHtml"] as? Bool, false)
        let features = try XCTUnwrap(fragmentObject["features"] as? [String: Any])
        assertJSONKeys(features, ["type", "keyName"])

        let label = LabelData(
            id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Important",
            style: BookmarkStyleData(
                color: 0xFFFF0000,
                isSpeak: true,
                isParagraphBreak: true,
                underline: true,
                underlineWholeVerse: true,
                markerStyle: true,
                markerStyleWholeVerse: true,
                hideStyle: true,
                hideStyleWholeVerse: true,
                customIcon: "star"
            ),
            isRealLabel: true
        )
        let labelObject = try bridgeJSONObject(label)
        assertJSONKeys(labelObject, ["id", "name", "style", "isRealLabel"])

        let style = try XCTUnwrap(labelObject["style"] as? [String: Any])
        assertJSONKeys(
            style,
            [
                "color",
                "isSpeak",
                "isParagraphBreak",
                "underline",
                "underlineWholeVerse",
                "markerStyle",
                "markerStyleWholeVerse",
                "hideStyle",
                "hideStyleWholeVerse",
                "customIcon",
            ]
        )

        let query = SelectionQuery(
            bookInitials: "KJV",
            osisRef: "Gen.1.1-Gen.1.3",
            startOrdinal: 0,
            startOffset: 1,
            endOrdinal: 2,
            endOffset: 50,
            bookmarks: ["id1", "id2"],
            text: "In the beginning God created..."
        )
        let queryObject = try bridgeJSONObject(query)
        assertJSONKeys(
            queryObject,
            [
                "bookInitials",
                "osisRef",
                "startOrdinal",
                "startOffset",
                "endOrdinal",
                "endOffset",
                "bookmarks",
                "text",
            ]
        )
    }

    /**
     Protects the Swift-to-Vue bridge payload key contract for plain OSIS fragments.

     Plain Bible fragments often omit an explicit `features` argument because no Strong's or
     morphology metadata is available. A passing test proves those fragments still emit the
     TypeScript-required `features` object as `{}` rather than omitting the key from bridge JSON.
     */
    func testBridgePayloadIncludesEmptyFeaturesObjectByDefault() throws {
        let fragment = OsisFragment(
            xml: "<div>In the beginning...</div>",
            key: "Gen.1",
            keyName: "Genesis 1",
            bookInitials: "KJV"
        )

        let fragmentObject = try bridgeJSONObject(fragment)

        let features = try XCTUnwrap(fragmentObject["features"] as? [String: Any])
        XCTAssertTrue(features.isEmpty)
    }

    #if os(iOS)
    func testDownloadLinkInitialsAreParsedForDownloadsSearch() {
        XCTAssertEqual(
            BibleReaderController.downloadSearchText(from: "download://?initials=KJV"),
            "KJV"
        )
        XCTAssertEqual(
            BibleReaderController.downloadSearchText(from: "download://?initials=StrongsHebrew%20"),
            "StrongsHebrew"
        )
        XCTAssertNil(BibleReaderController.downloadSearchText(from: "download://"))
        XCTAssertNil(BibleReaderController.downloadSearchText(from: "download://?initials="))
    }

    @MainActor
    func testDownloadLinkRoutesInitialsToDownloadsPresentation() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var requestedSearchText: String?
        controller.onRequestOpenDownloads = { requestedSearchText = $0 }

        controller.bridge(bridge, openExternalLink: "download://?initials=KJV")

        XCTAssertEqual(requestedSearchText, "KJV")

        requestedSearchText = "stale"
        controller.bridge(bridge, openExternalLink: "download://")

        XCTAssertNil(requestedSearchText)
    }

    /**
     Protects Android's localized fake Strong dictionary only for true compatible-book absence.

     - Setup: Opens an empty installed-book root and requests one Hebrew Strong number.
     - Expected result: One fake `StrongsHebrew` fragment keeps the raw requested key, empty
       features, null v11n/content type, and a module-specific localized download link.
     - Failure meaning: iOS drops Android's recovery action or fabricates real Strong metadata.
     - Side effects: Writes an isolated empty SWORD fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONReturnsInstallFallbackWhenNoStrongsDictionaryIsInstalled() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let multiDocJSON = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["H00430"], robinson: []),
            "Expected Android-style missing-document fallback when no Strong's dictionary is installed"
        )
        let payloadData = try XCTUnwrap(multiDocJSON.data(using: .utf8))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertTrue(payload["contentType"] is NSNull)
        XCTAssertEqual(fragment["bookCategory"] as? String, "DICTIONARY")
        XCTAssertEqual(fragment["key"] as? String, "StrongsHebrew--H00430")
        XCTAssertEqual(fragment["keyName"] as? String, "H00430")
        XCTAssertEqual(fragment["osisRef"] as? String, "H00430")
        XCTAssertEqual(fragment["bookInitials"] as? String, "StrongsHebrew")
        XCTAssertTrue(fragment["v11n"] is NSNull)
        XCTAssertFalse(fragment["hasStrongs"] as? Bool ?? true)
        XCTAssertTrue(features.isEmpty)
        XCTAssertEqual(
            fragment["xml"] as? String,
            "<div>Please download '<AndBibleLink href=\"download://?initials=StrongsHebrew\">StrongsHebrew</AndBibleLink>'</div>"
        )
    }

    /**
     Protects Android's external Strong's URI rule for values without a category prefix.

     - Setup: Requests prefixless Strong's value `243` with no installed dictionaries.
     - Expected result: The synthetic fragment targets `StrongsHebrew` with the raw requested key;
       lowercase `g` and leading-space `G` classify Hebrew, while raw UTF-16 `G` is Greek even when
       a combining mark joins it into one Swift `Character`.
     - Failure meaning: iOS normalized the raw external value before classification or restored the
       numeric-range heuristic, diverging from Android's literal first-character URI analyzer.
     - Side effects: Writes an isolated SWORD fixture that the base test case removes in teardown.
     */
    func testBuildStrongsMultiDocJSONTreatsPrefixlessExternalValueAsHebrew() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragment["bookInitials"] as? String, "StrongsHebrew")
        XCTAssertEqual(fragment["key"] as? String, "StrongsHebrew--243")
        XCTAssertEqual(fragment["keyName"] as? String, "243")
        XCTAssertTrue(features.isEmpty)
        XCTAssertTrue(payload["contentType"] is NSNull)
        XCTAssertTrue(BibleReaderStrongsDocumentBuilder.isHebrewStrongsNumber("H243"))
        XCTAssertTrue(BibleReaderStrongsDocumentBuilder.isHebrewStrongsNumber("g243"))
        XCTAssertTrue(BibleReaderStrongsDocumentBuilder.isHebrewStrongsNumber(" G243"))
        XCTAssertEqual(
            BibleReaderStrongsDocumentBuilder.strongsLookupKeyOptions(for: "g243"),
            ["g243", "", "\r", "Hnull"]
        )
        XCTAssertEqual(
            BibleReaderStrongsDocumentBuilder.strongsLookupKeyOptions(for: " G243"),
            [" G243", "", "\r", "Hnull"]
        )
        XCTAssertFalse(BibleReaderStrongsDocumentBuilder.isHebrewStrongsNumber("G243"))
        XCTAssertFalse(
            BibleReaderStrongsDocumentBuilder.isHebrewStrongsNumber("G\u{0301}243")
        )
    }

    /**
     Protects Android's automatic Robinson download fallback when no morphology book is installed.

     - Setup: Requests one Robinson code from an empty SWORD root with no explicit selection.
     - Expected result: One synthetic Robinson fragment links directly to its Downloads entry.
     - Failure meaning: Morphology links silently do nothing instead of exposing Android's missing-
       document action.
     - Side effects: Writes an isolated SWORD fixture that the base test case removes in teardown.
     */
    func testBuildStrongsMultiDocJSONReturnsInstallFallbackWhenNoMorphologyDictionaryIsInstalled() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: [], robinson: ["V-PAI-3S"])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragment["bookInitials"] as? String, "Robinson")
        XCTAssertEqual(fragment["bookAbbreviation"] as? String, "Robinson")
        XCTAssertEqual(fragment["key"] as? String, "Robinson--V_PAI_3S")
        XCTAssertEqual(fragment["keyName"] as? String, "V-PAI-3S")
        XCTAssertEqual(fragment["osisRef"] as? String, "V-PAI-3S")
        XCTAssertEqual(fragment["bookCategory"] as? String, DocumentCategory.dictionary.rawValue)
        XCTAssertTrue(fragment["v11n"] is NSNull)
        XCTAssertTrue(payload["contentType"] is NSNull)
        XCTAssertFalse(fragment["hasStrongs"] as? Bool ?? true)
        XCTAssertTrue(features.isEmpty)
        XCTAssertEqual(
            fragment["xml"] as? String,
            "<div>Please download '<AndBibleLink href=\"download://?initials=Robinson\">Robinson</AndBibleLink>'</div>"
        )
    }

    /**
     Protects Android's distinction between an unavailable Robinson book and an absent entry.

     - Setup: Installs an empty `GreekParse` RawLD module named `Robinson`, then requests a code.
     - Expected result: The builder returns Android's empty `Multi`, with no synthetic fragment and
       null content type.
     - Failure meaning: An exact-key miss in an installed morphology book is misreported as an
       installation problem.
     - Side effects: Writes an isolated SWORD fixture that the base test case removes in teardown.
     */
    func testBuildStrongsMultiDocJSONReturnsEmptyMultiWhenInstalledMorphologyDictionaryDoesNotContainEntry() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawDictionaryModule(
            named: "Robinson",
            in: modulePath,
            features: ["GreekParse"]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteModules: []
        )
        let builder = BibleReaderStrongsDocumentBuilder(
            installedDictionarySources: { resolver.dictionaryKeySources() },
            installedBookMetadata: { resolver.registeredBookMetadata() },
            installedDictionarySourceNamed: {
                resolver.module(named: $0)?.explicitDictionaryKeySource
            },
            selectedPreferenceValues: { _ in [] },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: [], robinson: ["V-PAI-3S"])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertTrue((payload["osisFragments"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertTrue(payload["contentType"] is NSNull)
    }

    /**
     Protects explicit Strong's and morphology preferences from automatic module substitution.

     Android treats a nonempty selected-book setting as authoritative. The fixture installs usable
     automatic candidates but selects different, unavailable names for each dictionary family.

     - Setup: Installs populated `StrongsGreek` and `Robinson` modules, then explicitly selects
       unavailable module names for Greek definitions and Robinson morphology.
     - Expected result: Strong's returns `nil`; Robinson returns Android's empty `Multi`. Neither
       installed candidate nor a synthetic missing-module document replaces the explicit selection.
     - Failure meaning: Stale or unavailable explicit preferences can silently open a different
       book and overwrite the user's chosen dictionary behavior.
     - Side effects: Writes isolated RawLD fixtures that the base test case removes in teardown.
     */
    func testBuildStrongsMultiDocJSONKeepsUnresolvedExplicitSelectionsAuthoritative() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "StrongsGreek",
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">G243 Greek definition</entryFree>"#
        )
        try seedPopulatedRawDictionaryModule(
            named: "Robinson",
            in: modulePath,
            features: ["GreekParse"],
            entryKey: "V-PAI-3S",
            entryXML: #"<entryFree n="V-PAI-3S">Morphology definition</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let greekModule = try XCTUnwrap(manager.module(named: "StrongsGreek"))
        let morphologyModule = try XCTUnwrap(manager.module(named: "Robinson"))
        XCTAssertNotNil(
            BibleReaderStrongsDocumentBuilder.lookupInModule(
                greekModule,
                keyOptions: ["G243"]
            ),
            "The automatic Greek candidate must contain the requested entry"
        )
        XCTAssertNotNil(
            BibleReaderStrongsDocumentBuilder.lookupInModule(
                morphologyModule,
                keyOptions: ["V-PAI-3S"]
            ),
            "The automatic morphology candidate must contain the requested entry"
        )
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { key in
                switch key {
                case .strongsGreekDictionary:
                    return ["UnavailableGreek"]
                case .robinsonGreekMorphology:
                    return ["UnavailableMorphology"]
                default:
                    return []
                }
            },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        XCTAssertNil(builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: []))
        let morphologyJSON = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: [], robinson: ["V-PAI-3S"])
        )
        let morphologyPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(morphologyJSON.utf8)) as? [String: Any]
        )
        XCTAssertTrue(
            (morphologyPayload["osisFragments"] as? [[String: Any]])?.isEmpty == true
        )
        XCTAssertTrue(morphologyPayload["contentType"] is NSNull)
    }

    /**
     Protects JSword RawLD's default case-insensitive search for one raw Robinson candidate.

     - Setup: Installs an uppercase Robinson record and requests its lowercase spelling without
       adding any iOS-generated key aliases.
     - Expected result: The single raw request case-normalizes to the stored key, whose exact
       uppercase identity appears in the fragment and whose GreekParse feature selects Strong mode.
     - Failure meaning: iOS mistakes “one requested key” for byte-sensitive backend search and
       returns Android's empty installed-miss Multi.
     - Side effects: Writes an isolated RawLD fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONUsesDefaultRawLDCaseNormalizationForRobinson() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "Robinson",
            in: modulePath,
            features: ["GreekParse"],
            entryKey: "V-PAI-3S",
            entryXML: #"<entryFree n="V-PAI-3S">Morphology definition</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteModules: []
        )
        let builder = BibleReaderStrongsDocumentBuilder(
            installedDictionarySources: { resolver.dictionaryKeySources() },
            installedBookMetadata: { resolver.registeredBookMetadata() },
            installedDictionarySourceNamed: {
                resolver.module(named: $0)?.explicitDictionaryKeySource
            },
            selectedPreferenceValues: { _ in [] },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: [], robinson: ["v-pai-3s"])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(fragment["key"] as? String, "Robinson--V_PAI_3S")
        XCTAssertEqual(fragment["keyName"] as? String, "V-PAI-3S")
        XCTAssertEqual(fragment["osisRef"] as? String, "V-PAI-3S")
        XCTAssertTrue((fragment["xml"] as? String)?.contains("Morphology definition") == true)
        XCTAssertEqual(payload["contentType"] as? String, "strongs")
    }

    /**
     Protects JSword RawLD's exact case-sensitive Robinson fallback.

     - Setup: Installs only an uppercase Robinson record with `CaseSensitiveKeys=true`, then asks
       for the lowercase raw code.
     - Expected result: Android's handled route opens an empty Multi with null content type.
     - Failure meaning: iOS applies default case folding despite the selected book's explicit
       case-sensitive key contract.
     - Side effects: Writes an isolated RawLD fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONKeepsCaseSensitiveRobinsonMissEmpty() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "Robinson",
            in: modulePath,
            features: ["GreekParse"],
            entryKey: "V-PAI-3S",
            entryXML: #"<entryFree n="V-PAI-3S">Morphology definition</entryFree>"#,
            caseSensitiveKeys: true
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: [], robinson: ["v-pai-3s"])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        XCTAssertTrue((payload["osisFragments"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertTrue(payload["contentType"] is NSNull)
    }

    /**
     Protects JSword's shared identity rules and feature-free explicit selection contract.

     - Setup: Installs a key-readable book with Bible category but no Strong's feature and selects
       it first by case-insensitive initials, then by its exact full description.
     - Expected result: Both authoritative selections resolve the same entry through global book
       identity; the fragment retains the actual Bible category, empty definition features, null
       Strong's content type, and false Strong's-numbers capability.
     - Failure meaning: iOS re-filters explicit selections by feature/category or supports only
       exact module initials while Android resolves the persisted token.
     - Side effects: Writes an isolated RawLD fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONResolvesExplicitSelectionBySharedBookIdentity() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "SelectedGreek",
            in: modulePath,
            features: [],
            category: ModuleCategory.bible.rawValue,
            entryKey: "00243",
            entryXML: #"<entryFree n="00243">Explicit selected definition</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertEqual(manager.module(named: "SelectedGreek")?.info.category, .bible)

        for selectedName in ["selectedgreek", "UI Test Dictionary"] {
            let builder = BibleReaderStrongsDocumentBuilder(
                swordManager: manager,
                selectedPreferenceValues: { key in
                    key == .strongsGreekDictionary ? [selectedName] : []
                },
                moduleDisplayLabel: { $0.info.name },
                localizedString: { _, defaultValue in defaultValue }
            )
            let json = try XCTUnwrap(
                builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: []),
                "Explicit selection \(selectedName) must resolve through shared JSword identity"
            )
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            )
            let fragment = try XCTUnwrap(
                (payload["osisFragments"] as? [[String: Any]])?.first
            )

            XCTAssertEqual(fragment["bookInitials"] as? String, "SelectedGreek")
            XCTAssertTrue((fragment["xml"] as? String)?.contains("Explicit selected definition") == true)
            XCTAssertEqual(fragment["bookCategory"] as? String, DocumentCategory.bible.rawValue)
            XCTAssertEqual(fragment["key"] as? String, "SelectedGreek--00243")
            XCTAssertEqual(fragment["keyName"] as? String, "00243")
            XCTAssertEqual(fragment["osisRef"] as? String, "00243")
            XCTAssertTrue((fragment["features"] as? [String: Any])?.isEmpty == true)
            XCTAssertFalse(fragment["hasStrongs"] as? Bool ?? true)
            XCTAssertTrue(fragment["v11n"] is NSNull)
            XCTAssertTrue(payload["contentType"] is NSNull)
        }
    }

    /**
     Protects Android's feature-only automatic Strong's discovery across the global book registry.

     - Setup: Installs a key-readable native book with Bible category and `GreekDef`, but leaves the
       explicit Greek selection empty.
     - Expected result: Automatic discovery finds the book by feature, returns its exact raw key,
       and preserves its actual Bible category and Greek definition metadata.
     - Failure meaning: iOS prefilters automatic candidates to dictionary/glossary categories even
       though Android scans every installed book for the requested feature.
     - Side effects: Writes an isolated RawLD fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONAutomaticallyDiscoversFeatureBookAcrossCategories() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "GreekFeatureBible",
            in: modulePath,
            features: ["GreekDef"],
            category: ModuleCategory.bible.rawValue,
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">Cross-category definition</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(fragment["bookInitials"] as? String, "GreekFeatureBible")
        XCTAssertEqual(fragment["bookCategory"] as? String, DocumentCategory.bible.rawValue)
        XCTAssertEqual(fragment["key"] as? String, "GreekFeatureBible--G243")
        XCTAssertEqual(fragment["keyName"] as? String, "G243")
        XCTAssertEqual(fragment["osisRef"] as? String, "G243")
        XCTAssertEqual(features["type"] as? String, "greek")
        XCTAssertEqual(features["keyName"] as? String, "G243")
        XCTAssertFalse(fragment["hasStrongs"] as? Bool ?? true)
        XCTAssertTrue(fragment["v11n"] is NSNull)
        XCTAssertEqual(payload["contentType"] as? String, "strongs")
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        XCTAssertTrue(xml.contains(#"<title type="x-gen">G243</title>"#))
        XCTAssertTrue(xml.contains("Cross-category definition"))
        XCTAssertFalse(xml.contains("<BVA"))
    }

    /**
     Protects JSword's Essays category metadata and ordinal during feature-only discovery.

     - Setup: Installs two Greek-definition RawLD books in deliberately conflicting name order: a
       dictionary whose initials sort after an Essays book, and an explicit lowercase `essays`
       category that exercises JSword's case-insensitive category parser.
     - Expected result: Android's category ordinal keeps the dictionary first; the Essays fragment
       remains `ESSAYS` and renders its real definition through the same feature-based lookup.
     - Failure meaning: iOS infers RawLD as dictionary despite an explicit category, serializes
       Essays as OTHER/DICTIONARY, or sorts automatic candidates by initials before category.
     - Side effects: Writes two isolated RawLD fixtures removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONPreservesEssaysCategoryAndJSwordOrder() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "ZuluGreekDictionary",
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">Dictionary definition</entryFree>"#
        )
        try seedPopulatedRawDictionaryModule(
            named: "AlphaGreekEssay",
            in: modulePath,
            features: ["GreekDef"],
            category: "essays",
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">Essay definition</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteModules: []
        )
        let builder = BibleReaderStrongsDocumentBuilder(
            installedDictionarySources: { resolver.dictionaryKeySources() },
            installedBookMetadata: { resolver.registeredBookMetadata() },
            installedDictionarySourceNamed: {
                resolver.module(named: $0)?.explicitDictionaryKeySource
            },
            selectedPreferenceValues: { _ in [] },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])

        XCTAssertEqual(
            fragments.compactMap { $0["bookInitials"] as? String },
            ["ZuluGreekDictionary", "AlphaGreekEssay"]
        )
        XCTAssertEqual(
            fragments.compactMap { $0["bookCategory"] as? String },
            [DocumentCategory.dictionary.rawValue, "ESSAYS"]
        )
        XCTAssertTrue((fragments[1]["xml"] as? String)?.contains("Essay definition") == true)
        XCTAssertTrue((fragments[1]["xml"] as? String)?.contains("<BVA") == true)
    }

    /**
     Protects Android's contradictory commentary-category `SwordDictionary` error projection.

     - Setup: Installs a populated RawLD Greek-definition book whose explicit category is
       commentary but whose assembled entry has no direct verse child.
     - Expected result: The exact book/key remains a Multi fragment with actual commentary and
       Greek metadata, while XML is the localized unanchored key-not-in-document error.
     - Failure meaning: iOS either drops an Android error fragment, renders dictionary siblings as
       commentary, invents a download fallback, or anchors an `OsisError` payload.
     - Side effects: Writes an isolated RawLD fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONEmitsCommentaryCategoryMissingVerseErrorFragment() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "GreekFeatureCommentary",
            in: modulePath,
            features: ["GreekDef"],
            category: ModuleCategory.commentary.rawValue,
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">Not a direct verse</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(fragment["bookInitials"] as? String, "GreekFeatureCommentary")
        XCTAssertEqual(fragment["bookCategory"] as? String, DocumentCategory.commentary.rawValue)
        XCTAssertEqual(fragment["key"] as? String, "GreekFeatureCommentary--G243")
        XCTAssertEqual(fragment["keyName"] as? String, "G243")
        XCTAssertEqual(fragment["osisRef"] as? String, "G243")
        XCTAssertEqual(features["type"] as? String, "greek")
        XCTAssertEqual(payload["contentType"] as? String, "strongs")
        XCTAssertEqual(
            fragment["xml"] as? String,
            "<div>G243 was not found in document GreekFeatureCommentary.</div>"
        )
        XCTAssertFalse((fragment["xml"] as? String)?.contains("<BVA") ?? true)
    }

    /**
     Protects automatic Strong's lookup through JSword's nested `SwordGenBook` key map.

     - Setup: Installs a real feature-bearing RawGenBook whose only definition lives at the nested
       TreeKey `Root/G243`, then requests the leaf candidate `G243`.
     - Expected result: Android's substring tier resolves the entry; keyName remains the leaf while
       fragment key and osisRef preserve the full TreeKey OSIS path.
     - Failure meaning: iOS category-filters automatic discovery, requires a flat exact libsword
       key, or flattens Android's distinct Key name/OSIS identities in the Vue payload.
     - Side effects: Writes an isolated three-file RawGenBook fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONResolvesNestedFeatureGenBookWithDistinctKeyIdentities() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedNestedGreekDefinitionGeneralBook(
            named: "NestedGreekBook",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )

        XCTAssertEqual(fragment["bookInitials"] as? String, "NestedGreekBook")
        XCTAssertEqual(fragment["bookCategory"] as? String, DocumentCategory.generalBook.rawValue)
        XCTAssertEqual(fragment["key"] as? String, "NestedGreekBook--Root_G243")
        XCTAssertEqual(fragment["keyName"] as? String, "G243")
        XCTAssertEqual(fragment["osisRef"] as? String, "Root/G243")
        XCTAssertTrue((fragment["xml"] as? String)?.contains("Nested Greek definition") == true)
        XCTAssertEqual(payload["contentType"] as? String, "strongs")
    }

    /**
     Protects driver-owned TreeKey resolution across contradictory RawGenBook categories.

     - Setup: Installs identical feature-bearing nested RawGenBooks explicitly categorized as Bible
       and Commentary; neither changes its concrete `SwordGenBook` backend or TreeKey identity.
     - Expected result: Bible returns the nested definition without BVA, while Commentary retains
       the same actual key metadata but emits Android's localized unanchored missing-verse error.
     - Failure meaning: iOS chooses key type from category, rejects a supported RawGenBook book,
       anchors Bible content, or drops the Commentary error fragment.
     - Side effects: Writes two isolated RawGenBook fixtures removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONPreservesRawGenBookKeysAcrossActualCategories() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedNestedGreekDefinitionGeneralBook(
            named: "NestedGreekBible",
            in: modulePath,
            category: ModuleCategory.bible.rawValue
        )
        try seedNestedGreekDefinitionGeneralBook(
            named: "NestedGreekCommentary",
            in: modulePath,
            category: ModuleCategory.commentary.rawValue
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let bible = try XCTUnwrap(
            fragments.first { $0["bookInitials"] as? String == "NestedGreekBible" }
        )
        let commentary = try XCTUnwrap(
            fragments.first { $0["bookInitials"] as? String == "NestedGreekCommentary" }
        )

        XCTAssertEqual(bible["bookCategory"] as? String, DocumentCategory.bible.rawValue)
        XCTAssertEqual(bible["key"] as? String, "NestedGreekBible--Root_G243")
        XCTAssertEqual(bible["keyName"] as? String, "G243")
        XCTAssertEqual(bible["osisRef"] as? String, "Root/G243")
        XCTAssertTrue((bible["xml"] as? String)?.contains("Nested Greek definition") == true)
        XCTAssertFalse((bible["xml"] as? String)?.contains("<BVA") ?? true)

        XCTAssertEqual(
            commentary["bookCategory"] as? String,
            DocumentCategory.commentary.rawValue
        )
        XCTAssertEqual(commentary["key"] as? String, "NestedGreekCommentary--Root_G243")
        XCTAssertEqual(commentary["keyName"] as? String, "G243")
        XCTAssertEqual(commentary["osisRef"] as? String, "Root/G243")
        XCTAssertEqual(
            commentary["xml"] as? String,
            "<div>G243 was not found in document NestedGreekCommentary.</div>"
        )
        XCTAssertFalse((commentary["xml"] as? String)?.contains("<BVA") ?? true)
    }

    /**
     Protects restored Multi's one persisted-key lookup and actual resolved-key metadata.

     - Setup: Installs one Greek dictionary containing only another Strong family (`00243`) and a
       second case-insensitive RawLD dictionary containing `G243`, then restores separate children.
     - Expected result: Persisted `G243` does not expand into the padded family; persisted lowercase
       `g243` resolves through RawLD itself and serializes the actual stored `G243` identity.
     - Failure meaning: Restore reuses LinkControl's four live-Strong families, or serializes the
       persisted query instead of the `Key` returned by the selected book.
     - Side effects: Writes two isolated RawLD fixtures removed by the base test case.
     */
    func testRestoredMultiUsesOnePersistedDictionaryKeyAndActualResolvedMetadata() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "RestorePaddedOnly",
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "00243",
            entryXML: #"<entryFree n="00243">Padded family only</entryFree>"#
        )
        try seedPopulatedRawDictionaryModule(
            named: "RestoreCasefold",
            in: modulePath,
            features: ["GreekDef", "StrongsNumbers"],
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">Casefold restore</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let activeBible = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleReaderRestoredMultiDocumentBuilder(
            swordManager: manager,
            activeModule: activeBible
        )

        XCTAssertNil(builder.build(pageKey: "RestorePaddedOnly:G243"))
        let request = try XCTUnwrap(builder.build(pageKey: "RestoreCasefold:g243"))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.documentJSON.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(request.renderedKey, AndroidSpecialDocumentIdentity.strongsRenderedKey)
        XCTAssertEqual(fragment["key"] as? String, "RestoreCasefold--G243")
        XCTAssertEqual(fragment["keyName"] as? String, "G243")
        XCTAssertEqual(fragment["osisRef"] as? String, "G243")
        XCTAssertEqual(fragment["bookCategory"] as? String, DocumentCategory.dictionary.rawValue)
        XCTAssertEqual(features["type"] as? String, "greek")
        XCTAssertEqual(features["keyName"] as? String, "G243")
        XCTAssertEqual(fragment["hasStrongs"] as? Bool, true)
        XCTAssertTrue(fragment["v11n"] is NSNull)
        XCTAssertEqual(payload["contentType"] as? String, "strongs")
    }

    /**
     Protects restored Multi dispatch by concrete JSword book class instead of configured category.

     - Setup: Installs two RawLD Greek-definition books explicitly categorized as Bible and
       Commentary, persists one exact child from each, and restores them through the shared resolver.
     - Expected result: The Bible-category RawLD child restores as a key-owned title/body fragment
       without BVA; the Commentary child restores as the localized actual-book/key error fragment.
     - Failure meaning: iOS treats RawLD as a verse-backed `SwordBook` because of Category metadata,
       drops the Commentary read error, or loses the actual categories during restore.
     - Side effects: Writes two isolated RawLD fixtures removed by the base test case.
     */
    func testRestoredMultiDispatchesContradictoryRawLDCategoriesByConcreteBookClass() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "RestoreGreekBible",
            in: modulePath,
            features: ["GreekDef"],
            category: ModuleCategory.bible.rawValue,
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">Restored Bible-category definition</entryFree>"#
        )
        try seedPopulatedRawDictionaryModule(
            named: "RestoreGreekCommentary",
            in: modulePath,
            features: ["GreekDef"],
            category: ModuleCategory.commentary.rawValue,
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">Not a direct verse</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let activeBible = try XCTUnwrap(manager.module(named: "KJV"))
        let builder = BibleReaderRestoredMultiDocumentBuilder(
            swordManager: manager,
            activeModule: activeBible,
            localizedString: { _, defaultValue in defaultValue }
        )

        let request = try XCTUnwrap(builder.build(
            pageKey: "RestoreGreekBible:G243||RestoreGreekCommentary:G243"
        ))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.documentJSON.utf8)) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let bible = try XCTUnwrap(
            fragments.first { $0["bookInitials"] as? String == "RestoreGreekBible" }
        )
        let commentary = try XCTUnwrap(
            fragments.first { $0["bookInitials"] as? String == "RestoreGreekCommentary" }
        )
        let bibleFeatures = try XCTUnwrap(bible["features"] as? [String: Any])
        let commentaryFeatures = try XCTUnwrap(commentary["features"] as? [String: Any])

        XCTAssertEqual(bible["bookCategory"] as? String, DocumentCategory.bible.rawValue)
        XCTAssertEqual(bible["key"] as? String, "RestoreGreekBible--G243")
        XCTAssertEqual(bible["keyName"] as? String, "G243")
        XCTAssertEqual(bible["osisRef"] as? String, "G243")
        XCTAssertEqual(bibleFeatures["type"] as? String, "greek")
        XCTAssertEqual(bibleFeatures["keyName"] as? String, "G243")
        XCTAssertFalse(bible["hasStrongs"] as? Bool ?? true)
        XCTAssertTrue(bible["v11n"] is NSNull)
        XCTAssertTrue((bible["xml"] as? String)?.contains("Restored Bible-category definition") == true)
        XCTAssertFalse((bible["xml"] as? String)?.contains("<BVA") ?? true)

        XCTAssertEqual(commentary["bookCategory"] as? String, DocumentCategory.commentary.rawValue)
        XCTAssertEqual(commentary["key"] as? String, "RestoreGreekCommentary--G243")
        XCTAssertEqual(commentary["keyName"] as? String, "G243")
        XCTAssertEqual(commentary["osisRef"] as? String, "G243")
        XCTAssertEqual(commentaryFeatures["type"] as? String, "greek")
        XCTAssertEqual(commentaryFeatures["keyName"] as? String, "G243")
        XCTAssertFalse(commentary["hasStrongs"] as? Bool ?? true)
        XCTAssertTrue(commentary["v11n"] is NSNull)
        XCTAssertEqual(
            commentary["xml"] as? String,
            "<div>G243 was not found in document RestoreGreekCommentary.</div>"
        )
        XCTAssertFalse((commentary["xml"] as? String)?.contains("<BVA") ?? true)
        XCTAssertEqual(payload["contentType"] as? String, "strongs")
    }

    /**
     Preserves actual metadata when restoring a native `SwordBook` configured as Commentary.

     - Setup: Publishes the readable zText KJV fixture under separate initials with Commentary
       category plus Greek-definition and Strong's-number features, then restores Genesis 1:1.
     - Expected result: Concrete SwordBook verse restoration succeeds while the fragment retains
       Commentary category, actual source features, Strong's state, and KJV versification.
     - Failure meaning: Restore dispatches by configured category, drops native commentary, or
       reuses the Bible fragment builder's route-derived BIBLE/empty-feature metadata.
     - Side effects: Writes one isolated descriptor removed by the base test case.
     */
    func testRestoredMultiPreservesNativeSwordBookCommentaryMetadata() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "RestoreNativeCommentary",
            description: "Restored native commentary",
            in: modulePath
        )
        let descriptorURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/restorenativecommentary.conf")
        var descriptor = try String(contentsOf: descriptorURL, encoding: .utf8)
        descriptor.append(
            "\nAbbreviation=RNC\nCategory=Commentaries\nFeature=GreekDef\n"
        )
        try descriptor.write(to: descriptorURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderRestoredMultiDocumentBuilder(
            swordManager: manager,
            activeModule: manager.module(named: "KJV")
        )
        let request = try XCTUnwrap(
            builder.build(pageKey: "RestoreNativeCommentary:Gen.1.1")
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(request.documentJSON.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(fragment["bookCategory"] as? String, DocumentCategory.commentary.rawValue)
        XCTAssertEqual(fragment["bookInitials"] as? String, "RestoreNativeCommentary")
        XCTAssertEqual(fragment["bookAbbreviation"] as? String, "RNC")
        XCTAssertEqual(fragment["key"] as? String, "RestoreNativeCommentary--Gen.1.1")
        XCTAssertEqual(fragment["osisRef"] as? String, "Gen.1.1")
        XCTAssertEqual(fragment["v11n"] as? String, "KJV")
        XCTAssertEqual(features["type"] as? String, "greek")
        XCTAssertEqual(features["keyName"] as? String, fragment["keyName"] as? String)
        XCTAssertEqual(fragment["hasStrongs"] as? Bool, true)
        XCTAssertEqual(payload["contentType"] as? String, "strongs")
    }

    /**
     Protects selected-word lookup's single backend key and RawLD-owned case semantics.

     - Setup: Installs two plain dictionaries with the same uppercase key; one uses default RawLD
       case folding and the other declares `CaseSensitiveKeys=true`, then looks up lowercase text.
     - Expected result: Only the default dictionary resolves and its actual uppercase key metadata
       is serialized; the builder never retries lowercase/title-case aliases itself.
     - Failure meaning: iOS performs host-side key expansion, ignores `CaseSensitiveKeys`, or emits
       query-derived fragment identity after backend normalization.
     - Side effects: Writes two isolated RawLD fixtures removed by the base test case.
     */
    func testWordLookupUsesOneQueryAndRawLDCaseSensitivityWithActualKeyMetadata() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "WordCasefold",
            in: modulePath,
            features: [],
            entryKey: "GRACE",
            entryXML: #"<entryFree n="GRACE">Casefold definition</entryFree>"#
        )
        try seedPopulatedRawDictionaryModule(
            named: "WordCaseSensitive",
            in: modulePath,
            features: [],
            entryKey: "GRACE",
            entryXML: #"<entryFree n="GRACE">Must not appear</entryFree>"#,
            caseSensitiveKeys: true
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderWordLookupDocumentBuilder(
            swordManager: manager,
            disabledDictionaryNames: { [] }
        )

        let json = try XCTUnwrap(builder.buildWordLookupMultiDocumentJSON(query: "grace"))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)

        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragment["bookInitials"] as? String, "WordCasefold")
        XCTAssertEqual(fragment["key"] as? String, "WordCasefold--GRACE")
        XCTAssertEqual(fragment["keyName"] as? String, "GRACE")
        XCTAssertEqual(fragment["osisRef"] as? String, "GRACE")
        XCTAssertEqual(fragment["bookCategory"] as? String, DocumentCategory.dictionary.rawValue)
        XCTAssertTrue((fragment["features"] as? [String: Any])?.isEmpty == true)
        XCTAssertFalse(fragment["hasStrongs"] as? Bool ?? true)
        XCTAssertTrue(fragment["v11n"] is NSNull)
        XCTAssertTrue(payload["contentType"] is NSNull)
        XCTAssertTrue((fragment["xml"] as? String)?.contains("Casefold definition") == true)
        XCTAssertFalse(json.contains("WordCaseSensitive"))
        XCTAssertFalse(json.contains("Must not appear"))
    }

    /**
     Protects Android's JSword TreeSet order for production selected-word results.

     - Setup: Installs two plain RawLD dictionaries in initials order `A`, `Z` but assigns opposing
       abbreviations `Zulu`, `Alpha`, then supplies the controller's shared resolver projection to
       the selected-word builder.
     - Expected result: Resolver candidates and emitted fragments both place abbreviation `Alpha`
       before `Zulu`, matching `SwordDocumentFacade.wordLookupDictionaries` filtering of
       `Books.installed().books`.
     - Failure meaning: The production path has regressed to native initials/registration order,
       causing Android/iOS word-result tabs to appear in a different order.
     - Side effects: Writes and rewrites two isolated RawLD descriptors/data files; base teardown
       removes the temporary SWORD tree. Lookup order is synchronous and deterministic.
     */
    func testWordLookupUsesJSwordTreeSetAbbreviationOrder() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let fixtures = [
            (name: "AWordZulu", abbreviation: "Zulu", definition: "Zulu tab definition"),
            (name: "ZWordAlpha", abbreviation: "Alpha", definition: "Alpha tab definition"),
        ]
        for fixture in fixtures {
            try seedPopulatedRawDictionaryModule(
                named: fixture.name,
                in: modulePath,
                features: [],
                entryKey: "GRACE",
                entryXML: #"<entryFree n="GRACE">\#(fixture.definition)</entryFree>"#
            )
            let descriptorURL = URL(fileURLWithPath: modulePath, isDirectory: true)
                .appendingPathComponent("mods.d/\(fixture.name.lowercased()).conf")
            var descriptor = try String(contentsOf: descriptorURL, encoding: .utf8)
            descriptor.append("\nAbbreviation=\(fixture.abbreviation)\n")
            try descriptor.write(to: descriptorURL, atomically: true, encoding: .utf8)
        }

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteModules: []
        )
        let orderedSources = resolver.wordLookupDictionarySources()
        let builder = BibleReaderWordLookupDocumentBuilder(
            installedDictionarySources: { orderedSources },
            disabledDictionaryNames: { [] }
        )

        XCTAssertEqual(orderedSources.map(\.info.name), ["ZWordAlpha", "AWordZulu"])
        let json = try XCTUnwrap(builder.buildWordLookupMultiDocumentJSON(query: "grace"))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])

        XCTAssertEqual(
            fragments.compactMap { $0["bookInitials"] as? String },
            ["ZWordAlpha", "AWordZulu"]
        )
        XCTAssertEqual(
            fragments.compactMap { $0["bookAbbreviation"] as? String },
            ["Alpha", "Zulu"]
        )
    }

    /**
     Protects pinned RawLD Strong's-padding normalization and typed-family caching.

     - Setup: Installs one `StrongsPadding=true` Greek dictionary whose stored pattern is `G0243`,
       then requests raw `G243` with an isolated preferred-family cache.
     - Expected result: JSword maps the raw family to the four-digit stored pattern, preserves that
       stored identity in the payload, and records the raw typed family rather than padded aliases.
     - Failure meaning: iOS requires byte-exact candidates, infers five-digit padding regardless of
       stored pattern, or caches the resolved text rather than Android's attempted KeyType.
     - Side effects: Writes an isolated RawLD fixture and mutates an isolated in-memory cache.
     */
    func testBuildStrongsMultiDocJSONUsesJSwordStrongsPaddingAndCachesTypedRawFamily() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "PaddedGreek",
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "G0243",
            entryXML: #"<entryFree n="G0243">Four-digit padded definition</entryFree>"#,
            strongsPadding: true
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let cache = AndroidStrongsKeyPreferenceCache()
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue },
            strongsLookupKeyPreferenceCache: cache
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        let orderedAfterLookup = cache.orderedCandidates(
            BibleReaderStrongsDocumentBuilder.strongsLookupKeyCandidates(for: "G244"),
            moduleInitials: "PaddedGreek"
        )

        XCTAssertEqual(fragment["key"] as? String, "PaddedGreek--G0243")
        XCTAssertEqual(fragment["keyName"] as? String, "G0243")
        XCTAssertEqual(fragment["osisRef"] as? String, "G0243")
        XCTAssertEqual(orderedAfterLookup.first?.family, .key)
    }

    /**
     Protects JSword's default-enabled Strong's padding when a RawLD descriptor omits the property.

     - Setup: Installs one Greek-definition RawLD book whose descriptor has no `StrongsPadding`
       entry and whose exact stored key uses JSword's four-digit prefixed form `G0243`.
     - Expected result: A live `G243` request resolves the stored `G0243` key and preserves that
       actual identity in the fragment, exactly as JSword's default configuration does.
     - Failure meaning: iOS treats an absent property as false, so ordinary dictionaries relying on
       JSword defaults silently miss entries that Android resolves.
     - Side effects: Writes one isolated RawLD fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONDefaultsOmittedStrongsPaddingToTrue() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "DefaultPaddedGreek",
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "G0243",
            entryXML: #"<entryFree n="G0243">Default padded definition</entryFree>"#,
            strongsPadding: nil
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "DefaultPaddedGreek"))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue },
            strongsLookupKeyPreferenceCache: AndroidStrongsKeyPreferenceCache()
        )

        XCTAssertNil(module.configEntry("StrongsPadding"))
        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )

        XCTAssertEqual(fragment["key"] as? String, "DefaultPaddedGreek--G0243")
        XCTAssertEqual(fragment["keyName"] as? String, "G0243")
        XCTAssertEqual(fragment["osisRef"] as? String, "G0243")
    }

    /**
     Protects RawLD's one-time first-midpoint padding-pattern selection for mixed-width indices.

     - Setup: Installs an index-zero work-title row followed by sorted five- and four-digit Strong's
       keys in a `StrongsPadding=true` single-feature dictionary.
     - Expected result: Source order is preserved; JSword's first midpoint is `G00243`, so raw
       request `G243` resolves that five-digit record without reconsidering the later four-digit key.
     - Failure meaning: iOS derives padding from libsword's eventual cursor record or from every
       binary-search probe, which can select a different logical entry from Android.
     - Side effects: Writes an isolated RawLD fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONUsesRawLDFirstMidpointPaddingPattern() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "MixedWidthGreek",
            in: modulePath,
            features: ["GreekDef"],
            entries: [
                ("About", "Work title"),
                ("G00243", #"<entryFree n="G00243">Five-digit definition</entryFree>"#),
                ("G0243", #"<entryFree n="G0243">Four-digit definition</entryFree>"#),
            ],
            strongsPadding: true
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "MixedWidthGreek"))
        XCTAssertEqual(
            try module.loadRawDictionaryIndexSlots()?.compactMap(\.key),
            ["About", "G00243", "G0243"]
        )
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue },
            strongsLookupKeyPreferenceCache: AndroidStrongsKeyPreferenceCache()
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        let xml = try XCTUnwrap(fragment["xml"] as? String)

        XCTAssertEqual(fragment["keyName"] as? String, "G00243")
        XCTAssertTrue(xml.contains(">G00243\n</BVA>"), xml)
        XCTAssertTrue(xml.contains("Five-") && xml.contains("digit definition"), xml)
        XCTAssertFalse(xml.contains("Four-") || xml.contains("Four-digit definition"), xml)
    }

    /**
     Protects Android's carriage-return Strong family through the physical RawLD index and payload.

     - Setup: Installs five Java-sorted RawLD slots whose midpoint is zero-size and whose only match
       is the `00243\r` family; the logical CR is encoded as two CR bytes before the LF delimiter.
     - Expected result: Search moves right to the CR record, caches that typed family, preserves CR
     in key metadata, sanitizes it only in the fragment ID, and serializes the generated title with
     JDOM-compatible `&#xD;`; XML newline normalization may fold the source header delimiter text.
     - Failure meaning: iOS strips the logical CR as a delimiter, retries an iOS-only alias, loses
       accepted-key identity, or processes a different physical index record from Android.
     - Side effects: Writes one isolated RawLD fixture and mutates an isolated preference cache.
     */
    func testBuildStrongsMultiDocJSONPreservesPhysicalRawLDCarriageReturnFamily() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "CarriageReturnGreek",
            in: modulePath,
            features: ["GreekDef"],
            entries: [
                ("About", "Work title"),
                ("00243\t", "Tab-family neighbor"),
                ("placeholder", "unused"),
                ("00243\r", #"<entryFree n="00243">CR definition</entryFree>"#),
                ("00999", "Later neighbor"),
            ],
            zeroSizeSlotIndices: [2]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "CarriageReturnGreek"))
        let slots = try XCTUnwrap(module.loadRawDictionaryIndexSlots())
        XCTAssertEqual(slots.map(\.key), ["About", "00243\t", nil, "00243\r", "00999"])
        XCTAssertEqual(slots.map { $0.size > 0 }, [true, true, false, true, true])

        let cache = AndroidStrongsKeyPreferenceCache()
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue },
            strongsLookupKeyPreferenceCache: cache
        )
        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        let orderedAfterLookup = cache.orderedCandidates(
            BibleReaderStrongsDocumentBuilder.strongsLookupKeyCandidates(for: "G244"),
            moduleInitials: "CarriageReturnGreek"
        )

        XCTAssertEqual(fragment["key"] as? String, "CarriageReturnGreek--00243_")
        XCTAssertEqual(fragment["keyName"] as? String, "00243\r")
        XCTAssertEqual(fragment["osisRef"] as? String, "00243\r")
        XCTAssertEqual(features["keyName"] as? String, "00243\r")
        XCTAssertEqual(orderedAfterLookup.first?.family, .zeroPaddedKeyWithCarriageReturn)
        XCTAssertTrue(xml.contains(">00243&#xD;</BVA></title>"), xml)
        XCTAssertTrue(xml.contains(">00243\n\n</BVA>"), xml)
        XCTAssertTrue(xml.contains("CR definition"), xml)
    }

    /**
     Protects Android's backend-owned RawLD key from entry-body headword revalidation.

     - Setup: Stores exact index key `G243` with body metadata deliberately naming `G244`.
     - Expected result: Android's raw key family is accepted, rendered, and recorded in the
       preferred-family cache despite the divergent body headword.
     - Failure meaning: iOS applies a second body/numeric/sentinel heuristic after `Book.getKey`
       has already established ownership, dropping valid modules or selecting another family.
     - Side effects: Writes an isolated RawLD fixture and mutates an isolated in-memory cache.
     */
    func testBuildStrongsMultiDocJSONAcceptsBackendOwnedKeyWithDivergentBodyMetadata() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "DivergentGreek",
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "G243",
            entryXML: #"<entryFree n="G244">Divergent body definition</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let cache = AndroidStrongsKeyPreferenceCache()
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue },
            strongsLookupKeyPreferenceCache: cache
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        let orderedAfterLookup = cache.orderedCandidates(
            BibleReaderStrongsDocumentBuilder.strongsLookupKeyCandidates(for: "G244"),
            moduleInitials: "DivergentGreek"
        )

        XCTAssertTrue((fragment["xml"] as? String)?.contains("Divergent body definition") == true)
        XCTAssertEqual(fragment["keyName"] as? String, "G243")
        XCTAssertEqual(orderedAfterLookup.first?.family, .key)
    }

    /**
     Protects JSword's generated SwordDictionary title and retained RawLD key header.

     - Setup: Installs an exact `G243` RawLD record whose body after the stored key is empty.
     - Expected result: The lookup succeeds and emits the generated key title followed by the
       physical record's key header, which pinned JSword passes through the source filter even when
       no definition follows it; no missing document or synthetic paragraph appears.
     - Failure meaning: iOS uses definition-body presence as ownership, forgets the title JSword
       inserts, or strips the RawLD header before the source filter sees the complete record.
     - Side effects: Writes an isolated RawLD fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONKeepsExactEmptyRawLDBodyAsGeneratedTitle() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "EmptyBodyGreek",
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "G243",
            entryXML: ""
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )

        XCTAssertEqual(fragment["keyName"] as? String, "G243")
        XCTAssertEqual(
            fragment["xml"] as? String,
            #"<div><title type="x-gen"><BVA ordinal="0" xmlns="http://www.w3.org/1999/xhtml">G243</BVA></title><BVA ordinal="1" xmlns="http://www.w3.org/1999/xhtml">G243</BVA></div>"#
        )
    }

    /**
     Protects Android from a libsword-only unpadded numeric alias.

     - Setup: Installs a Greek dictionary whose sole logical key is `243`, then requests `G243`.
     - Expected result: The Strong-only route returns `nil` because none of Android's four exact
       typed candidates names that record.
     - Failure meaning: Broad numeric equivalence or an extra alias turns an Android miss into iOS
       content and can bind the request to a distinct logical entry.
     - Side effects: Writes an isolated RawLD fixture removed by the base test case.
     */
    func testBuildStrongsMultiDocJSONRejectsUnpaddedOnlyLibswordAlias() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "StrongsGreek",
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "243",
            entryXML: #"<entryFree n="243">iOS-only alias definition</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        XCTAssertNil(builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: []))
    }

    /**
     Protects Android's observable per-book preferred Strong's key-family cache.

     - Setup: A mixed-style module stores `G243` and `00243`; `G243` first resolves raw, while a
       later `G244` lookup can succeed only through the padded family using one shared cache.
     - Expected result: Exact accepted keys drive key/name/reference metadata, and the final `G243`
       lookup tries the remembered padded family first even though raw still names another record.
     - Failure meaning: Route-local builders lose history, duplicate families collapse, or lookup
       always restarts in enum order and selects different content from Android.
     - Side effects: Writes an isolated RawLD fixture and mutates an isolated in-memory cache.
     */
    func testBuildStrongsMultiDocJSONUsesRememberedKeyFamilyBeforeRawFamily() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "MixedGreek",
            in: modulePath,
            features: ["GreekDef"],
            entries: [
                ("00243", #"<entryFree n="00243">Padded 243 definition</entryFree>"#),
                ("00244", #"<entryFree n="00244">Padded 244 definition</entryFree>"#),
                ("G243", #"<entryFree n="G243">Raw 243 definition</entryFree>"#),
            ]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let cache = AndroidStrongsKeyPreferenceCache()
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue },
            strongsLookupKeyPreferenceCache: cache
        )

        let rawJSON = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let rawPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(rawJSON.utf8)) as? [String: Any]
        )
        let rawFragment = try XCTUnwrap(
            (rawPayload["osisFragments"] as? [[String: Any]])?.first
        )
        let rawFeatures = try XCTUnwrap(rawFragment["features"] as? [String: Any])
        XCTAssertEqual(rawFragment["key"] as? String, "MixedGreek--G243")
        XCTAssertEqual(rawFragment["keyName"] as? String, "G243")
        XCTAssertEqual(rawFragment["osisRef"] as? String, "G243")
        XCTAssertEqual(rawFeatures["keyName"] as? String, "G243")

        XCTAssertNotNil(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G244"], robinson: []),
            "The first lookup must establish the padded-family preference"
        )
        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragment = try XCTUnwrap(
            (payload["osisFragments"] as? [[String: Any]])?.first
        )
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertTrue(xml.contains("Padded 243 definition"))
        XCTAssertFalse(xml.contains("Raw 243 definition"))
        XCTAssertEqual(fragment["key"] as? String, "MixedGreek--00243")
        XCTAssertEqual(fragment["keyName"] as? String, "00243")
        XCTAssertEqual(fragment["osisRef"] as? String, "00243")
        XCTAssertEqual(features["keyName"] as? String, "00243")
    }

    /**
     Seeds one populated RawLD dictionary using the shared empty-module fixture metadata.

     - Parameters:
       - moduleName: SWORD module initials to publish and populate.
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
       - features: SWORD dictionary features required by builder discovery.
       - entryKey: Exact RawLD lookup key stored before the record separator.
       - entryXML: Raw dictionary entry body returned for `entryKey`.
       - caseSensitiveKeys: Optional RawLD case-sensitivity config.
       - strongsPadding: Optional JSword Strong's-padding config.
       - zeroSizeSlotIndices: Physical placeholder indices to retain without a data record.
     - Side effects: Writes one `.conf`, `.dat`, and `.idx` fixture under `modulePath`.
     - Failure modes: Propagates filesystem failures and rejects RawLD records too large for its
       16-bit length field.
     */
    private func seedPopulatedRawDictionaryModule(
        named moduleName: String,
        in modulePath: String,
        features: [String],
        category: String = ModuleCategory.dictionary.rawValue,
        entryKey: String,
        entryXML: String,
        caseSensitiveKeys: Bool? = nil,
        strongsPadding: Bool? = false,
        zeroSizeSlotIndices: Set<Int> = []
    ) throws {
        try seedPopulatedRawDictionaryModule(
            named: moduleName,
            in: modulePath,
            features: features,
            category: category,
            entries: [(key: entryKey, xml: entryXML)],
            caseSensitiveKeys: caseSensitiveKeys,
            strongsPadding: strongsPadding,
            zeroSizeSlotIndices: zeroSizeSlotIndices
        )
    }

    /**
     Seeds ordered populated RawLD dictionary records for lookup-order integration tests.

     - Parameters:
       - moduleName: SWORD module initials to publish and populate.
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
       - features: SWORD dictionary features required by builder discovery.
       - category: Installed-book category kept independent from the RawLD key backend.
       - entries: Source-order exact keys and raw entry bodies; callers keep keys sorted for RawLD.
       - caseSensitiveKeys: Optional RawLD case-sensitivity config.
       - strongsPadding: Optional JSword Strong's-padding config.
       - zeroSizeSlotIndices: Physical index positions written with size zero and no data payload.
     - Side effects: Writes one `.conf`, `.dat`, and `.idx` fixture under `modulePath`.
     - Failure modes: Propagates filesystem failures and rejects any record or cumulative offset that
       cannot be represented by RawLD's fixed-width index.
     */
    private func seedPopulatedRawDictionaryModule(
        named moduleName: String,
        in modulePath: String,
        features: [String],
        category: String = ModuleCategory.dictionary.rawValue,
        entries: [(key: String, xml: String)],
        caseSensitiveKeys: Bool? = nil,
        strongsPadding: Bool? = false,
        zeroSizeSlotIndices: Set<Int> = []
    ) throws {
        try seedEmptyRawDictionaryModule(
            named: moduleName,
            in: modulePath,
            category: category,
            features: features,
            caseSensitiveKeys: caseSensitiveKeys,
            strongsPadding: strongsPadding
        )

        let moduleKey = moduleName.lowercased()
        let dataPrefix = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("modules/lexdict/rawld/\(moduleKey)/\(moduleKey)")
        var data = Data()
        var index = Data()
        for (physicalIndex, entry) in entries.enumerated() {
            if zeroSizeSlotIndices.contains(physicalIndex) {
                var offset = UInt32(data.count).littleEndian
                var length = UInt16(0).littleEndian
                Swift.withUnsafeBytes(of: &offset) { index.append(contentsOf: $0) }
                Swift.withUnsafeBytes(of: &length) { index.append(contentsOf: $0) }
                continue
            }
            let record = Data("\(entry.key)\r\n\(entry.xml)".utf8)
            guard record.count <= Int(UInt16.max), data.count <= Int(UInt32.max) else {
                throw NSError(
                    domain: "BibleUI.ReaderNavigationTests.RawLDFixture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "RawLD fixture record is too large"]
                )
            }

            var offset = UInt32(data.count).littleEndian
            var length = UInt16(record.count).littleEndian
            Swift.withUnsafeBytes(of: &offset) { index.append(contentsOf: $0) }
            Swift.withUnsafeBytes(of: &length) { index.append(contentsOf: $0) }
            data.append(record)
            data.append(0x0A)
        }
        try data.write(to: dataPrefix.appendingPathExtension("dat"))
        try index.write(to: dataPrefix.appendingPathExtension("idx"))
    }

    /**
     Seeds a genuine nested RawGenBook generated by SWORD's `imp2gbs` writer.

     - Parameters:
       - moduleName: Installed initials for the feature-bearing general book.
       - modulePath: Temporary SWORD root returned by `makeTemporarySwordFixturePath()`.
       - category: Explicit configured category; driver remains RawGenBook in every fixture.
     - Side effects: Writes the descriptor plus deterministic TreeKey index and entry bytes for
       `Root/G243` under the isolated fixture root.
     - Failure modes: Propagates directory/file writes and fails if the embedded writer output is
       unexpectedly invalid base64.
     */
    private func seedNestedGreekDefinitionGeneralBook(
        named moduleName: String,
        in modulePath: String,
        category: String = ModuleCategory.generalBook.rawValue
    ) throws {
        try seedEmptyRawGeneralBookModule(
            named: moduleName,
            in: modulePath,
            features: ["GreekDef"]
        )
        let moduleKey = moduleName.lowercased()
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/\(moduleKey).conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration = configuration.replacingOccurrences(
            of: "Category=Generic Books",
            with: "Category=\(category)"
        )
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)
        let dataPrefix = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("modules/genbook/rawgenbook/\(moduleKey)/\(moduleKey)")
        let encodedFiles = [
            "dat": "//////////8EAAAAAAAAAAAAAP////8IAAAAUm9vdAAAAAQAAAD//////////0cyNDMAAAAEAAAA//////////9HMjQzAAgAAAAAADoAAAA=",
            "idx": "AAAAAA8AAAA1AAAA",
            "bdt": "PGRpdiB0eXBlPSJlbnRyeSIgbj0iRzI0MyI+TmVzdGVkIEdyZWVrIGRlZmluaXRpb248L2Rpdj4KCg==",
        ]
        for (extensionName, encodedData) in encodedFiles {
            guard let data = Data(base64Encoded: encodedData) else {
                throw NSError(
                    domain: "BibleUI.ReaderNavigationTests.RawGenBookFixture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid embedded RawGenBook fixture"]
                )
            }
            try data.write(to: dataPrefix.appendingPathExtension(extensionName))
        }
    }

    /**
     Protects Android's distinction between a missing Strong's dictionary and a missing entry.

     Android creates its Downloads document only when no compatible dictionary book is installed;
     `LinkControl.getStrongsKey` returns no document when installed books contain no requested key.

     - Setup: Installs an empty `GreekDef` RawLD module named `StrongsGreek`, then requests the real
       gap `G243` reported in issue 388.
     - Expected result: The builder returns `nil`, with no synthetic Downloads fragment.
     - Failure meaning: iOS again treats an absent entry as an absent installation and shows a false
       download action to users who already have the dictionary.
     - Side effects: Writes an isolated SWORD fixture that the base test case removes in teardown.
     */
    func testBuildStrongsMultiDocJSONReturnsNilWhenInstalledDictionaryDoesNotContainEntry() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawDictionaryModule(
            named: "StrongsGreek",
            in: modulePath,
            features: ["GreekDef"]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertTrue(
            manager.installedModules().contains {
                $0.name == "StrongsGreek" && $0.features.contains(.greekDef)
            },
            "The fixture must represent an installed Android-compatible Greek Strong's dictionary"
        )
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        XCTAssertNil(
            builder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: []),
            "An installed dictionary miss must not produce the no-dictionary Downloads document"
        )
    }

    /**
     Protects installed-but-locked Strong's provenance from a false download fallback.

     - Setup: Installs a populated encrypted GreekDef book with no key, builds from the production
       inclusive resolver, then persists a verified key and rebuilds the registry.
     - Expected result: The locked book suppresses the fake Downloads document without exposing
       content; the fresh unlocked registry resolves the real definition.
     - Failure meaning: Automatic discovery equates unreadable with absent, leaks locked content, or
       caches authorization so a successful unlock remains unusable.
     - Side effects: Rewrites one isolated fixture descriptor and removes it in base teardown.
     */
    func testBuildStrongsMultiDocJSONSuppressesFallbackForLockedCompatibleBookThenReadsAfterUnlock() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let moduleName = "LockedGreekDef"
        try seedPopulatedRawDictionaryModule(
            named: moduleName,
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">Unlocked definition</entryFree>"#
        )
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/\(moduleName.lowercased()).conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let lockedManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let lockedResolver = BibleReaderInstalledModuleResolver(
            swordManager: lockedManager,
            sqliteModules: []
        )
        let lockedBuilder = BibleReaderStrongsDocumentBuilder(
            installedDictionarySources: { lockedResolver.dictionaryKeySources() },
            installedBookMetadata: { lockedResolver.registeredBookMetadata() },
            installedDictionarySourceNamed: {
                lockedResolver.module(named: $0)?.explicitDictionaryKeySource
            },
            selectedPreferenceValues: { _ in [] },
            localizedString: { _, defaultValue in defaultValue }
        )

        XCTAssertEqual(lockedManager.moduleAccessState(named: moduleName), .locked)
        XCTAssertFalse(
            lockedResolver.dictionaryKeySources().contains { $0.info.name == moduleName },
            "The locked owner must remain metadata-only even when other readable books exist"
        )
        XCTAssertTrue(
            lockedResolver.registeredBookMetadata().contains {
                $0.name == moduleName && $0.features.contains(.greekDef)
            }
        )
        XCTAssertNil(
            lockedBuilder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: []),
            "Installed locked content must suppress the fake download without being read"
        )

        configuration = configuration.replacingOccurrences(
            of: "CipherKey=\n",
            with: "CipherKey=verified-test-key\n"
        )
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)
        let unlockedManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let unlockedResolver = BibleReaderInstalledModuleResolver(
            swordManager: unlockedManager,
            sqliteModules: []
        )
        let unlockedBuilder = BibleReaderStrongsDocumentBuilder(
            installedDictionarySources: { unlockedResolver.dictionaryKeySources() },
            installedBookMetadata: { unlockedResolver.registeredBookMetadata() },
            installedDictionarySourceNamed: {
                unlockedResolver.module(named: $0)?.explicitDictionaryKeySource
            },
            selectedPreferenceValues: { _ in [] },
            localizedString: { _, defaultValue in defaultValue }
        )
        let json = try XCTUnwrap(
            unlockedBuilder.buildStrongsMultiDocumentJSON(strongs: ["G243"], robinson: [])
        )

        XCTAssertEqual(unlockedManager.moduleAccessState(named: moduleName), .readable)
        XCTAssertTrue(json.contains("Unlocked definition"))
    }

    /**
     Verifies missing-dictionary availability is evaluated for each requested Strong's number.

     - Setup: Installs an empty Greek definition dictionary, leaves Hebrew definitions uninstalled,
       and requests `G243` together with `H00430`.
     - Expected result: The Greek entry miss is omitted while one Hebrew Downloads fragment remains.
     - Failure meaning: A document-wide fallback check can label the wrong language as uninstalled or
       suppress a valid install action when a mixed Strong's request has partial availability.
     - Side effects: Writes an isolated SWORD fixture that the base test case removes in teardown.
     */
    func testBuildStrongsMultiDocJSONScopesInstallFallbackToEachRequestedNumber() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawDictionaryModule(
            named: "StrongsGreek",
            in: modulePath,
            features: ["GreekDef"]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let builder = BibleReaderStrongsDocumentBuilder(
            swordManager: manager,
            selectedPreferenceValues: { _ in [] },
            moduleDisplayLabel: { $0.info.name },
            localizedString: { _, defaultValue in defaultValue }
        )

        let json = try XCTUnwrap(
            builder.buildStrongsMultiDocumentJSON(
                strongs: ["G243", "H00430"],
                robinson: []
            )
        )
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragment["bookInitials"] as? String, "StrongsHebrew")
        XCTAssertEqual(fragment["keyName"] as? String, "H00430")
        XCTAssertTrue(features.isEmpty)
        XCTAssertTrue(payload["contentType"] is NSNull)
        XCTAssertTrue(
            (fragment["xml"] as? String)?.contains(
                "download://?initials=StrongsHebrew"
            ) == true
        )
    }

    /**
     Verifies the reader route preserves its current page when an installed Strong's dictionary
     lacks the requested entry, matching Android's null-result behavior.

     - Setup: Routes `ab-w://?strong=G243` through a controller backed by an empty installed
       `GreekDef` dictionary while recording Vue emissions and links-window routing.
     - Expected result: No definition document is emitted or routed and native rendered state stays
       unchanged.
     - Failure meaning: A builder miss still leaks into UI navigation, clears the current content,
       or opens a misleading Downloads document.
     - Side effects: Writes an isolated SWORD fixture that the base test case removes in teardown.
     */
    @MainActor
    func testStrongsLinkDoesNotNavigateWhenInstalledDictionaryDoesNotContainEntry() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawDictionaryModule(
            named: "StrongsGreek",
            in: modulePath,
            features: ["GreekDef"]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var routedDefinitionDocument = false
        controller.onOpenDefinitionDocumentInLinksWindow = { _, _, _ in
            routedDefinitionDocument = true
        }
        let renderedStateBeforeLookup = controller.renderedContentState

        controller.bridge(bridge, openExternalLink: "ab-w://?strong=G243")

        XCTAssertFalse(routedDefinitionDocument)
        XCTAssertFalse(recordedScripts().contains { $0.contains("emit('add_documents'") })
        XCTAssertEqual(controller.renderedContentState, renderedStateBeforeLookup)
    }

    /**
     Verifies Android's multi-link dispatcher still opens an empty definition document on misses.

     - Setup: Installs empty Greek and Hebrew definition books, then routes two Strong's query
       values through one `ab-w` link.
     - Expected result: The reader emits an empty `MultiDocument` with null content type and adopts
       Android's general-book `Multi` identity instead of treating the request as one failed link.
     - Failure meaning: iOS has collapsed Android's `openMulti` branch into the single-link no-op
       path and leaves users on unrelated content after a handled multi-definition request.
     - Side effects: Writes isolated SWORD fixtures removed by the base test case and records bridge
       scripts in memory.
     */
    @MainActor
    func testMultiStrongsLinkOpensEmptyMultiWhenAllInstalledEntriesMiss() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawDictionaryModule(
            named: "StrongsGreek",
            in: modulePath,
            features: ["GreekDef"]
        )
        try seedEmptyRawDictionaryModule(
            named: "StrongsHebrew",
            in: modulePath,
            features: ["HebrewDef"]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(
            bridge,
            openExternalLink: "ab-w://?strong=G243&strong=H00430"
        )

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertTrue((payload["osisFragments"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertTrue(payload["contentType"] is NSNull)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )
    }

    /**
     Verifies mixed Strong's/morphology multi-links retain Android's empty-Multi miss contract.

     - Setup: Installs empty Greek-definition and Robinson books, then routes one Strong's and one
       morphology value in a single `ab-w` request.
     - Expected result: One empty null-content-type `MultiDocument` is emitted.
     - Failure meaning: Definition type, rather than Android route cardinality, still controls
       whether an all-miss multi request navigates.
     - Side effects: Writes isolated SWORD fixtures removed by the base test case and records bridge
       scripts in memory.
     */
    @MainActor
    func testMixedDefinitionMultiLinkOpensEmptyMultiWhenAllInstalledEntriesMiss() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawDictionaryModule(
            named: "StrongsGreek",
            in: modulePath,
            features: ["GreekDef"]
        )
        try seedEmptyRawDictionaryModule(
            named: "Robinson",
            in: modulePath,
            features: ["GreekParse"]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(
            bridge,
            openExternalLink: "ab-w://?strong=G243&robinson=V-PAI-3S"
        )

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertTrue((payload["osisFragments"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertTrue(payload["contentType"] is NSNull)
    }

    /**
     Verifies one successful child remains the complete result of an Android multi-definition link.

     - Setup: Installs a Greek definition for `G243` plus an empty Hebrew definition book, then
       requests both values in one `ab-w` link.
     - Expected result: The emitted Multi contains only the genuine Greek fragment and Strong's
       content type; the Hebrew entry miss does not become Downloads or an empty-document override.
     - Failure meaning: The empty-Multi correction can replace partial results or revive issue #388's
       misleading missing-installation fallback.
     - Side effects: Writes isolated SWORD fixtures removed by the base test case and records bridge
       scripts in memory.
     */
    @MainActor
    func testMultiStrongsLinkKeepsPartialHitWithoutMissFallback() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "StrongsGreek",
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">another</entryFree>"#
        )
        try seedEmptyRawDictionaryModule(
            named: "StrongsHebrew",
            in: modulePath,
            features: ["HebrewDef"]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(
            bridge,
            openExternalLink: "ab-w://?strong=G243&strong=H00430"
        )

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments.first?["bookInitials"] as? String, "StrongsGreek")
        XCTAssertEqual(fragments.first?["keyName"] as? String, "G243")
        XCTAssertEqual(payload["contentType"] as? String, "strongs")
        XCTAssertFalse((fragments.first?["xml"] as? String)?.contains("download://") == true)
    }

    /**
     Verifies Android definition children retain their mixed query-type order in the emitted tabs.

     - Setup: Installs matching Robinson and Greek definition entries, then requests morphology
       before Strong's in one `ab-w` multi-link.
     - Expected result: The Robinson fragment remains first and the Greek fragment remains second.
     - Failure meaning: Routing or payload construction has regrouped children by definition type
       and visibly changed Android's multi-document tab order.
     - Side effects: Writes isolated SWORD fixtures removed by the base test case and records bridge
       scripts in memory.
     */
    @MainActor
    func testInterleavedDefinitionLinkPreservesAndroidFragmentOrder() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedPopulatedRawDictionaryModule(
            named: "Robinson",
            in: modulePath,
            features: ["GreekParse"],
            entryKey: "V-PAI-3S",
            entryXML: #"<entryFree n="V-PAI-3S">verb</entryFree>"#
        )
        try seedPopulatedRawDictionaryModule(
            named: "StrongsGreek",
            in: modulePath,
            features: ["GreekDef"],
            entryKey: "G243",
            entryXML: #"<entryFree n="G243">another</entryFree>"#
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(
            bridge,
            openExternalLink: "ab-w://?robinson=V-PAI-3S&strong=G243"
        )

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        XCTAssertEqual(fragments.map { $0["bookInitials"] as? String }, ["Robinson", "StrongsGreek"])
        XCTAssertEqual(fragments.map { $0["keyName"] as? String }, ["V-PAI-3S", "G243"])
    }

    /**
     Verifies ignored empty query children still select Android's multi-link execution branch.

     - Setup: Installs an empty Greek definition book and routes one empty unknown child before one
       unresolved Strong's child.
     - Expected result: Raw child cardinality selects `openMulti`, producing an empty Multi document.
     - Failure meaning: iOS counts only recognized nonempty definitions and incorrectly treats the
       request as Android's single-link no-op branch.
     - Side effects: Writes an isolated SWORD fixture removed by the base test case and records bridge
       scripts in memory.
     */
    @MainActor
    func testUnknownEmptyDefinitionChildStillSelectsMultiDispatch() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawDictionaryModule(
            named: "StrongsGreek",
            in: modulePath,
            features: ["GreekDef"]
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(
            bridge,
            openExternalLink: "ab-w://?lemma.TR=&strong=G243"
        )

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertTrue((payload["osisFragments"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertTrue(payload["contentType"] is NSNull)
    }

    @MainActor
    func testStrongsLinkEmitsVueDocumentInsteadOfNativeSheet() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(bridge, openExternalLink: "ab-w://?strong=H00430")

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertTrue(payload["contentType"] is NSNull)
        XCTAssertEqual(fragment["bookCategory"] as? String, "DICTIONARY")
        XCTAssertTrue(features.isEmpty)
        XCTAssertEqual(fragment["keyName"] as? String, "H00430")
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )
    }

    @MainActor
    func testStrongsLinkUsesLinksWindowRoutingCallbackWhenAvailable() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        var routedPayload: (json: String, book: String, key: String)?
        controller.onOpenDefinitionDocumentInLinksWindow = { documentJSON, renderedBook, renderedKey in
            routedPayload = (json: documentJSON, book: renderedBook, key: renderedKey)
        }

        controller.bridge(bridge, openExternalLink: "ab-w://?strong=H00430")

        let payload = try XCTUnwrap(routedPayload)
        XCTAssertTrue(payload.json.contains(#""contentType":null"#))
        XCTAssertEqual(payload.book, "Strongs")
        XCTAssertEqual(payload.key, "strongs")
        XCTAssertEqual(controller.renderedContentState, BibleReaderController.emptyRenderedContentState)

        let targetController = BibleReaderController(bridge: BibleBridge(), swordManagerOverride: manager)
        targetController.loadDefinitionDocument(
            payload.json,
            renderedBook: payload.book,
            renderedKey: payload.key
        )
        XCTAssertEqual(
            targetController.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )

        targetController.bridge(BibleBridge(), saveState: #"{"selectedStrongsDict":"HebrewGreek"}"#)
        XCTAssertEqual(
            targetController.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )
    }

    /**
     Protects Android links-window identity for Strong's and dictionary result documents.

     Android opens Strong's results in the target links window as
     `FakeBookFactory.multiDocument`, with the selected dictionaries rendered inside that page rather
     than becoming the window's document identity. The setup renders a Strong's `MultiDocument` into a
     target controller with a `PageManager`, then simulates Vue saving a different selected dictionary
     tab. The expected result is that native page/category state remains the general-book `Multi`
     special document, the links window stays non-Bible syncable behavior-wise, and tab selection does
     not relabel the whole window as `HebrewGreek`. A failure means iOS has preserved an iOS-only
     transient dictionary identity instead of Android's durable links-window document semantics.
     */
    @MainActor
    func testDefinitionDocumentUsesAndroidMultiPageIdentityForLinksWindowTarget() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }
        let documentJSON = try XCTUnwrap(
            controller.buildStrongsMultiDocJSON(strongs: ["H00430"], robinson: [])
        )

        controller.loadDefinitionDocument(
            documentJSON,
            renderedBook: "Strongs",
            renderedKey: "strongs"
        )

        let androidBookAndKeyListRef = "StrongsHebrew:H00430"
        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.currentGeneralBookKey, androidBookAndKeyListRef)
        XCTAssertTrue(controller.hasStrongs)
        XCTAssertFalse(controller.canUseBibleReferenceActions)
        XCTAssertFalse(controller.isCurrentPageSearchable)
        XCTAssertFalse(controller.isCurrentPageSpeakable)
        XCTAssertFalse(controller.isCurrentPageSyncable)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(pageManager.generalBookDocument, "Multi")
        XCTAssertEqual(pageManager.generalBookKey, androidBookAndKeyListRef)
        XCTAssertGreaterThan(persistCount, 0)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )

        controller.bridge(bridge, saveState: #"{"selectedStrongsDict":"HebrewGreek"}"#)

        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(pageManager.generalBookDocument, "Multi")
        XCTAssertEqual(pageManager.generalBookKey, androidBookAndKeyListRef)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )
    }

    /**
     Protects Android links-window identity for multi-reference Bible link result documents.

     Android does not leave a links-window target on the source Bible page after opening a multi-link;
     it sets the destination window's current document to `FakeBookFactory.multiDocument` and stores
     the synthetic key for that special document. The setup sends a minimal serialized Vue
     `MultiDocument` through the native target-controller entry point. The expected result is a
     persisted general-book `Multi` page identity with no mutation of the underlying Bible module
     selection. A failure means bottom tabs and restored window state can report a Bible window while
     visually displaying a link-result page.
     */
    @MainActor
    func testMultiReferenceDocumentUsesAndroidMultiPageIdentity() {
        let controller = BibleReaderController(bridge: BibleBridge())
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        let bibleDocumentBeforeLoad = pageManager.bibleDocument
        let documentJSON = """
        {
          "id": "multi-test",
          "type": "multi",
          "osisFragments": [
            {"bookInitials": "KJV", "osisRef": "Gen.1.1"},
            {"bookInitials": "KJV", "osisRef": "John.3.16"}
          ],
          "compare": false
        }
        """

        controller.loadMultiReferenceDocument(documentJSON)

        let androidBookAndKeyListRef = "KJV:Gen.1.1||KJV:John.3.16"
        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.currentGeneralBookKey, androidBookAndKeyListRef)
        XCTAssertFalse(controller.canUseBibleReferenceActions)
        XCTAssertFalse(controller.isCurrentPageSearchable)
        XCTAssertFalse(controller.isCurrentPageSpeakable)
        XCTAssertFalse(controller.isCurrentPageSyncable)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(pageManager.generalBookDocument, "Multi")
        XCTAssertEqual(pageManager.generalBookKey, androidBookAndKeyListRef)
        XCTAssertEqual(pageManager.bibleDocument, bibleDocumentBeforeLoad)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=multi"
        )
    }

    /**
     Protects restored Android `Multi` keys from malformed transient result payloads.

     Android's durable links-window restore key is the `BookAndKeyList` string stored in the general
     book page. iOS may still receive malformed transient JSON from a bridge path, but that should not
     overwrite the last restorable key with `nil`. The setup restores an existing Android `Multi`
     page, then loads a malformed multi-reference payload that cannot produce a new
     `BookAndKeyList`. The expected result is no durable PageManager mutation; a failure means one
     bad transient render can make the links window unrestorable after restart.
     */
    @MainActor
    func testMalformedMultiReferenceDocumentDoesNotEraseRestoredAndroidMultiKey() {
        let controller = BibleReaderController(bridge: BibleBridge())
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.generalBook.pageManagerKey)
        pageManager.generalBookDocument = "Multi"
        pageManager.generalBookKey = "KJV:Gen.1.1||KJV:John.3.16"
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.restoreSavedPosition()
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.loadMultiReferenceDocument(#"{"id":"bad-multi","type":"multi"}"#)

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.currentGeneralBookKey, "KJV:Gen.1.1||KJV:John.3.16")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(pageManager.generalBookDocument, "Multi")
        XCTAssertEqual(pageManager.generalBookKey, "KJV:Gen.1.1||KJV:John.3.16")
        XCTAssertEqual(persistCount, 0)
    }

    /**
     Rejects installed wrong-category identities in optional general-book and map restore fields.

     - Setup: Registers one readable dictionary, then restores two fresh panes whose general-book
       and map fields each point at that dictionary while their visible categories request the
       corresponding optional document.
     - Expected: Both restores leave controller module/key/category state, PageManager values,
       persistence count, and bridge emissions byte-for-byte unchanged.
     - Failure meaning: Category checks guard only the happy-path handle assignment while a fallback
       branch still reinterprets a globally owned dictionary as a general book or map.
     - Side effects: Writes one inherited temporary SWORD fixture and two in-memory pane models.
     */
    @MainActor
    func testRestoreRejectsWrongCategoryGeneralBookAndMapWithoutMutation() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawDictionaryModule(named: "WrongRestoreCategory", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        for (categoryName, configurePageManager) in [
            (
                DocumentCategory.generalBook.pageManagerKey,
                { (pageManager: PageManager) in
                    pageManager.generalBookDocument = "WrongRestoreCategory"
                    pageManager.generalBookKey = "wrong-general-key"
                }
            ),
            (
                DocumentCategory.map.pageManagerKey,
                { (pageManager: PageManager) in
                    pageManager.mapDocument = "WrongRestoreCategory"
                    pageManager.mapKey = "wrong-map-key"
                }
            ),
        ] {
            let (bridge, recordedScripts) = makeRecordingBridge()
            let controller = BibleReaderController(
                bridge: bridge,
                swordManagerOverride: manager
            )
            let window = Window(isSynchronized: false, isLinksWindow: false)
            let pageManager = PageManager(id: window.id, currentCategoryName: categoryName)
            configurePageManager(pageManager)
            window.pageManager = pageManager
            controller.activeWindow = window
            let baselineCategory = controller.currentCategory
            let baselineGeneralBookName = controller.activeGeneralBookModuleName
            let baselineGeneralBookKey = controller.currentGeneralBookKey
            let baselineMapName = controller.activeMapModuleName
            let baselineMapKey = controller.currentMapKey
            let baselineScripts = recordedScripts().count
            var persistCount = 0
            controller.onPersistState = { persistCount += 1 }

            controller.restoreSavedPosition()

            XCTAssertEqual(controller.currentCategory, baselineCategory)
            XCTAssertEqual(controller.activeGeneralBookModuleName, baselineGeneralBookName)
            XCTAssertEqual(controller.currentGeneralBookKey, baselineGeneralBookKey)
            XCTAssertEqual(controller.activeMapModuleName, baselineMapName)
            XCTAssertEqual(controller.currentMapKey, baselineMapKey)
            XCTAssertEqual(pageManager.currentCategoryName, categoryName)
            XCTAssertEqual(pageManager.generalBookDocument,
                           categoryName == DocumentCategory.generalBook.pageManagerKey
                               ? "WrongRestoreCategory" : nil)
            XCTAssertEqual(pageManager.generalBookKey,
                           categoryName == DocumentCategory.generalBook.pageManagerKey
                               ? "wrong-general-key" : nil)
            XCTAssertEqual(pageManager.mapDocument,
                           categoryName == DocumentCategory.map.pageManagerKey
                               ? "WrongRestoreCategory" : nil)
            XCTAssertEqual(pageManager.mapKey,
                           categoryName == DocumentCategory.map.pageManagerKey
                               ? "wrong-map-key" : nil)
            XCTAssertEqual(persistCount, 0)
            XCTAssertEqual(recordedScripts().count, baselineScripts)
        }
    }

    /**
     Protects restoration of Android's synthetic `Multi` document identity.

     Android persists links-window result pages as a general-book page whose document initials are
     `Multi`, even though that document is created by `FakeBookFactory` rather than installed from
     SWORD. The setup restores a controller from those PageManager fields without registering any real
     general-book module named `Multi`. The expected result is that iOS still marks the window as the
     synthetic `Multi` general-book document and treats it like Android's special non-navigation page.
     A failure means restored links-window tabs can fall back to stale Bible identity simply because
     the synthetic document is not a SWORD module.
     */
    @MainActor
    func testRestoreSavedPositionRecognizesAndroidMultiDocumentIdentity() {
        let controller = BibleReaderController(bridge: BibleBridge())
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.generalBook.pageManagerKey)
        pageManager.generalBookDocument = "Multi"
        pageManager.generalBookKey = "KJV:Gen.1.1||KJV:John.3.16"
        window.pageManager = pageManager
        controller.activeWindow = window

        controller.restoreSavedPosition()

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.activeGeneralBookModuleName, "Multi")
        XCTAssertEqual(controller.currentGeneralBookKey, "KJV:Gen.1.1||KJV:John.3.16")
        XCTAssertTrue(controller.hasStrongs)
        XCTAssertFalse(controller.hasNext)
        XCTAssertFalse(controller.hasPrevious)
        XCTAssertFalse(controller.canUseBibleReferenceActions)
        XCTAssertFalse(controller.isCurrentPageSearchable)
        XCTAssertFalse(controller.isCurrentPageSpeakable)
        XCTAssertFalse(controller.isCurrentPageSyncable)
    }

    /**
     Protects restoration of Android's synthetic Memorize document identity.

     Android persists Memorize as `FakeBookFactory.memorizeDocument`, a commentary-category fake
     document, not as an installed commentary module and not as Bible content. The setup restores a
     pane from only the local PageManager fields iOS currently owns. The expected result is that
     native state still reports `commentary/Memorize` and suppresses ordinary Bible/commentary
     actions. A failure means a restored Memorize links window can fall back to an installed
     commentary or to regular Bible chrome because the fake document is not a SWORD module.
     */
    @MainActor
    func testRestoreSavedPositionRecognizesAndroidMemorizeDocumentIdentity() {
        let controller = BibleReaderController(bridge: BibleBridge())
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.commentary.pageManagerKey)
        pageManager.commentaryDocument = "Memorize"
        pageManager.commentaryAnchorOrdinal = 1
        window.pageManager = pageManager
        controller.activeWindow = window

        controller.restoreSavedPosition()

        XCTAssertEqual(controller.currentCategory, .commentary)
        XCTAssertEqual(controller.activeModuleName(for: .commentary), "Memorize")
        XCTAssertTrue(controller.isShowingAndroidMemorizeDocument)
        XCTAssertFalse(controller.canUseBibleReferenceActions)
        XCTAssertFalse(controller.isCurrentPageSearchable)
        XCTAssertFalse(controller.isCurrentPageSpeakable)
        XCTAssertFalse(controller.isCurrentPageSyncable)
    }

    /**
     Protects restored Memorize content from falling through to missing-commentary placeholders.

     Android restores Memorize from a commentary fake document plus source `BookAndKey`. iOS does
     not yet store the full source range locally, but it does persist a commentary anchor ordinal.
     This setup restores from that local state and asks the controller to load current content. The
     expected result is a real single-anchor Vue Memorize document with `commentary/Memorize` native
     identity. A failure means a process-recreated links window can keep the right tab label while
     rendering ordinary no-commentary content.
     */
    @MainActor
    func testRestoredAndroidMemorizeDocumentRebuildsPayloadFromPersistedAnchor() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeInMemorySettingsStore()
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.commentary.pageManagerKey)
        pageManager.commentaryDocument = "Memorize"
        pageManager.commentaryAnchorOrdinal = ordinal
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.restoreSavedPosition()

        controller.loadCurrentContent()

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "memorize")
        XCTAssertEqual(payload["title"] as? String, "Genesis 1:1")
        XCTAssertEqual(payload["bookInitials"] as? String, "KJV")
        XCTAssertEqual(payload["startOrdinal"] as? Int, ordinal)
        XCTAssertEqual(payload["endOrdinal"] as? Int, ordinal)
        XCTAssertEqual(controller.currentCategory, .commentary)
        XCTAssertEqual(controller.activeModuleName(for: .commentary), "Memorize")
        XCTAssertEqual(
            controller.renderedContentState,
            "category=commentary;module=Memorize;book=Genesis 1:1;chapter=none;key=memorize:KJV:\(ordinal)-\(ordinal)"
        )
    }

    /**
     Protects Android's full Memorize restore source range.

     Android persists Memorize as `commentary/Memorize` plus a serialized `BookAndKey` source range
     in `commentary_sourceBookAndKey`. The setup mirrors a process restart after a multi-verse
     Memorize links-window load. The expected result is that iOS rebuilds the original full range,
     not only the anchor verse. A failure means iOS can preserve the fake-document tab while losing
     the user's selected Memorize passage.
     */
    @MainActor
    func testRestoredAndroidMemorizeDocumentRebuildsPayloadFromSerializedSourceBookAndKey() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let settingsStore = try makeInMemorySettingsStore()
        controller.settingsStore = settingsStore
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        let endOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 3))
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.commentary.pageManagerKey)
        pageManager.commentaryDocument = "Memorize"
        pageManager.commentaryAnchorOrdinal = startOrdinal
        window.pageManager = pageManager
        controller.activeWindow = window
        RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore).setPageManagerEntry(
            .init(
                windowID: window.id,
                rawCurrentCategoryName: "COMMENTARY",
                commentarySourceBookAndKey: #"{"document":"KJV","htmlId":null,"key":"Gen.1.1-Gen.1.3","ordinalRange":null}"#,
                dictionaryAnchorOrdinal: nil,
                generalBookAnchorOrdinal: nil,
                mapAnchorOrdinal: nil
            )
        )
        controller.restoreSavedPosition()

        controller.loadCurrentContent()

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "memorize")
        XCTAssertEqual(payload["title"] as? String, "Genesis 1:1-3")
        XCTAssertEqual(payload["bookInitials"] as? String, "KJV")
        XCTAssertEqual(payload["osisRef"] as? String, "Gen.1.1-Gen.1.3")
        XCTAssertEqual(payload["startOrdinal"] as? Int, startOrdinal)
        XCTAssertEqual(payload["endOrdinal"] as? Int, endOrdinal)
        XCTAssertEqual((payload["texts"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=commentary;module=Memorize;book=Genesis 1:1-3;chapter=none;key=memorize:KJV:\(startOrdinal)-\(endOrdinal)"
        )
    }

    /**
     Rejects a restored Memorize source that was relocked before process restoration.

     - Setup: Publishes a KJV-backed alias whose descriptor is already locked, restores Android's
       `commentary/Memorize` identity with that alias in the persisted `BookAndKey`, and retains a
       recording bridge plus the pre-load controller state.
     - Expected result: The inclusive manager can still identify the installed module, but the
       readable resolver rejects it; loading emits no Vue document, does not strip source text, and
       leaves the Memorize identity and rendered state unchanged.
     - Failure meaning: Process restoration can bypass a relock through `module(named:)`, or can
       reinterpret an authorization failure as unrelated commentary content.
     - Side effects: Writes only an inherited temporary SWORD descriptor and in-memory settings.
     */
    @MainActor
    func testRestoredAndroidMemorizeDocumentRejectsRelockedSourceWithoutMutation() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let moduleName = "LockedMemorize"
        try seedBibleAliasModule(
            named: moduleName,
            description: "Locked Memorize Bible",
            in: modulePath
        )
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/\(moduleName.lowercased()).conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertNotNil(manager.module(named: moduleName))
        XCTAssertNil(manager.readableModule(named: moduleName))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let settingsStore = try makeInMemorySettingsStore()
        controller.settingsStore = settingsStore
        let ordinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(
            id: window.id,
            currentCategoryName: DocumentCategory.commentary.pageManagerKey
        )
        pageManager.commentaryDocument = "Memorize"
        pageManager.commentaryAnchorOrdinal = ordinal
        window.pageManager = pageManager
        controller.activeWindow = window
        RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore).setPageManagerEntry(
            .init(
                windowID: window.id,
                rawCurrentCategoryName: "COMMENTARY",
                commentarySourceBookAndKey: "{\"document\":\"\(moduleName)\",\"htmlId\":null,\"key\":\"Gen.1.1\",\"ordinalRange\":null}",
                dictionaryAnchorOrdinal: nil,
                generalBookAnchorOrdinal: nil,
                mapAnchorOrdinal: nil
            )
        )
        controller.restoreSavedPosition()
        let baselineScripts = recordedScripts().count
        let baselineRenderedState = controller.renderedContentState

        controller.loadCurrentContent()

        XCTAssertEqual(recordedScripts().count, baselineScripts)
        XCTAssertEqual(controller.renderedContentState, baselineRenderedState)
        XCTAssertEqual(controller.currentCategory, .commentary)
        XCTAssertEqual(controller.activeModuleName(for: .commentary), "Memorize")
        XCTAssertTrue(controller.isShowingAndroidMemorizeDocument)
    }

    /**
     Protects Android's durable restore behavior for links-window `Multi` result pages.

     Android restores `FakeBookFactory.multiDocument` by parsing the persisted `BookAndKeyList` OSIS
     reference back into source document/key pairs, then rendering a `MultiFragmentDocument`. The setup
     starts with only the persisted PageManager category/document/key fields, as a process restart would.
     The expected result is a real Vue `MultiDocument` payload derived from the saved key; a failure
     means iOS has only fixed the bottom-tab label while losing the actual restored links-window content.
     */
    @MainActor
    func testRestoredAndroidMultiDocumentRebuildsPayloadFromPersistedKey() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.generalBook.pageManagerKey)
        pageManager.generalBookDocument = "Multi"
        pageManager.generalBookKey = "KJV:Gen.1.1||KJV:John.3.16"
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.restoreSavedPosition()

        controller.loadCurrentContent()

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])

        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertEqual(fragments.count, 2)
        XCTAssertEqual(fragments[0]["bookInitials"] as? String, "KJV")
        XCTAssertEqual(fragments[0]["osisRef"] as? String, "Gen.1.1")
        XCTAssertEqual(fragments[1]["bookInitials"] as? String, "KJV")
        XCTAssertEqual(fragments[1]["osisRef"] as? String, "John.3.16")
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=multi"
        )
    }

    #if os(iOS)
    /**
     Protects native selection state and payload decisions as a focused reader responsibility.

     Android action mode tracks selection state separately from page navigation, and `Multi`/generic
     pages must not fabricate Bible references from the pane that opened them. The setup exercises the
     coordinator directly with a normal Bible page and an Android-style non-Bible page. The expected
     result is a Bible copy/share payload only for Bible-capable pages, text-only copy for non-Bible
     pages, and cleared state after deselection. A failure means the selection extraction either lost
     state transitions or reintroduced stale Bible-reference behavior outside controller orchestration.
     The test performs no simulator, pasteboard, or persistence side effects and is deterministic.
     */
    func testReaderSelectionCoordinatorOwnsSelectionStateAndReferencePayloads() {
        var coordinator = BibleReaderSelectionCoordinator()
        let bibleContext = BibleReaderSelectionPageContext(
            canUseBibleReferenceActions: true,
            currentBook: "Genesis",
            currentChapter: 1,
            activeModuleName: "KJV"
        )
        let multiContext = BibleReaderSelectionPageContext(
            canUseBibleReferenceActions: false,
            currentBook: "Genesis",
            currentChapter: 1,
            activeModuleName: "KJV"
        )

        coordinator.selectionChanged("In the beginning")

        XCTAssertTrue(coordinator.hasActiveSelection)
        XCTAssertEqual(coordinator.selectedText, "In the beginning")
        XCTAssertEqual(
            coordinator.copyText(context: bibleContext),
            "In the beginning\n\u{2014} Genesis 1 (KJV)"
        )
        XCTAssertEqual(
            coordinator.shareText(context: bibleContext),
            "In the beginning\n\u{2014} Genesis 1 (KJV)"
        )
        XCTAssertEqual(coordinator.copyText(context: multiContext), "In the beginning")
        XCTAssertNil(coordinator.shareText(context: multiContext))

        coordinator.clearSelection()

        XCTAssertFalse(coordinator.hasActiveSelection)
        XCTAssertEqual(coordinator.selectedText, "")
        XCTAssertNil(coordinator.copyText(context: bibleContext))
        XCTAssertNil(coordinator.shareText(context: bibleContext))
    }

    /**
     Protects native selection actions from falling back to the stale Bible page behind `Multi`.

     Android treats `FakeBookFactory.multiDocument` as a special general-book page. Bible-only
     actions such as sharing verse references are unavailable there, while plain copy must not invent
     a Bible reference from the source pane. The setup renders a `Multi` links-window document and
     marks a native text selection. The expected result is a text-only copy payload and no Bible share
     callback. A failure means iOS can expose stale `Genesis 1 (KJV)` style output for a links-window
     document that Android no longer considers a Bible page.
     */
    @MainActor
    func testMultiDocumentNativeSelectionActionsDoNotUseStaleBibleReference() {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.loadMultiReferenceDocument("""
        {
          "id": "multi-selection-test",
          "type": "multi",
          "osisFragments": [
            {"bookInitials": "KJV", "osisRef": "Gen.1.1"}
          ],
          "compare": false
        }
        """)

        controller.bridge(bridge, selectionChanged: "Selected definition text")
        var sharedText: String?
        controller.onShareVerseText = { sharedText = $0 }

        XCTAssertEqual(controller.selectionCopyTextForCurrentPage(), "Selected definition text")
        XCTAssertNil(sharedText)

        controller.bridge(bridge, selectionChanged: "Selected definition text")
        controller.shareSelection()

        XCTAssertNil(sharedText)
    }
    #endif

    /**
     Protects pane menu action visibility before the pane controller is registered.

     SwiftUI can build a `BibleWindowPane` menu while the persisted `PageManager` already says the
     links window is Android's `general_book/Multi` page, but before `windowManager.controllers`
     contains the live controller. Android does not expose copy-reference or sync controls for that
     special page. The expected fallback is therefore based on persisted category/document state, not a
     permissive controller-nil default. A failure means the menu can briefly show stale Bible actions
     during initial render or controller re-registration.
     */
    func testPaneMenuCapabilitiesUsePageManagerBeforeControllerRegistration() {
        let window = Window(isSynchronized: false, isLinksWindow: true)
        let pageManager = PageManager(id: window.id, currentCategoryName: DocumentCategory.generalBook.pageManagerKey)
        pageManager.generalBookDocument = "Multi"
        pageManager.generalBookKey = "KJV:Gen.1.1"
        window.pageManager = pageManager

        let capabilities = BibleWindowPaneMenuCapabilities(window: window, controller: nil)

        XCTAssertFalse(capabilities.canCopyReference)
        XCTAssertFalse(capabilities.canSyncWindow)
    }

    @MainActor
    func testDefinitionDocumentRequestedBeforeClientReadyReplaysAfterClientReady() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let documentJSON = try XCTUnwrap(
            controller.buildStrongsMultiDocJSON(strongs: ["H00430"], robinson: [])
        )

        controller.loadDefinitionDocument(
            documentJSON,
            renderedBook: "Strongs",
            renderedKey: "strongs"
        )
        let scriptCountBeforeClientReady = recordedScripts().count

        controller.bridgeDidSetClientReady(bridge)

        let clientReadyScripts = Array(recordedScripts().dropFirst(scriptCountBeforeClientReady))
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: clientReadyScripts, event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        let fragment = try XCTUnwrap(fragments.first)
        let features = try XCTUnwrap(fragment["features"] as? [String: Any])

        XCTAssertTrue(payload["contentType"] is NSNull)
        XCTAssertTrue(features.isEmpty)
        XCTAssertEqual(fragment["keyName"] as? String, "H00430")
        XCTAssertNotEqual(fragment["osisRef"] as? String, "Gen.1")
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=Multi;book=Multi;chapter=none;key=strongs"
        )
    }

    @MainActor
    func testLoadCurrentContentEmitsBookIntroAndChapterMarkerForSecondCorinthiansOne() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let secondCorinthians = try XCTUnwrap(
            controller.bookList.first(where: { $0.osisId == "2Cor" })?.name
        )

        controller.navigateTo(book: secondCorinthians, chapter: 1, verse: 1)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )
        let hasSecondCorinthiansChapterMarker = addDocumentsScript.range(
            of: #"osisID=\\"2Cor\.1\\""#,
            options: .regularExpression
        ) != nil

        XCTAssertTrue(
            addDocumentsScript.contains("THE SECOND EPISTLE OF PAUL THE APOSTLE TO THE CORINTHIANS"),
            "Expected emitted payload to contain the book intro title. Script: \(addDocumentsScript)"
        )
        XCTAssertTrue(
            hasSecondCorinthiansChapterMarker,
            "Expected emitted payload to contain a chapter-start marker for 2Cor.1. Script: \(addDocumentsScript)"
        )
    }

    @MainActor
    func testLoadCurrentContentEmitsRenderableChapterMarkerForSecondCorinthiansTwo() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let secondCorinthians = try XCTUnwrap(
            controller.bookList.first(where: { $0.osisId == "2Cor" })?.name
        )

        controller.navigateTo(book: secondCorinthians, chapter: 2, verse: 1)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )
        let hasSecondCorinthiansChapterMarker = addDocumentsScript.range(
            of: #"osisID=\\"2Cor\.2\\""#,
            options: .regularExpression
        ) != nil

        XCTAssertTrue(
            hasSecondCorinthiansChapterMarker,
            "Expected emitted payload to contain a chapter-start marker for 2Cor.2. Script: \(addDocumentsScript)"
        )
        XCTAssertFalse(
            addDocumentsScript.contains("eID\\\":\\\"gen1794") && !addDocumentsScript.contains("sID\\\":\\\"gen1794"),
            "Expected an opening chapter marker in the emitted document payload, not only a closing tag. Script: \(addDocumentsScript)"
        )
    }

    /**
     Protects Android Strong's display parity at the native render boundary.

     Android's Hidden Links/Links/Text and Links modes all keep JSword lexical markup available and
     let the Vue OSIS renderer decide whether Strong's links are hidden, dotted, or shown as text.
     iOS panes share a SWORD manager whose global options can be changed by another pane or speech
     render, so loading a Bible chapter must reapply the current pane settings immediately before
     reading raw entries. The setup starts with Strong's disabled on the manager, enables Android's
     Links mode on the controller, and loads Genesis through the real controller path. The expected
     result is emitted OSIS containing Strong's lemma attributes; a failure means the WebView cannot
     render dotted Strong's links even when the persisted window setting requests them.
     */
    @MainActor
    func testLoadCurrentContentReappliesStrongsOptionsBeforeReadingChapter() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        var displaySettings = TextDisplaySettings.appDefaults
        displaySettings.strongsMode = StrongsMode.links.rawValue

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.displaySettings = displaySettings
        manager.setGlobalOption(.strongsNumbers, enabled: false)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.loadCurrentContent()

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        let fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])
        let xml = try XCTUnwrap(fragment["xml"] as? String)

        XCTAssertTrue(manager.isGlobalOptionEnabled(.strongsNumbers))
        XCTAssertTrue(
            xml.contains(#"lemma="strong:H0430""#),
            "Expected Genesis 1 emitted OSIS to retain Strong's lemma markup. XML: \(xml)"
        )
    }

    @MainActor
    func testLoadCurrentContentDoesNotHighlightRestoredReadingPosition() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 5
        window.pageManager = pageManager
        controller.activeWindow = window

        controller.restoreSavedPosition()
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )

        XCTAssertTrue(
            addDocumentsScript.contains("\"originalOrdinalRange\":null"),
            "Expected restored reading position to avoid verse highlighting. Script: \(addDocumentsScript)"
        )
    }

    /**
     Verifies explicit verse navigation highlights the JSword/SWORD ordinal for the selected verse.

     Android stores the navigation target as the active versification's verse ordinal, including
     intro slots. The KJV test fixture module supplies the expected ordinal here so this test fails if
     iOS reverts to literal verse numbers while still emitting an `originalOrdinalRange` field.
     */
    @MainActor
    func testLoadCurrentContentHighlightsExplicitVerseNavigationTarget() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let expectedOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5)
        )

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.navigateTo(book: "Genesis", chapter: 1, verse: 5)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )

        XCTAssertTrue(
            addDocumentsScript.contains("\"originalOrdinalRange\":[\(expectedOrdinal),\(expectedOrdinal)]"),
            "Expected explicit verse navigation to preserve the original highlighted target. Script: \(addDocumentsScript)"
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "setup_content") as? [String: Any]
        )
        XCTAssertTrue(setup["jumpToOrdinal"] is NSNull)
        XCTAssertEqual(setup["jumpToAnchor"] as? Int, expectedOrdinal)
        XCTAssertEqual(setup["ordinalStart"] as? Int, expectedOrdinal)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, expectedOrdinal)
        XCTAssertEqual(setup["highlight"] as? Bool, true)
        XCTAssertEqual(setup["bookInitials"] as? String, "KJV")
        XCTAssertEqual(setup["osisRef"] as? String, "Gen.1")
    }

    /**
     Verifies corrupt installed Bible content renders a visible no-content document.

     The installer should reject partial downloads before publication, but an already installed
     module can still be missing data because of filesystem damage, migration bugs, or older builds.
     This fixture removes the Old Testament files after copying KJV, then asks the reader for
     Genesis. A failure means the native bridge can clear Vue's documents and leave the reader on an
     endless loading spinner instead of emitting Android's no-content message.
     */
    @MainActor
    func testLoadCurrentContentEmitsNoContentErrorDocumentWhenInstalledBibleChapterIsMissing() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let dataPath = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("texts", isDirectory: true)
            .appendingPathComponent("ztext", isDirectory: true)
            .appendingPathComponent("kjv", isDirectory: true)
        for fileName in ["ot.bzs", "ot.bzz", "ot.bzv"] {
            try FileManager.default.removeItem(at: dataPath.appendingPathComponent(fileName))
        }
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertNotNil(manager.module(named: "KJV"))

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )

        XCTAssertEqual(payload["type"] as? String, "error")
        XCTAssertEqual(payload["errorMessage"] as? String, "No content for selected verse")
        XCTAssertEqual(payload["severity"] as? String, "NORMAL")
        XCTAssertTrue(recordedScripts().contains { $0.contains("emit('clear_document'") })
        XCTAssertTrue(recordedScripts().contains { $0.contains("emit('setup_content'") })
        XCTAssertEqual(
            controller.renderedContentState,
            "category=bible;module=KJV;book=Genesis;chapter=1;key=Gen.1"
        )
    }

    /**
     Verifies an installed commentary with no selected-verse entry emits Android's error document.

     The empty `RawCom` fixture makes the missing-content branch deterministic. Android surfaces
     that failure through `ErrorDocument`; fabricating a verse-shaped commentary fragment would
     misrepresent missing content as successfully loaded module data.
     */
    @MainActor
    func testCommentaryMissingEntryEmitsNoContentErrorDocument() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertTrue(
            manager.installedModules(category: .commentary).contains { $0.name == "UITestComm" },
            "Expected the temporary RawCom fixture to be discovered as a commentary module."
        )

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.navigateTo(book: "Genesis", chapter: 1, verse: 5)
        controller.switchCategory(to: .commentary)
        let baselineScriptCount = recordedScripts().count
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(recordedScripts().dropFirst(baselineScriptCount)),
                event: "add_documents"
            ) as? [String: Any]
        )

        XCTAssertEqual(payload["type"] as? String, "error")
        XCTAssertEqual(payload["errorMessage"] as? String, "No content for selected verse")
        XCTAssertEqual(payload["severity"] as? String, "NORMAL")
        XCTAssertNil(payload["osisFragment"])
        XCTAssertEqual(
            controller.renderedContentState,
            "category=commentary;module=UITestComm;book=Genesis;chapter=1;key=Gen.1.5"
        )
    }

    /**
     Verifies Android-style `multi://` links render as a Vue MultiDocument instead of a native sheet.

     Setup uses a temporary KJV test fixture module and a recording bridge, then invokes the production
     external-link bridge path with two OSIS parameters. The expected result is an `add_documents`
     payload containing a multi document and no cross-reference sheet callback. A failure means iOS
     regressed to an iOS-only presentation path for links Android handles as in-reader documents. The
     test is main-actor isolated for controller callbacks and creates only temporary module fixtures.
     */
    @MainActor
    func testMultiReferenceLinkEmitsVueMultiDocumentInsteadOfCrossReferenceSheet() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridge(bridge, openExternalLink: "multi://?osis=Gen.1.1&osis=Exod.2.1&v11n=KJVA")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )
        XCTAssertTrue(
            addDocumentsScript.contains(#""type":"multi""#),
            "Expected multi:// to render a Vue MultiDocument. Script: \(addDocumentsScript)"
        )
        XCTAssertTrue(addDocumentsScript.contains(#""bookCategory":"BIBLE""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Gen.1.1""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Exod.2.1""#))
    }

    /**
     Verifies comma-separated `osis://` links use the same MultiDocument path as Android.

     Setup records bridge emissions from the production external-link handler with a temporary KJV
     module. The expected result is one Vue multi-document payload containing both references and no
     cross-reference sheet callback. A failure means iOS is splitting or presenting multi-reference
     OSIS links differently from Android. The test is synchronous except for the main-run-loop drain
     needed to capture bridge emission.
     */
    @MainActor
    func testMultiReferenceOsisLinkEmitsVueMultiDocumentInsteadOfCrossReferenceSheet() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridge(bridge, openExternalLink: "osis://?osis=Gen.1.1,Exod.2.1&v11n=KJVA")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentsScript = try XCTUnwrap(
            recordedScripts().first(where: { $0.contains("emit('add_documents'") })
        )
        XCTAssertTrue(
            addDocumentsScript.contains(#""type":"multi""#),
            "Expected multi-reference osis:// to render a Vue MultiDocument. Script: \(addDocumentsScript)"
        )
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Gen.1.1""#))
        XCTAssertTrue(addDocumentsScript.contains(#""osisRef":"Exod.2.1""#))
    }

    /**
     Verifies one contiguous OSIS range remains a normal Bible passage like Android.

     Android only creates a `MultiDocument` when `Passage.countRanges(...)` is greater than one.
     This range therefore navigates the active Bible to its first verse and carries its complete
     ordinal span internally instead of changing the visible document category.
     */
    @MainActor
    func testContiguousOsisRangeNavigatesAsOneBiblePassage() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridge(bridge, openExternalLink: "osis://?osis=Exod.2.1-Exod.2.3&v11n=KJVA")

        XCTAssertEqual(controller.currentBook, "Exodus")
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertFalse(recordedScripts().contains { $0.contains(#""type":"multi""#) })
    }

    /**
     Verifies production pane routing retains a forced document's complete source passage identity.

     The source controller parses a KJVA Psalm range through the real external-link bridge callback,
     and the callback invokes `BibleWindowPane`'s production router against a separate destination
     controller already displaying a Multi document. Android's `LinkControl.showLink` keeps the
     `BookAndKey` source versification and range while selecting the forced target Bible. The
     expected result replaces that existing links-window content with a normal Vulgate Bible
     document whose first verse and highlighted ordinal range are both strictly mapped; any retained
     Multi identity, KJV target, or endpoint-only widening fails the contract.
     */
    @MainActor
    func testWindowPaneRouterPreservesForcedDocumentRangeAndVersification() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "VulgTest",
            description: "Vulgate OSIS routing fixture",
            versification: "Vulg",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (sourceBridge, sourceScripts) = makeRecordingBridge()
        let (targetBridge, targetScripts) = makeRecordingBridge()
        let sourceController = BibleReaderController(
            bridge: sourceBridge,
            swordManagerOverride: manager
        )
        let targetController = BibleReaderController(
            bridge: targetBridge,
            swordManagerOverride: manager
        )
        let targetWindow = Window()
        let targetPageManager = PageManager(id: targetWindow.id)
        targetWindow.pageManager = targetPageManager
        targetController.activeWindow = targetWindow
        targetController.loadMultiReferenceDocument(
            #"{"id":"existing-multi","type":"multi","osisFragments":[{"bookInitials":"KJV","osisRef":"Gen.1.1"}],"compare":false}"#
        )
        XCTAssertEqual(targetController.currentCategory, .generalBook)
        let targetScriptBaseline = targetScripts().count
        let targetModule = try XCTUnwrap(manager.module(named: "VulgTest"))
        let expectedStart = try XCTUnwrap(
            VersificationMapper.convertStrictly(
                osisBookId: "Ps",
                chapter: 10,
                verse: 1,
                from: JSwordKJVAVersification.name,
                to: "Vulg"
            )?.reference
        )
        let expectedEnd = try XCTUnwrap(
            VersificationMapper.convertStrictly(
                osisBookId: "Ps",
                chapter: 10,
                verse: 2,
                from: JSwordKJVAVersification.name,
                to: "Vulg"
            )?.reference
        )
        let expectedStartOrdinal = try XCTUnwrap(
            targetModule.verseOrdinal(
                osisBookId: expectedStart.osisBookId,
                chapter: expectedStart.chapter,
                verse: expectedStart.verse
            )
        )
        let expectedEndOrdinal = try XCTUnwrap(
            targetModule.verseOrdinal(
                osisBookId: expectedEnd.osisBookId,
                chapter: expectedEnd.chapter,
                verse: expectedEnd.verse
            )
        )
        let expectedBook = try XCTUnwrap(
            targetModule.getBookList().first(where: {
                $0.osisId == expectedStart.osisBookId
            })?.name
        )
        var routedReference: OsisRef?
        var didRoute = false
        sourceController.onOpenInLinksWindow = { reference in
            routedReference = reference
            didRoute = BibleWindowPaneReferenceRouter.navigate(
                reference,
                in: targetController
            )
        }

        sourceController.bridge(
            sourceBridge,
            openExternalLink: "osis://?osis=Ps.10.1-Ps.10.2&v11n=KJVA&doc=VulgTest&force-doc=true"
        )

        let reference = try XCTUnwrap(routedReference)
        XCTAssertTrue(didRoute)
        XCTAssertEqual(reference.sourceVersification, JSwordKJVAVersification.name)
        XCTAssertEqual(reference.targetBookInitials, "VulgTest")
        XCTAssertEqual(reference.sourceOsisRef, "Ps.10.1-Ps.10.2")
        XCTAssertEqual(
            reference.sourceVerses,
            [
                OsisVerseCoordinate(osisBookId: "Ps", chapter: 10, verse: 1),
                OsisVerseCoordinate(osisBookId: "Ps", chapter: 10, verse: 2),
            ]
        )
        XCTAssertEqual(targetController.activeModuleName, "VulgTest")
        XCTAssertEqual(targetController.currentCategory, .bible)
        XCTAssertEqual(targetController.currentBook, expectedBook)
        XCTAssertEqual(targetController.currentChapter, expectedStart.chapter)
        XCTAssertEqual(targetController.currentVerse, expectedStart.verse)
        XCTAssertEqual(targetPageManager.bibleDocument, "VulgTest")
        XCTAssertFalse(sourceScripts().contains { $0.contains(#""type":"multi""#) })

        targetController.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(targetScripts().dropFirst(targetScriptBaseline)),
                event: "add_documents"
            ) as? [String: Any]
        )
        XCTAssertEqual(payload["bookInitials"] as? String, "VulgTest")
        XCTAssertEqual(
            payload["originalOrdinalRange"] as? [Int],
            [expectedStartOrdinal, expectedEndOrdinal]
        )
        XCTAssertFalse(
            expectedStart.chapter == 10 && expectedStart.verse == 1,
            "Fixture must exercise a real KJVA-to-Vulgate coordinate change"
        )
        XCTAssertNotEqual(payload["type"] as? String, "multi")
    }

    /**
     Guards the production `BibleWindowPane` callback against reducing `OsisRef` to coordinates.

     The source slice covers the real `onOpenInLinksWindow` assignment through the adjacent Multi
     callback. All three single-reference branches (current pane, delayed fallback, and registered
     destination pane) must pass the same complete `reference` to the shared router. A return to a
     `(book, chapter)` closure or direct `navigateTo(book:chapter:)` call would discard verses,
     ranges, forced target initials, and source versification before behavior tests reach the router.
     */
    func testBibleWindowPaneProductionCallbackRoutesCompleteOsisReference() throws {
        let source = try BibleUITestSourceLocator.source(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift"
        )
        let callbackStart = try XCTUnwrap(
            source.range(
                of: "ctrl.onOpenInLinksWindow = { [weak ctrl, weak windowManager] reference in"
            )
        )
        let callbackEnd = try XCTUnwrap(
            source.range(
                of: "ctrl.onOpenMultiReferenceDocumentInLinksWindow",
                range: callbackStart.upperBound..<source.endIndex
            )
        )
        let callbackSource = source[callbackStart.lowerBound..<callbackEnd.lowerBound]
        let routeCount = callbackSource
            .components(separatedBy: "BibleWindowPaneReferenceRouter.navigate(reference, in:")
            .count - 1

        XCTAssertEqual(routeCount, 3)
        XCTAssertFalse(callbackSource.contains("navigateTo(book:"))
        XCTAssertTrue(source.contains("controller.navigateToBibleLink(reference)"))
    }

    /**
     Verifies OSIS list separators and range expansion compose through the SWORD parser boundary.

     JSword `PassageKeyFactory` accepts comma-separated passage lists and expands each range against
     the active versification. iOS must preserve both semantics instead of sending the whole comma
     string to SWORD, whose flat parser only reliably expands individual segments here. A failure
     means mixed cross-reference links can silently drop later list entries or range members.
     */
    @MainActor
    func testOsisMixedListAndRangeLinkEmitsEveryParsedVerse() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridge(bridge, openExternalLink: "osis://?osis=Gen.1.1-Gen.1.2,Exod.2.1&v11n=KJVA")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertEqual(fragments.count, 2)
        XCTAssertEqual(fragments[0]["osisRef"] as? String, "Gen.1.1-Gen.1.2")
        XCTAssertTrue((fragments[0]["xml"] as? String)?.contains("osisID=\"Gen.1.1\"") == true)
        XCTAssertTrue((fragments[0]["xml"] as? String)?.contains("osisID=\"Gen.1.2\"") == true)
        XCTAssertEqual(fragments[1]["osisRef"] as? String, "Exod.2.1")
    }

    /**
     Verifies space-delimited OSIS passages become semantic discontiguous ranges, never endpoints.

     Android's `PassageKeyFactory` treats whitespace as a passage-list separator and
     `Passage.countRanges(...)` reports two ranges here. The production bridge must emit two Multi
     fragments, preserving the first contiguous range and the second verse independently. A single
     `Gen.1.1-Exod.2.1` fragment would silently include every intervening canonical verse.
     */
    @MainActor
    func testSpaceDelimitedDiscontiguousOsisListEmitsSeparateMultiFragments() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(
            bridge,
            openExternalLink: "osis://?osis=Gen.1.1-Gen.1.2%20Exod.2.1&v11n=KJVA"
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertEqual(fragments.count, 2)
        XCTAssertEqual(fragments[0]["osisRef"] as? String, "Gen.1.1-Gen.1.2")
        XCTAssertEqual(fragments[1]["osisRef"] as? String, "Exod.2.1")
        XCTAssertFalse(
            fragments.contains { $0["osisRef"] as? String == "Gen.1.1-Exod.2.1" }
        )
    }

    /**
     Protects the single-reference `osis://` path from being widened into MultiDocument behavior.

     Android opens a single OSIS reference as normal reader navigation, while multi-reference links
     become MultiDocument content. Setup drives the bridge with one OSIS reference and a recording
     bridge backed by a temporary Bible module. The expected result is verse-level controller
     navigation to Exodus 2:1 without a multi-document payload or cross-reference sheet. A failure
     means the resolver/link split changed user-visible
     navigation semantics.
     */
    @MainActor
    func testSingleOsisReferenceStillNavigatesWithoutMultiDocument() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridge(bridge, openExternalLink: "osis://?osis=Exod.2.1&v11n=KJVA")

        XCTAssertEqual(controller.currentBook, "Exodus")
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertFalse(recordedScripts().contains { $0.contains(#""type":"multi""#) })
    }

    /**
     Protects Android's boundary between `osis://` navigation and `multi://` MultiDocument links.

     Android's `SCHEME_REFERENCE` handler reads only `getQueryParameter("osis")`; repeated `osis`
     query values are not a MultiDocument signal. Setup sends a deliberately duplicated `osis://`
     link through the native bridge with a temporary Bible module. The expected result is navigation
     to the first exact verse only and no transient multi-document payload. A
     failure means iOS widened single-reference links into invented multi-reference behavior instead
     of requiring Android's `multi://` route.
     */
    @MainActor
    func testOsisReferenceUsesFirstQueryValueLikeAndroidReferenceScheme() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(bridge, openExternalLink: "osis://?osis=Exod.2.1&osis=Gen.1.1&v11n=KJVA")

        XCTAssertEqual(controller.currentBook, "Exodus")
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertFalse(recordedScripts().contains { $0.contains(#""type":"multi""#) })
    }

    /**
     Verifies OSIS and Multi pseudo-links fail closed when no Bible module is active.

     Android `LinkControl.showLink` returns before navigation when `currentBible` or its document is
     absent. A controller created with SWORD initialization disabled models that state. Neither the
     single-reference pane route nor the Multi-document route may fire, and reader coordinates must
     remain unchanged.
     */
    @MainActor
    func testReferenceLinksFailClosedWithoutActiveBibleModule() {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let originalBook = controller.currentBook
        let originalChapter = controller.currentChapter
        let originalVerse = controller.currentVerse
        var routedSingle = false
        var routedMulti = false
        controller.onOpenInLinksWindow = { _ in routedSingle = true }
        controller.onOpenMultiReferenceDocumentInLinksWindow = { _ in routedMulti = true }

        controller.bridge(bridge, openExternalLink: "osis://?osis=Exod.2.1&v11n=KJVA")
        controller.bridge(
            bridge,
            openExternalLink: "multi://?osis=Gen.1.1&osis=Exod.2.1&v11n=KJVA"
        )

        XCTAssertFalse(routedSingle)
        XCTAssertFalse(routedMulti)
        XCTAssertEqual(controller.currentBook, originalBook)
        XCTAssertEqual(controller.currentChapter, originalChapter)
        XCTAssertEqual(controller.currentVerse, originalVerse)
        XCTAssertFalse(recordedScripts().contains { $0.contains("emit('add_documents'") })
    }

    /**
     Protects Android-style external-link classification outside controller orchestration.

     Android splits responsibilities between `BibleJavascriptInterface.openExternalLink`,
     `BibleView.openLink`, and `LinkControl`: pseudo-links become typed app routes while unknown
     web links remain platform URLs. The setup exercises the new pure router with Strong's,
     morphology, MyBible, MySword, multi-reference, EPUB, Downloads, My Notes, and StudyPad inputs.
     The expected result is typed route data with no bridge, SWORD, pasteboard, or simulator side
     effects. A failure means the extraction preserved the controller code shape without preserving
     Android's routing contract.
     */
    func testExternalLinkRouterClassifiesAndroidPseudoSchemes() {
        let router = BibleReaderExternalLinkRouter()

        XCTAssertEqual(
            router.route(for: "ab-w://?strong=H0430&robinson=N-NSM"),
            .multiDefinition(items: [.strong("H0430"), .robinson("N-NSM")])
        )
        XCTAssertEqual(
            router.route(for: "strongs://G2316"),
            .definition(items: [.strong("G2316")])
        )
        XCTAssertEqual(
            router.route(for: "morphology://robinson/V-PAI-3S"),
            .definition(items: [.robinson("V-PAI-3S")])
        )
        XCTAssertEqual(
            router.route(for: "ab-find-all://?type=hebrew&name=5775"),
            .findAllOccurrences("h5775")
        )
        XCTAssertEqual(
            router.route(for: "ab-find-all://?type=greek&name=3056"),
            .findAllOccurrences("g3056")
        )
        XCTAssertEqual(
            router.route(for: "ab-find-all://?type=hebrew-and-greek&name=5775"),
            .findAllOccurrences("h5775")
        )
        XCTAssertEqual(
            router.route(for: "ab-find-all://?type=hebrew-and-greek&name=H05775"),
            .findAllOccurrences("h05775")
        )
        XCTAssertEqual(
            router.route(for: "ab-find-all://?type=hebrew&name=X5775"),
            .findAllOccurrences("hx5775")
        )
        XCTAssertNil(router.route(for: "ab-find-all://?name=5775"))
        XCTAssertEqual(
            router.route(for: "download://?initials=KJV"),
            .downloads(searchText: "KJV")
        )
        XCTAssertEqual(
            router.route(for: "epub-ref://?book=Pilgrim&toKey=chapter1.xhtml&toId=anchor"),
            .epubReference(book: "Pilgrim", toKey: "chapter1.xhtml", toId: "anchor")
        )
        XCTAssertEqual(
            router.route(for: "my-notes://?v11n=Vulg&ordinal=42"),
            .myNotes(v11n: "Vulg", ordinal: 42)
        )
        XCTAssertNil(router.route(for: "my-notes://?ordinal=42"))
        XCTAssertEqual(
            router.route(for: "journal://?id=00000000-0000-0000-0000-000000000001&bookmarkId=00000000-0000-0000-0000-000000000002"),
            .studyPad(
                labelId: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                bookmarkId: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            )
        )
        XCTAssertEqual(
            router.route(for: "osis://?osis=Gen.1.1,Exod.2.1&v11n=Vulg&doc=VulgTest&force-doc=true"),
            .osisReferences(
                values: ["Gen.1.1,Exod.2.1"],
                v11n: "Vulg",
                documentInitials: "VulgTest",
                forceDocument: true
            )
        )
        XCTAssertEqual(
            router.route(for: "multi://?osis=Gen.1.1&osis=Exod.2.1&v11n=KJVA"),
            .multiReferences(values: ["Gen.1.1", "Exod.2.1"], v11n: "KJVA")
        )
        XCTAssertEqual(
            router.route(for: "sword://Bible/John.3.16"),
            .swordReference("John.3.16")
        )
        XCTAssertEqual(
            router.route(for: "B:470 1:1"),
            .osisNavigation("Matt.1.1")
        )
        XCTAssertEqual(
            router.route(for: "#b40.1.1"),
            .osisNavigation("Matt.1.1")
        )
        XCTAssertEqual(
            router.route(for: "S:G2424"),
            .definition(items: [.strong("G2424")])
        )
        XCTAssertEqual(
            router.route(for: "#dH0430"),
            .definition(items: [.strong("H0430")])
        )
        XCTAssertEqual(
            router.route(for: "https://andbible.org"),
            .platformURL(URL(string: "https://andbible.org")!)
        )
    }

    /**
     Protects multi-reference document construction as its own Android `Multi` responsibility.

     Android stores cross-reference results as `FakeBookFactory.multiDocument` backed by a
     `BookAndKeyList`, not as a controller-local sheet. The setup feeds parsed references into the
     builder with KJV and Vulgate source modules. The expected JSON has one exact SWORD fragment per
     reference and preserves each fragment's own module and versification metadata.
     */
    func testMultiReferenceDocumentBuilderCreatesAndroidMultiPayload() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "VulgTest",
            description: "Vulgate mixed-reference fixture",
            versification: "Vulg",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let kjv = try XCTUnwrap(manager.module(named: "KJV"))
        let vulg = try XCTUnwrap(manager.module(named: "VulgTest"))
        let refs = [
            OsisRef(
                book: "Genesis",
                chapter: 1,
                verse: 1,
                osisId: "Gen",
                sourceVersification: "KJV"
            ),
            OsisRef(
                book: "Psalms",
                chapter: 10,
                verse: 1,
                osisId: "Ps",
                sourceVersification: "Vulg",
                targetBookInitials: "VulgTest"
            ),
        ]
        let builder = BibleReaderMultiReferenceDocumentBuilder(
            swordManager: manager,
            activeModule: kjv,
            activeModuleName: "KJV"
        )

        let json = try XCTUnwrap(builder.buildDocumentJSON(refs: refs))
        let data = try XCTUnwrap(json.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])

        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertEqual(payload["compare"] as? Bool, false)
        XCTAssertEqual(fragments.count, 2)
        XCTAssertEqual(fragments[0]["key"] as? String, "KJV--Gen.1.1")
        XCTAssertEqual(fragments[0]["osisRef"] as? String, "Gen.1.1")
        XCTAssertEqual(fragments[0]["bookCategory"] as? String, "BIBLE")
        XCTAssertEqual(fragments[0]["v11n"] as? String, "KJV")
        let kjvOrdinal = try XCTUnwrap(kjv.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))
        XCTAssertEqual(fragments[0]["ordinalRange"] as? [Int], [kjvOrdinal, kjvOrdinal])
        XCTAssertEqual(fragments[1]["key"] as? String, "VulgTest--Ps.10.1")
        XCTAssertEqual(fragments[1]["v11n"] as? String, "Vulg")
        let vulgOrdinal = try XCTUnwrap(vulg.verseOrdinal(osisBookId: "Ps", chapter: 10, verse: 1))
        XCTAssertEqual(fragments[1]["ordinalRange"] as? [Int], [vulgOrdinal, vulgOrdinal])
    }

    /**
     Validates the native-to-WebView reader configuration contract for Android parity fields.

     The setup writes pane text-display settings, app settings, workspace state, and reading
     progress settings before the client-ready handshake. The expected result is a `set_config`
     payload whose `config` object includes every renderer field consumed by bibleview-js; a failure
     means the native settings model can drift from the shared Android renderer contract.
     */
    @MainActor
    func testReaderConfigPayloadIncludesDisplaySettingsAndActiveWindowState() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Reader Config")
        let studyPadCursorId = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let autoAssignLabelId = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let hiddenLabelId = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        workspace.workspaceSettings = WorkspaceSettings(
            autoAssignLabels: [autoAssignLabelId],
            studyPadCursors: [studyPadCursorId: 7],
            hideCompareDocuments: ["KJV", "ESV"]
        )
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        _ = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        windowManager.activeWindow = firstWindow

        settingsStore.setBool(.showActiveWindowIndicator, value: true)
        settingsStore.setBool(.showErrorBox, value: true)
        settingsStore.setBool(.monochromeMode, value: true)
        settingsStore.setBool(.disableAnimations, value: true)
        settingsStore.setBool(.disableClickToEdit, value: true)
        settingsStore.setInt(.fontSizeMultiplier, value: 125)
        settingsStore.setString(.notesContentType, value: "PLAINTEXT")
        settingsStore.setStringSet(.disableBibleBookmarkModalButtons, values: ["speak", "bookmark"])
        settingsStore.setStringSet(.disableGenBookmarkModalButtons, values: ["generic-note"])
        settingsStore.setStringSet(
            .experimentalFeatures,
            values: ["bookmark_edit_actions", "add_paragraph_break"]
        )

        var display = TextDisplaySettings()
        display.showVerseNumbers = false
        display.strongsMode = 2
        display.showMorphology = true
        display.showRedLetters = false
        display.showVersePerLine = true
        display.showSectionTitles = false
        display.showFootNotes = true
        display.showFootNotesInline = true
        display.showXrefs = true
        display.expandXrefs = true
        display.fontFamily = "Georgia"
        display.fontSize = 21
        display.showBookmarks = false
        display.showMyNotes = false
        display.hyphenation = false
        display.lineSpacing = 14
        display.justifyText = true
        display.marginLeft = 5
        display.marginRight = 6
        display.maxWidth = 410
        display.topMargin = 12
        display.showPageNumber = true
        display.infiniteScroll = false
        display.nonStrongsWordItalic = true
        display.showMarkAsReadButton = false
        display.showTitleScrollButton = true
        display.showMemorizationIndicators = true
        display.showAiDocMarkers = false
        display.pageScrollAmount = 66
        display.showOrdinals = true
        display.bookmarksHideLabels = [hiddenLabelId]
        display.dayBackground = -2
        display.dayNoise = 3
        display.nightBackground = -123_456
        display.nightNoise = 4
        display.dayTextColor = -654_321
        display.nightTextColor = -111_111

        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = settingsStore
        try controller.readingProgressStore?.saveSettings(
            ReadingProgressSettingsSnapshot(
                autoTrackReading: true,
                autoMarkMemorized: false,
                memorizeTypeFullWords: true,
                memorizeWordVisibility: "dim",
                memorizeErrorHeatmap: false,
                memorizeScrambleHideUsed: true,
                memorizeIncludeReference: false
            )
        )
        controller.displaySettings = display
        controller.nightMode = true
        controller.activeWindow = firstWindow
        controller.windowManagerRef = windowManager

        controller.bridgeDidSetClientReady(bridge)

        let payload = try setConfigPayload(from: recordedScripts())
        assertJSONKeys(payload, ["config", "appSettings", "initial"])
        let config = try XCTUnwrap(payload["config"] as? [String: Any])
        let appSettings = try XCTUnwrap(payload["appSettings"] as? [String: Any])
        assertJSONKeys(
            config,
            [
                "developmentMode",
                "testMode",
                "showAnnotations",
                "showChapterNumbers",
                "showVerseNumbers",
                "strongsMode",
                "showMorphology",
                "showRedLetters",
                "showVersePerLine",
                "showNonCanonical",
                "makeNonCanonicalItalic",
                "showSectionTitles",
                "showStrongsSeparately",
                "showFootNotes",
                "showFootNotesInline",
                "showXrefs",
                "expandXrefs",
                "fontFamily",
                "fontSize",
                "disableBookmarking",
                "showBookmarks",
                "showMyNotes",
                "bookmarksHideLabels",
                "bookmarksAssignLabels",
                "colors",
                "hyphenation",
                "lineSpacing",
                "justifyText",
                "marginSize",
                "topMargin",
                "showPageNumber",
                "infiniteScroll",
                "nonStrongsWordItalic",
                "showMarkAsReadButton",
                "showTitleScrollButton",
                "showMemorizationIndicators",
                "showAiDocMarkers",
                "pageScrollAmount",
                "showOrdinals",
            ]
        )
        assertJSONKeys(
            appSettings,
            [
                "nightMode",
                "errorBox",
                "favouriteLabels",
                "recentLabels",
                "studyPadCursors",
                "autoAssignLabels",
                "hideCompareDocuments",
                "activeWindow",
                "rightToLeft",
                "actionMode",
                "hasActiveIndicator",
                "activeSince",
                "limitAmbiguousModalSize",
                "windowId",
                "disableBibleModalButtons",
                "disableGenericModalButtons",
                "monochromeMode",
                "disableAnimations",
                "disableClickToEdit",
                "notesContentType",
                "fontSizeMultiplier",
                "enabledExperimentalFeatures",
                "autoTrackReading",
                "readingProgressSettings",
                "llmConfigured",
                "llmActionLabel",
            ]
        )
        let colors = try XCTUnwrap(config["colors"] as? [String: Any])
        assertJSONKeys(
            colors,
            ["dayBackground", "dayNoise", "nightBackground", "nightNoise", "dayTextColor", "nightTextColor"]
        )
        let marginSize = try XCTUnwrap(config["marginSize"] as? [String: Any])
        assertJSONKeys(marginSize, ["marginLeft", "marginRight", "maxWidth"])

        XCTAssertEqual(payload["initial"] as? Bool, false)
        XCTAssertEqual(config["showVerseNumbers"] as? Bool, false)
        XCTAssertEqual(config["strongsMode"] as? Int, 2)
        XCTAssertEqual(config["showMorphology"] as? Bool, true)
        XCTAssertEqual(config["showRedLetters"] as? Bool, false)
        XCTAssertEqual(config["showVersePerLine"] as? Bool, true)
        XCTAssertEqual(config["showSectionTitles"] as? Bool, false)
        XCTAssertEqual(config["showFootNotes"] as? Bool, true)
        XCTAssertEqual(config["showFootNotesInline"] as? Bool, true)
        XCTAssertEqual(config["showXrefs"] as? Bool, true)
        XCTAssertEqual(config["expandXrefs"] as? Bool, true)
        XCTAssertEqual(config["fontFamily"] as? String, "Georgia")
        XCTAssertEqual(config["fontSize"] as? Int, 21)
        XCTAssertEqual(config["showBookmarks"] as? Bool, false)
        XCTAssertEqual(config["showMyNotes"] as? Bool, false)
        XCTAssertEqual(
            try XCTUnwrap(config["bookmarksHideLabels"] as? [String]),
            [hiddenLabelId.uuidString]
        )
        XCTAssertEqual(config["hyphenation"] as? Bool, false)
        XCTAssertEqual(config["lineSpacing"] as? Int, 14)
        XCTAssertEqual(config["justifyText"] as? Bool, true)
        XCTAssertEqual(config["topMargin"] as? Int, 12)
        XCTAssertEqual(config["showPageNumber"] as? Bool, true)
        XCTAssertEqual(config["infiniteScroll"] as? Bool, false)
        XCTAssertEqual(config["nonStrongsWordItalic"] as? Bool, true)
        XCTAssertEqual(config["showMarkAsReadButton"] as? Bool, false)
        XCTAssertEqual(config["showTitleScrollButton"] as? Bool, true)
        XCTAssertEqual(config["showMemorizationIndicators"] as? Bool, true)
        XCTAssertEqual(config["showAiDocMarkers"] as? Bool, false)
        XCTAssertEqual(config["pageScrollAmount"] as? Int, 66)
        XCTAssertEqual(config["showOrdinals"] as? Bool, true)
        XCTAssertEqual(colors["dayBackground"] as? Int, -2)
        XCTAssertEqual(colors["dayNoise"] as? Int, 3)
        XCTAssertEqual(colors["nightBackground"] as? Int, -123_456)
        XCTAssertEqual(colors["nightNoise"] as? Int, 4)
        XCTAssertEqual(colors["dayTextColor"] as? Int, -654_321)
        XCTAssertEqual(colors["nightTextColor"] as? Int, -111_111)
        XCTAssertEqual(marginSize["marginLeft"] as? Int, 5)
        XCTAssertEqual(marginSize["marginRight"] as? Int, 6)
        XCTAssertEqual(marginSize["maxWidth"] as? Int, 410)

        XCTAssertEqual(appSettings["nightMode"] as? Bool, true)
        XCTAssertEqual(appSettings["errorBox"] as? Bool, true)
        XCTAssertEqual(appSettings["activeWindow"] as? Bool, true)
        XCTAssertEqual(appSettings["hasActiveIndicator"] as? Bool, true)
        XCTAssertEqual(appSettings["rightToLeft"] as? Bool, false)
        XCTAssertEqual(appSettings["actionMode"] as? Bool, false)
        XCTAssertEqual(appSettings["limitAmbiguousModalSize"] as? Bool, false)
        XCTAssertEqual(appSettings["windowId"] as? String, "")
        XCTAssertEqual(appSettings["monochromeMode"] as? Bool, true)
        XCTAssertEqual(appSettings["disableAnimations"] as? Bool, true)
        XCTAssertEqual(appSettings["disableClickToEdit"] as? Bool, true)
        XCTAssertEqual(appSettings["notesContentType"] as? String, "HTML")
        XCTAssertEqual(appSettings["fontSizeMultiplier"] as? Double, 1.25)
        XCTAssertEqual(appSettings["autoTrackReading"] as? Bool, true)
        XCTAssertNotNil(appSettings["activeSince"] as? Int)
        let readingProgressSettings = try XCTUnwrap(appSettings["readingProgressSettings"] as? [String: Any])
        assertJSONKeys(
            readingProgressSettings,
            [
                "autoMarkMemorized",
                "memorizeTypeFullWords",
                "memorizeWordVisibility",
                "memorizeErrorHeatmap",
                "memorizeScrambleHideUsed",
                "memorizeIncludeReference",
            ]
        )
        XCTAssertEqual(readingProgressSettings["autoMarkMemorized"] as? Bool, false)
        XCTAssertEqual(readingProgressSettings["memorizeTypeFullWords"] as? Bool, true)
        XCTAssertEqual(readingProgressSettings["memorizeWordVisibility"] as? String, "dim")
        XCTAssertEqual(readingProgressSettings["memorizeErrorHeatmap"] as? Bool, false)
        XCTAssertEqual(readingProgressSettings["memorizeScrambleHideUsed"] as? Bool, true)
        XCTAssertEqual(readingProgressSettings["memorizeIncludeReference"] as? Bool, false)
        XCTAssertEqual(
            appSettings["studyPadCursors"] as? [String: Int],
            [studyPadCursorId.uuidString: 7]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(appSettings["autoAssignLabels"] as? [String])),
            [autoAssignLabelId.uuidString]
        )
        XCTAssertEqual(Set(try XCTUnwrap(appSettings["hideCompareDocuments"] as? [String])), ["ESV", "KJV"])
        XCTAssertEqual(
            Set(try XCTUnwrap(appSettings["disableBibleModalButtons"] as? [String])),
            ["bookmark", "speak"]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(appSettings["disableGenericModalButtons"] as? [String])),
            ["generic-note"]
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(appSettings["enabledExperimentalFeatures"] as? [String])),
            ["add_paragraph_break", "bookmark_edit_actions"]
        )
    }

    /**
     Protects the reader bridge's last-resort margin fallback from iOS-only layout drift.

     Android's `WorkspaceEntities.kt` initializes text-display margins to left `3`, right `3`,
     and max width `170`. The bridge normally receives resolved app defaults, but restored or
     migrated data can temporarily leave both the pane settings and defaults empty; this test
     verifies that even that edge case encodes Android's baseline instead of the older iOS
     fallback (`2`, `2`, `600`). A failure means dictionary and reader panes can render with
     platform-specific margins before persisted settings are available.
     */
    func testReaderConfigMarginFallbackMatchesAndroidDefaultsWhenSettingsAreEmpty() throws {
        let config = BibleReaderDisplayConfig(settings: TextDisplaySettings(), defaults: TextDisplaySettings())
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let marginSize = try XCTUnwrap(object["marginSize"] as? [String: Any])

        XCTAssertEqual(marginSize["marginLeft"] as? Int, 3)
        XCTAssertEqual(marginSize["marginRight"] as? Int, 3)
        XCTAssertEqual(marginSize["maxWidth"] as? Int, 170)
    }

    /**
     Protects the WebView paging contract from invalid synced or migrated `PAGE_SCROLL_AMOUNT` data.

     Android's `PageScrollAmountPreference` only accepts six discrete percentages and falls back to
     `100%` for unknown stored values. This test drives the native client-ready path and verifies the
     emitted Vue `set_config` payload receives that normalized value, not the raw invalid setting.
     */
    @MainActor
    func testReaderConfigPayloadNormalizesInvalidPageScrollAmount() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        var display = TextDisplaySettings()
        display.pageScrollAmount = 150

        let controller = BibleReaderController(bridge: bridge)
        controller.displaySettings = display

        controller.bridgeDidSetClientReady(bridge)

        let payload = try setConfigPayload(from: recordedScripts())
        let config = try XCTUnwrap(payload["config"] as? [String: Any])
        XCTAssertEqual(config["pageScrollAmount"] as? Int, 100)
    }

    /**
     Protects restored Strong's mode from splitting native toolbar state and Vue render state.

     Android restores `strongsMode=1` as dotted Strong's links: JSword still emits lexical OSIS
     markup and the shared Vue renderer receives mode `1` before the Bible document is added. This
     setup mirrors an iOS process restart with a window-scoped Strong's setting and a Strong's-capable
     KJV module, then drives the client-ready replay path. The expected result is a `set_config`
     payload with `strongsMode=1` followed by emitted OSIS containing Strong's lemma attributes.
     A failure means the visible toolbar/menu state can say Links while the WebView renders hidden
     Strong's links or strips lexical data.
     */
    @MainActor
    func testClientReadyReplayRestoresStrongsLinksModeAndLexicalMarkup() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        var displaySettings = TextDisplaySettings.appDefaults
        displaySettings.strongsMode = StrongsMode.links.rawValue

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.displaySettings = displaySettings

        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 1
        pageManager.textDisplaySettings = displaySettings
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.restoreSavedPosition()

        controller.bridgeDidSetClientReady(bridge)

        let configPayload = try setConfigPayload(from: recordedScripts())
        let config = try XCTUnwrap(configPayload["config"] as? [String: Any])
        XCTAssertEqual(config["strongsMode"] as? Int, StrongsMode.links.rawValue)

        let documentPayload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        let fragment = try XCTUnwrap(documentPayload["osisFragment"] as? [String: Any])
        let xml = try XCTUnwrap(fragment["xml"] as? String)
        XCTAssertTrue(
            xml.contains(#"lemma="strong:H0430""#),
            "Expected client-ready replay to retain Strong's lemma markup. XML: \(xml)"
        )
    }

    @MainActor
    func testToggleCompareDocumentPersistsWorkspaceHiddenStateAndReemitsConfig() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let workspace = workspaceStore.createWorkspace(name: "Compare State")
        workspace.workspaceSettings = WorkspaceSettings(hideCompareDocuments: ["ESV"])
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let controller = BibleReaderController(bridge: bridge)
        controller.activeWindow = window

        var persistCount = 0
        controller.onPersistState = {
            persistCount += 1
            try? context.save()
        }

        controller.bridgeDidSetClientReady(bridge)
        let initialPayload = try setConfigPayload(from: recordedScripts())
        let initialAppSettings = try XCTUnwrap(initialPayload["appSettings"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(initialAppSettings["hideCompareDocuments"] as? [String])), ["ESV"])

        let initialScriptCount = recordedScripts().count
        XCTAssertEqual(bridge.dispatchMessage(method: "toggleCompareDocument", args: ["KJV"]), .handled)

        XCTAssertEqual(workspace.workspaceSettings?.hideCompareDocuments, ["ESV", "KJV"])
        XCTAssertEqual(persistCount, 1)
        let togglePayload = try setConfigPayload(from: Array(recordedScripts().dropFirst(initialScriptCount)))
        let toggleAppSettings = try XCTUnwrap(togglePayload["appSettings"] as? [String: Any])
        XCTAssertEqual(Set(try XCTUnwrap(toggleAppSettings["hideCompareDocuments"] as? [String])), ["ESV", "KJV"])
    }

    @MainActor
    func testReaderConfigPayloadMarksInactiveWindowWithoutActiveIndicator() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let settingsStore = SettingsStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Reader Config")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        windowManager.activeWindow = firstWindow
        settingsStore.setBool(.showActiveWindowIndicator, value: true)

        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = settingsStore
        controller.activeWindow = secondWindow
        controller.windowManagerRef = windowManager

        controller.bridgeDidSetClientReady(bridge)

        let payload = try setConfigPayload(from: recordedScripts())
        let appSettings = try XCTUnwrap(payload["appSettings"] as? [String: Any])
        XCTAssertEqual(appSettings["activeWindow"] as? Bool, false)
        XCTAssertEqual(appSettings["hasActiveIndicator"] as? Bool, false)
    }

    /**
     Protects the extracted reader configuration coordinator's ownership of active-window projection.

     The setup mirrors Android's `windowControl.activeWindow.id == window.id` rule with two visible
     windows and active-indicator preference enabled. The focused contract is that the coordinator
     computes both `activeWindow` and `hasActiveIndicator` together so the controller does not keep
     duplicate window-state math beside the config payload builder. A failure means #146 regressed by
     moving state projection mechanically without preserving Android's active-pane semantics.
     */
    @MainActor
    func testReaderConfigurationCoordinatorComputesActiveWindowProjection() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Config Coordinator")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let secondWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        windowManager.activeWindow = firstWindow

        let coordinator = BibleReaderConfigurationCoordinator()

        let activeProjection = coordinator.activeWindowState(
            activeWindow: firstWindow,
            windowManager: windowManager,
            activeIndicatorEnabled: true
        )
        let inactiveProjection = coordinator.activeWindowState(
            activeWindow: secondWindow,
            windowManager: windowManager,
            activeIndicatorEnabled: true
        )

        XCTAssertEqual(activeProjection.isActive, true)
        XCTAssertEqual(activeProjection.hasActiveIndicator, true)
        XCTAssertEqual(activeProjection.eventJSON, #"{"hasActiveIndicator":true,"isActive":true}"#)
        XCTAssertEqual(inactiveProjection.isActive, false)
        XCTAssertEqual(inactiveProjection.hasActiveIndicator, false)
        XCTAssertEqual(inactiveProjection.eventJSON, #"{"hasActiveIndicator":false,"isActive":false}"#)
    }

    /**
     Protects workspace-backed compare visibility as coordinator-owned reader configuration state.

     Android stores compare-document visibility with workspace settings instead of treating it as
     transient pane state. This test creates a persisted workspace, toggles one module through the
     coordinator, and verifies the updated set is written to `WorkspaceSettings`, mirrored to the
     coordinator fallback, and persisted exactly once. A failure means the extraction preserved file
     shape but left #146's reader/window/workspace state ownership split across the controller.
     */
    @MainActor
    func testReaderConfigurationCoordinatorPersistsHiddenCompareDocumentsToWorkspace() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let workspace = workspaceStore.createWorkspace(name: "Compare Coordinator")
        workspace.workspaceSettings = WorkspaceSettings(hideCompareDocuments: ["ESV"])
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        var coordinator = BibleReaderConfigurationCoordinator()
        var persistCount = 0

        coordinator.toggleHiddenCompareDocument("KJV", activeWindow: window) {
            persistCount += 1
        }

        XCTAssertEqual(workspace.workspaceSettings?.hideCompareDocuments, ["ESV", "KJV"])
        XCTAssertEqual(coordinator.hiddenCompareDocuments(activeWindow: window), ["ESV", "KJV"])
        XCTAssertEqual(persistCount, 1)

        coordinator.toggleHiddenCompareDocument("ESV", activeWindow: nil) {
            persistCount += 1
        }

        XCTAssertEqual(coordinator.hiddenCompareDocuments(activeWindow: nil), ["KJV"])
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects recent bookmark-label state as a coordinator-owned reader configuration input.

     Android exposes recently used bookmark labels through reader configuration without making the
     top-level reader controller own the de-duplication, ordering, and persisted setting value. The
     setup starts from the legacy comma-separated setting, reuses one older label, then adds enough
     labels to exceed the five-label cap. The expected result is most-recent-first ordering, no
     duplicate reused label, cap enforcement, and one persisted comma-separated value per tracked
     label. A failure means #146 regressed by leaving state semantics in the controller or changing
     the config payload behavior that Vue receives.
     */
    func testReaderRecentLabelCoordinatorLoadsDeduplicatesCapsAndPersistsRecentLabels() {
        var coordinator = BibleReaderRecentLabelCoordinator()
        var persistedValues: [String] = []

        coordinator.load(storedValue: "oldA,oldB")
        XCTAssertEqual(coordinator.labelIds, ["oldA", "oldB"])

        for labelId in ["oldC", "oldA", "oldD", "oldE", "oldF", "oldG"] {
            coordinator.track(labelId) { persistedValues.append($0) }
        }

        XCTAssertEqual(coordinator.labelIds, ["oldG", "oldF", "oldE", "oldD", "oldA"])
        XCTAssertEqual(
            persistedValues,
            [
                "oldC,oldA,oldB",
                "oldA,oldC,oldB",
                "oldD,oldA,oldC,oldB",
                "oldE,oldD,oldA,oldC,oldB",
                "oldF,oldE,oldD,oldA,oldC",
                "oldG,oldF,oldE,oldD,oldA"
            ]
        )
    }

    /**
     Protects pending/active transient `MultiDocument` state as a coordinator-owned reader concern.

     Android links-window `Multi` documents can be requested before the WebView client is ready, so
     iOS must remember the same transient document as both the active special document and the
     pending client-ready replay. The test then consumes that pending replay once and verifies that a
     later client-ready request remains active without leaving stale pending replay state. A failure
     means the controller has regained hidden transient state ownership or the Android `Multi`
     restore/replay contract can duplicate or lose special documents.
     */
    func testReaderTransientDocumentCoordinatorStoresActiveAndPendingReplayState() {
        var coordinator = BibleReaderTransientDocumentCoordinator()
        let pendingRequest = BibleReaderTransientDocumentRequest(
            documentJSON: #"{"id":"pending"}"#,
            renderedBook: "Multi",
            renderedKey: "multi",
            renderedCategory: .generalBook,
            renderedModuleName: "Multi",
            pageCategory: .generalBook,
            pageDocumentInitials: "Multi",
            pageKey: "KJV:Gen.1.1"
        )
        let readyRequest = BibleReaderTransientDocumentRequest(
            documentJSON: #"{"id":"ready"}"#,
            renderedBook: "Compare",
            renderedKey: "compare",
            renderedCategory: .bible,
            renderedModuleName: nil,
            pageCategory: nil,
            pageDocumentInitials: nil,
            pageKey: nil
        )

        coordinator.store(pendingRequest, clientReady: false)

        XCTAssertEqual(coordinator.activeRequest(isShowingAndroidMultiDocument: true)?.documentJSON, pendingRequest.documentJSON)
        XCTAssertNil(coordinator.activeRequest(isShowingAndroidMultiDocument: false))
        XCTAssertEqual(coordinator.consumePendingClientReadyRequest()?.documentJSON, pendingRequest.documentJSON)
        XCTAssertNil(coordinator.consumePendingClientReadyRequest())

        coordinator.store(readyRequest, clientReady: true)

        XCTAssertEqual(coordinator.activeRequest(isShowingAndroidMultiDocument: true)?.documentJSON, readyRequest.documentJSON)
        XCTAssertNil(coordinator.consumePendingClientReadyRequest())
    }

    /**
     Protects the extracted special-document coordinator's Android fake-document identity rule.

     Android renders links-window results as Vue `MultiDocument` content while native page state is
     persisted as `general_book/Multi` plus a `BookAndKeyList` key. The setup sends both a valid
     durable `Multi` request and a malformed request without a durable key. The expected result is
     that valid requests produce a PageManager persistence plan, while malformed requests still move
     the visible category to general book without erasing the previous restorable key. A failure
     means the controller could regress into either iOS-only transient state or data-lossy restore
     semantics.
     */
    func testReaderSpecialDocumentCoordinatorBuildsAndroidMultiPageIdentityPlan() {
        let coordinator = BibleReaderSpecialDocumentCoordinator()
        let validRequest = BibleReaderTransientDocumentRequest(
            documentJSON: #"{"id":"valid"}"#,
            renderedBook: "Multi",
            renderedKey: "multi",
            renderedCategory: .generalBook,
            renderedModuleName: "Multi",
            pageCategory: .generalBook,
            pageDocumentInitials: "Multi",
            pageKey: "KJV:Gen.1.1"
        )
        let malformedRequest = BibleReaderTransientDocumentRequest(
            documentJSON: #"{"id":"bad"}"#,
            renderedBook: "Multi",
            renderedKey: "multi",
            renderedCategory: .generalBook,
            renderedModuleName: "Multi",
            pageCategory: .generalBook,
            pageDocumentInitials: "Multi",
            pageKey: nil
        )
        let missingInitialsRequest = BibleReaderTransientDocumentRequest(
            documentJSON: #"{"id":"missing-initials"}"#,
            renderedBook: "Multi",
            renderedKey: "multi",
            renderedCategory: .generalBook,
            renderedModuleName: "Multi",
            pageCategory: .generalBook,
            pageDocumentInitials: nil,
            pageKey: "KJV:Gen.1.1"
        )

        let validUpdate = coordinator.pageIdentityUpdate(for: validRequest)
        XCTAssertEqual(validUpdate.currentCategory, .generalBook)
        XCTAssertTrue(validUpdate.clearsActiveGeneralBookModule)
        XCTAssertTrue(validUpdate.assignsActiveGeneralBookModuleName)
        XCTAssertEqual(validUpdate.activeGeneralBookModuleName, "Multi")
        XCTAssertEqual(validUpdate.currentGeneralBookKey, "KJV:Gen.1.1")
        XCTAssertEqual(validUpdate.pageManagerCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(validUpdate.pageManagerGeneralBookDocument, "Multi")
        XCTAssertEqual(validUpdate.pageManagerGeneralBookKey, "KJV:Gen.1.1")
        XCTAssertTrue(validUpdate.persistsPageManagerState)

        let malformedUpdate = coordinator.pageIdentityUpdate(for: malformedRequest)
        XCTAssertEqual(malformedUpdate.currentCategory, .generalBook)
        XCTAssertTrue(malformedUpdate.clearsActiveGeneralBookModule)
        XCTAssertTrue(malformedUpdate.assignsActiveGeneralBookModuleName)
        XCTAssertEqual(malformedUpdate.activeGeneralBookModuleName, "Multi")
        XCTAssertNil(malformedUpdate.currentGeneralBookKey)
        XCTAssertFalse(malformedUpdate.persistsPageManagerState)

        let missingInitialsUpdate = coordinator.pageIdentityUpdate(for: missingInitialsRequest)
        XCTAssertEqual(missingInitialsUpdate.currentCategory, .generalBook)
        XCTAssertTrue(missingInitialsUpdate.clearsActiveGeneralBookModule)
        XCTAssertTrue(missingInitialsUpdate.assignsActiveGeneralBookModuleName)
        XCTAssertNil(missingInitialsUpdate.activeGeneralBookModuleName)
        XCTAssertNil(missingInitialsUpdate.currentGeneralBookKey)
        XCTAssertFalse(missingInitialsUpdate.persistsPageManagerState)
    }

    /**
     Protects My Documents active-page identity as a coordinator-owned reader state rule.

     Android treats My Documents as generated general-book modules, so iOS must keep the active
     local page only while the rendered content still points at the same general-book document. The
     setup records one active page, exercises an unrelated module/category render, and expects the
     coordinator to preserve or clear the page key exactly where the controller previously did. A
     failure means #146 moved state ownership without preserving the reload/delete guard that keeps
     My Documents bridge actions scoped to the visible local document.
     */
    func testReaderMyDocumentCoordinatorTracksActivePageUntilDifferentRenderedContent() {
        var coordinator = BibleReaderMyDocumentCoordinator()

        coordinator.setActivePage(bookInitials: "MYDOC", pageKey: "intro")

        XCTAssertEqual(coordinator.activePageKey(for: "MYDOC"), "intro")
        XCTAssertNil(coordinator.activePageKey(for: "OTHER"))

        coordinator.clearActivePageUnless(category: .generalBook, moduleName: "MYDOC")
        XCTAssertEqual(coordinator.activePageKey(for: "MYDOC"), "intro")

        coordinator.clearActivePageUnless(category: .commentary, moduleName: "MYDOC")
        XCTAssertNil(coordinator.activePageKey(for: "MYDOC"))

        coordinator.setActivePage(bookInitials: "MYDOC", pageKey: "intro")
        coordinator.clearActivePageUnless(category: .generalBook, moduleName: "OTHER")

        XCTAssertNil(coordinator.activePageKey(for: "MYDOC"))
    }

    /**
     Protects the Android-compatible My Documents document payload outside the reader controller.

     Android exposes My Documents through the general-book document pipeline while retaining raw
     editable content behind bridge calls. The setup builds a Markdown page containing XML-sensitive
     characters and expects the coordinator to emit a valid Vue `OsisDocument` JSON payload with the
     same category, identity, AI metadata, and escaped markup fields used by the current reader. A
     failure means the extraction changed the WebView payload contract rather than simply moving it
     out of `BibleReaderController`.
     */
    func testReaderMyDocumentCoordinatorBuildsAndroidGeneralBookDocumentPayload() throws {
        let coordinator = BibleReaderMyDocumentCoordinator()
        let pageId = try XCTUnwrap(UUID(uuidString: "77777777-7777-7777-7777-777777777777"))
        let sourcePromptId = try XCTUnwrap(UUID(uuidString: "88888888-8888-8888-8888-888888888888"))
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let page = MyDocumentPage(
            id: pageId,
            title: "Intro",
            pageKey: "intro",
            contentType: .markdown,
            sourcePromptId: sourcePromptId,
            languageCode: "en"
        )
        let content = MyDocumentPageContent(pageId: pageId, content: "Raw \\<markdown\\> & \"quoted\"")
        page.pageContent = content
        page.document = document

        let json = try XCTUnwrap(
            coordinator.documentJSON(
                document: document,
                page: page,
                bookLocale: Locale(identifier: "en")
            )
        )
        let renderedDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let osisFragment = try XCTUnwrap(renderedDocument["osisFragment"] as? [String: Any])

        XCTAssertEqual(renderedDocument["type"] as? String, "osis")
        XCTAssertEqual(renderedDocument["bookInitials"] as? String, "MYDOC")
        XCTAssertEqual(renderedDocument["bookCategory"] as? String, DocumentCategory.generalBook.rawValue)
        XCTAssertEqual(renderedDocument["bookName"] as? String, "My Document")
        XCTAssertEqual(renderedDocument["key"] as? String, "intro")
        XCTAssertEqual(renderedDocument["isMyDocument"] as? Bool, true)
        XCTAssertEqual(renderedDocument["isAiDocument"] as? Bool, false)
        XCTAssertEqual(renderedDocument["myDocumentPageId"] as? String, pageId.uuidString)
        XCTAssertEqual(renderedDocument["sourcePromptId"] as? String, sourcePromptId.uuidString)
        XCTAssertEqual(osisFragment["bookCategory"] as? String, DocumentCategory.generalBook.rawValue)
        XCTAssertEqual(osisFragment["bookInitials"] as? String, "MYDOC")
        XCTAssertEqual(osisFragment["keyName"] as? String, "Intro")
        XCTAssertEqual(osisFragment["language"] as? String, "en")
        let xml = try XCTUnwrap(osisFragment["xml"] as? String)
        XCTAssertTrue(xml.contains("<div class=\"mydoc-markdown\"><p><BVA"))
        XCTAssertTrue(xml.contains(">Raw &lt;markdown&gt; &amp; \"quoted\"</BVA>"), xml)
    }

    /**
     Protects infinite-scroll loaded-range state as a coordinator-owned reader concern.

     Android advances the loaded Bible range only after an adjacent chapter document is available.
     The setup asks for a previous chapter, deliberately does not commit it, and then asks again to
     prove failed document loading cannot advance the lower bound. It then commits the candidate and
     verifies the next request crosses into the previous book. A failure means the controller has
     regained mutate-and-revert loaded-range state that can drift after failed prepend loads.
     */
    func testReaderInfiniteScrollCoordinatorKeepsPreviousCandidateUncommittedUntilLoadSucceeds() {
        var coordinator = BibleReaderInfiniteScrollCoordinator()
        coordinator.reset(book: "Exodus", chapter: 2)

        let firstCandidate = coordinator.previousCandidate(
            previousBook: { $0 == "Exodus" ? "Genesis" : nil },
            chapterCount: { $0 == "Genesis" ? 50 : 40 }
        )
        XCTAssertEqual(firstCandidate, BibleReaderInfiniteScrollChapter(book: "Exodus", chapter: 1))

        XCTAssertEqual(
            coordinator.previousCandidate(
                previousBook: { $0 == "Exodus" ? "Genesis" : nil },
                chapterCount: { $0 == "Genesis" ? 50 : 40 }
            ),
            BibleReaderInfiniteScrollChapter(book: "Exodus", chapter: 1)
        )

        if let firstCandidate {
            coordinator.commitPrevious(firstCandidate)
        }

        XCTAssertEqual(
            coordinator.previousCandidate(
                previousBook: { $0 == "Exodus" ? "Genesis" : nil },
                chapterCount: { $0 == "Genesis" ? 50 : 40 }
            ),
            BibleReaderInfiniteScrollChapter(book: "Genesis", chapter: 50)
        )
    }

    /**
     Protects the controller's pre-render infinite-scroll sentinel behavior during extraction.

     The legacy controller kept its loaded range at Genesis chapter 0 until the first reader render.
     Vue can still request append/prepend during that window: prepend has no valid chapter, while
     append resolves to Genesis 1. A failure here means the extracted coordinator changed startup
     bridge behavior instead of only moving the range ownership out of `BibleReaderController`.
     */
    func testReaderInfiniteScrollCoordinatorPreservesPreRenderAppendSentinel() {
        let coordinator = BibleReaderInfiniteScrollCoordinator()

        XCTAssertNil(
            coordinator.previousCandidate(
                previousBook: { $0 == "Genesis" ? nil : "Genesis" },
                chapterCount: { book in
                    XCTFail("Genesis sentinel prepend should not query chapter count, got \(book)")
                    return 0
                }
            )
        )

        XCTAssertEqual(
            coordinator.nextCandidate(
                nextBook: { book in
                    XCTFail("Genesis sentinel append should not query a next book, got \(book)")
                    return nil
                },
                chapterCount: { $0 == "Genesis" ? 50 : 0 }
            ),
            BibleReaderInfiniteScrollChapter(book: "Genesis", chapter: 1)
        )
    }

    /**
     Protects infinite-scroll append range state as a coordinator-owned reader concern.

     Android appends within the current book until the active versification reaches the final
     chapter, then crosses to the next book. The setup starts at the final Genesis chapter, verifies
     that the next candidate is Exodus 1, commits it, and then verifies normal same-book append
     resumes at Exodus 2. A failure means the extraction changed cross-book append behavior instead
     of only moving loaded-range ownership out of `BibleReaderController`.
     */
    func testReaderInfiniteScrollCoordinatorCrossesToNextBookAfterFinalChapter() {
        var coordinator = BibleReaderInfiniteScrollCoordinator()
        coordinator.reset(book: "Genesis", chapter: 50)

        let nextBookCandidate = coordinator.nextCandidate(
            nextBook: { $0 == "Genesis" ? "Exodus" : nil },
            chapterCount: { $0 == "Genesis" ? 50 : 40 }
        )
        XCTAssertEqual(nextBookCandidate, BibleReaderInfiniteScrollChapter(book: "Exodus", chapter: 1))

        if let nextBookCandidate {
            coordinator.commitNext(nextBookCandidate)
        }

        XCTAssertEqual(
            coordinator.nextCandidate(
                nextBook: { $0 == "Genesis" ? "Exodus" : nil },
                chapterCount: { $0 == "Genesis" ? 50 : 40 }
            ),
            BibleReaderInfiniteScrollChapter(book: "Exodus", chapter: 2)
        )
    }

    @MainActor
    func testRequestMoreToBeginningSendsDocumentResponseWithOriginalCallId() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.navigateTo(book: "Genesis", chapter: 2, verse: 1)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let baselineCount = recordedScripts().count
        controller.bridge(bridge, requestMoreToBeginning: 3701)

        let responseScript = try XCTUnwrap(
            recordedScripts().dropFirst(baselineCount).first {
                $0.contains("bibleView.response(3701")
            }
        )

        XCTAssertTrue(
            responseScript.hasPrefix("bibleView.response(3701, {"),
            "Expected a document JSON response for the original callId. Script: \(responseScript)"
        )
        XCTAssertTrue(
            responseScript.contains(#""key":"Gen.1""#),
            "Expected the previous chapter document to be returned. Script: \(responseScript)"
        )
        XCTAssertTrue(
            responseScript.contains(#""osisFragment""#),
            "Expected the response payload to preserve the Bible document shape. Script: \(responseScript)"
        )
    }

    /**
     Protects append infinite-scroll bridge responses after the reader content is rendered.

     The setup loads Genesis 1 through the real controller path, records the existing bridge output,
     then requests more content at the end and verifies the original call id receives a full Genesis 2
     document payload. A failure means the coordinator extraction broke the controller delegate path,
     stale call id handling, or the Android-compatible document shape used by Vue infinite scroll.
     */
    @MainActor
    func testRequestMoreToEndSendsDocumentResponseWithOriginalCallId() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.loadCurrentContent()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        let baselineCount = recordedScripts().count
        controller.bridge(bridge, requestMoreToEnd: 3703)

        let responseScript = try XCTUnwrap(
            recordedScripts().dropFirst(baselineCount).first {
                $0.contains("bibleView.response(3703")
            }
        )

        XCTAssertTrue(
            responseScript.hasPrefix("bibleView.response(3703, {"),
            "Expected a document JSON response for the original callId. Script: \(responseScript)"
        )
        XCTAssertTrue(
            responseScript.contains(#""key":"Gen.2""#),
            "Expected the next chapter document to be returned. Script: \(responseScript)"
        )
        XCTAssertTrue(
            responseScript.contains(#""osisFragment""#),
            "Expected the response payload to preserve the Bible document shape. Script: \(responseScript)"
        )
    }

    @MainActor
    func testRefChooserDialogSendsResponseWithOriginalCallId() {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.onRefChooserDialog = { completion in
            completion("Gen.1.1")
        }

        controller.bridge(bridge, refChooserDialog: 3702)

        XCTAssertEqual(recordedScripts().last, #"bibleView.response(3702, "Gen.1.1");"#)
    }

    /**
     Verifies reference chooser cancellation matches Android's empty-string bridge contract.

     A recording bridge exercises both native cancellation and the missing-handler fallback. Each
     request must resolve under its original call ID with `""`; `null` would diverge from Android
     and can break Vue callers expecting `Promise<string>`.
     */
    @MainActor
    func testRefChooserDialogCancellationReturnsAndroidEmptyString() {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.onRefChooserDialog = { completion in
            completion(nil)
        }

        controller.bridge(bridge, refChooserDialog: 3704)
        XCTAssertEqual(recordedScripts().last, #"bibleView.response(3704, "");"#)

        controller.onRefChooserDialog = nil
        controller.bridge(bridge, refChooserDialog: 3705)
        XCTAssertEqual(recordedScripts().last, #"bibleView.response(3705, "");"#)
    }

    /**
     Verifies the bridge `parseRef` response preserves call IDs and JSword-compatible parsing.

     Setup uses a recording bridge and temporary KJV module so reference parsing goes through the
     active-module parser path, matching Android's JSword `PassageKeyFactory` behavior. The expected
     result is a response with the original call ID for each request, compact OSIS serialization for
     valid references/lists/ranges, and `null` for out-of-range or reverse inputs. Failures indicate
     either bridge response routing drift or parser semantics that diverge from Android. The test is
     main-actor isolated, uses temporary module files only, and has deterministic synchronous parser
     inputs.
     */
    @MainActor
    func testParseRefSendsResponseWithOriginalCallId() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)

        controller.bridge(bridge, parseRef: 3703, text: "Genesis 1:1")

        XCTAssertEqual(recordedScripts().last, #"bibleView.response(3703, "Gen.1.1");"#)

        controller.bridge(bridge, parseRef: 3705, text: "III John 1:2")

        XCTAssertEqual(
            recordedScripts().last,
            #"bibleView.response(3705, "3John.1.2");"#,
            "parseRef should delegate to the active module parser so JSword-compatible book names are accepted."
        )

        controller.bridge(bridge, parseRef: 3706, text: "Genesis 1:1, Exodus 2:1")

        XCTAssertEqual(
            recordedScripts().last,
            #"bibleView.response(3706, "Gen.1.1 Exod.2.1");"#,
            "parseRef should preserve JSword PassageKeyFactory semantics for multi-reference passage lists."
        )

        controller.bridge(bridge, parseRef: 3707, text: "Genesis 1:1, 2")

        XCTAssertEqual(
            recordedScripts().last,
            #"bibleView.response(3707, "Gen.1.1-Gen.1.2");"#,
            "parseRef should preserve JSword basis semantics for verse lists."
        )

        controller.bridge(bridge, parseRef: 3708, text: "Genesis 1")

        XCTAssertEqual(
            recordedScripts().last,
            #"bibleView.response(3708, "Gen.1");"#,
            "parseRef should serialize whole chapters using JSword getOsisRef semantics."
        )

        controller.bridge(bridge, parseRef: 3709, text: "Genesis 1-2")

        XCTAssertEqual(
            recordedScripts().last,
            #"bibleView.response(3709, "Gen.1-Gen.2");"#,
            "parseRef should serialize chapter ranges using JSword getOsisRef semantics."
        )

        controller.bridge(bridge, parseRef: 3704, text: "Gen.1.99")

        XCTAssertEqual(
            recordedScripts().last,
            "bibleView.response(3704, null);",
            "parseRef must reject out-of-range references through the active module parser instead of accepting any OSIS-looking string."
        )

        controller.bridge(bridge, parseRef: 3710, text: "Genesis 1:1, 99")

        XCTAssertEqual(
            recordedScripts().last,
            "bibleView.response(3710, null);",
            "parseRef must reject invalid shorthand verse-list entries the same way JSword validates VerseRange parts."
        )

        controller.bridge(bridge, parseRef: 3711, text: "Genesis 1:1-99")

        XCTAssertEqual(
            recordedScripts().last,
            "bibleView.response(3711, null);",
            "parseRef must reject invalid range endpoints before SWORD normalizes them."
        )

        controller.bridge(bridge, parseRef: 3712, text: "Genesis 2-1")

        XCTAssertEqual(
            recordedScripts().last,
            "bibleView.response(3712, null);",
            "parseRef must reject reverse ranges using active module ordinals instead of accepting fabricated ordering values."
        )
    }

    /**
     Protects reference parsing as a standalone reader responsibility instead of controller state.

     The resolver must preserve Android/JSword `PassageKeyFactory` behavior while being usable
     without routing through the bridge: active-module parsing accepts JSword-compatible book names,
     serializes verse lists and chapter ranges in compact OSIS form, and rejects coordinates SWORD
     would otherwise normalize. A failure means the controller extraction changed reference parsing
     semantics or left this behavior coupled to `BibleReaderController` orchestration.

     Setup uses the temporary KJV SWORD fixture because Android validates these cases through
     the active document's JSword versification rather than a static iOS table. The expected result is
     exact OSIS serialization for valid references and `nil` for invalid explicit coordinates. The
     test creates only temporary module files through the shared fixture helper, performs no persisted
     app-state writes, and is deterministic because all parsing runs synchronously against the fixture
     module.
     */
    func testReferenceResolverPreservesActiveModuleParseRefSemantics() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let books = BibleReaderSwordCoordinator().bookList(for: module)
        let resolver = BibleReaderReferenceResolver(
            activeModule: module,
            bookList: books,
            fallbackBooks: BibleReaderController.defaultBooks,
            fallbackVerseCount: BibleReaderController.verseCount(for:chapter:)
        )

        XCTAssertEqual(resolver.resolveReference("Genesis 1:1"), "Gen.1.1")
        XCTAssertEqual(resolver.resolveReference("III John 1:2"), "3John.1.2")
        XCTAssertEqual(resolver.resolveReference("Genesis 1:1, Exodus 2:1"), "Gen.1.1 Exod.2.1")
        XCTAssertEqual(resolver.resolveReference("Genesis 1:1, 2"), "Gen.1.1-Gen.1.2")
        XCTAssertEqual(resolver.resolveReference("Genesis 1"), "Gen.1")
        XCTAssertEqual(resolver.resolveReference("Genesis 1-2"), "Gen.1-Gen.2")
        XCTAssertNil(resolver.resolveReference("Gen.1.99"))
        XCTAssertNil(resolver.resolveReference("Genesis 1:1, 99"))
        XCTAssertNil(resolver.resolveReference("Genesis 1:1-99"))
        XCTAssertNil(resolver.resolveReference("Genesis 2-1"))
    }

    /**
     Guards active-module reference resolution against static-canon fallback drift.

     Android resolves editor references through the active document versification. If iOS has an
     active SWORD module but cannot expose that module's book list, the resolver must fail closed
     instead of accepting KJV/default-canon names and OSIS IDs. A failure means the extraction
     reintroduced iOS-only fallback behavior that can fabricate references for the active module.

     Setup intentionally supplies a valid active KJV module with an empty book list, which models a
     metadata failure after module selection. The expected result is rejection from the full parser,
     direct OSIS parser, and human-readable parser. The test creates only temporary module files via
     the shared fixture helper, performs no persisted app-state writes, and has no async ordering
     assumptions.
     */
    func testReferenceResolverRejectsStaticFallbackWhenActiveModuleBookListIsUnavailable() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let resolver = BibleReaderReferenceResolver(
            activeModule: module,
            bookList: [],
            fallbackBooks: BibleReaderController.defaultBooks,
            fallbackVerseCount: BibleReaderController.verseCount(for:chapter:)
        )

        XCTAssertNil(resolver.resolveReference("Genesis 1:1"))
        XCTAssertNil(resolver.resolveOsisRef("Gen.1.1"))
        XCTAssertNil(resolver.resolveHumanRef("Genesis 1:1"))
    }

    @MainActor
    func testMyDocumentRawContentBridgeSendsAndroidCompatiblePayloadAndNullFallback() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let pageId = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let sourcePromptId = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let page = MyDocumentPage(
            id: pageId,
            title: "Intro",
            pageKey: "intro",
            contentType: .markdown,
            sourcePromptId: sourcePromptId
        )
        let content = MyDocumentPageContent(pageId: pageId, content: "Raw *markdown*")
        page.pageContent = content
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        let controller = BibleReaderController(bridge: bridge)
        controller.myDocumentStore = store
        var sharedPayload: MyDocumentSharePayload?
        controller.onShareMyDocumentContent = { sharedPayload = $0 }

        controller.bridge(bridge, getMyDocumentPageRawContent: 3704, bookInitials: "MYDOC", pageKey: "intro")
        controller.bridge(bridge, shareMyDocumentContent: "MYDOC", pageKey: "intro")
        controller.bridge(bridge, getMyDocumentPageRawContent: 3705, bookInitials: "MYDOC", pageKey: "missing")

        let payloadScript = try XCTUnwrap(recordedScripts().first { $0.contains("bibleView.response(3704") })
        XCTAssertTrue(payloadScript.hasPrefix("bibleView.response(3704, {"))
        XCTAssertTrue(payloadScript.contains(#""pageId":"11111111-1111-1111-1111-111111111111""#))
        XCTAssertTrue(payloadScript.contains(#""contentType":"MARKDOWN""#))
        XCTAssertTrue(payloadScript.contains(#""content":"Raw *markdown*""#))
        XCTAssertTrue(payloadScript.contains(#""title":"Intro""#))
        XCTAssertTrue(payloadScript.contains(#""sourcePromptId":"22222222-2222-2222-2222-222222222222""#))
        XCTAssertEqual(
            sharedPayload,
            MyDocumentSharePayload(subject: "Intro", body: "Raw *markdown*")
        )
        XCTAssertEqual(recordedScripts().last, "bibleView.response(3705, null);")
    }

    /**
     Verifies local full-name aliases retain Android's canonical My Documents identity and key.

     - Setup: Persists a two-page local document, loads its second page through an exact full-name
       token, then restores a fresh pane whose saved document uses the case-insensitive full-name
       tier accepted by `Books.getBook`.
     - Expected result: Both paths read the requested second page through canonical initials, expose
       canonical active state, and normalize the restored PageManager document token.
     - Failure meaning: Global lookup can select the correct local owner while a downstream exact-
       initials database query drops the requested key, falls back to page one, or fails to render.
     - Side effects: Uses an in-memory SwiftData graph and bridge recorder; restore records one
       persistence callback when it canonicalizes the saved alias.
     */
    @MainActor
    func testMyDocumentFullNameAliasesLoadAndRestoreCanonicalRequestedPage() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let document = MyDocument(name: "Canonical Local Name", initials: "LOCALCANON")
        let firstPage = MyDocumentPage(
            title: "First",
            pageKey: "first",
            contentType: .markdown,
            orderNumber: 0
        )
        let secondPage = MyDocumentPage(
            title: "Second",
            pageKey: "second",
            contentType: .markdown,
            orderNumber: 1
        )
        firstPage.pageContent = MyDocumentPageContent(
            pageId: firstPage.id,
            content: "First body"
        )
        secondPage.pageContent = MyDocumentPageContent(
            pageId: secondPage.id,
            content: "Second body"
        )
        firstPage.document = document
        secondPage.document = document
        document.pages = [firstPage, secondPage]
        context.insert(document)
        context.insert(firstPage)
        context.insert(secondPage)
        try context.save()

        let loadedWindow = Window()
        loadedWindow.pageManager = PageManager(id: loadedWindow.id)
        let loadedController = BibleReaderController(bridge: bridge)
        loadedController.myDocumentStore = store
        loadedController.activeWindow = loadedWindow

        XCTAssertTrue(
            loadedController.loadMyDocumentPage(
                bookInitials: document.name,
                pageKey: secondPage.pageKey
            )
        )
        XCTAssertEqual(loadedController.activeGeneralBookModuleName, document.initials)
        XCTAssertEqual(loadedController.currentGeneralBookKey, secondPage.pageKey)
        XCTAssertEqual(loadedWindow.pageManager?.generalBookDocument, document.initials)
        XCTAssertEqual(loadedWindow.pageManager?.generalBookKey, secondPage.pageKey)
        XCTAssertTrue(recordedScripts().contains { $0.contains("Second body") })

        let restoredWindow = Window()
        let restoredPageManager = PageManager(
            id: restoredWindow.id,
            currentCategoryName: DocumentCategory.generalBook.pageManagerKey
        )
        restoredPageManager.generalBookDocument = document.name.lowercased()
        restoredPageManager.generalBookKey = secondPage.pageKey
        restoredWindow.pageManager = restoredPageManager
        let restoredController = BibleReaderController(bridge: BibleBridge())
        restoredController.myDocumentStore = store
        restoredController.activeWindow = restoredWindow
        var persistCount = 0
        restoredController.onPersistState = { persistCount += 1 }

        restoredController.restoreSavedPosition()

        XCTAssertEqual(restoredController.activeGeneralBookModuleName, document.initials)
        XCTAssertEqual(restoredController.currentGeneralBookKey, secondPage.pageKey)
        XCTAssertEqual(restoredPageManager.generalBookDocument, document.initials)
        XCTAssertEqual(restoredPageManager.generalBookKey, secondPage.pageKey)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Rejects direct My Documents copy/share/save calls when Android's installed registry owns the
     supplied exact-initials, full-name, or Java case-insensitive token.

     - Setup: Registers the KJV fixture and colliding local documents whose initials equal each
       supported installed lookup tier, then sends the three direct bridge actions for every page.
     - Expected result: The shared raw-content gate rejects each token, the share callback remains
       untouched, and every local page retains its original title/body before copy/share/save work.
     - Failure meaning: A stale or forged My Documents payload can disclose or mutate a local page
       after an installed book claims the same Android `Books.getBook` identity.
     - Side effects: Uses temporary SWORD files and an in-memory SwiftData graph; inherited teardown
       removes the module fixture and no platform pasteboard read is required.
     */
    @MainActor
    func testMyDocumentContentActionsRejectEveryInstalledOwnerIdentityTier() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let installed = try XCTUnwrap(
            manager.installedModules().first(where: { $0.name == "KJV" })
        )
        let ownerTokens = [installed.name, installed.description, installed.name.lowercased()]
        XCTAssertEqual(Set(ownerTokens).count, 3)

        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        var fixtures: [(document: MyDocument, page: MyDocumentPage)] = []
        for (index, token) in ownerTokens.enumerated() {
            let pageID = try XCTUnwrap(
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))
            )
            let document = MyDocument(name: "Local collision \(index)", initials: token)
            let page = MyDocumentPage(
                id: pageID,
                title: "Original \(index)",
                pageKey: "entry-\(index)",
                contentType: .markdown
            )
            let content = MyDocumentPageContent(
                pageId: pageID,
                content: "Private local body \(index)"
            )
            page.pageContent = content
            page.document = document
            document.pages = [page]
            context.insert(document)
            context.insert(page)
            context.insert(content)
            fixtures.append((document, page))
        }
        try context.save()

        let bridge = BibleBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager
        )
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        var sharedPayloads: [MyDocumentSharePayload] = []
        controller.onShareMyDocumentContent = { sharedPayloads.append($0) }

        for (index, fixture) in fixtures.enumerated() {
            XCTAssertNil(
                controller.authorizedMyDocumentRawContentPayload(
                    bookInitials: fixture.document.initials,
                    pageKey: fixture.page.pageKey
                )
            )
            controller.bridge(
                bridge,
                copyMyDocumentContent: fixture.document.initials,
                pageKey: fixture.page.pageKey
            )
            controller.bridge(
                bridge,
                shareMyDocumentContent: fixture.document.initials,
                pageKey: fixture.page.pageKey
            )
            controller.bridge(
                bridge,
                saveMyDocumentPageContent: fixture.document.initials,
                pageId: fixture.page.id.uuidString,
                content: "Leaked replacement \(index)",
                title: "Leaked title \(index)"
            )

            XCTAssertEqual(fixture.page.title, "Original \(index)")
            XCTAssertEqual(fixture.page.pageContent?.content, "Private local body \(index)")
        }

        XCTAssertTrue(sharedPayloads.isEmpty)
    }

    /**
     Verifies editing a visible My Documents page persists raw Markdown and reloads Android's
     processed general-book document instead of stale source text.

     - Setup: Stores one Markdown page, renders it, saves changed content through the bridge, and
       requests an in-place reload while recording Vue emissions.
     - Expected result: SwiftData retains the raw edit while the second `add_documents` payload
       carries the new title and CommonMark output with Android-style `BVA` anchors.
     - Failure meaning: The edit bridge lost persistence, reloaded stale content, or bypassed the
       generic-document anchor pipeline used for selection and scroll tracking.
     - Side effects: Uses an in-memory SwiftData store and an in-memory bridge recorder only.
     */
    @MainActor
    func testMyDocumentEditBridgePersistsContentAndReloadsVisiblePage() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let pageId = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let page = MyDocumentPage(
            id: pageId,
            title: "Intro",
            pageKey: "intro",
            contentType: .markdown,
            languageCode: "en"
        )
        let content = MyDocumentPageContent(pageId: pageId, content: "Original *markdown*")
        page.pageContent = content
        page.document = document
        document.pages = [page]
        context.insert(document)
        context.insert(page)
        context.insert(content)
        try context.save()

        let controller = BibleReaderController(bridge: bridge)
        controller.myDocumentStore = store
        controller.bridge(bridge, selectionChanged: "Selected text")
        controller.bridge(bridge, setEditing: true)

        XCTAssertTrue(controller.loadMyDocumentPage(bookInitials: "MYDOC", pageKey: "intro"))
        XCTAssertEqual(
            controller.renderedContentState,
            "category=general_book;module=MYDOC;book=My Document;chapter=none;key=intro"
        )
        XCTAssertFalse(controller.hasActiveSelection)
        XCTAssertEqual(controller.selectedText, "")
        XCTAssertFalse(controller.editingInWebView)
        XCTAssertTrue(recordedScripts().contains("window.getSelection().removeAllRanges();"))

        controller.bridge(
            bridge,
            saveMyDocumentPageContent: "MYDOC",
            pageId: pageId.uuidString,
            content: "Edited **markdown**",
            title: "Renamed"
        )

        let savedPayload = try XCTUnwrap(store.rawContentPayload(bookInitials: "MYDOC", pageKey: "intro"))
        XCTAssertEqual(savedPayload.content, "Edited **markdown**")
        XCTAssertEqual(savedPayload.title, "Renamed")

        controller.bridge(bridge, reloadMyDocumentPage: "MYDOC")

        let addDocumentScripts = recordedScripts().filter { $0.contains("emit('add_documents'") }
        XCTAssertEqual(addDocumentScripts.count, 2)

        let reloadedScript = try XCTUnwrap(addDocumentScripts.last)
        let reloadedDocument = try XCTUnwrap(
            bridgeEmissionPayload(from: [reloadedScript], event: "add_documents") as? [String: Any]
        )
        let reloadedFragment = try XCTUnwrap(reloadedDocument["osisFragment"] as? [String: Any])
        let reloadedXML = try XCTUnwrap(reloadedFragment["xml"] as? String)

        XCTAssertEqual(reloadedDocument["bookInitials"] as? String, "MYDOC")
        XCTAssertEqual(reloadedDocument["bookCategory"] as? String, "GENERAL_BOOK")
        XCTAssertEqual(reloadedDocument["isMyDocument"] as? Bool, true)
        XCTAssertEqual(
            reloadedDocument["myDocumentPageId"] as? String,
            "33333333-3333-3333-3333-333333333333"
        )
        XCTAssertEqual(reloadedFragment["keyName"] as? String, "Renamed")
        XCTAssertTrue(reloadedXML.contains("<strong><BVA"))
        XCTAssertTrue(reloadedXML.contains(">markdown</BVA></strong>"))
        XCTAssertFalse(reloadedXML.contains("Edited **markdown**"))
        XCTAssertFalse(reloadedXML.contains("Original *markdown*"))
    }

    /**
     Verifies AI-page regeneration and deletion retain Android's ownership and fallback contracts.

     - Setup: Builds isolated My Documents records and injects the inherited temporary KJV SWORD
       fixture, preventing globally installed simulator modules from changing the reader fallback.
     - Expected result: Only the AI page can regenerate or delete; deletion restores the owned KJV
       Bible page, persists once, and clears the prior rendered document.
     - Failure meaning: AI metadata routing, deletion authorization, reader fallback, or test fixture
       isolation has regressed.
     - Side effects: Mutates only an in-memory My Documents store and a temporary SWORD tree removed
       by inherited teardown; bridge and persistence effects are captured by local probes.
     */
    @MainActor
    func testMyDocumentAIPageBridgeDeletesActivePageAndHandsOffRegeneration() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let store = MyDocumentStore(modelContext: context)
        let aiPageId = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        let userPageId = try XCTUnwrap(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        let promptId = try XCTUnwrap(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let document = MyDocument(name: "AI Documents", initials: "AIDocuments")
        let aiPage = MyDocumentPage(
            id: aiPageId,
            title: "AI Page",
            pageKey: "ai",
            contentType: .markdown,
            sourcePromptId: promptId,
            languageCode: "en"
        )
        let aiContent = MyDocumentPageContent(pageId: aiPageId, content: "AI generated content")
        let aiCacheEntry = AiPageCacheEntry(
            pageId: aiPageId,
            sourcePromptId: promptId,
            sourceContext: #"{"osisRef":"Gen.1"}"#,
            kjvOrdinalStart: 1,
            kjvOrdinalEnd: 31,
            sourceModelName: "model"
        )
        let userPage = MyDocumentPage(
            id: userPageId,
            title: "User Page",
            pageKey: "user",
            contentType: .markdown
        )
        let userContent = MyDocumentPageContent(pageId: userPageId, content: "User content")

        aiPage.pageContent = aiContent
        aiPage.document = document
        aiCacheEntry.page = aiPage
        aiPage.aiPageCacheEntries = [aiCacheEntry]
        userPage.pageContent = userContent
        userPage.document = document
        document.pages = [aiPage, userPage]
        context.insert(document)
        context.insert(aiPage)
        context.insert(aiContent)
        context.insert(aiCacheEntry)
        context.insert(userPage)
        context.insert(userContent)
        try context.save()

        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.myDocumentStore = store
        var regeneratedContext: MyDocumentAIPageActionContext?
        var persistCount = 0
        controller.onRegenerateMyDocumentPage = { regeneratedContext = $0 }
        controller.onPersistState = { persistCount += 1 }

        controller.bridge(bridge, regenerateMyDocumentPage: aiPageId.uuidString)
        XCTAssertEqual(regeneratedContext?.pageId, aiPageId)
        XCTAssertEqual(regeneratedContext?.sourcePromptId, promptId)
        XCTAssertEqual(regeneratedContext?.sourceContext, #"{"osisRef":"Gen.1"}"#)
        XCTAssertEqual(regeneratedContext?.sourceModelName, "model")

        regeneratedContext = nil
        controller.bridge(bridge, regenerateMyDocumentPage: userPageId.uuidString)
        XCTAssertNil(regeneratedContext)

        controller.bridge(bridge, deleteMyDocumentPage: userPageId.uuidString)
        XCTAssertNotNil(store.rawContentPayload(bookInitials: "AIDocuments", pageKey: "user"))

        XCTAssertTrue(controller.loadMyDocumentPage(bookInitials: "AIDocuments", pageKey: "ai"))
        let clearDocumentCountBeforeDelete = recordedScripts().filter { $0.contains("emit('clear_document'") }.count

        controller.bridge(bridge, deleteMyDocumentPage: aiPageId.uuidString)

        XCTAssertNil(store.rawContentPayload(bookInitials: "AIDocuments", pageKey: "ai"))
        XCTAssertNotNil(store.rawContentPayload(bookInitials: "AIDocuments", pageKey: "user"))
        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(
            controller.renderedContentState,
            "category=bible;module=KJV;book=Genesis;chapter=1;key=Gen.1"
        )
        XCTAssertGreaterThan(
            recordedScripts().filter { $0.contains("emit('clear_document'") }.count,
            clearDocumentCountBeforeDelete
        )
    }

    func testOpenExternalLinkRoutesAbErrorToIssueTrackerURL() {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        var openedURL: URL?
        controller.onOpenExternalURL = { openedURL = $0 }

        controller.bridge(bridge, openExternalLink: "ab-error://error")

        XCTAssertEqual(openedURL?.absoluteString, "https://github.com/AndBible/and-bible/issues")
    }
    #endif

    func testNavigateToPersistsSelectedVerseOnPageManager() {
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window

        controller.navigateTo(book: "Genesis", chapter: 1, verse: 5)

        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(pageManager.bibleChapterNo, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)
    }

    /**
     Protects visible-verse persistence against synthetic ordinal arithmetic.

     Android receives scroll ordinals that belong to the active JSword versification. This test
     uses the KJV SWORD test fixture to derive the ordinal for Genesis 1:5, then expects the
     native reader to reverse-map that ordinal back to verse 5 before debouncing persistence. A
     failure means reader state is deriving verses from fixed 40-verse chapter math.
     */
    func testDidScrollToOrdinalDebouncesPersistenceWithinCurrentChapter() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)

        let persisted = expectation(description: "Visible verse state persisted after debounce")
        var persistCount = 0
        controller.onPersistState = {
            persistCount += 1
            persisted.fulfill()
        }

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)

        wait(for: [persisted], timeout: 2.0)

        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects Android-style visible-verse tracking when the web client cannot supply a document key.

     Android's Bible `scrolledToOrdinal` path ignores the key for Bible documents and resolves the
     ordinal through JSword. The setup reports the KJV test fixture ordinal for Genesis 2:3 with an empty
     key and expects iOS to update/persist the native chapter and verse from the ordinal. A failure
     means valid scroll telemetry can be dropped whenever `dataset.osisRef` is missing.
     */
    func testDidScrollToOrdinalPersistsVisibleVerseWhenKeyIsEmpty() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 3))
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)

        let persisted = expectation(description: "Visible verse state persisted after debounce")
        var persistCount = 0
        controller.onPersistState = {
            persistCount += 1
            persisted.fulfill()
        }

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "", atChapterTop: false)

        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 3)
        XCTAssertEqual(pageManager.bibleChapterNo, 2)
        XCTAssertEqual(pageManager.bibleVerseNo, 3)

        wait(for: [persisted], timeout: 2.0)

        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects visible-verse key parsing for OSIS refs that include a verse segment.

     Android's Bible visible-position callback updates by JSword ordinal and does not mistake
     `Gen.1.5` for chapter 5. The setup reports the Genesis 1:5 ordinal with a verse-qualified
     document key. The expected result is that native state remains in chapter 1, updates to verse 5,
     and uses the normal intra-chapter debounce path; a failure means source keys with verse suffixes
     can corrupt the pane chapter and send synchronized targets to the wrong location.
     */
    func testDidScrollToOrdinalParsesVerseQualifiedKeyAsChapter() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)

        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1.5", atChapterTop: false)

        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(pageManager.bibleChapterNo, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)
    }

    /**
     Protects the synchronized-scroll loop when visible keys include verse suffixes.

     Android accepts verse-qualified keys as the same chapter position, updates stale inactive
     windows once, and then treats the target's matching callback as passive feedback. The setup
     makes the first synced pane report `Gen.1.5`, leaves the target's persisted book incomplete to
     model restored/stale pane state, checks that only the stale second pane remains a secondary
     target, applies that target update, and then sends the target callback. The expected result is
     one source broadcast with both panes on comparable Genesis 1:5 PageManager state and no reverse
     broadcast; a failure means iOS can corrupt the chapter from the key suffix, leave the target
     perpetually stale, or keep issuing redundant target scrolls that start the alternating rollback
     loop.
     */
    @MainActor
    func testVerseQualifiedSynchronizedScrollUpdatesTargetOnceWithoutReverseBroadcast() throws {
        let sourceBridge = BibleBridge()
        let targetBridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let sourceController = BibleReaderController(bridge: sourceBridge, swordManagerOverride: manager)
        let targetController = BibleReaderController(bridge: targetBridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: sourceController.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Verse Qualified Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        sourceController.activeWindow = sourceWindow
        sourceController.windowManagerRef = windowManager
        targetController.activeWindow = targetWindow
        targetController.windowManagerRef = windowManager
        sourceController.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        targetController.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        targetWindow.pageManager?.bibleBibleBook = nil

        let sourceBroadcast = expectation(description: "source scroll broadcasts once")
        windowManager.onSyncVerseChanged = { eventSourceWindow, sourceOrdinal, key in
            XCTAssertEqual(eventSourceWindow.id, sourceWindow.id)
            XCTAssertEqual(sourceOrdinal, ordinal)
            XCTAssertEqual(key, "Gen.1.5")
            sourceBroadcast.fulfill()
        }

        sourceController.bridge(sourceBridge, didScrollToOrdinal: ordinal, key: "Gen.1.5", atChapterTop: false)

        wait(for: [sourceBroadcast], timeout: 1.0)
        XCTAssertEqual(sourceController.currentChapter, 1)
        XCTAssertEqual(sourceController.currentVerse, 5)
        XCTAssertEqual(sourceWindow.pageManager?.bibleChapterNo, 1)
        XCTAssertEqual(sourceWindow.pageManager?.bibleVerseNo, 5)
        XCTAssertEqual(windowManager.synchronizedVerseUpdateTargets(for: sourceWindow).map(\.id), [targetWindow.id])

        targetController.scrollToOrdinal(ordinal)

        XCTAssertEqual(targetWindow.pageManager?.bibleBibleBook, 0)
        XCTAssertTrue(windowManager.synchronizedVerseUpdateTargets(for: sourceWindow).isEmpty)

        let reverseBroadcast = expectation(description: "target acknowledgement must not rebroadcast")
        reverseBroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            reverseBroadcast.fulfill()
        }

        targetController.bridge(targetBridge, didScrollToOrdinal: ordinal, key: "Gen.1.5", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(targetController.currentChapter, 1)
        XCTAssertEqual(targetController.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleChapterNo, 1)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [reverseBroadcast], timeout: 0.35)
    }

    /**
     Protects Android's target-local synchronized scroll anchor conversion.

     Android synchronizes a `Verse` key, then converts it to the inactive window's own
     versification before emitting `scroll_to_verse`. This fixture uses a KJV source and a
     generated no-module KJVA target; both must resolve Genesis 1:10 to the same intro-inclusive
     JSword ordinal rather than remapping the target through legacy `chapter * 40` placeholder
     math. Divergent source/target conversion is covered separately by non-KJVA bridge fixtures.
     */
    @MainActor
    func testSynchronizedScrollConvertsSourceVerseToTargetOrdinalSpace() throws {
        let sourceBridge = BibleBridge()
        let (targetBridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let sourceController = BibleReaderController(bridge: sourceBridge, swordManagerOverride: manager)
        let targetController = BibleReaderController(bridge: targetBridge, initializesSword: false)
        let sourceModule = try XCTUnwrap(manager.module(named: sourceController.activeModuleName))
        let sourceOrdinal = try XCTUnwrap(
            sourceModule.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 10)
        )
        let targetOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 10)
        )
        XCTAssertEqual(sourceOrdinal, targetOrdinal)
        XCTAssertNotEqual(targetOrdinal, 10)

        let sourceWindow = Window()
        let sourcePageManager = PageManager(id: sourceWindow.id)
        sourceWindow.pageManager = sourcePageManager
        sourceController.activeWindow = sourceWindow
        sourceController.navigateTo(book: "Genesis", chapter: 1, verse: 1)

        let targetWindow = Window()
        let targetPageManager = PageManager(id: targetWindow.id)
        targetWindow.pageManager = targetPageManager
        targetController.activeWindow = targetWindow
        targetController.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        targetController.bridgeDidSetClientReady(targetBridge)
        let setupScriptCount = recordedScripts().count

        let sourceReference = try XCTUnwrap(sourceController.synchronizedVerseReference(ordinal: sourceOrdinal))
        XCTAssertEqual(sourceReference.osisBookId, "Gen")
        XCTAssertEqual(sourceReference.chapter, 1)
        XCTAssertEqual(sourceReference.verse, 10)

        targetController.scrollToSynchronizedVerse(
            osisBookId: sourceReference.osisBookId,
            chapter: sourceReference.chapter,
            verse: sourceReference.verse
        )

        let newScripts = Array(recordedScripts().dropFirst(setupScriptCount))
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: newScripts, event: "scroll_to_verse") as? [String: Any]
        )
        XCTAssertEqual(payload["ordinal"] as? Int, targetOrdinal)
        XCTAssertEqual(payload["now"] as? Bool, false)
        XCTAssertEqual(targetController.currentVerse, 10)
        XCTAssertEqual(targetPageManager.bibleVerseNo, 10)
    }

    /**
     Protects Android's visible-verse old/new guard for synchronized windows.

     Android only posts a synchronized verse-change event when
     `CurrentBiblePage.setCurrentVerseOrdinal` changes the stored ordinal. The setup makes one
     synchronized iOS pane active at Genesis 1:5, then reports the same visible ordinal again. The
     expected result is no sync event because duplicate callbacks are scroll maintenance, not a new
     source position. A failure means stale duplicate callbacks can leave delayed sync work that
     later pulls another pane back after focus changes.
     */
    @MainActor
    func testDuplicateVisibleVerseCallbackDoesNotRebroadcastSynchronizedPane() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Duplicate Visible Verse")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        window.isSynchronized = true
        window.syncGroup = 0
        windowManager.setActiveWorkspace(workspace)
        windowManager.activeWindow = window
        controller.activeWindow = window
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 5)
        let rebroadcast = expectation(description: "duplicate visible verse must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, window.id)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(window.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)
    }

    /**
     Protects the synchronized-scroll feedback state machine used by reader panes.

     Android keeps secondary synchronized panes passive until explicit user interaction, including
     when a target scroll arrives before the Vue client is ready. The setup drives the extracted
     state machine without a WebView: it defers a target ordinal, promotes it after client-ready
     replay, acknowledges intermediate and matching callbacks, and finally clears through explicit
     interaction. The expected result is that sync-origin callbacks and native deltas stay passive
     until interaction. A failure means the state owner can reintroduce target-pane ping-pong even
     when controller-level tests pass through incidental state.
     */
    func testReaderSynchronizedScrollCoordinatorPreservesPassiveTargetStateUntilInteraction() {
        let coordinator = BibleReaderSynchronizedScrollCoordinator()

        XCTAssertTrue(coordinator.shouldTreatNativeScrollDeltaAsUserInteraction)

        coordinator.deferUntilClientReady(ordinal: 105)
        XCTAssertFalse(coordinator.shouldTreatNativeScrollDeltaAsUserInteraction)

        let deferredOrdinal = coordinator.consumeDeferredClientReadyOrdinalForReplay()
        XCTAssertEqual(deferredOrdinal, 105)
        if let deferredOrdinal {
            coordinator.markClientReadyReplayPending(ordinal: deferredOrdinal)
        }

        XCTAssertTrue(coordinator.acknowledgeVisibleOrdinal(104))
        XCTAssertFalse(coordinator.shouldTreatNativeScrollDeltaAsUserInteraction)
        XCTAssertTrue(coordinator.acknowledgeVisibleOrdinal(105))
        XCTAssertFalse(coordinator.shouldTreatNativeScrollDeltaAsUserInteraction)
        XCTAssertTrue(coordinator.acknowledgeVisibleOrdinal(106))

        coordinator.clearForUserInteraction()

        XCTAssertTrue(coordinator.shouldTreatNativeScrollDeltaAsUserInteraction)
        XCTAssertFalse(coordinator.acknowledgeVisibleOrdinal(105))
    }

    /**
     Protects Android's secondary-window synchronized scroll contract.

     Android posts a secondary scroll event to synced inactive windows and does not let the web
     client's resulting visible-verse callback become a new source window. The setup creates two
     synchronized panes, keeps the first pane active, then asks the second pane's controller to
     perform two sync-origin scrolls before acknowledging the latest. The expected result is that
     the second pane updates its visible verse state without focusing itself or rebroadcasting
     through `WindowManager`, while explicit user interaction cancels feedback suppression before a
     later real scroll callback; a failure means synced panes can ping-pong until a document
     boundary or stale sync requests can hide user-origin scrolling.
     */
    @MainActor
    func testSynchronizedScrollCallbackDoesNotRefocusOrRebroadcastTargetPane() throws {
        let bridge = BibleBridge()
        var emittedScripts: [String] = []
        bridge.javaScriptEvaluationObserver = { emittedScripts.append($0) }
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let olderOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 4))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Synchronized Scroll")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        emittedScripts.removeAll()
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "sync-origin scroll must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.scrollToOrdinal(olderOrdinal)
        controller.scrollToOrdinal(ordinal)
        XCTAssertEqual(emittedScripts.count, 2)
        XCTAssertTrue(emittedScripts.allSatisfy { $0.contains("scroll_to_verse") })
        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)

        let laterUserBroadcast = expectation(description: "older sync ordinal does not remain pending")
        windowManager.onSyncVerseChanged = { sourceWindow, sourceOrdinal, key in
            XCTAssertEqual(sourceWindow.id, targetWindow.id)
            XCTAssertEqual(sourceOrdinal, olderOrdinal)
            XCTAssertEqual(key, "Gen.1")
            laterUserBroadcast.fulfill()
        }

        controller.handleUserInteraction()
        controller.bridge(bridge, didScrollToOrdinal: olderOrdinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, targetWindow.id)
        XCTAssertEqual(controller.currentVerse, 4)
        wait(for: [laterUserBroadcast], timeout: 1.0)
    }

    /**
     Protects inactive synced panes from intermediate programmatic scroll telemetry.

     Android keeps a secondary pane passive while a synchronized scroll is settling; WebView
     visible-verse callbacks that report nearby/intermediate ordinals are still feedback from the
     source pane, not a new user scroll in the target pane. The setup keeps the first synced window
     active, sends a sync scroll to the second window, then reports an adjacent ordinal before the
     target ordinal arrives. The expected result is that the second pane updates its native visible
     verse state without focusing itself or rebroadcasting. A failure means iOS can ping-pong
     between synced panes when WebKit reports partial scroll progress.
     */
    @MainActor
    func testSynchronizedScrollIntermediateCallbackDoesNotRefocusOrRebroadcastTargetPane() throws {
        let bridge = BibleBridge()
        var emittedScripts: [String] = []
        bridge.javaScriptEvaluationObserver = { emittedScripts.append($0) }
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let targetOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let intermediateOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 4))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Intermediate Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        emittedScripts.removeAll()
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "intermediate sync-origin scroll must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.scrollToOrdinal(targetOrdinal)

        XCTAssertEqual(emittedScripts.count, 1)
        XCTAssertTrue(emittedScripts[0].contains("scroll_to_verse"))

        controller.bridge(bridge, didScrollToOrdinal: intermediateOrdinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(controller.currentVerse, 4)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 4)
        wait(for: [rebroadcast], timeout: 0.35)
    }

    /**
     Protects Android's touch-driven source handoff for native WebView scroll telemetry.

     A synchronized secondary scroll can make UIKit report vertical scroll deltas while the target
     pane is moving programmatically. Android does not promote that inactive pane until an actual
     touch/web interaction occurs in it. The setup simulates the pane-host wiring: a native scroll
     delta is forwarded only when the controller classifies it as user-origin, then explicit user
     interaction is delivered and the same delta path is retried. The expected result is that
     sync-origin deltas neither focus nor auto-hide chrome, while real user interaction cancels the
     guard and restores normal delta forwarding. A failure means programmatic target scrolling can
     still activate and rebroadcast from the wrong pane.
     */
    @MainActor
    func testSynchronizedScrollNativeDeltaDoesNotFocusUntilExplicitUserInteraction() throws {
        let bridge = BibleBridge()
        bridge.javaScriptEvaluationObserver = { _ in }
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Native Delta Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        var forwardedDeltas: [Double] = []
        func simulatePaneNativeScrollDelta(_ deltaY: Double) {
            guard controller.shouldTreatNativeScrollDeltaAsUserInteraction() else { return }
            if windowManager.activeWindow?.id != targetWindow.id {
                controller.handleUserInteraction()
            }
            forwardedDeltas.append(deltaY)
        }

        controller.scrollToOrdinal(ordinal)
        simulatePaneNativeScrollDelta(18)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertTrue(forwardedDeltas.isEmpty)

        controller.handleUserInteraction()
        simulatePaneNativeScrollDelta(18)

        XCTAssertEqual(windowManager.activeWindow?.id, targetWindow.id)
        XCTAssertEqual(forwardedDeltas, [18])
    }

    /**
     Protects synchronized target panes across the native/WebView delivery boundary.

     Android updates an inactive synchronized window's key as sync-origin state before attempting
     the secondary scroll. If that inactive view later reports the same visible key, it must remain
     passive even when host focus has moved to the pane through a non-scroll path; only explicit
     user interaction may make it a new sync source. The setup uses a client-ready bridge without
     an attached WebView so the JavaScript emit is not delivered, then verifies the native sync
     state still suppresses the follow-up visible-verse callback. A failure means a detached or
     rebuilding target pane can rebroadcast its peer's synchronized key and start a reverse loop.
     */
    @MainActor
    func testDetachedSynchronizedScrollRemainsPassiveUntilExplicitInteraction() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let olderOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 4))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Detached Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "detached sync-origin scroll must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.scrollToOrdinal(ordinal)
        windowManager.activeWindow = targetWindow
        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, targetWindow.id)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)

        let userBroadcast = expectation(description: "explicit target interaction restores broadcasting")
        windowManager.onSyncVerseChanged = { sourceWindow, sourceOrdinal, key in
            XCTAssertEqual(sourceWindow.id, targetWindow.id)
            XCTAssertEqual(sourceOrdinal, olderOrdinal)
            XCTAssertEqual(key, "Gen.1")
            userBroadcast.fulfill()
        }

        controller.handleUserInteraction()
        controller.bridge(bridge, didScrollToOrdinal: olderOrdinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, targetWindow.id)
        XCTAssertEqual(controller.currentVerse, 4)
        wait(for: [userBroadcast], timeout: 1.0)
    }

    /**
     Protects visible-verse telemetry from acting as source-window ownership.

     Android treats document visible-position reports as passive state updates; a synced pane only
     becomes the new source after an explicit touch or web interaction has already made it active.
     The setup leaves the second synchronized window inactive and sends a plain visible-verse
     callback without any native interaction. The expected result is that the target pane records
     the verse for restoration but neither focuses itself nor schedules reverse synchronization. A
     failure means an inactive pane can start the alternating sync loop from passive WebView
     telemetry alone.
     */
    @MainActor
    func testInactiveSynchronizedScrollCallbackDoesNotFocusOrBroadcastWithoutInteraction() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Passive Visible Verse")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "passive inactive scroll must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)
    }

    /**
     Protects cross-chapter synchronized navigation from becoming a new scroll source.

     Android treats a secondary window chapter change caused by synchronized scrolling as passive
     feedback from the source pane. The setup keeps the first synced window active, asks the target
     controller to navigate to the source ordinal in the next chapter using the sync-specific entry
     point, then reports that visible ordinal from the web client. The expected result is that the
     target updates to the source verse without focusing or rebroadcasting. A failure means iOS only
     suppresses same-chapter sync scrolls and can still ping-pong when synced panes cross a chapter
     boundary.
     */
    @MainActor
    func testSynchronizedNavigationCallbackDoesNotRefocusOrRebroadcastTargetPane() throws {
        let bridge = BibleBridge()
        bridge.javaScriptEvaluationObserver = { _ in }
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Cross Chapter Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "sync-origin chapter navigation must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.navigateToSynchronizedPosition(book: "Genesis", chapter: 2, ordinal: ordinal)
        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.2", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleChapterNo, 2)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)
    }

    /**
     Protects synchronized scrolling across the native/WebView bootstrap boundary.

     Android updates the inactive window's verse key before attempting a secondary visible scroll, so
     a rebuilding target pane lands on the synchronized verse when its content is replayed without
     becoming the new source window. This fixture attaches a recording bridge before
     `clientReady`, sends a sync scroll, and verifies iOS does not queue `scroll_to_verse` into an
     unmounted Vue listener while still suppressing the replay-induced `scrolledToOrdinal`
     callback. A failure means iOS can either drop the target pane position or treat a bootstrap
     replay as a user-origin sync source.
     */
    @MainActor
    func testSynchronizedScrollBeforeClientReadyReplaysWithoutRefocusOrRebroadcast() throws {
        let bridge = BibleBridge()
        var emittedScripts: [String] = []
        bridge.javaScriptEvaluationObserver = { emittedScripts.append($0) }
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "Pre-Ready Sync")
        let sourceWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let targetWindow = try XCTUnwrap(windowManager.addWindow(from: sourceWindow))
        sourceWindow.isSynchronized = true
        sourceWindow.syncGroup = 0
        targetWindow.isSynchronized = true
        targetWindow.syncGroup = 0
        windowManager.activeWindow = sourceWindow
        controller.activeWindow = targetWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.onInteraction = {
            windowManager.activeWindow = targetWindow
        }
        let rebroadcast = expectation(description: "ready replay must not rebroadcast")
        rebroadcast.isInverted = true
        windowManager.onSyncVerseChanged = { _, _, _ in
            rebroadcast.fulfill()
        }

        controller.scrollToOrdinal(ordinal)

        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        XCTAssertFalse(emittedScripts.contains { $0.contains("scroll_to_verse") })

        controller.bridgeDidSetClientReady(bridge)

        XCTAssertFalse(emittedScripts.contains { $0.contains("scroll_to_verse") })
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(emittedScripts.reversed()),
                event: "setup_content"
            ) as? [String: Any]
        )
        XCTAssertEqual(setup["jumpToOrdinal"] as? Int, ordinal)
        XCTAssertTrue(setup["jumpToAnchor"] is NSNull)
        XCTAssertTrue(setup["ordinalStart"] is NSNull)
        XCTAssertTrue(setup["ordinalEnd"] is NSNull)
        XCTAssertEqual(setup["highlight"] as? Bool, false)
        XCTAssertTrue(setup["bookInitials"] is NSNull)
        XCTAssertTrue(setup["osisRef"] is NSNull)
        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, sourceWindow.id)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(targetWindow.pageManager?.bibleVerseNo, 5)
        wait(for: [rebroadcast], timeout: 0.35)
    }

    /**
     Protects user-origin synchronized scrolling while suppressing only secondary feedback.

     Android still treats a real scroll in a synchronized pane as the new source window. The setup
     mirrors the secondary-scroll regression fixture with a detached bridge, then delivers the
     explicit interaction that native dragging sends before a changed visible-position callback. The
     expected result is that explicit interaction clears sync-origin suppression and the active pane
     emits one sync event through `WindowManager`; a failure means the feedback-loop guard has
     disabled real synchronized scrolling or visible-verse telemetry is being treated as source
     ownership.
     */
    @MainActor
    func testUserScrollCallbackStillFocusesAndBroadcastsSynchronizedPane() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let syncOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 5))
        let userOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 6))
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let workspaceStore = WorkspaceStore(modelContext: context)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        let workspace = workspaceStore.createWorkspace(name: "User Scroll")
        let firstWindow = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        windowManager.setActiveWorkspace(workspace)
        let scrolledWindow = try XCTUnwrap(windowManager.addWindow(from: firstWindow))
        scrolledWindow.isSynchronized = true
        scrolledWindow.syncGroup = 0
        windowManager.activeWindow = firstWindow
        controller.activeWindow = scrolledWindow
        controller.windowManagerRef = windowManager
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        controller.onInteraction = {
            windowManager.activeWindow = scrolledWindow
        }
        let broadcast = expectation(description: "user-origin scroll rebroadcasts")
        windowManager.onSyncVerseChanged = { sourceWindow, sourceOrdinal, key in
            XCTAssertEqual(sourceWindow.id, scrolledWindow.id)
            XCTAssertEqual(sourceOrdinal, userOrdinal)
            XCTAssertEqual(key, "Gen.1")
            broadcast.fulfill()
        }

        controller.scrollToOrdinal(syncOrdinal)
        controller.handleUserInteraction()
        controller.bridge(bridge, didScrollToOrdinal: userOrdinal, key: "Gen.1", atChapterTop: false)

        XCTAssertEqual(windowManager.activeWindow?.id, scrolledWindow.id)
        XCTAssertEqual(controller.currentVerse, 6)
        wait(for: [broadcast], timeout: 1.0)
    }

    /**
     Protects chapter-change scroll persistence against synthetic ordinal arithmetic.

     The document key tells the native reader which chapter is visible, but the verse number must
     still be reverse-mapped from the JSword/SWORD ordinal. Genesis 2:5 is intentionally chosen
     because SWORD's ordinal is not the legacy `45`; a failure means infinite-scroll persistence
     can store the wrong visible verse after a chapter boundary.
     */
    func testDidScrollToOrdinalPersistsImmediatelyWhenChapterChanges() throws {
        let bridge = BibleBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 5))
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)

        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.bridge(bridge, didScrollToOrdinal: ordinal, key: "Gen.2", atChapterTop: false)

        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.currentVerse, 5)
        XCTAssertEqual(pageManager.bibleChapterNo, 2)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)
    }

    /**
     Mutable state captured by the navigation context test closures.

     The production coordinator receives escaping closures owned by `BibleReaderController`. Tests
     use this reference type to model the same lifetime explicitly without unsafe pointer captures.
     A failure involving this helper usually means the test fixture no longer matches the
     coordinator's closure-based dependency contract.
     */
    private final class NavigationCoordinatorStateBox {
        /// Current visible Bible position.
        var position: BibleReaderNavigationPosition

        /// Recorded history keys supplied by explicit navigation.
        var history: [String] = []

        /// Number of durable persistence requests.
        var persistCount = 0

        /// Number of host content reload requests.
        var loadCount = 0

        /// Creates a fixture state box for one coordinator test.
        init(position: BibleReaderNavigationPosition) {
            self.position = position
        }
    }

    /**
     Builds a deterministic navigation context backed by in-memory state.

     The fixture uses two books and synthetic ordinals (`chapter * 100 + verse`) so assertions can
     focus on coordinator ownership rather than SWORD lookups. This mirrors the production contract:
     the controller supplies versification lookups, while the coordinator decides when to use them
     and when to persist PageManager state.
     */
    private func makeNavigationCoordinatorContext(
        state: NavigationCoordinatorStateBox,
        pageManager: PageManager,
        clientReady: Bool = true,
        isShowingAndroidMultiDocument: Bool = false
    ) -> BibleReaderNavigationContext {
        let books = [
            BibleReaderNavigationBook(name: "Genesis", osisId: "Gen", chapterCount: 50),
            BibleReaderNavigationBook(name: "Exodus", osisId: "Exod", chapterCount: 40),
        ]

        func book(named name: String) -> BibleReaderNavigationBook? {
            books.first { $0.name == name }
        }

        func osisId(for name: String) -> String {
            book(named: name)?.osisId ?? name
        }

        return BibleReaderNavigationContext(
            currentPosition: { state.position },
            setCurrentPosition: { state.position = $0 },
            pageManager: { pageManager },
            bookList: { books },
            isShowingAndroidMultiDocument: { isShowingAndroidMultiDocument },
            clientReady: { clientReady },
            chapterCount: { book(named: $0)?.chapterCount ?? 0 },
            nextBook: { name in
                guard let index = books.firstIndex(where: { $0.name == name }),
                      index + 1 < books.count else {
                    return nil
                }
                return books[index + 1].name
            },
            previousBook: { name in
                guard let index = books.firstIndex(where: { $0.name == name }),
                      index > 0 else {
                    return nil
                }
                return books[index - 1].name
            },
            bookNameForOsisId: { osisId in
                books.first { $0.osisId == osisId }?.name
            },
            ordinalForVerse: { _, chapter, verse in
                chapter * 100 + verse
            },
            verseReference: { bookName, ordinal in
                BibleReaderNavigationVerseReference(
                    chapter: ordinal / 100,
                    verse: ordinal % 100,
                    osisBookId: osisId(for: bookName)
                )
            },
            recordHistory: { bookName, chapter, verse in
                state.history.append("\(osisId(for: bookName)).\(chapter).\(verse)")
            },
            persistState: {
                state.persistCount += 1
            },
            loadCurrentContent: {
                state.loadCount += 1
            }
        )
    }

    /**
     Protects the extracted direct-navigation state transition.

     Setup creates an active in-memory PageManager and a client-ready context. Navigation to an
     explicit verse should update visible state, persist the Bible position, record the Android-style
     OSIS history key, retain the explicit ordinal range for the next render, and ask the host to
     reload content once. A failure means direct reader navigation has drifted back into ad hoc
     controller mutations instead of a single durable page-position transition.
     */
    func testReaderNavigationCoordinatorPersistsHistoryAndExplicitRestoreTarget() {
        let coordinator = BibleReaderNavigationCoordinator()
        let state = NavigationCoordinatorStateBox(
            position: BibleReaderNavigationPosition(book: "Genesis", chapter: 1, verse: 1)
        )
        let pageManager = PageManager()
        let context = makeNavigationCoordinatorContext(
            state: state,
            pageManager: pageManager
        )

        coordinator.navigateTo(book: "Exodus", chapter: 2, verse: 3, context: context)

        XCTAssertEqual(state.position, BibleReaderNavigationPosition(book: "Exodus", chapter: 2, verse: 3))
        XCTAssertEqual(pageManager.bibleBibleBook, 1)
        XCTAssertEqual(pageManager.bibleChapterNo, 2)
        XCTAssertEqual(pageManager.bibleVerseNo, 3)
        XCTAssertEqual(state.history, ["Exod.2.3"])
        XCTAssertEqual(state.persistCount, 1)
        XCTAssertEqual(state.loadCount, 1)
        XCTAssertEqual(coordinator.originalNavigationOrdinalRange, [203, 203])
        XCTAssertEqual(
            coordinator.consumeContentRestoreTarget(
                currentPosition: state.position,
                ordinalForVerse: { _, chapter, verse in chapter * 100 + verse }
            ),
            .ordinal(203)
        )
    }

    /**
     Protects visible-scroll state updates reported by the Vue reader.

     Android treats WebView visible-position callbacks as page-manager updates, not transient UI
     hints. This test scrolls from Genesis into an Exodus key and expects the coordinator to update
     the visible book/chapter/verse, persist the new PageManager position immediately, and preserve a
     restore target for the current visible verse. A failure means iOS can reopen or synchronize a
     stale verse after infinite-scroll movement.
     */
    func testReaderNavigationCoordinatorVisibleScrollUpdatesBookChapterVerseAndPageManager() {
        let coordinator = BibleReaderNavigationCoordinator()
        let state = NavigationCoordinatorStateBox(
            position: BibleReaderNavigationPosition(book: "Genesis", chapter: 1, verse: 1)
        )
        let pageManager = PageManager()
        let context = makeNavigationCoordinatorContext(
            state: state,
            pageManager: pageManager
        )

        let changed = coordinator.updateVisiblePosition(
            ordinal: 205,
            key: "Exod.2",
            atChapterTop: false,
            context: context
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(state.position, BibleReaderNavigationPosition(book: "Exodus", chapter: 2, verse: 5))
        XCTAssertEqual(pageManager.bibleBibleBook, 1)
        XCTAssertEqual(pageManager.bibleChapterNo, 2)
        XCTAssertEqual(pageManager.bibleVerseNo, 5)
        XCTAssertEqual(state.persistCount, 1)
        XCTAssertEqual(state.loadCount, 0)
        XCTAssertEqual(
            coordinator.consumeContentRestoreTarget(
                currentPosition: state.position,
                ordinalForVerse: { _, chapter, verse in chapter * 100 + verse }
            ),
            .ordinal(205)
        )
    }

    /**
     Protects Android-style chapter wrapping and synthetic multi-document blocking.

     The reader host delegates next/previous chapter controls into the same coordinator used by
     bridge navigation. Genesis 50 should wrap to Exodus 1, Exodus 1 should wrap back to Genesis 50,
     and Android synthetic multi documents must not advertise Bible chapter navigation. A failure
     means toolbar, keyboard, swipe, and bridge navigation can diverge.
     */
    func testReaderNavigationCoordinatorChapterWrappingAndMultiDocumentNavigationAvailability() {
        let coordinator = BibleReaderNavigationCoordinator()
        let state = NavigationCoordinatorStateBox(
            position: BibleReaderNavigationPosition(book: "Genesis", chapter: 50, verse: 1)
        )
        let pageManager = PageManager()
        let context = makeNavigationCoordinatorContext(
            state: state,
            pageManager: pageManager
        )

        XCTAssertTrue(coordinator.hasNext(context: context))
        coordinator.navigateNext(context: context)
        XCTAssertEqual(state.position, BibleReaderNavigationPosition(book: "Exodus", chapter: 1, verse: 1))

        coordinator.navigatePrevious(context: context)
        XCTAssertEqual(state.position, BibleReaderNavigationPosition(book: "Genesis", chapter: 50, verse: 1))

        let multiDocumentContext = makeNavigationCoordinatorContext(
            state: state,
            pageManager: pageManager,
            isShowingAndroidMultiDocument: true
        )
        XCTAssertFalse(coordinator.hasNext(context: multiDocumentContext))
        XCTAssertFalse(coordinator.hasPrevious(context: multiDocumentContext))
    }

}
