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
     Verifies reader chapters apply JSword's configured source filter before OSIS repair.

     - Setup: Builds licensed-safe RawText Bibles containing ThML, GBF, and undeclared plain-text
       entries whose raw bytes are not valid reader OSIS.
     - Expected result: ThML and GBF markup is converted to well-formed OSIS, plain markup-looking
       bytes are escaped as visible text, and each chapter retains its source words.
     - Failure meaning: The NETtext repair was applied narrowly to raw OSIS; Android-supported
       non-OSIS Bibles can still emit malformed Vue templates or change visible semantics.
     - Side effects: Writes and opens three temporary native SWORD trees, parses their emitted XML,
       and removes every fixture before returning.
     */
    func testConfiguredBibleSourceTypesConvertToOSISBeforeReaderRepair() throws {
        let fixtures: [(initials: String, sourceType: String?, source: String, text: String)] = [
            ("READERTHML", "ThML", "<p>ThML source</p>", "ThML source"),
            ("READERGBF", "GBF", "<FI>GBF emphasis<Fi>", "GBF emphasis"),
            ("READERPLAIN", nil, "Plain <literal> & text", "Plain"),
        ]

        for fixtureDefinition in fixtures {
            let fixture = try makeRawTextFixture(
                initials: fixtureDefinition.initials,
                sourceType: fixtureDefinition.sourceType,
                sources: ["", "", "", "", fixtureDefinition.source]
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let source = try fixture.module.inspectVerseKeyOSISSourceRestoringPrevious("=Gen.1.1")
            XCTAssertFalse(
                source.osisFragment.isEmpty,
                "\(fixtureDefinition.initials) produced empty source-filtered OSIS"
            )
            let chapter = try XCTUnwrap(
                BibleChapterDocumentBuilder(module: fixture.module, includeHeadings: true)
                    .loadChapter(osisBookId: "Gen", chapter: 1)
            )
            let parser = XMLParser(data: Data(chapter.xml.utf8))

            XCTAssertTrue(
                parser.parse(),
                "\(fixtureDefinition.initials): \(parser.parserError?.localizedDescription ?? "XML parse failed")"
            )
            XCTAssertEqual(chapter.verseCount, 1)
            XCTAssertTrue(chapter.xml.contains(fixtureDefinition.text))
            XCTAssertFalse(chapter.xml.contains("<FI>"))
            if fixtureDefinition.sourceType == nil {
                XCTAssertTrue(chapter.xml.contains("Plain &lt;literal&gt; &amp; text"))
                XCTAssertFalse(chapter.xml.contains("<literal>"))
            }
        }
    }

    /**
     Verifies exact-key source conversion restores the complete native cursor for present and empty
     content.

     - Setup: Positions a plain-text RawText module on Genesis 1:2, then inspects populated 1:1 and
       addressable-but-empty 1:31 through the new source-neutral accessor.
     - Expected result: Present content is escaped, empty content remains empty, and both calls
       restore the original key text and VerseKey ordinal exactly.
     - Failure meaning: Chapter or introduction reads can publish a stale entry or perturb another
       content caller's native position after either a successful read or a no-content result.
     - Side effects: Writes and opens one temporary native SWORD tree and removes it after the test.
     */
    func testExactSourceInspectionRestoresCursorForPresentAndEmptyEntries() throws {
        let fixture = try makeRawTextFixture(
            initials: "READERCURSOR",
            sourceType: nil,
            sources: ["", "", "", "", "Present <source> & text", "Cursor anchor"]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.module.setKey("=Gen.1.2")
        let originalKey = fixture.module.currentKey()
        let originalIndex = fixture.module.currentVerseKeyIndex()

        let present = try fixture.module.inspectVerseKeyOSISSourceRestoringPrevious("=Gen.1.1")
        XCTAssertTrue(
            present.osisFragment.contains("Present &lt;source&gt; &amp; text"),
            "Unexpected plain source projection: \(present.osisFragment)"
        )
        XCTAssertEqual(fixture.module.currentKey(), originalKey)
        XCTAssertEqual(fixture.module.currentVerseKeyIndex(), originalIndex)

        let empty = try fixture.module.inspectVerseKeyOSISSourceRestoringPrevious("=Gen.1.31")
        XCTAssertEqual(empty.verseKey?.osisRef, "Gen.1.31")
        XCTAssertTrue(empty.osisFragment.isEmpty)
        XCTAssertEqual(fixture.module.currentKey(), originalKey)
        XCTAssertEqual(fixture.module.currentVerseKeyIndex(), originalIndex)
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
        try makeRawTextFixture(
            initials: "SPLITSECTION",
            sourceType: "OSIS",
            sources: [
                "",
                "",
                "",
                "<div type=\"section\" scope=\"Gen.1\">",
                "Opening verse",
                "Closing verse</div>",
            ]
        )
    }

    /**
     Builds one licensed-safe RawText Bible from an exact configured source representation.

     - Parameters:
       - initials: Unique module initials and normalized data-directory stem.
       - sourceType: Optional configured SWORD source type; `nil` exercises JSword plain text.
       - sources: RawText index slots beginning with testament, testament intro, book intro, chapter
         intro, and positive verses.
     - Returns: Temporary module root plus its live manager-owned SWORD module.
     - Side effects: Writes one configuration, Old Testament payload, and fixed-width verse index.
     - Failure modes: Propagates filesystem errors and fails unwrapping when libsword cannot discover
       the synthetic module, because that leaves the production source-filter path untested.
     */
    private func makeRawTextFixture(
        initials: String,
        sourceType: String?,
        sources: [String]
    ) throws -> (root: URL, manager: SwordManager, module: SwordModule) {
        let stem = initials.lowercased()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-source-\(UUID().uuidString)", isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/texts/rawtext/\(stem)",
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
        let sourceTypeLine = sourceType.map { "SourceType=\($0)\n" } ?? ""
        let configuration = """
        [\(initials)]
        Description=Reader Source Fixture
        DataPath=./modules/texts/rawtext/\(stem)/
        ModDrv=RawText
        \(sourceTypeLine)Encoding=UTF-8
        Lang=en
        Versification=KJV
        """
        try Data(configuration.utf8).write(
            to: configDirectory.appendingPathComponent("\(stem).conf")
        )

        var textData = Data()
        var indexData = Data()
        for source in sources {
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
        return (root, manager, try XCTUnwrap(manager.module(named: initials)))
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
