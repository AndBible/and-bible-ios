// SwordSourceFormatParityTests.swift -- Physical Android source-filter parity

import Foundation
import XCTest
@testable import SwordKit

/**
 Verifies every native SWORD source family crosses the pinned Android JSword filter boundary.

 Tests combine exact pure-filter oracles with physical RawCom/RawLD modules so a native bridge
 shortcut cannot silently reintroduce libsword conversion. Every temporary module tree is unique and
 removed by its owning test; no simulator, network, or persisted application state is touched.
 */
final class SwordSourceFormatParityTests: XCTestCase {
    /**
     Verifies JSword plain text retains literal markup and expresses every LF as structural OSIS.

     - Setup: Converts leading space, XML-looking text, an empty line, CRLF, and a trailing LF.
     - Expected result: Markup remains text, each LF except after the final split line becomes `lb`,
       and JDOM-compatible CR serialization remains exact.
     - Failure meaning: Missing/unknown `SourceType` differs from Android in visible lines, anchors,
       or structural serialization.
     */
    func testPlainTextFilterUsesJSwordLineBreakAndLiteralMarkupSemantics() {
        XCTAssertEqual(
            SwordJSwordPlainTextSourceFilter.convert(
                " first <tag> & \"quote\"\n\nlast\r\n"
            ),
            " first &lt;tag&gt; &amp; \"quote\"<lb/><lb/>last&#xD;<lb/>"
        )
        XCTAssertEqual(SwordJSwordPlainTextSourceFilter.convert(""), "")
    }

    /**
     Verifies the GBF tokenizer and tag stack match pinned JSword semantics rather than libsword.

     - Setup: Supplies formatting, line/paragraph, reference, Strong, morph, note, unknown,
       alternate-versification, non-ASCII uppercase/lowercase, terminal-bracket, and stack-underflow
       cases.
     - Expected result: Known commands produce exact OSIS, version markers/unknown uppercase tags
       disappear, and a lowercase-led angle sequence remains doubly entity-protected like JSword's
       explicit XMLUtil escape followed by JDOM serialization.
       Android runtime-failure cases fail the nonthrowing iOS conversion closed as empty output.
     - Failure meaning: Reader/Search semantics depend on libsword or host Unicode behavior.
     */
    func testGBFFilterMatchesJSwordTokenizerStackAndMetadataSemantics() {
        let source = "  Alpha<FB>bold<Fb><FI>ital<Fi><FR>red<Fr><FU>under<Fu><CL><CM>"
            + "<RXMt 1:2>link<Rx> word<WG123><WTABC><RF>note<Rf>"
            + "<WG1-2><ZZ>ignored<Äx>hidden<äx>visible  "
        let converted = SwordJSwordGBFSourceFilter.convert(source) { reference in
            reference == "Mt 1:2" ? "Matt.1.2" : ""
        }

        XCTAssertEqual(
            converted,
            "Alpha<hi type=\"bold\">bold</hi><hi type=\"italic\">ital</hi>"
                + "<q who=\"Jesus\">red</q><hi type=\"underline\">under</hi><lb/><p/>"
                + "<reference osisRef=\"Matt.1.2\">link</reference> "
                + "<w lemma=\"strong:G123\" morph=\"x-StrongsMorph:TABC\">word</w>"
                + "<note type=\"x-StudyNote\">note</note>ignoredhidden"
                + "&amp;lt;äx&amp;gt;visible"
        )
        XCTAssertEqual(SwordJSwordGBFSourceFilter.convert("terminal<") { _ in "" }, "")
        XCTAssertEqual(SwordJSwordGBFSourceFilter.convert("<Fb><FB>lost") { _ in "" }, "")
    }

    /**
     Verifies physical OSIS and TEI records both use Android's registered `OSISFilter` repair path.

     - Setup: Writes separate RawCom modules with bare entities and OSIS/TEI structural elements.
     - Expected result: Both records repair the entity while retaining their original element
       families; TEI `entryFree`/`orth` never passes through a lossy native renderer.
     - Side effects: Creates, opens, and removes two temporary SWORD module trees.
     - Failure meaning: The shared OSIS repair ladder is bypassed for one registered source alias.
     */
    func testPhysicalOSISAndTEIUseSharedJSwordOSISFilter() throws {
        let osis = try makeRawComFixture(
            initials: "FORMATOSIS",
            sourceType: "OSIS",
            source: #"<hi type="italic">OSIS & source</hi>"#
        )
        defer { try? FileManager.default.removeItem(at: osis) }
        let osisFixture = try openedModule(named: "FORMATOSIS", in: osis)
        let osisInspection = try withExtendedLifetime(osisFixture.manager) {
            try osisFixture.module.inspectVerseKeyOSISSourceRestoringPrevious("=Matt.1.1")
        }
        XCTAssertEqual(
            osisInspection.osisFragment,
            #"<hi type="italic">OSIS &amp; source</hi>"#
        )

        let tei = try makeRawComFixture(
            initials: "FORMATTEI",
            sourceType: "TEI",
            source: "<entryFree><orth>Word</orth><def>Meaning & source</def></entryFree>"
        )
        defer { try? FileManager.default.removeItem(at: tei) }
        let teiFixture = try openedModule(named: "FORMATTEI", in: tei)
        let teiInspection = try withExtendedLifetime(teiFixture.manager) {
            try teiFixture.module.inspectVerseKeyOSISSourceRestoringPrevious("=Matt.1.1")
        }
        XCTAssertEqual(
            teiInspection.osisFragment,
            "<entryFree><orth>Word</orth><def>Meaning &amp; source</def></entryFree>"
        )
    }

