import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
import BibleView
@testable import SwordKit

/**
 Exercises generic SWORD bookmark seeds through the real bridge and persistence boundaries.

 Each test creates a real RawLD SWORD module, derives a seed from its production raw-fragment API,
 writes through `BibleReaderAnnotationBridgeCoordinator`, parses emitted Vue JSON, and reloads from
 the persisted Android-shaped row. Temporary module roots and SwiftData containers never touch app
 or simulator state.
 */
final class GenericBookmarkSeedIntegrationTests: XCTestCase {
    /**
     Verifies a multi-anchor selected-text seed survives create, reload, and delete boundaries.

     - Setup: Loads exact dictionary OSIS with three `BVA` anchors, uses UTF-16 offsets spanning the
       first and last anchors, and configures an unrelated active Bible identity.
     - Expected result: Persistence and both creation/reload payloads retain exact initials/key,
       local ordinals, paired offsets, flags, and Android text projection; deletion emits the UUID.
     - Failure meaning: Seed integration flattened offsets, reloaded a nearest key, borrowed active Bible
       metadata, or failed to synchronize native deletion with Vue.
     - Side effects: Creates and removes one temporary SWORD tree and an in-memory SwiftData graph.
     */
    func testSelectedSwordSeedRoundTripsBridgePersistenceReloadAndDeletion() throws {
        let fixture = try makeGenericBookmarkSeedIntegrationRawLDFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let module = try XCTUnwrap(manager.module(named: "SEEDDICT"))
        let fragment = try module.rawOSISFragment(forKey: fixture.key)
        XCTAssertGreaterThan(fragment.contentOrdinalRange.upperBound, fragment.contentOrdinalRange.lowerBound)
        let seed = try fragment.genericSelectedTextBookmark(
            ordinalRange: fragment.contentOrdinalRange,
            startOffset: 3,
            endOffset: 5,
            wholeVerse: false
        )

        let container = try makeGenericBookmarkSeedIntegrationModelContainer()
        let modelContext = ModelContext(container)
        let service = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let factory = makeGenericBookmarkSeedIntegrationPayloadFactory(module: module)
        let handler = makeGenericBookmarkSeedIntegrationHandler(
            bridge: bridge,
            service: service,
            payloadFactory: factory
        )

        handler.addGenericBookmark(bridge: bridge, seed: seed, addNote: false)

        let persisted = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<GenericBookmark>()).first
        )
        XCTAssertEqual(persisted.bookInitials, seed.source.bookInitials)
        XCTAssertEqual(persisted.key, seed.source.key)
        XCTAssertEqual(persisted.ordinalStart, seed.ordinalStart)
        XCTAssertEqual(persisted.ordinalEnd, seed.ordinalEnd)
        XCTAssertEqual(persisted.startOffset, seed.startOffset)
        XCTAssertEqual(persisted.endOffset, seed.endOffset)
        XCTAssertEqual(persisted.wholeVerse, seed.wholeVerse)

        let expectedText = androidSelectedTextProjection(
            texts: seed.text,
            startOffset: try XCTUnwrap(seed.startOffset),
            endOffset: try XCTUnwrap(seed.endOffset)
        )
        let created = try XCTUnwrap(
            bridgeEmissionPayload(
                from: recordedScripts(),
                event: "add_or_update_bookmarks"
            ) as? [[String: Any]]
        ).first
        let createdPayload = try XCTUnwrap(created)
        assertSelectedSeedPayload(createdPayload, seed: seed, expectedText: expectedText)
        XCTAssertTrue(createdPayload["osisFragment"] is NSNull)
        XCTAssertFalse(String(describing: createdPayload).contains("ACTIVE-WRONG"))

        let reloadedPayload = try bridgeJSONObject(
            factory.genericBookmarkJSONForStudyPad(persisted)
        )
        assertSelectedSeedPayload(reloadedPayload, seed: seed, expectedText: expectedText)
        XCTAssertTrue(reloadedPayload["osisFragment"] is NSNull)

        let unavailableSourceFactory = BibleReaderAnnotationPayloadFactory(
            currentBook: "Genesis",
            activeModuleName: "ACTIVE-WRONG",
            activeModule: nil,
            sourceModuleResolver: { _ in nil },
            genericSourceResolver: { _, _ in nil },
            bookCatalog: BibleReaderBookCatalog(activeModule: nil, moduleBookList: []),
            unlabeledLabelID: Label.unlabeledId.uuidString
        )
        let unavailableSourcePayload = try bridgeJSONObject(
            unavailableSourceFactory.genericBookmarkJSONForStudyPad(persisted)
        )
        XCTAssertEqual(unavailableSourcePayload["bookInitials"] as? String, seed.source.bookInitials)
        XCTAssertEqual(unavailableSourcePayload["key"] as? String, seed.source.key)
        XCTAssertEqual(unavailableSourcePayload["text"] as? String, "")
        XCTAssertTrue(unavailableSourcePayload["osisFragment"] is NSNull)
        XCTAssertFalse(String(describing: unavailableSourcePayload).contains("ACTIVE-WRONG"))

        handler.removeGenericBookmark(bridge: bridge, bookmarkId: persisted.id.uuidString)
        XCTAssertEqual(
            try XCTUnwrap(
                bridgeEmissionPayload(from: recordedScripts(), event: "delete_bookmarks") as? [String]
            ),
            [persisted.id.uuidString]
        )
        XCTAssertNil(service.genericBookmark(id: persisted.id))
    }

    /**
     Verifies a whole-entry seed retains Android nullability and exact source category on reload.

     - Setup: Creates a whole-entry bookmark from the same real RawLD dictionary fragment.
     - Expected result: Stored ordinals/offsets stay nil, the bridge fragment retains source raw and
       original OSIS plus dictionary metadata, and reload reproduces the same source projection.
     - Failure meaning: Whole-entry state gained synthetic zeroes, lost category/features, or
       reconstructed fragment metadata from an unrelated active source.
     - Side effects: Creates and removes one temporary SWORD tree and an in-memory SwiftData graph.
     */
    func testWholeEntrySwordSeedRetainsNullsCategoryAndRawFragmentAcrossReload() throws {
        let fixture = try makeGenericBookmarkSeedIntegrationRawLDFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let module = try XCTUnwrap(manager.module(named: "SEEDDICT"))
        let rawFragment = try module.rawOSISFragment(forKey: fixture.key)
        let seed = rawFragment.genericWholeEntryBookmark()

        let container = try makeGenericBookmarkSeedIntegrationModelContainer()
        let modelContext = ModelContext(container)
        let service = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let (bridge, recordedScripts) = makeRecordingBridge()
        let factory = makeGenericBookmarkSeedIntegrationPayloadFactory(module: module)
        let handler = makeGenericBookmarkSeedIntegrationHandler(
            bridge: bridge,
            service: service,
            payloadFactory: factory
        )

        handler.addGenericBookmark(bridge: bridge, seed: seed, addNote: false)

        let persisted = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<GenericBookmark>()).first
        )
        XCTAssertNil(persisted.ordinalStart)
        XCTAssertNil(persisted.ordinalEnd)
        XCTAssertNil(persisted.startOffset)
        XCTAssertNil(persisted.endOffset)
        XCTAssertTrue(persisted.wholeVerse)

        let createdRows = try XCTUnwrap(
            bridgeEmissionPayload(
                from: recordedScripts(),
                event: "add_or_update_bookmarks"
            ) as? [[String: Any]]
        )
        let createdPayload = try XCTUnwrap(createdRows.first)
        assertWholeEntrySeedPayload(createdPayload, seed: seed)

        let reloadedPayload = try bridgeJSONObject(
            factory.genericBookmarkJSONForStudyPad(persisted)
        )
        assertWholeEntrySeedPayload(reloadedPayload, seed: seed)
    }
}

