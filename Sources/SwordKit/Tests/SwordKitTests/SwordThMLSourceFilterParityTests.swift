// SwordThMLSourceFilterParityTests.swift — Real native ThML conversion parity

import Foundation
import XCTest
@testable import SwordKit

/**
 Verifies native ThML modules use Android's structural JSword conversion boundary.

 Tests construct real SWORD drivers and data files instead of passing already-converted XML into a
 helper. Each fixture is isolated under a temporary directory and removed before the test returns.
 */
final class SwordThMLSourceFilterParityTests: XCTestCase {
    /**
     Verifies a real RawCom ThML entry survives JSword's repair ladder and preserves semantics.

     - Setup: Installs a synthetic KJV RawCom commentary whose Matthew 1:1 source contains a bare
       ampersand, an HTML-style open `br`, italic markup, and a relative `scripRef`.
     - Expected result: The public raw-fragment API returns renderable commentary, preserves visible
       text/italics/line break, and resolves the scripture reference to canonical `Matt.1.2` OSIS.
     - Side effects: Creates and removes one temporary SWORD module tree and exercises the native
       module cursor under `SwordRuntime`.
     - Failure meaning: iOS has regressed to malformed libsword `ThMLOSIS`, lost Android cleanup/tag
       semantics, or bypassed the shared converter on a public reader path.
     */
    func testRawComThMLUsesJSwordRepairAndCanonicalReferenceConversion() throws {
        let root = try makeRawComThMLFixture(
            source: "Barnes & companion<br><i>Italic note</i> "
                + #"<scripRef passage="Mt 1:2">Matthew link</scripRef>"#
                + #" <scripRef passage="Mk 7:34, Mt 27:46">Two links</scripRef>"#
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = try XCTUnwrap(SwordManager(modulePath: root.path))
        let module = try XCTUnwrap(manager.module(named: "THMLCOMMENTARY"))
        let fragment = try module.rawOSISFragment(forKey: "Matt.1.1")

        XCTAssertEqual(fragment.key, "Matt.1.1")
        XCTAssertTrue(fragment.hasRenderableContent)
        XCTAssertTrue(fragment.comparablePlainText?.contains("Barnes & companion") == true)
        XCTAssertTrue(fragment.originalXML.contains("<lb/>"))
        XCTAssertTrue(fragment.originalXML.contains(#"<hi type="italic">Italic note</hi>"#))
        XCTAssertTrue(
            fragment.originalXML.contains(
                #"<reference osisRef="Matt.1.2">Matthew link</reference>"#
            )
        )
        XCTAssertTrue(
            fragment.originalXML.contains(
                #"<reference osisRef="Mark.7.34 Matt.27.46">Two links</reference>"#
            )
        )
    }

    /**
     Verifies a nonempty ThML entry whose entire source is skipped does not invent verse content.

     - Setup: Installs a RawCom entry containing only a pinned JSword-skipped `script` subtree.
     - Expected result: Exact source inspection returns an empty OSIS fragment instead of wrapping
       the removed subtree in an empty generated verse.
     - Side effects: Creates and removes one temporary SWORD module tree and briefly moves its
       native cursor under `SwordRuntime`.
     - Failure meaning: Empty filtered content becomes a false positive that reader/Search callers
       can mistake for an installed verse.
     */
    func testRawComThMLDoesNotWrapCompletelySkippedContent() throws {
        let root = try makeRawComThMLFixture(source: "<script>hidden source</script>")
        defer { try? FileManager.default.removeItem(at: root) }

        let manager = try XCTUnwrap(SwordManager(modulePath: root.path))
        let module = try XCTUnwrap(manager.module(named: "THMLCOMMENTARY"))
        let inspection = try module.inspectVerseKeyOSISSourceRestoringPrevious("=Matt.1.1")

        XCTAssertEqual(inspection.verseKey?.osisRef, "Matt.1.1")
        XCTAssertTrue(inspection.osisFragment.isEmpty)
    }

    /**
     Creates one physical RawCom commentary with Matthew 1:1 at the pinned KJV NT index slot.

     - Parameter source: Exact UTF-8 ThML source stored for Matthew 1:1.
     - Returns: Temporary SWORD root containing config, NT data/index, and empty OT files.
     - Side effects: Writes a unique directory beneath the process temporary directory.
     - Failure modes: Propagates filesystem writes and rejects source larger than RawVerse's
       two-byte record-length field.
     */
    private func makeRawComThMLFixture(source: String) throws -> URL {
        let sourceBytes = Data(source.utf8)
        guard sourceBytes.count <= Int(UInt16.max) else {
            throw SwordThMLFixtureError.entryTooLarge
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/comments/rawcom/thmlcommentary",
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

        var ntIndex = Data(repeating: 0, count: 8_246 * 6)
        writeRawVerseIndexRecord(
            offset: 0,
            length: UInt16(sourceBytes.count),
            at: 4,
            in: &ntIndex
        )
        try sourceBytes.write(to: dataDirectory.appendingPathComponent("nt"))
        try ntIndex.write(to: dataDirectory.appendingPathComponent("nt.vss"))
        try Data().write(to: dataDirectory.appendingPathComponent("ot"))
        try Data(repeating: 0, count: 24_115 * 6).write(
            to: dataDirectory.appendingPathComponent("ot.vss")
        )

        try """
        [THMLCOMMENTARY]
        Description=Synthetic ThML Commentary
        Category=Commentaries
        ModDrv=RawCom
        DataPath=./modules/comments/rawcom/thmlcommentary/
        SourceType=ThML
        Encoding=UTF-8
        Lang=en
        Versification=KJV
        """.write(
            to: configDirectory.appendingPathComponent("thmlcommentary.conf"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    /**
     Writes one RawVerse six-byte little-endian `(offset,length)` index record.

     - Parameters:
       - offset: Byte offset into the testament data file.
       - length: Entry byte count.
       - record: Zero-based KJV index slot.
       - index: Mutable complete `.vss` buffer.
     - Side effects: Replaces exactly six bytes in `index`.
     - Failure modes: Test fixtures provide an in-range slot; an invalid slot triggers Swift's
       normal collection bounds precondition rather than writing a corrupt fixture.
     */
    private func writeRawVerseIndexRecord(
        offset: UInt32,
        length: UInt16,
        at record: Int,
        in index: inout Data
    ) {
        let start = record * 6
        index[start] = UInt8(offset & 0x0000_00ff)
        index[start + 1] = UInt8((offset >> 8) & 0x0000_00ff)
        index[start + 2] = UInt8((offset >> 16) & 0x0000_00ff)
        index[start + 3] = UInt8((offset >> 24) & 0x0000_00ff)
        index[start + 4] = UInt8(length & 0x00ff)
        index[start + 5] = UInt8((length >> 8) & 0x00ff)
    }
}

/** Fixture-construction failures that are clearer than truncating a RawVerse record. */
private enum SwordThMLFixtureError: Error {
    /// Source cannot fit RawVerse's two-byte length field.
    case entryTooLarge
}