    /**
     Verifies physical plain-text and GBF verse records use the shared JSword filters.

     - Setup: Writes real RawCom entries for declared Plain, unknown-source fallback, and GBF
       Strong/morph/reference commands.
     - Expected result: Declared and unknown plain LF become `lb`; GBF creates structured word
       metadata and a canonical resolved reference while every exact verse cursor restores.
     - Side effects: Creates, opens, and removes three temporary SWORD module trees.
     - Failure meaning: Native source conversion still selects the former escaped/libsword path.
     */
    func testPhysicalPlainTextAndGBFUseSharedJSwordFilters() throws {
        let plain = try makeRawComFixture(
            initials: "FORMATPLAIN",
            sourceType: "Plain",
            source: "Plain <literal>\nsecond line"
        )
        defer { try? FileManager.default.removeItem(at: plain) }
        let plainFixture = try openedModule(named: "FORMATPLAIN", in: plain)
        let plainInspection = try withExtendedLifetime(plainFixture.manager) {
            try plainFixture.module.inspectVerseKeyOSISSourceRestoringPrevious("=Matt.1.1")
        }
        XCTAssertEqual(
            plainInspection.osisFragment,
            "Plain &lt;literal&gt;<lb/>second line"
        )

        let unknown = try makeRawComFixture(
            initials: "FORMATUNKNOWN",
            sourceType: "Unregistered",
            source: "Unknown <literal>\nfallback"
        )
        defer { try? FileManager.default.removeItem(at: unknown) }
        let unknownFixture = try openedModule(named: "FORMATUNKNOWN", in: unknown)
        let unknownInspection = try withExtendedLifetime(unknownFixture.manager) {
            try unknownFixture.module.inspectVerseKeyOSISSourceRestoringPrevious("=Matt.1.1")
        }
        XCTAssertEqual(
            unknownInspection.osisFragment,
            "Unknown &lt;literal&gt;<lb/>fallback"
        )

        let gbf = try makeRawComFixture(
            initials: "FORMATGBF",
            sourceType: "GBF",
            source: "Word<WG123><WTABC><CL><RXMt 1:2>link<Rx>"
        )
        defer { try? FileManager.default.removeItem(at: gbf) }
        let gbfFixture = try openedModule(named: "FORMATGBF", in: gbf)
        let gbfInspection = try withExtendedLifetime(gbfFixture.manager) {
            try gbfFixture.module.inspectVerseKeyOSISSourceRestoringPrevious("=Matt.1.1")
        }
        XCTAssertEqual(
            gbfInspection.osisFragment,
            "<w lemma=\"strong:G123\" morph=\"x-StrongsMorph:TABC\">Word</w>"
                + "<lb/><reference osisRef=\"Matt.1.2\">link</reference>"
        )
    }

