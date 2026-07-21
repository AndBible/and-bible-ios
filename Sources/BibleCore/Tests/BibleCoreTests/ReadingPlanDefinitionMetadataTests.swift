import Foundation
import XCTest
@testable import BibleCore

/**
 Temporary Android-compatible reading-plan source layout for definition metadata tests.

 Each fixture owns isolated user-plan and SWORD add-on directories. Tests remove the root after
 use, so source priority and unreadable-file behavior remain deterministic without touching app
 documents or the installed module store.
 */
private struct ReadingPlanDefinitionFixture {
    let root: URL
    let userPlanDirectory: URL
    let swordDirectory: URL
    let modsDirectory: URL
    let addonDirectory: URL

    /**
     Creates the user, module-config, and add-on payload directories used by Android discovery.

     - Returns: A fully created isolated fixture.
     - Side effects: Creates directories under the process temporary directory.
     - Throws: File-system errors when the fixture cannot be created.
     */
    static func make() throws -> ReadingPlanDefinitionFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userPlanDirectory = root
            .appendingPathComponent("jsword/readingplan", isDirectory: true)
        let swordDirectory = root.appendingPathComponent("sword", isDirectory: true)
        let modsDirectory = swordDirectory.appendingPathComponent("mods.d", isDirectory: true)
        let addonDirectory = swordDirectory
            .appendingPathComponent("modules/genbook/rawgenbook/planaddon", isDirectory: true)

        try FileManager.default.createDirectory(
            at: userPlanDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: modsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: addonDirectory,
            withIntermediateDirectories: true
        )
        return ReadingPlanDefinitionFixture(
            root: root,
            userPlanDirectory: userPlanDirectory,
            swordDirectory: swordDirectory,
            modsDirectory: modsDirectory,
            addonDirectory: addonDirectory
        )
    }

    /**
     Writes one user reading-plan definition using Android's filename-derived identity.

     - Parameters:
       - code: Stable plan code used as the filename stem.
       - text: Raw Java-properties definition.
     - Side effects: Writes one UTF-8 file under `jsword/readingplan`.
     - Throws: File-system errors from the write.
     */
    func writeUserPlan(code: String, text: String) throws {
        try text.write(
            to: userPlanDirectory.appendingPathComponent("\(code).properties"),
            atomically: true,
            encoding: .utf8
        )
    }

    /**
     Writes one user definition as exact bytes without applying a Swift string encoding.

     - Parameters:
       - code: Stable plan code used as the filename stem.
       - data: Exact Java-properties input bytes.
     - Side effects: Writes one file under `jsword/readingplan`.
     - Throws: File-system errors from the write.
     */
    func writeUserPlan(code: String, data: Data) throws {
        try data.write(
            to: userPlanDirectory.appendingPathComponent("\(code).properties"),
            options: .atomic
        )
    }

    /**
     Installs one discoverable add-on definition and optional module versification metadata.

     - Parameters:
       - code: Stable plan code and provider filename stem.
       - text: Raw Java-properties provider content.
       - moduleVersification: Optional SWORD config value Android gives precedence over file data.
     - Side effects: Writes one provider file and one module config under the fixture SWORD root.
     - Throws: File-system errors from either write.
     */
    func writeAddonPlan(
        code: String,
        text: String,
        moduleVersification: String? = nil
    ) throws {
        try text.write(
            to: addonDirectory.appendingPathComponent("\(code).properties"),
            atomically: true,
            encoding: .utf8
        )
        let versificationLine = moduleVersification.map { "Versification=\($0)\n" } ?? ""
        try """
        [PLANADDON]
        Description=Add-on Reading Plans
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./modules/genbook/rawgenbook/planaddon/
        ShortPromo=Plans supplied by an add-on module.
        \(versificationLine)AndBibleProvidesReadingPlan=\(code).properties
        """.write(
            to: modsDirectory.appendingPathComponent("planaddon.conf"),
            atomically: true,
            encoding: .utf8
        )
    }

    /** Removes the fixture root and all definition files on a best-effort basis. */
    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/** JVM-observed outputs for one exact `Properties.load(InputStream)` byte fixture. */
