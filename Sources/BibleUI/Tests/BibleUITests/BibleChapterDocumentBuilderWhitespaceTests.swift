import Foundation
import SwordKit
import XCTest

@testable import BibleUI

/** Protects source repair and Java-significant whitespace through reader chapter XML emission. */
final class BibleChapterDocumentBuilderWhitespaceTests: XCTestCase {
    /**
     Verifies historical NETtext split section tags cannot invalidate the Vue chapter template.

     - Setup: Builds a licensed-safe RawText Bible whose verse-zero introduction opens NETtext's
       chapter section and whose final populated verse carries the orphan terminal close.
     - Expected result: Pinned JSword repair balances/drops the entry-local structure, the chapter
       remains well-formed XML, and both synthetic verse wrappers retain visible content.
     - Failure meaning: The reader can emit Vue compiler error 24 and show an entirely blank chapter
       even though SWORD returned real verse text.
     - Side effects: Writes and opens one temporary native SWORD tree, parses its chapter XML, and
       removes the fixture root before returning.
     */
    func testSplitNETtextSectionTagsProduceWellFormedChapterXML() throws {
        let fixture = try makeSplitSectionRawTextFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let builder = BibleChapterDocumentBuilder(module: fixture.module, includeHeadings: true)
        let chapter = try XCTUnwrap(builder.loadChapter(osisBookId: "Gen", chapter: 1))
        let xml = chapter.xml

        let parser = XMLParser(data: Data(xml.utf8))
        XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "XML parse failed")
        XCTAssertEqual(chapter.verseCount, 2)
        XCTAssertTrue(xml.contains("Opening verse"))
        XCTAssertTrue(xml.contains("Closing verse"))
    }

    /**
     Verifies the chapter builder does not pre-trim NBSP before structured verse projection.

     - Setup: Builds one emitted verse from raw OSIS with ordinary outer whitespace surrounding
       leading/trailing NBSP content.
     - Expected result: The lossless shared projector retains ordinary source edges and both NBSP;
       the builder adds only its established inter-verse trailing space.
     - Failure meaning: Reader display and Search canonical text can observe different source bytes
       because the chapter caller reapplied Foundation's broader whitespace rules.
     - Side effects: Parses one bounded in-memory verse fragment.
     */
    func testVerseChunkEmissionPreservesEdgeNBSP() {
        let xml = BibleChapterDocumentBuilder.buildVerseChunkXML(
            osisBookId: "Gen",
            chapter: 1,
            verses: [
                BibleChapterDocumentBuilder.VerseEntry(
                    verse: 1,
                    ordinal: 4,
                    xml: " \n\u{00A0}edge\u{00A0}\n "
                ),
            ]
        )

        XCTAssertEqual(
            xml,
            "<div><verse osisID=\"Gen.1.1\" verseOrdinal=\"4\"> \n\u{00A0}edge\u{00A0}\n  </verse></div>"
        )
    }

    /**
     Builds a licensed-safe RawText Bible with NETtext's split chapter-section topology.

     - Returns: Temporary module root plus its live SWORD module; the caller owns cleanup.
     - Side effects: Writes one configuration, Old Testament payload, and fixed-width verse index.
     - Failure modes: Propagates filesystem errors and fails unwrapping when libsword cannot discover
       the synthetic module, because that leaves the production reader path untested.
     */
    private func makeSplitSectionRawTextFixture() throws -> (
        root: URL,
        manager: SwordManager,
        module: SwordModule
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-section-reader-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/texts/rawtext/splitsection",
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
        [SPLITSECTION]
        Description=Split Section Reader Fixture
        DataPath=./modules/texts/rawtext/splitsection/
        ModDrv=RawText
        SourceType=OSIS
        Encoding=UTF-8
        Lang=en
        Versification=KJV
        """
        try Data(configuration.utf8).write(
            to: configDirectory.appendingPathComponent("splitsection.conf")
        )

        var textData = Data()
        var indexData = Data()
        for source in [
            "",
            "",
            "",
            "<div type=\"section\" scope=\"Gen.1\">",
            "Opening verse",
            "Closing verse</div>",
        ] {
            let bytes = Data(source.utf8)
            appendRawVerseIndex(
                offset: UInt32(textData.count),
                size: UInt16(bytes.count),
                to: &indexData
            )
            textData.append(bytes)
            if !bytes.isEmpty {
                textData.append(0x0A)
            }
        }
        try textData.write(to: dataDirectory.appendingPathComponent("ot"))
        try indexData.write(to: dataDirectory.appendingPathComponent("ot.vss"))
        try Data().write(to: dataDirectory.appendingPathComponent("nt"))
        try Data().write(to: dataDirectory.appendingPathComponent("nt.vss"))

        let manager = try XCTUnwrap(SwordManager(modulePath: root.path))
        return (root, manager, try XCTUnwrap(manager.module(named: "SPLITSECTION")))
    }

    /**
     Appends one RawText little-endian `(offset, size)` verse-index record.

     - Parameters:
       - offset: Byte offset into the matching text payload.
       - size: Exact entry byte count, excluding the fixture separator.
       - data: Mutable index buffer receiving one six-byte record.
     - Side effects: Appends six deterministic bytes to `data`.
     - Failure modes: None; the fixture builder supplies bounded UInt32/UInt16 values.
     */
    private func appendRawVerseIndex(offset: UInt32, size: UInt16, to data: inout Data) {
        var littleEndianOffset = offset.littleEndian
        var littleEndianSize = size.littleEndian
        withUnsafeBytes(of: &littleEndianOffset) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &littleEndianSize) { data.append(contentsOf: $0) }
    }
}
