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
        XCTAssertEqual(info.version, "")
        XCTAssertNil(info.installSizeBytes)
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

    func testMalformedPseudoBookRefreshDoesNotOverwriteCachedMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validData = """
        [
          {"id": "ESV", "suggested": "Please contact the copyright holder."}
        ]
        """.data(using: .utf8)!
        let malformedData = Data("<html>temporary failure</html>".utf8)
        var responseBodies = [validData, malformedData]

        PseudoBooksMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responseBodies.removeFirst())
        }
        defer { PseudoBooksMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: Self.makePseudoBooksMockSession()
        )

        let refreshedModules = try await repository.refreshPseudoModules()
        XCTAssertEqual(refreshedModules.map(\.name), ["ESV"])
        XCTAssertEqual(repository.loadCachedPseudoModules().map(\.name), ["ESV"])

        do {
            _ = try await repository.refreshPseudoModules()
            XCTFail("Expected malformed pseudo book metadata to fail decoding.")
        } catch {
            XCTAssertEqual(repository.loadCachedPseudoModules().map(\.name), ["ESV"])
        }
    }

    /**
     Verifies recommended-document refresh failures preserve the last valid Android metadata cache.

     Downloads and startup default-module selection rely on this cache when GitHub-hosted metadata is
     malformed or temporarily unavailable. A failure means a transient server problem can erase the
     Android-compatible recommendation state even though the prior cache is still valid.
     */
    func testRecommendedDocumentRefreshPreservesCachedMetadataAfterFailures() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let validData = """
        {
          "bibles": {"en": ["KJV::CrossWire"]},
          "commentaries": {},
          "dictionaries": {},
          "books": {},
          "maps": {}
        }
        """.data(using: .utf8)!
        let malformedData = Data("<html>temporary failure</html>".utf8)
        var responses = [
            (statusCode: 200, data: validData),
            (statusCode: 200, data: malformedData),
            (statusCode: 500, data: Data("temporary failure".utf8))
        ]

        PseudoBooksMockURLProtocol.requestHandler = { request in
            let responsePayload = responses.removeFirst()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: responsePayload.statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, responsePayload.data)
        }
        defer { PseudoBooksMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: Self.makePseudoBooksMockSession()
        )

        let refreshedMetadata = try await repository.refreshRecommendedDocuments()
        XCTAssertEqual(refreshedMetadata.bibles["en"], ["KJV::CrossWire"])
        XCTAssertEqual(repository.loadCachedRecommendedDocuments()?.bibles["en"], ["KJV::CrossWire"])

        do {
            _ = try await repository.refreshRecommendedDocuments()
            XCTFail("Expected malformed recommended-document metadata to fail decoding.")
        } catch {
            XCTAssertEqual(repository.loadCachedRecommendedDocuments()?.bibles["en"], ["KJV::CrossWire"])
        }

        do {
            _ = try await repository.refreshRecommendedDocuments()
            XCTFail("Expected non-200 recommended-document metadata to fail downloading.")
        } catch {
            XCTAssertEqual(repository.loadCachedRecommendedDocuments()?.bibles["en"], ["KJV::CrossWire"])
        }
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
        XCTAssertEqual(ModuleCategory(typeString: "And Bible"), .addon)
        XCTAssertEqual(ModuleCategory(typeString: "Unknown Type"), .unknown)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "MyBibleBible"), .bible)
        XCTAssertEqual(ModuleCategory(typeString: "Unknown", modDrv: "MyBibleDictionary"), .dictionary)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "MyBibleCommentary"), .commentary)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "MySwordDictionary"), .dictionary)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "ESwordBible"), .bible)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "RawLD4"), .dictionary)
        XCTAssertEqual(ModuleCategory(typeString: "", modDrv: "RawGenBook"), .generalBook)
    }

    /**
     Verifies restored Android custom-driver configs participate in shared installed inventory.

     Android registers `MyBibleDictionary` as a JSword dictionary `BookType`, so restored BDBT-style
     configs must appear as dictionaries even when their `Category=` line is absent or `Unknown`.

     - Setup: Writes a minimal `mods.d` config plus readable `module.SQLite3` payload.
     - Expected result: `installedModules()` and category filtering both expose the dictionary row.
     - Failure meaning: Reader/settings/download filters are likely hiding restored Android modules.
     */
    func testInstalledModulesIncludesRestoredAndroidMyBibleDictionary() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let modsDir = swordDir.appendingPathComponent("mods.d", isDirectory: true)
        let moduleDir = swordDir
            .appendingPathComponent("modules/texts/MyBible/BDBT", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        [BDBT]
        Description=Brown-Driver-Briggs' Hebrew Definitions / Thayer's Greek Definitions
        Category=Unknown
        DataPath=./modules/texts/MyBible/BDBT/
        ModDrv=MyBibleDictionary
        Lang=en
        Feature=GreekDef
        Feature=HebrewDef
        """.write(
            to: modsDir.appendingPathComponent("bdbt.conf"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: moduleDir.appendingPathComponent("module.SQLite3"))

        let manager = try XCTUnwrap(SwordManager(modulePath: swordDir.path))
        let modules = manager.installedModules()
        let bdbt = try XCTUnwrap(modules.first { $0.name == "BDBT" })

        XCTAssertEqual(bdbt.category, .dictionary)
        XCTAssertEqual(bdbt.language, "en")
        XCTAssertTrue(bdbt.features.contains(.greekDef))
        XCTAssertTrue(bdbt.features.contains(.hebrewDef))
        XCTAssertTrue(manager.installedModules(category: .dictionary).contains { $0.name == "BDBT" })
    }

    /**
     Verifies Android custom-driver configs cannot escape the SWORD install root.

     Restored Android configs should describe payloads unpacked into the local module tree. A
     readable SQLite file elsewhere on disk must not become visible through installed inventory just
     because a config path points to it.

     - Setup: Writes a `MyBibleDictionary` row with an absolute external `DataPath`.
     - Expected result: `installedModules()` ignores the row.
     - Failure meaning: Inventory parity is being achieved by trusting unsafe metadata rather than by
       restoring Android modules into the same local module contract.
     */
    func testInstalledModulesRejectsCustomPayloadOutsideSwordRoot() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let modsDir = swordDir.appendingPathComponent("mods.d", isDirectory: true)
        let externalModuleDir = tempDir
            .appendingPathComponent("outside", isDirectory: true)
            .appendingPathComponent("BDBT", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalModuleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        [BDBT]
        Description=Brown-Driver-Briggs' Hebrew Definitions / Thayer's Greek Definitions
        Category=Unknown
        DataPath=\(externalModuleDir.path)
        ModDrv=MyBibleDictionary
        Lang=en
        """.write(
            to: modsDir.appendingPathComponent("bdbt.conf"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: externalModuleDir.appendingPathComponent("module.SQLite3"))

        let manager = try XCTUnwrap(SwordManager(modulePath: swordDir.path))

        XCTAssertFalse(manager.installedModules().contains { $0.name == "BDBT" })
    }

    /**
     Verifies manifest-installed MyBible packages use the same inventory contract as SWORD modules.

     Android adds downloaded MyBible packages to `Books.installed().books`. iOS stores those packages
     in a sidecar directory, but `SwordManager.installedModules()` must still expose them so Downloads,
     settings, and reader pickers do not each maintain a different installed-module definition.

     - Setup: Writes a sidecar `module.json` and readable `.SQLite3` payload under `sword/mybible`.
     - Expected result: `installedModules()` includes the MyBible row and `moduleCount` agrees.
     - Failure meaning: MyBible package installs are only visible to Downloads and Android parity has
       regressed.
     */
    func testInstalledModulesIncludesMyBiblePackageSidecarModules() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let moduleDir = swordDir
            .appendingPathComponent("mybible", isDirectory: true)
            .appendingPathComponent("MyBible-finrk_SQLite3", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metadata = InstalledMyBibleModule(
            name: "MyBible-finrk_SQLite3",
            description: "Finnish RK",
            category: ModuleCategory.bible.rawValue,
            language: "fi",
            version: "2026-06-27",
            sourceName: "Example MyBible",
            packageFileName: "finrk.SQLite3.zip",
            downloadURL: "https://example.test/finrk.SQLite3.zip",
            installedAt: Date(timeIntervalSince1970: 0)
        )
        try JSONEncoder().encode(metadata).write(
            to: moduleDir.appendingPathComponent("module.json"),
            options: .atomic
        )
        try Data().write(to: moduleDir.appendingPathComponent("finrk.SQLite3"))

        let manager = try XCTUnwrap(SwordManager(modulePath: swordDir.path))
        let modules = manager.installedModules()
        let finrk = try XCTUnwrap(modules.first { $0.name == "MyBible-finrk_SQLite3" })

        XCTAssertEqual(finrk.description, "Finnish RK")
        XCTAssertEqual(finrk.category, .bible)
        XCTAssertEqual(finrk.language, "fi")
        XCTAssertEqual(manager.moduleCount, modules.count)
    }

    /**
     Verifies stale MyBible sidecar metadata does not produce an installed-book row.

     Android's MyBible import only adds a book when the SQLite payload can be opened. iOS should not
     create a visible installed module from `module.json` alone.

     - Setup: Writes sidecar metadata without any SQLite/MyBible payload file.
     - Expected result: The package row is absent from `installedModules()`.
     - Failure meaning: Stale sidecars can make Downloads/settings/reader lists advertise unusable
       modules.
     */
    func testInstalledModulesSkipsMyBiblePackageSidecarWithoutPayload() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let moduleDir = swordDir
            .appendingPathComponent("mybible", isDirectory: true)
            .appendingPathComponent("MyBible-finrk_SQLite3", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let metadata = InstalledMyBibleModule(
            name: "MyBible-finrk_SQLite3",
            description: "Finnish RK",
            category: ModuleCategory.bible.rawValue,
            language: "fi",
            version: "2026-06-27",
            sourceName: "Example MyBible",
            packageFileName: "finrk.SQLite3.zip",
            downloadURL: "https://example.test/finrk.SQLite3.zip",
            installedAt: Date(timeIntervalSince1970: 0)
        )
        try JSONEncoder().encode(metadata).write(
            to: moduleDir.appendingPathComponent("module.json"),
            options: .atomic
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: swordDir.path))

        XCTAssertFalse(manager.installedModules().contains { $0.name == "MyBible-finrk_SQLite3" })
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

    private static func makePseudoBooksMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PseudoBooksMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class PseudoBooksMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            fatalError("PseudoBooksMockURLProtocol.requestHandler must be set before use")
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
