import Foundation
import XCTest
@testable import BibleCore
@testable import SwordKit

/**
 Native SWORD cursor-level coverage for the backend-neutral Bible Search source adapter.

 The suite builds isolated real RawText modules to verify production traversal, structured OSIS
 capture, per-entry repair isolation, and cursor restoration. Tests own and remove every temporary
 module tree; a failure means the adapter no longer proves behavior against the native backend.
 */
final class SwordBibleSearchIndexAdapterTests: XCTestCase {
    /**
     Exercises the native SWORD adapter across valid, repairable, then valid current-entry OSIS.

     - Setup: Builds a minimal real RawText/OSIS module at Genesis 1:1-3, leaves 1:2 malformed, and
       positions its cursor at John 3:16 before streaming through `BibleSearchIndexSource`.
     - Expected result: All three entries carry their own current-cursor structured text, entry 2's
       note is repaired and omitted, traversal continues to entry 3, and key plus ordinal restore.
     - Failure meaning: The adapter can pair coordinates with stale OSIS, abort a Bible after one bad
       verse, silently use strip text, or leak its traversal cursor into reader state.
     - Side effects: Creates and removes one isolated native SWORD module tree.
     */
    func testNativeSwordAdapterRepairsCurrentOSISContinuesAndRestoresCursor() throws {
        let fixture = try makeRawSwordSearchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.module.setKey("John 3:16")
        let originalKey = fixture.module.currentKey()
        let originalIndex = fixture.module.currentVerseKeyIndex()
        var entries: [BibleSearchIndexEntry] = []

        try fixture.module.forEachSearchIndexEntry { entry in
            entries.append(entry)
            return entries.count < 3
        }

        XCTAssertEqual(entries.map(\.verse), [1, 2, 3])
        XCTAssertEqual(entries.map(\.entryOrder), [4, 5, 6])
        XCTAssertEqual(
            entries.map(\.indexText),
            ["First current entry", "Broken", "Third  entry"]
        )
        XCTAssertEqual(
            entries.map(\.previewText),
            ["First current entry", "Broken ", "Third entry"]
        )
        XCTAssertTrue(entries[0].sourceMarkup.contains("<hi>current</hi>"))
        XCTAssertTrue(entries[1].sourceMarkup.contains("not closed"))
        XCTAssertTrue(entries[2].sourceMarkup.contains("<note>hidden</note>"))
        XCTAssertEqual(fixture.module.currentKey(), originalKey)
        XCTAssertEqual(fixture.module.currentVerseKeyIndex(), originalIndex)
    }

    /**
     Builds a real sparse RawText module whose middle OSIS entry is intentionally malformed.

     - Returns: Temporary module root, its live manager, and the fixture's installed Bible module.
     - Throws: File-system write failures or an XCTest unwrap failure if the native fixture cannot
       be loaded, which means the adapter regression has no valid backend evidence.
     - Side effects: Creates a unique temporary CrossWire tree containing configuration, text, and
       verse-index files; the caller owns recursive cleanup of the returned root.
     - Note: The first four empty records align Genesis 1:1 with RawText's KJV ordinal layout, while
       the next three records deliberately cover valid, repairable, and valid structured OSIS.
     */
    private func makeRawSwordSearchFixture() throws -> (
        root: URL,
        manager: SwordManager,
        module: SwordModule
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-sword-search-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/texts/rawtext/searchfixture",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dataDirectory,
            withIntermediateDirectories: true
        )
        let configuration = """
        [SEARCHFIXTURE]
        Description=Search Projection Fixture
        DataPath=./modules/texts/rawtext/searchfixture/
        ModDrv=RawText
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        Versification=KJV
        """
        try Data(configuration.utf8).write(
            to: configDirectory.appendingPathComponent("searchfixture.conf")
        )

        var textData = Data()
        var indexData = Data()
        for _ in 0..<4 {
            appendRawVerseIndex(offset: 0, size: 0, to: &indexData)
        }
        for source in [
            "First <hi>current</hi> entry",
            "Broken <note>not closed",
            "Third <note>hidden</note> entry",
        ] {
            let bytes = Data(source.utf8)
            appendRawVerseIndex(
                offset: UInt32(textData.count),
                size: UInt16(bytes.count),
                to: &indexData
            )
            textData.append(bytes)
            textData.append(0x0A)
        }
        try textData.write(to: dataDirectory.appendingPathComponent("ot"))
        try indexData.write(to: dataDirectory.appendingPathComponent("ot.vss"))
        try Data().write(to: dataDirectory.appendingPathComponent("nt"))
        try Data().write(to: dataDirectory.appendingPathComponent("nt.vss"))

        let manager = try XCTUnwrap(SwordManager(modulePath: root.path))
        return (root, manager, try XCTUnwrap(manager.module(named: "SEARCHFIXTURE")))
    }

    /**
     Appends one native RawText verse-index record in the backend's fixed little-endian layout.

     - Parameters:
       - offset: Byte offset of the verse payload within the corresponding RawText data file.
       - size: Exact payload byte count, excluding the fixture's trailing newline separator.
       - data: Mutable index buffer that receives one six-byte `(UInt32, UInt16)` record.
     - Side effects: Appends six deterministic bytes to `data`; no file I/O occurs here.
     - Failure modes: None; callers must ensure the supplied offset and size describe their payload.
     */
    private func appendRawVerseIndex(offset: UInt32, size: UInt16, to data: inout Data) {
        var littleEndianOffset = offset.littleEndian
        var littleEndianSize = size.littleEndian
        withUnsafeBytes(of: &littleEndianOffset) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &littleEndianSize) { data.append(contentsOf: $0) }
    }
}
