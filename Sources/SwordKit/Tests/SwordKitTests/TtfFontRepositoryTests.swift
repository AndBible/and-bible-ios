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
}