    /**
     Verifies physical RawLD index selection cannot bypass GBF conversion after resolving a slot.

     - Setup: Writes one RawLD key/body record and loads it through the physical index API used for
       JSword-exact dictionary collision handling.
     - Expected result: Generated title and GBF italic/Strong nodes survive in canonical OSIS.
     - Side effects: Creates, opens, and removes one temporary RawLD module tree.
     - Failure meaning: Direct-key reads and physical-index reads apply different source contracts.
     */
    func testPhysicalRawLDDictionaryIndexUsesSharedGBFFilter() throws {
        let root = try makeRawLDFixture(
            sourceType: "GBF",
            key: "WORD",
            source: "Definition <FI>italic<Fi><WG123>"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try openedModule(named: "FORMATDICT", in: root)
        let fragment = try withExtendedLifetime(fixture.manager) {
            try fixture.module.rawDictionaryOSISFragment(forIndex: 0, storedKey: "WORD")
        }

        XCTAssertTrue(fragment.originalXML.contains("<title type=\"x-gen\">WORD</title>"))
        XCTAssertTrue(
            fragment.originalXML.contains(
                "<hi lemma=\"strong:G123\" type=\"italic\">italic</hi>"
            )
        )
    }

    /**
     Opens one exact module from a temporary source-format fixture.

     - Parameters:
       - initials: Exact configured module initials.
       - root: Temporary SWORD installation root.
     - Returns: Retained manager and readable native module; callers keep the tuple alive through
       every module access.
     - Side effects: Opens libsword manager/module handles.
     - Failure modes: Throws XCTest unwrap failures for invalid fixture construction.
     */
    private func openedModule(
        named initials: String,
        in root: URL
    ) throws -> (manager: SwordManager, module: SwordModule) {
        let manager = try XCTUnwrap(SwordManager(modulePath: root.path))
        return (manager, try XCTUnwrap(manager.module(named: initials)))
    }

    /**
     Writes one physical RawCom entry at pinned KJV Matthew 1:1.

     - Parameters:
       - initials: Exact unique config/module identity.
       - sourceType: Optional declared `SourceType`; nil exercises a missing metadata value.
       - source: Exact UTF-8 entry bytes.
     - Returns: Temporary SWORD root containing complete NT/OT index files.
     - Side effects: Writes config, data, and index files beneath a unique temporary directory.
     - Failure modes: Propagates filesystem errors and rejects a RawVerse record over UInt16 length.
     */
    private func makeRawComFixture(
        initials: String,
        sourceType: String?,
        source: String
    ) throws -> URL {
        let sourceBytes = Data(source.utf8)
        guard sourceBytes.count <= Int(UInt16.max) else {
            throw SourceFormatFixtureError.entryTooLarge
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/comments/rawcom/format",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        var ntIndex = Data(repeating: 0, count: 8_246 * 6)
        writeRawVerseIndexRecord(offset: 0, length: UInt16(sourceBytes.count), at: 4, in: &ntIndex)
        try sourceBytes.write(to: dataDirectory.appendingPathComponent("nt"))
        try ntIndex.write(to: dataDirectory.appendingPathComponent("nt.vss"))
        try Data().write(to: dataDirectory.appendingPathComponent("ot"))
        try Data(repeating: 0, count: 24_115 * 6).write(
            to: dataDirectory.appendingPathComponent("ot.vss")
        )

        let sourceTypeLine = sourceType.map { "SourceType=\($0)\n" } ?? ""
        try """
        [\(initials)]
        Description=\(initials) Source Fixture
        Category=Commentaries
        ModDrv=RawCom
        DataPath=./modules/comments/rawcom/format/
        \(sourceTypeLine)Encoding=UTF-8
        Lang=en
        Versification=KJV
        """.write(
            to: configDirectory.appendingPathComponent("format.conf"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    /**
     Writes one physical RawLD dictionary record with a six-byte little-endian index.

     - Parameters:
       - sourceType: Declared source filter family.
       - key: Exact stored dictionary key.
       - source: Exact UTF-8 record body.
     - Returns: Temporary SWORD root containing one readable RawLD module.
     - Side effects: Writes config, data, and index files under a unique temporary directory.
     - Failure modes: Propagates filesystem errors and rejects an oversized physical record.
     */
    private func makeRawLDFixture(
        sourceType: String,
        key: String,
        source: String
    ) throws -> URL {
        let record = Data("\(key)\r\n\(source)\n".utf8)
        guard record.count <= Int(UInt16.max) else {
            throw SourceFormatFixtureError.entryTooLarge
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/lexdict/rawld/formatdict",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try record.write(to: dataDirectory.appendingPathComponent("formatdict.dat"))
        var index = Data()
        index.appendLittleEndian(UInt32(0))
        index.appendLittleEndian(UInt16(record.count - 1))
        try index.write(to: dataDirectory.appendingPathComponent("formatdict.idx"))
        try """
        [FORMATDICT]
        Description=Format Dictionary
        Category=Lexicons / Dictionaries
        ModDrv=RawLD
        DataPath=./modules/lexdict/rawld/formatdict/formatdict
        SourceType=\(sourceType)
        Encoding=UTF-8
        Lang=en
        """.write(
            to: configDirectory.appendingPathComponent("formatdict.conf"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    /** Writes one six-byte little-endian RawVerse index record. */
    private func writeRawVerseIndexRecord(
        offset: UInt32,
        length: UInt16,
        at record: Int,
        in index: inout Data
    ) {
        let start = record * 6
        index[start] = UInt8(offset & 0xFF)
        index[start + 1] = UInt8((offset >> 8) & 0xFF)
        index[start + 2] = UInt8((offset >> 16) & 0xFF)
        index[start + 3] = UInt8((offset >> 24) & 0xFF)
        index[start + 4] = UInt8(length & 0xFF)
        index[start + 5] = UInt8((length >> 8) & 0xFF)
    }
}

/** Source-format fixture construction failures that must not silently truncate module data. */
private enum SourceFormatFixtureError: Error {
    /// Source/record cannot fit SWORD's UInt16 physical length field.
    case entryTooLarge
}

private extension Data {
    /** Appends one fixed-width integer in SWORD's little-endian module format. */
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
