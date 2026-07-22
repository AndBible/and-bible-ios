import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

/**
 Controller integration tests for exact Bible and generic bookmark destinations.

 Each test uses an isolated SWORD tree and an in-memory recording bridge. Temporary module files are
 removed by the inherited fixture teardown; no test touches network or shared persistence.
 */
final class BibleReaderBookmarkNavigationIntegrationTests: BibleUISwordFixtureTestCase {
    /**
     Verifies a Bible bookmark commits the complete mapped range in the active module.

     - Side effects: Loads one fixture chapter and records reader bridge events.
     - Failure modes: Fails if controller integration substitutes a module, drops the range endpoint,
       or emits a single-verse setup highlight.
     */
    @MainActor
    func testBibleTargetCommitsCompleteMappedRangeToActiveModule() throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let sourceStart = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let sourceEnd = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 3)
        )
        let kjvaStart = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1)
        )
        let kjvaEnd = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 3)
        )
        let target = BookmarkNavigationTarget.bible(.init(
            sourceModuleInitials: "KJV",
            sourceVersification: "KJV",
            sourceOrdinalRange: sourceStart...sourceEnd,
            sourceOSISReference: "Gen.1.1-Gen.1.3",
            kjvaOrdinalRange: kjvaStart...kjvaEnd,
            kjvaOSISReference: "Gen.1.1-Gen.1.3"
        ))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        try controller.navigate(toBookmarkTarget: target)

        let setup = try XCTUnwrap(
            bridgeEmissionPayload(
                from: Array(scripts().dropFirst(baseline)),
                event: "setup_content"
            ) as? [String: Any]
        )
        XCTAssertEqual(controller.activeModuleName, "KJV")
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 1)
        XCTAssertEqual(setup["ordinalStart"] as? Int, sourceStart)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, sourceEnd)
        XCTAssertEqual(setup["highlight"] as? Bool, true)
    }

    /**
     Verifies an exact generic target emits one owning-module document and one scoped setup payload.

     - Side effects: Writes one RawLD dictionary, resolves its exact structural fragment, and records
       one controller navigation.
     - Failure modes: Fails if controller integration borrows the active Bible, chooses another key,
       drops the BVA range, or emits duplicate content.
     */
    @MainActor
    func testGenericTargetCommitsExactModuleKeyAndSelectionOnce() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeBookmarkNavigationRawLDModule(
            named: "BOOKNAV",
            entries: [
                ("G0001", "<div><p>Exact dictionary entry.</p></div>"),
                ("G0002", "<div><p>Neighbor entry.</p></div>"),
            ],
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "BOOKNAV"))
        let fragment = try module.rawOSISFragment(forKey: "G0001")
        let available = fragment.keyOrdinalRange ?? fragment.contentOrdinalRange
        let selected = available.lowerBound...available.lowerBound
        let target = BookmarkNavigationTarget.generic(.init(
            moduleInitials: "BOOKNAV",
            key: "G0001",
            ordinalRange: selected
        ))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count

        try controller.navigate(toBookmarkTarget: target)

        let emissions = Array(scripts().dropFirst(baseline))
        let documentEmissions = emissions.filter { $0.contains("bibleView.emit('add_documents', ") }
        let document = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "add_documents") as? [String: Any]
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emissions, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(documentEmissions.count, 1)
        XCTAssertEqual(document["bookInitials"] as? String, "BOOKNAV")
        XCTAssertEqual(document["key"] as? String, "G0001")
        XCTAssertEqual(setup["bookInitials"] as? String, "BOOKNAV")
        XCTAssertEqual(setup["osisRef"] as? String, "G0001")
        XCTAssertEqual(setup["ordinalStart"] as? Int, selected.lowerBound)
        XCTAssertEqual(setup["ordinalEnd"] as? Int, selected.upperBound)
        XCTAssertEqual(controller.currentCategory, .dictionary)
        XCTAssertEqual(controller.activeModuleName(for: .dictionary), "BOOKNAV")
    }

    /**
     Verifies a missing exact generic key performs no reader or bridge mutation.

     - Side effects: Writes one RawLD dictionary and attempts one invalid navigation.
     - Failure modes: Fails if the controller falls back to a neighboring/current key or clears the
       existing document before exact planning succeeds.
     */
    @MainActor
    func testMissingGenericKeyFailsBeforeReaderMutation() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try writeBookmarkNavigationRawLDModule(
            named: "BOOKNAV",
            entries: [("ONLY", "<div><p>Only exact entry.</p></div>")],
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bridgeDidSetClientReady(bridge)
        let baseline = scripts().count
        let originalCategory = controller.currentCategory

        XCTAssertThrowsError(
            try controller.navigate(
                toBookmarkTarget: .generic(.init(
                    moduleInitials: "BOOKNAV",
                    key: "MISSING",
                    ordinalRange: nil
                ))
            )
        )

        XCTAssertEqual(scripts().count, baseline)
        XCTAssertEqual(controller.currentCategory, originalCategory)
        XCTAssertNil(controller.activeModuleName(for: .dictionary))
    }
}

/** Errors raised while writing the test-only RawLD fixture. */
private enum BookmarkNavigationFixtureError: Error {
    /// RawLD records exceeded their fixed index widths.
    case recordTooLarge
}

/**
 Writes a deterministic dictionary with exact lexical keys into an isolated SWORD root.

 - Parameters:
   - moduleName: Stable installed module initials.
   - entries: Exact key and structural OSIS body pairs.
   - modulePath: Existing temporary SWORD root.
 - Side effects: Writes one config plus RawLD data and index files.
 - Failure modes: Propagates filesystem errors and rejects records beyond RawLD index widths.
 */
private func writeBookmarkNavigationRawLDModule(
    named moduleName: String,
    entries: [(String, String)],
    in modulePath: String
) throws {
    let key = moduleName.lowercased()
    let root = URL(fileURLWithPath: modulePath, isDirectory: true)
    let modsDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
    let dataDirectory = root.appendingPathComponent(
        "modules/lexdict/rawld/\(key)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

    var data = Data()
    var index = Data()
    for (entryKey, xml) in entries {
        let record = Data("\(entryKey)\r\n\(xml)".utf8)
        guard record.count <= Int(UInt16.max), data.count <= Int(UInt32.max) else {
            throw BookmarkNavigationFixtureError.recordTooLarge
        }
        index.appendBookmarkNavigationLittleEndian(UInt32(data.count))
        index.appendBookmarkNavigationLittleEndian(UInt16(record.count))
        data.append(record)
        data.append(0x0A)
    }

    let prefix = dataDirectory.appendingPathComponent(key, isDirectory: false)
    try data.write(to: prefix.appendingPathExtension("dat"))
    try index.write(to: prefix.appendingPathExtension("idx"))
    try """
    [\(moduleName)]
    Description=Bookmark Navigation Dictionary
    Abbreviation=\(moduleName)
    Category=Lexicons / Dictionaries
    DataPath=./modules/lexdict/rawld/\(key)/\(key)
    ModDrv=RawLD
    SourceType=OSIS
    Encoding=UTF-8
    Lang=en
    """.write(
        to: modsDirectory.appendingPathComponent("\(key).conf", isDirectory: false),
        atomically: true,
        encoding: .utf8
    )
}

private extension Data {
    /** Appends one RawLD index integer in little-endian order. */
    mutating func appendBookmarkNavigationLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