private struct JavaPropertiesInputStreamOracle: Decodable {
    let oracle: String
    let value1Base64: String
    let value2Base64: String
    let comment1Base64: String
    let comment2Base64: String
}

/**
 Android-parity tests for fail-visible reading-plan definition metadata lookup.

 The suite anchors source priority to `ReadingPlanTextFileDao`: add-on provider, then user file,
 then bundled definition. Each priority assertion also checks catalog readings so metadata cannot
 silently resolve from a different source than the plan content.
 */
final class ReadingPlanDefinitionMetadataTests: XCTestCase {
    /**
     Verifies Java InputStream values and UTF-8 comment metadata use their distinct byte semantics.

     The source-controlled fixture was evaluated by a JVM. It combines UTF-8 comments, a raw
     ISO-8859-1 value byte, and a UTF-16 surrogate-pair escape; any transcoding or scalar-by-scalar
     escape handling changes either the parsed readings or the catalog display metadata.
     */
    func testJavaInputStreamOraclePreservesValueAndCommentDecoding() throws {
        let fixture = try ReadingPlanDefinitionFixture.make()
        defer { fixture.remove() }
        let fixtureDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/JavaProperties", isDirectory: true)
        let inputHex = try String(
            contentsOf: fixtureDirectory.appendingPathComponent(
                "PropertiesLoadInputStream.hex"
            ),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let inputData = try decodeHexFixture(inputHex)
        let expected = try JSONDecoder().decode(
            JavaPropertiesInputStreamOracle.self,
            from: Data(
                contentsOf: fixtureDirectory.appendingPathComponent(
                    "PropertiesLoadInputStream.expected.json"
                )
            )
        )
        XCTAssertEqual(expected.oracle, "java.util.Properties.load(InputStream)")

        let valuesText = try XCTUnwrap(String(data: inputData, encoding: .isoLatin1))
        let readings = ReadingPlanService.parseProperties(valuesText)
        XCTAssertEqual(readings[1], try decodeBase64UTF8(expected.value1Base64))
        XCTAssertEqual(readings[2], try decodeBase64UTF8(expected.value2Base64))

        let code = "java_input_stream_oracle"
        try fixture.writeUserPlan(code: code, data: inputData)
        let template = try XCTUnwrap(
            ReadingPlanService.catalog(
                userPlanDirectory: fixture.userPlanDirectory,
                modulePath: fixture.swordDirectory.path
            ).templates.first { $0.code == code }
        )
        XCTAssertEqual(
            template.name,
            try decodeBase64UTF8(expected.comment1Base64).replacingOccurrences(of: "# ", with: "")
        )
        XCTAssertEqual(
            template.description,
            try decodeBase64UTF8(expected.comment2Base64).replacingOccurrences(of: "# ", with: "")
        )
    }

    /**
     Verifies a selected add-on file supplies metadata before same-code user and bundled sources.

     A failure means action parsing could use a canon from a lower-priority definition than the
     readings materialized by the catalog.
     */
    func testVersificationPropertyUsesAddonDefinitionBeforeUserAndBundledDefinition() throws {
        let fixture = try ReadingPlanDefinitionFixture.make()
        defer { fixture.remove() }
        let code = "y1ot1nt1_OTthenNT"
        try fixture.writeUserPlan(
            code: code,
            text: "Versification=Vulg\n1=Exod.1\n"
        )
        try fixture.writeAddonPlan(
            code: code,
            text: "Versification=NRSVA\n1=Luke.1\n"
        )

        let versification = try ReadingPlanService.versificationProperty(
            forPlanCode: code,
            userPlanDirectory: fixture.userPlanDirectory,
            modulePath: fixture.swordDirectory.path
        )
        let template = try XCTUnwrap(
            ReadingPlanService.catalog(
                userPlanDirectory: fixture.userPlanDirectory,
                modulePath: fixture.swordDirectory.path
            ).templates.first { $0.code == code }
        )

        XCTAssertEqual(versification, "NRSVA")
        XCTAssertEqual(template.readingsForDay(1), "Luke.1")
    }

    /**
     Verifies add-on module metadata overrides the selected add-on file property as on Android.

     A failure means iOS ignores the `Book` metadata argument passed by Android when constructing
     reading-plan versification.
     */
    func testVersificationPropertyUsesAddonModuleMetadataBeforeAddonFileProperty() throws {
        let fixture = try ReadingPlanDefinitionFixture.make()
        defer { fixture.remove() }
        let code = "addon_metadata_override"
        try fixture.writeAddonPlan(
            code: code,
            text: "Versification=NRSVA\n1=Luke.1\n",
            moduleVersification: "German"
        )

        let versification = try ReadingPlanService.versificationProperty(
            forPlanCode: code,
            userPlanDirectory: fixture.userPlanDirectory,
            modulePath: fixture.swordDirectory.path
        )

        XCTAssertEqual(versification, "German")
    }

    /**
     Verifies a user definition wins over the bundle and decodes Java key/value escapes.

     The duplicate escaped key also proves Java's last-value-wins behavior. A failure means metadata
     parsing has drifted from the structural parser already used for day assignments.
     */
    func testVersificationPropertyUsesEscapedUserDefinitionBeforeBundledDefinition() throws {
        let fixture = try ReadingPlanDefinitionFixture.make()
        defer { fixture.remove() }
        let code = "y1ot1nt1_OTthenNT"
        try fixture.writeUserPlan(
            code: code,
            text: #"""
            Versification=KJV
            Versifica\u0074ion:Vu\
              lg
            1=Exod.1

            """#
        )

        let versification = try ReadingPlanService.versificationProperty(
            forPlanCode: code,
            userPlanDirectory: fixture.userPlanDirectory,
            modulePath: fixture.swordDirectory.path
        )
        let template = try XCTUnwrap(
            ReadingPlanService.catalog(
                userPlanDirectory: fixture.userPlanDirectory,
                modulePath: fixture.swordDirectory.path
            ).templates.first { $0.code == code }
        )

        XCTAssertEqual(versification, "Vulg")
        XCTAssertEqual(template.readingsForDay(1), "Exod.1")
    }

    /**
     Verifies the bundled definition is used when no external source exists.

     The selected Android bundle currently omits `Versification`, so `nil` plus its known day-one
     content jointly prove the bundle was loaded without applying a default canon in this API.
     */
    func testVersificationPropertyUsesBundledDefinitionWhenExternalSourcesAreAbsent() throws {
        let fixture = try ReadingPlanDefinitionFixture.make()
        defer { fixture.remove() }
        let code = "y1ot1nt1_OTthenNT"

        let versification = try ReadingPlanService.versificationProperty(
            forPlanCode: code,
            userPlanDirectory: fixture.userPlanDirectory,
            modulePath: fixture.swordDirectory.path
        )
        let template = try XCTUnwrap(
            ReadingPlanService.catalog(
                userPlanDirectory: fixture.userPlanDirectory,
                modulePath: fixture.swordDirectory.path
            ).templates.first { $0.code == code }
        )

        XCTAssertNil(versification)
        XCTAssertEqual(template.readingsForDay(1), "Gen.1-Gen.4")
    }

    /**
     Verifies a valid selected definition without `Versification` returns `nil` rather than failing.

     A failure would make Android's implicit KJV policy indistinguishable from an unavailable plan
     definition at the service boundary.
     */
    func testVersificationPropertyReturnsNilWhenSelectedDefinitionOmitsProperty() throws {
        let fixture = try ReadingPlanDefinitionFixture.make()
        defer { fixture.remove() }
        let code = "user_without_versification"
        try fixture.writeUserPlan(code: code, text: "1=Mark.1\n")

        let versification = try ReadingPlanService.versificationProperty(
            forPlanCode: code,
            userPlanDirectory: fixture.userPlanDirectory,
            modulePath: fixture.swordDirectory.path
        )

        XCTAssertNil(versification)
    }

    /**
     Verifies an unknown plan throws the typed localized definition-unavailable contract.

     A failure would collapse missing definition data into the same `nil` used for a valid plan
     that intentionally omits `Versification`, preventing fail-visible daily-reading behavior.
     */
    func testVersificationPropertyThrowsTypedLocalizedErrorWhenDefinitionIsMissing() throws {
        let fixture = try ReadingPlanDefinitionFixture.make()
        defer { fixture.remove() }
        let code = "missing_plan"

        XCTAssertThrowsError(
            try ReadingPlanService.versificationProperty(
                forPlanCode: code,
                userPlanDirectory: fixture.userPlanDirectory,
                modulePath: fixture.swordDirectory.path
            )
        ) { error in
            guard let definitionError = error as? ReadingPlanDefinitionError else {
                return XCTFail("Expected ReadingPlanDefinitionError, got \(error)")
            }
            XCTAssertEqual(definitionError, .unavailable(planCode: code))
            XCTAssertEqual(
                definitionError.errorDescription,
                String(localized: "error_occurred", defaultValue: "An error has occurred")
            )
            XCTAssertFalse(definitionError.localizedDescription.isEmpty)
        }
    }

    /**
     Verifies a readable malformed add-on blocks fallback to valid user and bundled definitions.

     Catalog template selection already stops after decoding the add-on, then rejects its missing
     numeric days. Metadata must throw from that same selection rather than borrowing a lower-source
     versification that does not describe any materialized content.
     */
    func testVersificationPropertyDoesNotFallBackFromReadableMalformedAddonDefinition() throws {
        let fixture = try ReadingPlanDefinitionFixture.make()
        defer { fixture.remove() }
        let code = "y1ot1nt1_OTthenNT"
        try fixture.writeUserPlan(
            code: code,
            text: "Versification=Vulg\n1=Exod.1\n"
        )
        try fixture.writeAddonPlan(
            code: code,
            text: "Versification=NRSVA\nnot-a-day=Luke.1\n"
        )

        XCTAssertThrowsError(
            try ReadingPlanService.versificationProperty(
                forPlanCode: code,
                userPlanDirectory: fixture.userPlanDirectory,
                modulePath: fixture.swordDirectory.path
            )
        ) { error in
            XCTAssertEqual(
                error as? ReadingPlanDefinitionError,
                .unavailable(planCode: code)
            )
        }
        XCTAssertFalse(
            ReadingPlanService.catalog(
                userPlanDirectory: fixture.userPlanDirectory,
                modulePath: fixture.swordDirectory.path
            ).templates.contains { $0.code == code }
        )
    }

    /**
     Verifies an unreadable user candidate falls through to the valid bundled definition.

     A directory with a `.properties` suffix is discovered as a candidate but cannot be decoded as
     file data. The bundled day-one content proves metadata lookup and template selection both apply
     the same readability fallback instead of treating the candidate's mere presence as shadowing.
     */
    func testVersificationPropertyFallsBackFromUnreadableUserCandidateToBundledDefinition() throws {
        let fixture = try ReadingPlanDefinitionFixture.make()
        defer { fixture.remove() }
        let code = "y1ot1nt1_OTthenNT"
        try FileManager.default.createDirectory(
            at: fixture.userPlanDirectory.appendingPathComponent("\(code).properties"),
            withIntermediateDirectories: false
        )

        let versification = try ReadingPlanService.versificationProperty(
            forPlanCode: code,
            userPlanDirectory: fixture.userPlanDirectory,
            modulePath: fixture.swordDirectory.path
        )
        let template = try XCTUnwrap(
            ReadingPlanService.catalog(
                userPlanDirectory: fixture.userPlanDirectory,
                modulePath: fixture.swordDirectory.path
            ).templates.first { $0.code == code }
        )

        XCTAssertNil(versification)
        XCTAssertEqual(template.readingsForDay(1), "Gen.1-Gen.4")
    }

    /** Decodes one source-controlled even-length lowercase hexadecimal byte fixture. */
    private func decodeHexFixture(_ value: String) throws -> Data {
        guard value.count.isMultiple(of: 2), value.allSatisfy(\.isHexDigit) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var result = Data()
        result.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<end], radix: 16) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result.append(byte)
            index = end
        }
        return result
    }

    /** Decodes one JVM-emitted Base64 UTF-8 scalar value without lossy fallback. */
    private func decodeBase64UTF8(_ value: String) throws -> String {
        guard let data = Data(base64Encoded: value),
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }
}