/** Exact expected Android `BookmarkControl.addText` projection for a multi-anchor selection. */
private struct GenericBookmarkSeedIntegrationAndroidSelectedTextProjection {
    /// Trimmed selected text.
    let text: String
    /// Selected range reconstructed with first/last unselected text.
    let fullText: String
    /// Reconstructed range with selected text wrapped in `<b>`.
    let highlightedText: String
}

/** Temporary real RawLD module used by one seed integration test. */
private struct GenericBookmarkSeedIntegrationRawLDFixture {
    /// SWORD root containing `mods.d` and RawLD data files.
    let root: URL
    /// Exact dictionary key written into the fixture.
    let key: String
}

/** Deterministic generic bookmark seed fixture-construction failure. */
private enum GenericBookmarkSeedIntegrationRawLDFixtureError: Error {
    /// A key/XML record exceeded RawLD's fixed-width index representation.
    case recordTooLarge
}

/**
 Builds a real dictionary module whose text spans multiple source `BVA` anchors.

 - Returns: Temporary SWORD root and exact source key.
 - Side effects: Writes one config, RawLD data file, and RawLD index file under a UUID directory.
 - Failure modes: Propagates filesystem errors and rejects records too large for RawLD indexes.
 */
private func makeGenericBookmarkSeedIntegrationRawLDFixture() throws
    -> GenericBookmarkSeedIntegrationRawLDFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let modsDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
    let dataDirectory = root.appendingPathComponent(
        "modules/lexdict/rawld/seeddict",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

    let key = "ENTRY-EXACT"
    let xml = """
    <entryFree n="ENTRY-EXACT"><orth>exact</orth><p>A😀lpha start. </p><p>Middle segment. </p><p>Omega finish.</p></entryFree>
    """
    let record = Data("\(key)\r\n\(xml)".utf8)
    guard record.count <= Int(UInt16.max) else {
        throw GenericBookmarkSeedIntegrationRawLDFixtureError.recordTooLarge
    }
    var index = Data()
    index.appendGenericBookmarkSeedIntegrationLittleEndian(UInt32(0))
    index.appendGenericBookmarkSeedIntegrationLittleEndian(UInt16(record.count))
    var data = record
    data.append(0x0A)

    let prefix = dataDirectory.appendingPathComponent("seeddict", isDirectory: false)
    try data.write(to: prefix.appendingPathExtension("dat"))
    try index.write(to: prefix.appendingPathExtension("idx"))
    try """
    [SEEDDICT]
    Description=Generic Bookmark Seed Dictionary
    Abbreviation=A2D
    Category=Lexicons / Dictionaries
    DataPath=./modules/lexdict/rawld/seeddict/seeddict
    ModDrv=RawLD
    SourceType=OSIS
    Encoding=UTF-8
    Lang=grc
    Feature=GreekDef
    """.write(
        to: modsDirectory.appendingPathComponent("seeddict.conf", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )
    return GenericBookmarkSeedIntegrationRawLDFixture(root: root, key: key)
}

/** Builds the in-memory bookmark schema used by generic bookmark seed integration tests. */
private func makeGenericBookmarkSeedIntegrationModelContainer() throws -> ModelContainer {
    let schema = Schema([
        BibleBookmark.self,
        BibleBookmarkNotes.self,
        BibleBookmarkToLabel.self,
        GenericBookmark.self,
        GenericBookmarkNotes.self,
        GenericBookmarkToLabel.self,
        Label.self,
        StudyPadTextEntry.self,
        StudyPadTextEntryText.self,
    ])
    return try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
    )
}

