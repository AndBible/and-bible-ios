// SwordManagerTests.swift — Tests for SwordKit

import XCTest
@testable import SwordKit

final class SwordManagerTests: XCTestCase {
    func testDefaultModulePath() {
        let path = SwordManager.defaultModulePath()
        XCTAssertTrue(path.contains("sword"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testModuleInfoCreation() {
        let info = ModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            version: "2.3",
            features: [.strongsNumbers, .redLetterWords]
        )
        XCTAssertEqual(info.name, "KJV")
        XCTAssertEqual(info.id, "KJV")
        XCTAssertEqual(info.category, .bible)
        XCTAssertTrue(info.features.contains(.strongsNumbers))
        XCTAssertFalse(info.features.contains(.morphology))
        XCTAssertFalse(info.isEncrypted)
        XCTAssertTrue(info.isUnlocked)
    }

    func testRemoteModuleInfoDefaultsToInstallable() {
        let info = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire"
        )

        XCTAssertTrue(info.isInstallable)
        XCTAssertEqual(info.availability, .installable)
        XCTAssertNil(info.unavailableReason)
    }

    func testPseudoBookMetadataCreatesUnavailableModules() throws {
        let data = """
        [
          {"id": "ESV", "suggested": "Please contact the copyright holder."},
          {"id": "NIV", "suggested": ""}
        ]
        """.data(using: .utf8)!

        let modules = try ModuleRepository.pseudoModules(from: data)

        XCTAssertEqual(modules.map(\.name), ["ESV", "NIV"])
        XCTAssertEqual(modules.map(\.sourceName), ["Not Available", "Not Available"])
        XCTAssertTrue(modules.allSatisfy { !$0.isInstallable })
        XCTAssertTrue(modules.allSatisfy { $0.category == .bible })
        XCTAssertTrue(modules.allSatisfy { $0.language == "en" })
        XCTAssertTrue(modules[0].description.contains("not available due to Copyright Holder"))
        XCTAssertTrue(modules[0].description.contains("Please contact the copyright holder."))
        XCTAssertEqual(modules[0].unavailableReason, modules[0].description)
    }

    func testDefaultInstallManagerConfigIncludesAndBibleSources() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)

        let configPath = tempDir.appendingPathComponent("InstallMgr.conf")
        let config = try String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(config.contains("HTTPSource=AndBible|andbible.github.io|/data/andbible"))
        XCTAssertTrue(config.contains("HTTPSource=AndBible Beta|andbible.github.io|/data/andbible/beta"))
    }

    func testLegacyInstallManagerConfigMigratesAndBibleSourcesOnce() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("InstallMgr.conf")
        try """
        [General]
        PassiveFTP=true

        [Sources]
        HTTPSource=CrossWire|crosswire.org|/ftpmirror/pub/sword/raw
        HTTPSource=AndBible Extra|andbible.github.io|/andbible-extra
        """.write(to: configPath, atomically: true, encoding: .utf8)

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)

        let migrated = try String(contentsOf: configPath, encoding: .utf8)
        XCTAssertTrue(migrated.contains("HTTPSource=AndBible|andbible.github.io|/data/andbible"))
        XCTAssertTrue(migrated.contains("HTTPSource=AndBible Beta|andbible.github.io|/data/andbible/beta"))

        let withoutAndBible = migrated
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("HTTPSource=AndBible|") }
            .joined(separator: "\n")
        try withoutAndBible.write(to: configPath, atomically: true, encoding: .utf8)

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)

        let afterUserDeletion = try String(contentsOf: configPath, encoding: .utf8)
        XCTAssertFalse(afterUserDeletion.contains("HTTPSource=AndBible|andbible.github.io|/data/andbible"))
        XCTAssertTrue(afterUserDeletion.contains("HTTPSource=AndBible Beta|andbible.github.io|/data/andbible/beta"))
    }

    func testModuleCategoryInit() {
        XCTAssertEqual(ModuleCategory(typeString: "Biblical Texts"), .bible)
        XCTAssertEqual(ModuleCategory(typeString: "Commentaries"), .commentary)
        XCTAssertEqual(ModuleCategory(typeString: "Unknown Type"), .unknown)
    }

    func testSearchOptionsDefaults() {
        let opts = SearchOptions(query: "love")
        XCTAssertEqual(opts.searchType, .multiWord)
        XCTAssertTrue(opts.caseInsensitive)
        XCTAssertNil(opts.scope)
    }

    func testSearchResultIdentity() {
        let r = SearchResult(key: "Gen 1:1", moduleName: "KJV")
        XCTAssertEqual(r.id, "KJV:Gen 1:1")
    }
}
