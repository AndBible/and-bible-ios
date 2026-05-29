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