/**
 Builds a stored-source-aware production payload factory for one exact module.

 - Parameter module: Real SWORD module that produced the tested seed.
 - Returns: Factory whose active Bible identity is deliberately unrelated to the source module.
 - Side effects: None during construction; payload reload may move the module cursor.
 - Failure modes: Unknown initials resolve to no source rather than the active Bible.
 */
private func makeGenericBookmarkSeedIntegrationPayloadFactory(
    module: SwordModule
) -> BibleReaderAnnotationPayloadFactory {
    BibleReaderAnnotationPayloadFactory(
        currentBook: "Genesis",
        activeModuleName: "ACTIVE-WRONG",
        activeModule: nil,
        sourceModuleResolver: { initials in
            initials == module.info.name ? module : nil
        },
        genericSourceResolver: { _, _ in nil },
        bookCatalog: BibleReaderBookCatalog(activeModule: nil, moduleBookList: []),
        unlabeledLabelID: Label.unlabeledId.uuidString
    )
}

/** Builds the production annotation handler and coordinator with inert reader-state callbacks. */
private func makeGenericBookmarkSeedIntegrationHandler(
    bridge: BibleBridge,
    service: BookmarkService,
    payloadFactory: BibleReaderAnnotationPayloadFactory
) -> BibleReaderAnnotationBridgeHandler {
    let coordinator = BibleReaderAnnotationBridgeCoordinator(
        bridge: bridge,
        bookmarkService: service,
        payloadFactory: payloadFactory,
        currentBook: "Genesis",
        verifiedKJVAOrdinalRange: { _, _, _ in nil },
        currentNotesContentType: { "HTML" },
        workspaceSettings: { nil },
        setWorkspaceSettings: { _ in },
        persistState: {},
        incrementMyNotesRevision: {},
        incrementStudyPadRevision: {},
        trackRecentLabel: { _ in },
        sendLabels: {},
        buildConfigJSON: { "{}" }
    )
    return BibleReaderAnnotationBridgeHandler(
        coordinator: { _ in coordinator },
        bookmarkService: { service },
        isShowingMyNotes: { false },
        isShowingStudyPad: { false },
        activeStudyPadLabelId: { nil },
        currentChapterMyNotesBookmarks: { [] },
        setEditingInWebView: { _ in },
        assignLabels: { _ in }
    )
}

