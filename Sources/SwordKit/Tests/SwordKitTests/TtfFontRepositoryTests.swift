import Foundation
@testable import SwordKit
import XCTest

/**
 Package-level tests for Android-style app-owned TTF font installation.

 `ExternalDocumentImportService` decides when a selected file should be routed to the font installer,
 but the filesystem contract belongs to `SwordKit.TtfFontRepository`: copying fonts into the SWORD
 root, writing addon metadata, and reporting user-facing filenames on errors.
 */
final class TtfFontRepositoryTests: XCTestCase {
    /**
     TTF font installation creates Android-shaped addon metadata in the SWORD root.

     Failure means the importer copied a font without making it discoverable as an And Bible addon,
     which would preserve the original iOS parity gap despite accepting the file type.
     */
    func testTtfFontRepositoryInstallsAndroidStyleAddonConfig() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("SourceGentium.ttf")
        try Data([0x00, 0x01, 0x00, 0x00]).write(to: sourceURL)

        let repository = TtfFontRepository(swordPath: tempDir.path)

        let installed = try repository.installFont(from: sourceURL, displayName: "Gentium.ttf")

        XCTAssertEqual(
            installed,
            InstalledTtfFont(fontName: "Gentium", moduleName: "TTF_Gentium", fileName: "Gentium.ttf")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("ttf/Gentium.ttf").path))
        let configURL = tempDir.appendingPathComponent("mods.d/ttf_gentium.conf")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(config.contains("[TTF_Gentium]"))
        XCTAssertTrue(config.contains("Category=And Bible"))
        XCTAssertTrue(config.contains("AndBibleProvidesFont=Gentium;Gentium.ttf"))
    }

    /**
     TTF import rejects special path components before constructing an install destination.

     Android routes TTF imports through display names that end in `.ttf`; iOS mirrors that extension
     gate after reducing provider names to one basename. Failure means `.` or `..` could reach
     destination URL construction and weaken the `ttf/` containment contract.
     */
    func testTtfFontRepositoryRejectsSpecialPathComponentDisplayNames() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("SourceGentium.ttf")
        try Data([0x00, 0x01, 0x00, 0x00]).write(to: sourceURL)
        let repository = TtfFontRepository(swordPath: tempDir.path)

        for displayName in [".", ".."] {
            do {
                _ = try repository.installFont(from: sourceURL, displayName: displayName)
                XCTFail("Expected special path component \(displayName) to be rejected")
            } catch TtfFontRepositoryError.invalidFont(let fileName) {
                XCTAssertEqual(fileName, displayName)
            } catch {
                XCTFail("Expected invalidFont for special path component \(displayName), got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("ttf").path))
    }

    /**
     TTF addon-config write failures keep import feedback anchored to the selected font filename.

     Android's TTF installer only exposes the imported TTF filename to the user; iOS persists an
     extra SWORD `.conf` file as platform plumbing. Failure means an internal config filename can leak
     through `ExternalDocumentImportService` as a misleading font-write error.
     */
    func testTtfFontRepositoryReportsFontNameWhenAddonConfigWriteFails() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("SourceGentium.ttf")
        try Data([0x00, 0x01, 0x00, 0x00]).write(to: sourceURL)
        let modsDirectory = tempDir.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: modsDirectory.appendingPathComponent("ttf_gentium.conf", isDirectory: true),
            withIntermediateDirectories: true
        )
        let repository = TtfFontRepository(swordPath: tempDir.path)

        do {
            _ = try repository.installFont(from: sourceURL, displayName: "Gentium.ttf")
            XCTFail("Expected TTF config write to fail")
        } catch TtfFontRepositoryError.cantWrite(let fileName) {
            XCTAssertEqual(fileName, "Gentium.ttf")
        } catch {
            XCTFail("Expected cantWrite for selected TTF file, got \(error)")
        }
    }

    /**
     TTF copy failures from unreadable sources surface as read errors.

     This protects the import feedback contract: a missing or inaccessible provider file should not be
     reported as a destination write problem.
     */
    func testTtfFontRepositoryReportsUnreadableSourceWhenCopyFails() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let missingSourceURL = tempDir.appendingPathComponent("Missing.ttf")
        let repository = TtfFontRepository(swordPath: tempDir.path)

        do {
            _ = try repository.installFont(from: missingSourceURL)
            XCTFail("Expected unreadable TTF source to fail")
        } catch TtfFontRepositoryError.cantRead(let fileName) {
            XCTAssertEqual(fileName, "Missing.ttf")
        } catch {
            XCTFail("Expected cantRead, got \(error)")
        }
    }

    /** Verifies startup registration publishes generated configs through the transaction path. */
    func testTtfFontRepositoryRegistersExistingFontAndInvalidatesCache() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fontURL = tempDir.appendingPathComponent("ttf/Existing.ttf")
        let cacheURL = tempDir.appendingPathComponent("mods.d/modules-conf.cache")
        try FileManager.default.createDirectory(
            at: fontURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try Data([0x00, 0x01, 0x00, 0x00]).write(to: fontURL)
        try Data("cache".utf8).write(to: cacheURL)

        let installed = try TtfFontRepository(swordPath: tempDir.path).registerInstalledFonts()

        XCTAssertEqual(installed, [
            InstalledTtfFont(
                fontName: "Existing",
                moduleName: "TTF_Existing",
                fileName: "Existing.ttf"
            ),
        ])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("mods.d/ttf_existing.conf").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    /**
     Verifies recursive registration keeps Android's first filename winner and FontPack ownership.

     Two nested files synthesize the same `TTF_Duplicate` initials, a third nested file is unique,
     and a root file is already referenced by an ordinary FontPack config. Registration must choose
     the lexicographically first duplicate path, emit nested `DataPath` metadata for both manual
     winners, and leave the configured FontPack as the sole owner of its file. Failure means an
     Android restore becomes unusable after restart or one physical font is exported twice.
     */
    func testTtfFontRepositoryRegistersNestedFirstWinnersWithoutClaimingFontPackFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fixtures: [(String, Data)] = [
            ("ttf/a/Duplicate.ttf", Data("first".utf8)),
            ("ttf/b/Duplicate.ttf", Data("second".utf8)),
            ("ttf/nested/Unique.ttf", Data("unique".utf8)),
            ("ttf/FontPack.ttf", Data("pack".utf8)),
        ]
        for (relativePath, data) in fixtures {
            let url = tempDir.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        let fontPackConfig = tempDir.appendingPathComponent("mods.d/fontpack.conf")
        try FileManager.default.createDirectory(
            at: fontPackConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            """
            [FontPack]
            Description=Configured pack
            Category=And Bible
            ModDrv=RawGenBook
            DataPath=./ttf/
            AndBibleProvidesFont=Pack;FontPack.ttf

            """.utf8
        ).write(to: fontPackConfig)

        let installed = try TtfFontRepository(swordPath: tempDir.path).registerInstalledFonts()

        XCTAssertEqual(installed, [
            InstalledTtfFont(
                fontName: "Duplicate",
                moduleName: "TTF_Duplicate",
                fileName: "Duplicate.ttf",
                relativePath: "a/Duplicate.ttf"
            ),
            InstalledTtfFont(
                fontName: "Unique",
                moduleName: "TTF_Unique",
                fileName: "Unique.ttf",
                relativePath: "nested/Unique.ttf"
            ),
        ])
        let duplicateConfig = try String(
            contentsOf: tempDir.appendingPathComponent("mods.d/ttf_duplicate.conf"),
            encoding: .utf8
        )
        XCTAssertTrue(duplicateConfig.contains("DataPath=./ttf/a/"))
        XCTAssertTrue(duplicateConfig.contains("AndBibleProvidesFont=Duplicate;Duplicate.ttf"))
        let uniqueConfig = try String(
            contentsOf: tempDir.appendingPathComponent("mods.d/ttf_unique.conf"),
            encoding: .utf8
        )
        XCTAssertTrue(uniqueConfig.contains("DataPath=./ttf/nested/"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("mods.d/ttf_fontpack.conf").path
        ))
        XCTAssertEqual(
            try String(contentsOf: fontPackConfig, encoding: .utf8).contains("[FontPack]"),
            true
        )
    }

    /**
     Verifies ambiguous exact-initials add-ons cannot reappear as generated manual TTF books.

     - Setup: Installs two comparator-distinct add-on configs with the same exact initials and two
       readable TTF providers below the manual-font scan root.
     - Expected result: Shared admission publishes neither provider, and startup registration
       reserves both physical files instead of synthesizing a second ownership path.
     - Side effects: Creates, scans, and removes one isolated SWORD tree.
     - Failure meaning: A fail-closed config collision can be bypassed by manual TTF discovery.
     */
    func testTtfFontRepositoryDoesNotSynthesizeAmbiguousConfigOwnedFonts() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = tempDir.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for (index, abbreviation) in ["Alpha", "Beta"].enumerated() {
            let component = index == 0 ? "first" : "second"
            let fileName = index == 0 ? "First.ttf" : "Second.ttf"
            let payload = tempDir.appendingPathComponent("ttf/\(component)", isDirectory: true)
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            try Data([0x00, UInt8(index)]).write(to: payload.appendingPathComponent(fileName))
            try """
            [AMBIGFONT]
            Description=Ambiguous \(abbreviation)
            Abbreviation=\(abbreviation)
            Category=And Bible
            ModDrv=RawGenBook
            DataPath=./ttf/\(component)/
            Encoding=UTF-8
            AndBibleProvidesFont=\(abbreviation);\(fileName)
            """.write(
                to: configDirectory.appendingPathComponent("\(component).conf"),
                atomically: true,
                encoding: .utf8
            )
        }

        let manager = try XCTUnwrap(SwordManager(modulePath: tempDir.path))
        XCTAssertTrue(manager.admittedFonts().isEmpty)

        let registered = try TtfFontRepository(swordPath: tempDir.path).registerInstalledFonts()

        XCTAssertTrue(registered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: configDirectory.appendingPathComponent("ttf_first.conf").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: configDirectory.appendingPathComponent("ttf_second.conf").path
        ))
    }
}
