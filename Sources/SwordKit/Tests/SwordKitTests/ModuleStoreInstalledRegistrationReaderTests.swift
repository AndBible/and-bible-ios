import Foundation
import XCTest
@testable import SwordKit

/**
 Verifies side-effect-free installed registration discovery used by backup inspection.

 The fixture combines an ordinary SWORD Bible, one durable Android resource registration, an
 incomplete registration, and unsupported/custom configs. Assertions pin Android registration
 ownership while proving inventory creates no libsword globals or cache files.
 */
final class ModuleStoreInstalledRegistrationReaderTests: XCTestCase {
    /**
     Reads valid registrations, omits invalid siblings, and leaves the module tree byte-identical.

     - Side effects: Creates and removes one UUID-scoped temporary module tree.
     - Failure modes: Fixture I/O is surfaced through XCTest; production discovery itself is
       nonthrowing and reports only independently valid rows.
     */
    func testReaderDoesNotInitializeLibswordOrPublishRepairFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("installed-registration-reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mods = root.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)

        try write(
            """
            [KJV]
            Description=King James Version
            Category=Biblical Texts
            ModDrv=RawText
            DataPath=./modules/texts/rawtext/kjv/
            Lang=en
            Versification=KJVA
            """,
            to: mods.appendingPathComponent("kjv.conf")
        )
        try write(
            """
            [TTF_Test]
            Description=Test Font
            Category=And Bible
            ModDrv=RawGenBook
            DataPath=./ttf/
            AndBibleIOSGeneratedRegistration=true
            AndBibleIOSRegistrationFamily=ttf
            AndBibleIOSRegistrationPath=ttf/Test.ttf
            AndBibleProvidesFont=Test Font;Test.ttf
            """,
            to: mods.appendingPathComponent("font_test.conf")
        )
        try write("font", to: root.appendingPathComponent("ttf/Test.ttf"))
        try write(
            """
            [FONT_Missing]
            Description=Missing Font
            Category=And Bible
            ModDrv=RawGenBook
            DataPath=./ttf/
            AndBibleIOSGeneratedRegistration=true
            AndBibleIOSRegistrationFamily=ttf
            AndBibleIOSRegistrationPath=ttf/Missing.ttf
            """,
            to: mods.appendingPathComponent("font_missing.conf")
        )
        try write(
            """
            [BROKEN]
            Description=Unsupported Canon
            Category=Biblical Texts
            ModDrv=RawText
            DataPath=./modules/texts/rawtext/broken/
            Versification=NotARealVersification
            """,
            to: mods.appendingPathComponent("broken.conf")
        )
        try write(
            """
            [CUSTOM]
            Description=Custom SQLite
            Category=Biblical Texts
            ModDrv=MyBibleBible
            DataPath=./mybible/custom/
            Versification=KJVA
            """,
            to: mods.appendingPathComponent("custom.conf")
        )

        let before = try fileSnapshot(under: root)
        let registrations = ModuleStoreInstalledRegistrationReader.read(modulePath: root.path)
        let after = try fileSnapshot(under: root)

        XCTAssertEqual(before, after)
        XCTAssertEqual(registrations.map(\.moduleInfo.name), ["KJV", "TTF_Test"])
        XCTAssertEqual(registrations[1].ownership, .androidFamily(
            family: "ttf",
            relativePath: "ttf/Test.ttf"
        ))
        XCTAssertEqual(registrations[0].ownership, .swordConfiguration)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: mods.appendingPathComponent("globals.conf").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: mods.appendingPathComponent("modules-conf.cache").path
        ))
    }

    /**
     Proves metadata-only admission is controlled by the injectable static seam.

     The fixture advertises an unknown versification that production's static validator rejects. A
     supplied closure admits it synchronously, demonstrating that discovery does not consult
     `ModuleInfo.isSupported` or initialize libsword globals behind the seam.

     - Side effects: Creates and removes one temporary config tree; fulfills one XCTest expectation.
     - Failure modes: Fixture I/O is thrown. Missing seam invocation or hidden support checks fail the
       registration and expectation assertions.
     */
    func testReaderUsesInjectedStaticSupportValidatorWithoutLibswordFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("installed-registration-seam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("mods.d/static.conf")
        try write(
            """
            [STATIC]
            Description=Static Admission
            Category=Biblical Texts
            ModDrv=RawText
            DataPath=./modules/texts/rawtext/static/
            Versification=DefinitelyUnknown
            """,
            to: configURL
        )
        let invoked = expectation(description: "static validator invoked")

        let registrations = ModuleStoreInstalledRegistrationReader.read(
            modulePath: root.path,
            staticSupportValidator: { module in
                invoked.fulfill()
                return module.name == "STATIC"
            }
        )

        wait(for: [invoked], timeout: 0.1)
        XCTAssertEqual(registrations.map(\.moduleInfo.name), ["STATIC"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("mods.d/globals.conf").path
        ))
    }

    /**
     Rejects generated registrations whose family ownership metadata is not exact.

     Valid root-level TTF metadata is mixed with wrong roots, extensions, drivers, section identities,
     and a symlinked backing path. Only the exact real-file registration may reserve its identity.

     - Side effects: Creates temporary files and one symbolic link, then removes the fixture root.
     - Failure modes: Filesystem errors are thrown; any malformed registration entering the result
       fails the exact identity assertion.
     */
    func testGeneratedRegistrationsRequireExactFamilyShapeAndRealBackingNode() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("installed-registration-shape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mods = root.appendingPathComponent("mods.d", isDirectory: true)
        try write("font", to: root.appendingPathComponent("ttf/Good.ttf"))
        try write("font", to: root.appendingPathComponent("background/WrongRoot.ttf"))
        try write("font", to: root.appendingPathComponent("ttf/Wrong.otf"))
        try write("font", to: root.appendingPathComponent("ttf/WrongDriver.ttf"))
        try write("font", to: root.appendingPathComponent("ttf/WrongSection.ttf"))
        try write("font", to: root.appendingPathComponent("ttf/MissingCategory.ttf"))
        try write("font", to: root.appendingPathComponent("ttf/MissingProvider.ttf"))
        let outside = root.appendingPathComponent("outside.ttf")
        try write("font", to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("ttf/Linked.ttf"),
            withDestinationURL: outside
        )

        let cases: [(String, String, String, String)] = [
            ("good", "TTF_Good", "RawGenBook", "ttf/Good.ttf"),
            ("root", "TTF_WrongRoot", "RawGenBook", "background/WrongRoot.ttf"),
            ("extension", "TTF_Wrong", "RawGenBook", "ttf/Wrong.otf"),
            ("driver", "TTF_WrongDriver", "RawText", "ttf/WrongDriver.ttf"),
            ("section", "NOT_THE_PATH_IDENTITY", "RawGenBook", "ttf/WrongSection.ttf"),
            ("symlink", "TTF_Linked", "RawGenBook", "ttf/Linked.ttf"),
        ]
        for (fileName, section, driver, relativePath) in cases {
            try write(
                """
                [\(section)]
                Description=\(section)
                Category=And Bible
                ModDrv=\(driver)
                DataPath=./\((relativePath as NSString).deletingLastPathComponent)/
                AndBibleIOSGeneratedRegistration=true
                AndBibleIOSRegistrationFamily=ttf
                AndBibleIOSRegistrationPath=\(relativePath)
                AndBibleProvidesFont=\(section);\((relativePath as NSString).lastPathComponent)
                """,
                to: mods.appendingPathComponent("\(fileName).conf")
            )
        }
        try write(
            """
            [TTF_MissingCategory]
            Description=TTF_MissingCategory
            ModDrv=RawGenBook
            DataPath=./ttf/
            AndBibleIOSGeneratedRegistration=true
            AndBibleIOSRegistrationFamily=ttf
            AndBibleIOSRegistrationPath=ttf/MissingCategory.ttf
            AndBibleProvidesFont=TTF_MissingCategory;MissingCategory.ttf
            """,
            to: mods.appendingPathComponent("missing_category.conf")
        )
        try write(
            """
            [TTF_MissingProvider]
            Description=TTF_MissingProvider
            Category=And Bible
            ModDrv=RawGenBook
            DataPath=./ttf/
            AndBibleIOSGeneratedRegistration=true
            AndBibleIOSRegistrationFamily=ttf
            AndBibleIOSRegistrationPath=ttf/MissingProvider.ttf
            """,
            to: mods.appendingPathComponent("missing_provider.conf")
        )

        let registrations = ModuleStoreInstalledRegistrationReader.read(modulePath: root.path)

        XCTAssertEqual(registrations.map(\.moduleInfo.name), ["TTF_Good"])
        XCTAssertEqual(
            registrations.first?.ownership,
            .androidFamily(family: "ttf", relativePath: "ttf/Good.ttf")
        )
    }

    /** Writes one UTF-8 fixture file after creating its parent directory. */
    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url, options: .atomic)
    }

    /** Captures every regular fixture file by path for zero-mutation assertions. */
    private func fileSnapshot(under root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() {
            let url = root.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            result[path] = try Data(contentsOf: url)
        }
        return result
    }
}