/**
 Computes Android's multi-anchor generic selection text oracle with UTF-16 offsets.

 - Parameters:
   - texts: Ordered source anchor texts for the selected local ordinal range.
   - startOffset: UTF-16 offset in the first anchor.
   - endOffset: UTF-16 offset in the last anchor.
 - Returns: Android `text`, `fullText`, and `highlightedText` values.
 - Side effects: None.
 - Failure modes: Returns empty fields when the fixture unexpectedly contains no anchor text.
 */
private func androidSelectedTextProjection(
    texts: [String],
    startOffset: Int,
    endOffset: Int
) -> GenericBookmarkSeedIntegrationAndroidSelectedTextProjection {
    guard let firstText = texts.first else {
        return GenericBookmarkSeedIntegrationAndroidSelectedTextProjection(
            text: "",
            fullText: "",
            highlightedText: ""
        )
    }
    let first = firstText as NSString
    let start = max(0, min(startOffset, first.length))
    let prefix = first.substring(with: NSRange(location: 0, length: start))
    if texts.count == 1 {
        let end = max(start, min(endOffset, first.length))
        let selected = first.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = first.substring(with: NSRange(location: end, length: first.length - end))
        return GenericBookmarkSeedIntegrationAndroidSelectedTextProjection(
            text: selected,
            fullText: "\(prefix)\(selected)\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines),
            highlightedText: "\(prefix)<b>\(selected)</b>\(suffix)"
        )
    }
    let firstSelection = first.substring(
        with: NSRange(location: start, length: first.length - start)
    )
    let last = (texts.last ?? "") as NSString
    let end = max(0, min(endOffset, last.length))
    let lastSelection = last.substring(with: NSRange(location: 0, length: end))
    let suffix = last.substring(with: NSRange(location: end, length: last.length - end))
    let middle = texts.count > 2 ? texts[1..<(texts.count - 1)].joined(separator: " ") : ""
    let selected = "\(firstSelection)\(middle)\(lastSelection)"
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return GenericBookmarkSeedIntegrationAndroidSelectedTextProjection(
        text: selected,
        fullText: "\(prefix)\(selected)\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines),
        highlightedText: "\(prefix)<b>\(selected)</b>\(suffix)"
    )
}

/** Asserts selected-seed persistence metadata and Android text fields in one parsed bridge row. */
private func assertSelectedSeedPayload(
    _ payload: [String: Any],
    seed: SwordGenericBookmarkSeed,
    expectedText: GenericBookmarkSeedIntegrationAndroidSelectedTextProjection,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(payload["bookInitials"] as? String, seed.source.bookInitials, file: file, line: line)
    XCTAssertEqual(payload["bookName"] as? String, seed.source.bookName, file: file, line: line)
    XCTAssertEqual(payload["bookAbbreviation"] as? String, seed.source.bookAbbreviation, file: file, line: line)
    XCTAssertEqual(payload["key"] as? String, seed.source.key, file: file, line: line)
    XCTAssertEqual(payload["keyName"] as? String, seed.source.keyName, file: file, line: line)
    XCTAssertEqual(payload["ordinalRange"] as? [Int], seed.ordinalRange.compactMap { $0 }, file: file, line: line)
    XCTAssertEqual(payload["offsetRange"] as? [Int], seed.offsetRange?.compactMap { $0 }, file: file, line: line)
    XCTAssertEqual(payload["wholeVerse"] as? Bool, seed.wholeVerse, file: file, line: line)
    XCTAssertEqual(payload["text"] as? String, expectedText.text, file: file, line: line)
    XCTAssertEqual(payload["fullText"] as? String, expectedText.fullText, file: file, line: line)
    XCTAssertEqual(payload["highlightedText"] as? String, expectedText.highlightedText, file: file, line: line)
}

/** Asserts whole-entry nullability and exact generic source fragment metadata. */
private func assertWholeEntrySeedPayload(
    _ payload: [String: Any],
    seed: SwordGenericBookmarkSeed,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let ordinals = payload["ordinalRange"] as? [Any]
    XCTAssertEqual(ordinals?.count, 2, file: file, line: line)
    XCTAssertTrue(ordinals?[0] is NSNull, file: file, line: line)
    XCTAssertTrue(ordinals?[1] is NSNull, file: file, line: line)
    XCTAssertTrue(payload["offsetRange"] is NSNull, file: file, line: line)
    XCTAssertTrue(payload["wholeVerse"] as? Bool == true, file: file, line: line)
    XCTAssertEqual(payload["bookInitials"] as? String, seed.source.bookInitials, file: file, line: line)
    XCTAssertEqual(payload["key"] as? String, seed.source.key, file: file, line: line)
    let fragment = payload["osisFragment"] as? [String: Any]
    XCTAssertEqual(fragment?["key"] as? String, seed.source.osisFragment.fragmentKey, file: file, line: line)
    XCTAssertEqual(fragment?["keyName"] as? String, seed.source.keyName, file: file, line: line)
    XCTAssertEqual(fragment?["bookCategory"] as? String, DocumentCategory.dictionary.rawValue, file: file, line: line)
    XCTAssertEqual(fragment?["bookInitials"] as? String, seed.source.bookInitials, file: file, line: line)
    XCTAssertEqual(fragment?["xml"] as? String, seed.source.osisFragment.xml, file: file, line: line)
    XCTAssertEqual(fragment?["originalXml"] as? String, seed.source.osisFragment.originalXML, file: file, line: line)
    let features = fragment?["features"] as? [String: Any]
    XCTAssertEqual(features?["type"] as? String, "greek", file: file, line: line)
    XCTAssertEqual(features?["keyName"] as? String, seed.source.keyName, file: file, line: line)
    XCTAssertTrue(fragment?["v11n"] is NSNull, file: file, line: line)
    XCTAssertTrue(fragment?["ordinalRange"] is NSNull, file: file, line: line)
}

private extension Data {
    /** Appends one integer in the little-endian width used by SWORD RawLD index files. */
    mutating func appendGenericBookmarkSeedIntegrationLittleEndian<T: FixedWidthInteger>(
        _ value: T
    ) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
