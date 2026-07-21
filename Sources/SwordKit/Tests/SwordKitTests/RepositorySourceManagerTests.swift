import Foundation
import XCTest
@testable import SwordKit

/**
 App-host-free package coverage for Android-parity custom repository source management.

 `RepositorySourceManager` is owned by SwordKit because it reads and mutates SWORD
 `InstallMgr.conf` rows plus the iOS sidecar metadata needed to model Android/MyBible repository
 sources. These tests run in the SwordKit package lane with a local mocked URL session so manifest
 parsing, sidecar repair, default-source protection, and reset behavior stay independent of the app
 target and UI helpers.
 */
final class RepositorySourceManagerTests: XCTestCase {
    override func tearDown() {
        RepositorySourceManagerMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /**
     Verifies an Android-style SWORD HTTPS manifest becomes a persisted `InstallMgr.conf` source.

     The mocked manifest supplies host, catalog, package, and manifest URL metadata. The expected
     result is that `RepositorySourceManager` writes a SWORD-compatible HTTP source while preserving
     package metadata for later Downloads installs. A failure means custom SWORD repositories can be
     accepted by the UI but not survive reload through SwordKit.
     */
    func testRepositorySourceManagerAddsSwordHTTPSManifestSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "Example Repo",
          "description": "Example catalog",
          "type": "sword-https",
          "host": "example.org",
          "catalogDirectory": "/sword",
          "packageDirectory": "/sword/packages",
          "manifestUrl": "https://example.org/sword/manifest.json"
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.org/sword/manifest.json")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        let registration = try await manager.addCustomSource(from: "https://example.org/sword/manifest.json")

        XCTAssertEqual(registration.source.name, "Example Repo")
        XCTAssertEqual(registration.source.type, "HTTP")
        XCTAssertEqual(registration.source.host, "example.org")
        XCTAssertEqual(registration.source.catalogPath, "/sword")
        XCTAssertEqual(registration.packageDirectory, "/sword/packages")

        let config = try String(
            contentsOf: tempDir.appendingPathComponent("InstallMgr.conf"),
            encoding: .utf8
        )
        XCTAssertTrue(config.contains("HTTPSource=Example Repo|example.org|/sword"))
        XCTAssertTrue(manager.loadSources().contains { $0.name == "Example Repo" })
    }

    /**
     Verifies Android's editable SWORD package directory overrides manifest metadata and round-trips.

     Setup:
     - serves a manifest whose package path differs from the editor value
     - adds and then replaces the same custom source with two explicit package paths

     Expected result:
     - normalized editor values win over manifest/default/heuristic paths
     - reload after each write returns the explicit value from persisted sidecar metadata

     Failure meaning:
     - repositories that Android can install through a custom package directory remain impossible to
       configure on iOS, or edits appear to save but package downloads still use stale paths.
     */
    func testRepositorySourceManagerPersistsEditablePackageDirectoryOverride() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = Data(
            """
            {
              "name": "Editable Repo",
              "description": "Editable package path",
              "type": "sword-https",
              "host": "example.org",
              "catalogDirectory": "/catalog",
              "packageDirectory": "/manifest/packages",
              "manifestUrl": "https://example.org/manifest.json"
            }
            """.utf8
        )
        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }
        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        let added = try await manager.addCustomSource(
            from: "https://example.org/manifest.json",
            packageDirectory: " custom/packages/ "
        )
        XCTAssertEqual(added.packageDirectory, "/custom/packages")
        XCTAssertEqual(
            manager.loadSources().first { $0.name == "Editable Repo" }?.packageDirectory,
            "/custom/packages"
        )

        let replaced = try await manager.replaceCustomSource(
            named: "Editable Repo",
            with: "https://example.org/manifest.json",
            packageDirectory: "/second/packages"
        )
        XCTAssertEqual(replaced.packageDirectory, "/second/packages")
        XCTAssertEqual(
            manager.loadSources().first { $0.name == "Editable Repo" }?.packageDirectory,
            "/second/packages"
        )
    }

    /**
     Verifies unsafe package-directory editor input is rejected before source persistence.

     Failure means a custom repository can escape its host path, inject configuration syntax, or
     save a value that cannot produce Android-compatible package URLs.
     */
    func testRepositorySourceManagerRejectsUnsafeEditablePackageDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = Data(
            """
            {
              "name": "Unsafe Repo",
              "description": "Unsafe package path",
              "type": "sword-https",
              "host": "example.org",
              "catalogDirectory": "/catalog",
              "packageDirectory": "/manifest/packages",
              "manifestUrl": "https://example.org/manifest.json"
            }
            """.utf8
        )
        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }
        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        do {
            _ = try await manager.addCustomSource(
                from: "https://example.org/manifest.json",
                packageDirectory: "../outside"
            )
            XCTFail("Expected traversal package directory to be rejected.")
        } catch RepositorySourceManagementError.invalidPackageDirectory(let value) {
            XCTAssertEqual(value, "../outside")
        }
        XCTAssertFalse(manager.loadSources().contains { $0.name == "Unsafe Repo" })
    }

    /**
     Verifies SWORD package directories are normalized before persistence and reload.

     Android package directories are repository paths. iOS accepts Android-style manifests and direct
     sidecar reloads, so relative manifest values must become root-relative paths before Downloads
     later builds package ZIP URLs from the host/path tuple.
     */
    func testRepositorySourceManagerNormalizesRelativeSwordManifestPackageDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "Relative Repo",
          "description": "Relative package catalog",
          "type": "sword-https",
          "host": "example.org",
          "catalogDirectory": "/sword",
          "packageDirectory": "sword/packages",
          "manifestUrl": "https://example.org/sword/manifest.json"
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.org/sword/manifest.json")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        let registration = try await manager.addCustomSource(from: "https://example.org/sword/manifest.json")

        XCTAssertEqual(registration.packageDirectory, "/sword/packages")
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Relative Repo" })
        XCTAssertEqual(source.packageDirectory, "/sword/packages")

        let sidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        let record = try XCTUnwrap(repositories.first { ($0["name"] as? String) == "Relative Repo" })
        XCTAssertEqual(record["packageDirectory"] as? String, "/sword/packages")
    }

    /**
     Verifies empty SWORD package directories fall back to the Android default package path.

     A manifest can include a blank package directory. Android/JSword behavior treats missing package
     metadata as a catalog-relative packages path, so iOS must normalize blank values to that fallback
     instead of persisting an empty package URL component.
     */
    func testRepositorySourceManagerFallsBackForBlankSwordManifestPackageDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "Blank Package Repo",
          "description": "Blank package catalog",
          "type": "sword-https",
          "host": "example.org",
          "catalogDirectory": "/sword",
          "packageDirectory": "   ",
          "manifestUrl": "https://example.org/sword/manifest.json"
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.org/sword/manifest.json")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        let registration = try await manager.addCustomSource(from: "https://example.org/sword/manifest.json")

        XCTAssertEqual(registration.packageDirectory, "/sword/packages")
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Blank Package Repo" })
        XCTAssertEqual(source.packageDirectory, "/sword/packages")

        let sidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        let record = try XCTUnwrap(repositories.first { ($0["name"] as? String) == "Blank Package Repo" })
        XCTAssertEqual(record["packageDirectory"] as? String, "/sword/packages")
    }

    /**
     Ensures untrusted manifest metadata cannot downgrade the persisted manifest URL.

     The request URL is HTTPS, but the manifest body advertises an HTTP `manifestUrl`. The expected
     result is that iOS stores the validated HTTPS URL that the user supplied. A failure means sidecar
     metadata can retain insecure Android/SWORD repository URLs after validation.
     */
    func testRepositorySourceManagerIgnoresNonHTTPSSwordManifestURLMetadata() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "Example Repo",
          "description": "Example catalog",
          "type": "sword-https",
          "host": "example.org",
          "catalogDirectory": "/sword",
          "packageDirectory": "/sword/packages",
          "manifestUrl": "http://example.org/sword/manifest.json"
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.org/sword/manifest.json")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        let registration = try await manager.addCustomSource(from: "https://example.org/sword/manifest.json")

        XCTAssertEqual(registration.manifestURL.absoluteString, "https://example.org/sword/manifest.json")
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Example Repo" })
        XCTAssertEqual(source.manifestURL?.absoluteString, "https://example.org/sword/manifest.json")

        let sidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(
            repositories.compactMap { $0["manifestURL"] as? String },
            ["https://example.org/sword/manifest.json"]
        )
    }

    /**
     Verifies legacy `InstallMgr.conf`-only custom SWORD rows are backfilled into sidecar metadata.

     The setup appends a custom HTTP source with no JSON sidecar. Loading sources should synthesize
     Android-compatible repository type, package, manifest, and source URL metadata and persist that
     repair. A failure means older custom repositories remain partially modeled after upgrade.
     */
    func testRepositorySourceManagerBackfillsSourceOnlyCustomSwordMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Legacy Repo|legacy.example|/catalog\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Legacy Repo" })

        XCTAssertEqual(source.repositoryType, SourceConfig.swordHTTPSRepositoryType)
        XCTAssertEqual(source.description, "https://legacy.example/catalog")
        XCTAssertEqual(source.packageDirectory, "/catalog/packages")
        XCTAssertEqual(source.manifestURL?.absoluteString, "https://legacy.example/catalog")
        XCTAssertEqual(source.sourceURL?.absoluteString, "https://legacy.example/catalog")

        let sidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(repositories.count, 1)

        let record = try XCTUnwrap(repositories.first)
        XCTAssertEqual(record["name"] as? String, "Legacy Repo")
        XCTAssertEqual(record["description"] as? String, "https://legacy.example/catalog")
        XCTAssertEqual(record["type"] as? String, SourceConfig.swordHTTPSRepositoryType)
        XCTAssertEqual(record["host"] as? String, "legacy.example")
        XCTAssertEqual(record["catalogDirectory"] as? String, "/catalog")
        XCTAssertEqual(record["packageDirectory"] as? String, "/catalog/packages")
        XCTAssertEqual(record["manifestURL"] as? String, "https://legacy.example/catalog")
        XCTAssertEqual(record["sourceURL"] as? String, "https://legacy.example/catalog")
    }

    /**
     Protects unreadable sidecar data from destructive repair attempts.

     The setup has a valid legacy SWORD row plus malformed sidecar JSON. The expected result is that
     load-time metadata is repaired in memory while the unreadable sidecar bytes are left untouched.
     A failure means a bad sidecar can be silently overwritten during a read-only source load.
     */
    func testRepositorySourceManagerDoesNotOverwriteUnreadableSidecarDuringBackfill() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Legacy Repo|legacy.example|/catalog\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let sidecarURL = tempDir.appendingPathComponent("CustomRepositories.json")
        let unreadableSidecar = Data("{\"version\":1,\"repositories\":[".utf8)
        try unreadableSidecar.write(to: sidecarURL)

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Legacy Repo" })

        XCTAssertEqual(source.manifestURL?.absoluteString, "https://legacy.example/catalog")
        XCTAssertEqual(source.packageDirectory, "/catalog/packages")
        XCTAssertEqual(try Data(contentsOf: sidecarURL), unreadableSidecar)
    }

    /**
     Verifies sidecar package directories are normalized when merged onto SWORD config rows.

     Older sidecars can contain Android package-directory values before iOS normalized them at write
     time. Loading must normalize the merged `SourceConfig` so Downloads package installs receive
     the same root-relative repository path Android passes to JSword.
     */
    func testRepositorySourceManagerNormalizesSidecarPackageDirectoryWhenMergingConfigSource() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Sidecar Repo|sidecar.example|/catalog\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let sidecar = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Sidecar Repo",
              "description": "Sidecar catalog",
              "type": "sword-https",
              "host": "sidecar.example",
              "catalogDirectory": "/catalog",
              "packageDirectory": " packages ",
              "manifestURL": "https://sidecar.example/catalog",
              "sourceURL": "https://sidecar.example/catalog"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecar.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Sidecar Repo" })

        XCTAssertEqual(source.packageDirectory, "/packages")
    }

    /**
     Verifies whitespace-only package metadata is treated as absent when loading old sidecars.

     A whitespace string is not an Android package directory. Keeping it as non-nil empty metadata
     can hide the direct-catalog fallback path, so the source model should expose `nil` instead.
     */
    func testRepositorySourceManagerTreatsWhitespaceSidecarPackageDirectoryAsMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Whitespace Repo|whitespace.example|/catalog\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let sidecar = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Whitespace Repo",
              "description": "Whitespace catalog",
              "type": "sword-https",
              "host": "whitespace.example",
              "catalogDirectory": "/catalog",
              "packageDirectory": "   ",
              "manifestURL": "https://whitespace.example/catalog",
              "sourceURL": "https://whitespace.example/catalog"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecar.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Whitespace Repo" })

        XCTAssertNil(source.packageDirectory)
    }

    /**
     Verifies an Android/MyBible manifest is stored only in the sidecar repository list.

     MyBible repositories are not SWORD install-manager sources, so adding one should persist sidecar
     metadata without projecting an `HTTPSource` row into `InstallMgr.conf`. A failure means MyBible
     repository setup can pollute SWORD config or disappear from custom repository reloads.
     */
    func testRepositorySourceManagerAddsMyBibleManifestSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "url": "https://mybible.example/manifest.json",
          "file_name": "Example MyBible",
          "description": "Example MyBible catalog | Android",
          "modules": [
            {
              "file_name": "finrk.SQLite3.zip",
              "description": "Finnish RK",
              "download_url": "https://mybible.example/finrk.SQLite3.zip",
              "language_code": "fi",
              "update_date": "2026-05-01",
              "update_info": "initial"
            }
          ]
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mybible.example/manifest.json")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        let registration = try await manager.addCustomSource(from: "https://mybible.example/manifest.json")

        XCTAssertEqual(registration.source.name, "Example MyBible")
        XCTAssertTrue(registration.source.isMyBibleRepository)
        XCTAssertEqual(registration.source.manifestURL?.absoluteString, "https://mybible.example/manifest.json")
        XCTAssertEqual(registration.type, SourceConfig.myBibleHTTPSRepositoryType)

        let config = try String(
            contentsOf: tempDir.appendingPathComponent("InstallMgr.conf"),
            encoding: .utf8
        )
        XCTAssertFalse(
            config.contains("HTTPSource=Example MyBible"),
            "MyBible repositories should not be projected into SWORD InstallMgr.conf."
        )

        let loadedSource = try XCTUnwrap(manager.loadSources().first { $0.name == "Example MyBible" })
        XCTAssertTrue(loadedSource.isMyBibleRepository)
        XCTAssertEqual(loadedSource.description, "Example MyBible catalog | Android")
        XCTAssertEqual(loadedSource.manifestURL?.absoluteString, "https://mybible.example/manifest.json")

        try manager.deleteCustomSource(named: "Example MyBible")
        XCTAssertFalse(manager.loadSources().contains { $0.name == "Example MyBible" })
    }

    /**
     Ensures MyBible sidecar repositories remain available when SWORD config cannot be read.

     The setup makes `InstallMgr.conf` a directory and provides both MyBible and SWORD sidecar rows.
     The expected result is that only the sidecar-only MyBible repository is loaded. A failure means
     SWORD config failures can hide Android MyBible repositories or expose unusable SWORD rows.
     */
    func testRepositorySourceManagerLoadsMyBibleSidecarWhenSwordConfigUnreadable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("InstallMgr.conf", isDirectory: true),
            withIntermediateDirectories: true
        )
        let sidecarData = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Example MyBible",
              "description": "Example MyBible catalog",
              "type": "mybible-https",
              "host": "mybible.example",
              "catalogDirectory": "/manifest.json",
              "packageDirectory": "",
              "manifestURL": "https://mybible.example/manifest.json",
              "sourceURL": "https://mybible.example/manifest.json"
            },
            {
              "name": "Example SWORD",
              "description": "Example SWORD catalog",
              "type": "sword-https",
              "host": "sword.example",
              "catalogDirectory": "/sword",
              "packageDirectory": "/sword/packages",
              "manifestURL": "https://sword.example/manifest.json",
              "sourceURL": "https://sword.example/sword"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecarData.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let sources = manager.loadSources()

        XCTAssertEqual(sources.map(\.name), ["Example MyBible"])
        let source = try XCTUnwrap(sources.first)
        XCTAssertTrue(source.isMyBibleRepository)
        XCTAssertEqual(source.manifestURL?.absoluteString, "https://mybible.example/manifest.json")
    }

    /**
     Verifies invalid sidecar repository rows are ignored while valid MyBible rows still load.

     The fixture includes a path-traversal name, an HTTP manifest URL, and one valid HTTPS MyBible
     repository. The expected result is that only the safe repository is returned. A failure means
     stale or malicious sidecar rows can leak into Downloads source lists.
     */
    func testRepositorySourceManagerDropsInvalidSidecarRecords() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("InstallMgr.conf", isDirectory: true),
            withIntermediateDirectories: true
        )
        let sidecarData = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "../Escape",
              "description": "Unsafe name",
              "type": "mybible-https",
              "host": "unsafe.example",
              "catalogDirectory": "/manifest.json",
              "packageDirectory": "",
              "manifestURL": "https://unsafe.example/manifest.json",
              "sourceURL": "https://unsafe.example/manifest.json"
            },
            {
              "name": "HTTP MyBible",
              "description": "Unsafe scheme",
              "type": "mybible-https",
              "host": "http.example",
              "catalogDirectory": "/manifest.json",
              "packageDirectory": "",
              "manifestURL": "http://http.example/manifest.json",
              "sourceURL": "http://http.example/manifest.json"
            },
            {
              "name": "Example MyBible",
              "description": "Example MyBible catalog",
              "type": "mybible-https",
              "host": "mybible.example",
              "catalogDirectory": "/manifest.json",
              "packageDirectory": "",
              "manifestURL": "https://mybible.example/manifest.json",
              "sourceURL": "https://mybible.example/manifest.json"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecarData.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let sources = manager.loadSources()

        XCTAssertEqual(sources.map(\.name), ["Example MyBible"])
        XCTAssertEqual(sources.first?.manifestURL?.absoluteString, "https://mybible.example/manifest.json")
    }

    /**
     Protects SWORD sidecar repair when persisted manifest metadata is not HTTPS.

     The SWORD config row is valid, but its sidecar manifest URL is HTTP. Loading should repair the
     source to the HTTPS catalog URL and persist the repaired manifest metadata. A failure means
     repository reload can keep insecure stale URLs even after the SWORD source row is safe.
     */
    func testRepositorySourceManagerRepairsSwordSidecarWithNonHTTPSManifestURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = """
        [General]

        [Sources]
        HTTPSource=Example SWORD|sword.example|/sword
        """
        try config.write(
            to: tempDir.appendingPathComponent("InstallMgr.conf"),
            atomically: true,
            encoding: .utf8
        )

        let sidecarData = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Example SWORD",
              "description": "Unsafe manifest metadata",
              "type": "sword-https",
              "host": "sword.example",
              "catalogDirectory": "/sword",
              "packageDirectory": "/sword/packages",
              "manifestURL": "http://sword.example/manifest.json",
              "sourceURL": "https://sword.example/sword"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecarData.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Example SWORD" })

        XCTAssertEqual(source.host, "sword.example")
        XCTAssertEqual(source.catalogPath, "/sword")
        XCTAssertEqual(source.manifestURL?.absoluteString, "https://sword.example/sword")
        XCTAssertEqual(source.sourceURL?.absoluteString, "https://sword.example/sword")
        XCTAssertEqual(source.description, "https://sword.example/sword")
        XCTAssertEqual(source.packageDirectory, "/sword/packages")

        let repairedSidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let repairedSidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: repairedSidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(repairedSidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(repositories.compactMap { $0["manifestURL"] as? String }, ["https://sword.example/sword"])
    }

    /**
     Verifies MyBible add and replace operations work through sidecar storage without readable SWORD config.

     The setup makes `InstallMgr.conf` unreadable, adds a MyBible source, then replaces it with a
     different manifest. The expected result is an ordered sidecar replacement with no dependency on
     SWORD config writes. A failure means MyBible repository management is coupled to SWORD-only
     storage.
     */
    func testRepositorySourceManagerAddsAndReplacesMyBibleWhenSwordConfigUnreadable() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("InstallMgr.conf", isDirectory: true),
            withIntermediateDirectories: true
        )

        let manifestNamesByHost = [
            "initial.example": "Initial MyBible",
            "updated.example": "Updated MyBible"
        ]
        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let host = try XCTUnwrap(request.url?.host)
            let fileName = try XCTUnwrap(manifestNamesByHost[host])
            let manifestData = """
            {
              "url": "\(request.url!.absoluteString)",
              "file_name": "\(fileName)",
              "description": "\(fileName) catalog",
              "modules": []
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        let added = try await manager.addCustomSource(from: "https://initial.example/manifest.json")
        XCTAssertEqual(added.source.name, "Initial MyBible")
        XCTAssertEqual(manager.loadSources().map(\.name), ["Initial MyBible"])

        let replacement = try await manager.replaceCustomSource(
            named: "Initial MyBible",
            with: "https://updated.example/manifest.json"
        )

        XCTAssertEqual(replacement.source.name, "Updated MyBible")
        let sources = manager.loadSources()
        XCTAssertEqual(sources.map(\.name), ["Updated MyBible"])
        XCTAssertEqual(sources.first?.manifestURL?.absoluteString, "https://updated.example/manifest.json")
    }

    /**
     Ensures deleting a sidecar-only MyBible repository succeeds when SWORD config is unreadable.

     The fixture includes one MyBible and one SWORD sidecar row while `InstallMgr.conf` is a
     directory. Deleting the MyBible row should update only sidecar metadata and leave SWORD deletion
     rejected because config cannot be read. A failure means sidecar-only repositories inherit SWORD
     config failure behavior.
     */
    func testRepositorySourceManagerDeletesMyBibleSidecarWhenSwordConfigUnreadable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("InstallMgr.conf", isDirectory: true),
            withIntermediateDirectories: true
        )
        let sidecarURL = tempDir.appendingPathComponent("CustomRepositories.json")
        let sidecarData = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Example MyBible",
              "description": "Example MyBible catalog",
              "type": "mybible-https",
              "host": "mybible.example",
              "catalogDirectory": "/manifest.json",
              "packageDirectory": "",
              "manifestURL": "https://mybible.example/manifest.json",
              "sourceURL": "https://mybible.example/manifest.json"
            },
            {
              "name": "Example SWORD",
              "description": "Example SWORD catalog",
              "type": "sword-https",
              "host": "sword.example",
              "catalogDirectory": "/sword",
              "packageDirectory": "/sword/packages",
              "manifestURL": "https://sword.example/manifest.json",
              "sourceURL": "https://sword.example/sword"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecarData.write(to: sidecarURL)

        let manager = RepositorySourceManager(basePath: tempDir.path)
        XCTAssertEqual(manager.loadSources().map(\.name), ["Example MyBible"])

        try manager.deleteCustomSource(named: "Example MyBible")

        XCTAssertTrue(manager.loadSources().isEmpty)
        let updatedSidecarData = try Data(contentsOf: sidecarURL)
        let updatedSidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: updatedSidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(updatedSidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(repositories.compactMap { $0["name"] as? String }, ["Example SWORD"])
        XCTAssertThrowsError(try manager.deleteCustomSource(named: "Example SWORD")) { error in
            XCTAssertEqual(error as? RepositorySourceManagementError, .configReadFailed)
        }
    }

    /**
     Verifies replacing a MyBible repository preserves its position in Android-style source ordering.

     The setup adds first/middle/last MyBible repositories and replaces the middle one. The expected
     result is that both load order and persisted sidecar order keep the replacement in the middle.
     A failure means source replacement can reorder Downloads repositories unexpectedly.
     */
    func testRepositorySourceManagerPreservesMyBibleOrderWhenReplacingSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestNamesByHost = [
            "first.example": "First MyBible",
            "middle.example": "Middle MyBible",
            "last.example": "Last MyBible",
            "middle-updated.example": "Middle Updated MyBible"
        ]

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let host = try XCTUnwrap(request.url?.host)
            let fileName = try XCTUnwrap(manifestNamesByHost[host])
            let manifestData = """
            {
              "url": "\(request.url!.absoluteString)",
              "file_name": "\(fileName)",
              "description": "\(fileName) catalog",
              "modules": []
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        _ = try await manager.addCustomSource(from: "https://first.example/manifest.json")
        _ = try await manager.addCustomSource(from: "https://middle.example/manifest.json")
        _ = try await manager.addCustomSource(from: "https://last.example/manifest.json")

        _ = try await manager.replaceCustomSource(
            named: "Middle MyBible",
            with: "https://middle-updated.example/manifest.json"
        )

        let customNames = manager.loadSources()
            .map(\.name)
            .filter { manifestNamesByHost.values.contains($0) }
        XCTAssertEqual(customNames, ["First MyBible", "Middle Updated MyBible", "Last MyBible"])

        let sidecarData = try Data(contentsOf: tempDir.appendingPathComponent("CustomRepositories.json"))
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(
            repositories.compactMap { $0["name"] as? String },
            ["First MyBible", "Middle Updated MyBible", "Last MyBible"]
        )
    }

    /**
     Ensures MyBible manifests cannot create repositories whose names collide with defaults.

     The mocked MyBible manifest uses `AndBible`, a built-in source name. The expected result is a
     duplicate-source error before any source is persisted. A failure means custom MyBible manifests
     can shadow Android/default repository entries.
     */
    func testRepositorySourceManagerRejectsDuplicateMyBibleRepositoryName() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "url": "https://duplicate.example/manifest.json",
          "file_name": "AndBible",
          "description": "Duplicate MyBible catalog",
          "modules": []
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        do {
            _ = try await manager.addCustomSource(from: "https://duplicate.example/manifest.json")
            XCTFail("Expected duplicate MyBible repository name to be rejected.")
        } catch RepositorySourceManagementError.duplicateSourceName(let name) {
            XCTAssertEqual(name, "AndBible")
        } catch {
            XCTFail("Unexpected duplicate MyBible repository error: \(error)")
        }
    }

    /**
     Verifies structurally invalid MyBible manifests are rejected without persisting source rows.

     The mocked manifest omits the required modules array. The expected result is an invalid-manifest
     error and no source with that name after reload. A failure means incomplete Android/MyBible
     repository metadata can enter the source list.
     */
    func testRepositorySourceManagerRejectsInvalidMyBibleManifest() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "url": "https://invalid.example/manifest.json",
          "file_name": "Invalid MyBible",
          "description": "Missing modules"
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        do {
            _ = try await manager.addCustomSource(from: "https://invalid.example/manifest.json")
            XCTFail("Expected invalid MyBible manifest to be rejected.")
        } catch RepositorySourceManagementError.invalidManifest {
            XCTAssertFalse(manager.loadSources().contains { $0.name == "Invalid MyBible" })
        } catch {
            XCTFail("Unexpected invalid MyBible manifest error: \(error)")
        }
    }

    /**
     Ensures unsupported manifest types fail explicitly and do not fall through to SWORD/MyBible handling.

     The fixture serves a manifest with an unknown type. The expected result is an
     `unsupportedRepositoryType` error containing that type. A failure means new or malformed manifest
     types can be silently interpreted as a supported repository family.
     */
    func testRepositorySourceManagerRejectsUnsupportedManifestType() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "type": "unsupported-https",
          "name": "Unsupported Repo"
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        do {
            _ = try await manager.addCustomSource(from: "https://unsupported.example/manifest.json")
            XCTFail("Expected unsupported custom repository type to be rejected.")
        } catch RepositorySourceManagementError.unsupportedRepositoryType(let type) {
            XCTAssertEqual(type, "unsupported-https")
        } catch {
            XCTFail("Unexpected unsupported manifest error: \(error)")
        }
    }

    /**
     Verifies direct SWORD catalog URLs fall back to Android-compatible package and source metadata.

     The manifest URL returns 404 while catalog/package probes succeed. The expected result is a
     generated source name, preserved host including port, catalog path, package path, and source URL.
     A failure means users cannot add repositories that expose a JSword catalog without a manifest.
     */
    func testRepositorySourceManagerAddsDirectSwordCatalogFallbackSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let statusCode: Int
            let data: Data
            switch path {
            case "/sword", "/sword/packages", "/sword/mods.d.tar.gz":
                statusCode = 200
                data = Data("readable".utf8)
            case "/sword/manifest.json":
                statusCode = 404
                data = Data()
            default:
                XCTFail("Unexpected repository validation URL: \(request.url?.absoluteString ?? "")")
                statusCode = 404
                data = Data()
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, data)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        let registration = try await manager.addCustomSource(from: "https://custom.example:8443/sword")

        XCTAssertTrue(registration.source.name.hasPrefix("custom.example-"))
        XCTAssertEqual(registration.source.host, "custom.example:8443")
        XCTAssertEqual(registration.source.catalogPath, "/sword")
        XCTAssertEqual(registration.packageDirectory, "/sword/packages")
        XCTAssertEqual(registration.sourceURL.absoluteString, "https://custom.example:8443/sword")

        let config = try String(
            contentsOf: tempDir.appendingPathComponent("InstallMgr.conf"),
            encoding: .utf8
        )
        XCTAssertTrue(config.contains("HTTPSource=\(registration.source.name)|custom.example:8443|/sword"))
    }

    /**
     Ensures SWORD manifests cannot replace built-in repository names.

     The mocked SWORD manifest uses the default `AndBible` name. The expected result is a duplicate
     source error and no custom source write. A failure means custom manifests can shadow protected
     default repository rows.
     */
    func testRepositorySourceManagerRejectsDuplicateDefaultRepositoryName() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "AndBible",
          "description": "Duplicate default",
          "type": "sword-https",
          "host": "duplicate.example",
          "catalogDirectory": "/sword"
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        do {
            _ = try await manager.addCustomSource(from: "https://duplicate.example/manifest.json")
            XCTFail("Expected duplicate default repository name to be rejected.")
        } catch RepositorySourceManagementError.duplicateSourceName(let name) {
            XCTAssertEqual(name, "AndBible")
        } catch {
            XCTFail("Unexpected duplicate-source error: \(error)")
        }
    }

    /**
     Verifies stale SWORD sidecar metadata does not block a new validated source with the same name.

     The fixture has a sidecar-only SWORD row that is not present in `InstallMgr.conf`, then adds a
     validated manifest with the same name. The expected result is that the new validated metadata
     replaces the orphaned sidecar record. A failure means stale sidecars can prevent legitimate
     repository re-adds.
     */
    func testRepositorySourceManagerIgnoresOrphanedSwordSidecarForDuplicateNames() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let sidecarData = """
        {
          "version": 1,
          "repositories": [
            {
              "name": "Hidden Repo",
              "description": "Stale SWORD metadata",
              "type": "sword-https",
              "host": "stale.example",
              "catalogDirectory": "/stale",
              "packageDirectory": "/stale/packages",
              "manifestURL": "https://stale.example/manifest.json",
              "sourceURL": "https://stale.example/stale"
            }
          ]
        }
        """.data(using: .utf8)!
        try sidecarData.write(to: tempDir.appendingPathComponent("CustomRepositories.json"))

        let manifestData = """
        {
          "name": "Hidden Repo",
          "description": "Visible replacement",
          "type": "sword-https",
          "host": "visible.example",
          "catalogDirectory": "/sword",
          "packageDirectory": "/sword/packages",
          "manifestUrl": "https://visible.example/manifest.json"
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        let registration = try await manager.addCustomSource(from: "https://visible.example/manifest.json")

        XCTAssertEqual(registration.source.name, "Hidden Repo")
        let source = try XCTUnwrap(manager.loadSources().first { $0.name == "Hidden Repo" })
        XCTAssertEqual(source.host, "visible.example")

        let sidecarDataAfterAdd = try Data(
            contentsOf: tempDir.appendingPathComponent("CustomRepositories.json")
        )
        let sidecarJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: sidecarDataAfterAdd) as? [String: Any]
        )
        let repositories = try XCTUnwrap(sidecarJSON["repositories"] as? [[String: Any]])
        XCTAssertEqual(repositories.compactMap { $0["host"] as? String }, ["visible.example"])
    }

    /**
     Protects repository source persistence from manifest names that contain path separators.

     The mocked SWORD manifest uses `../custom`. The expected result is an invalid-manifest error,
     no config write, and no loaded source. A failure means repository names can escape their intended
     config/sidecar namespace.
     */
    func testRepositorySourceManagerRejectsManifestSourceNamesWithPathSeparators() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manifestData = """
        {
          "name": "../custom",
          "description": "Unsafe name",
          "type": "sword-https",
          "host": "unsafe.example",
          "catalogDirectory": "/sword"
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        do {
            _ = try await manager.addCustomSource(from: "https://unsafe.example/manifest.json")
            XCTFail("Expected manifest source names with path separators to be rejected.")
        } catch RepositorySourceManagementError.invalidManifest(let name) {
            XCTAssertEqual(name, "../custom")
        } catch {
            XCTFail("Unexpected path-separator validation error: \(error)")
        }

        let sourcesAfterFailure = manager.loadSources()
        let config = try String(
            contentsOf: tempDir.appendingPathComponent("InstallMgr.conf"),
            encoding: .utf8
        )
        XCTAssertFalse(config.contains("../custom"))
        XCTAssertFalse(sourcesAfterFailure.contains { $0.name == "../custom" })
    }

    /**
     Verifies delete semantics protect built-in sources while removing true custom SWORD rows.

     The setup adds one custom config row alongside defaults. Deleting `AndBible` should fail with a
     protected-default error, while deleting the custom row should remove it and preserve defaults.
     A failure means reset/delete UI can mutate Android default repository sources.
     */
    func testRepositorySourceManagerProtectsDefaultsAndDeletesCustomSources() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Example Repo|example.org|/sword\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = RepositorySourceManager(basePath: tempDir.path)

        XCTAssertThrowsError(try manager.deleteCustomSource(named: "AndBible")) { error in
            XCTAssertEqual(error as? RepositorySourceManagementError, .protectedDefaultSource("AndBible"))
        }

        try manager.deleteCustomSource(named: "Example Repo")

        let remaining = manager.loadSources()
        XCTAssertTrue(remaining.contains { $0.name == "AndBible" })
        XCTAssertFalse(remaining.contains { $0.name == "Example Repo" })
    }

    /**
     Verifies built-in Downloads sources retain Android's package and catalog directories separately.

     Android's `repositories.txt` defines both directories for every SWORD repository. iOS uses a
     SWORD-compatible config file as local plumbing, but the source model consumed by Downloads and
     installs must still expose the Android package directory instead of reconstructing it later.
     */
    func testRepositorySourceManagerLoadsAndroidDefaultPackageDirectories() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let manager = RepositorySourceManager(basePath: tempDir.path)
        let sources = manager.loadSources()

        let crossWire = try XCTUnwrap(sources.first { $0.name == "CrossWire" })
        XCTAssertEqual(crossWire.host, "crosswire.org")
        XCTAssertEqual(crossWire.catalogPath, "/ftpmirror/pub/sword/raw")
        XCTAssertEqual(crossWire.packageDirectory, "/ftpmirror/pub/sword/packages/rawzip")

        let step = try XCTUnwrap(sources.first { $0.name == "STEP Bible (Tyndale)" })
        XCTAssertEqual(step.host, "public.modules.stepbible.org")
        XCTAssertEqual(step.catalogPath, "/catalog")
        XCTAssertEqual(step.packageDirectory, "/packages")
    }

    /**
     Ensures reset-to-defaults removes custom SWORD rows, restores built-ins, and emits change notification.

     The setup appends a custom source then observes `sourcesDidChangeNotification`. The expected
     result is that reset posts the notification, removes the custom source, and leaves only default
     sources. A failure means Downloads repository reset can leave stale rows or fail to refresh UI.
     */
    func testRepositorySourceManagerResetToDefaultsRemovesCustomSourcesAndRestoresDefaults() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Example Repo|example.org|/sword\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = RepositorySourceManager(basePath: tempDir.path)
        XCTAssertTrue(manager.loadSources().contains { $0.name == "Example Repo" })

        let notificationExpectation = expectation(description: "Repository source reset posts change notification")
        let observer = NotificationCenter.default.addObserver(
            forName: RepositorySourceManager.sourcesDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        try manager.resetToDefaults()

        wait(for: [notificationExpectation], timeout: 1)
        let restoredSources = manager.loadSources()
        XCTAssertFalse(restoredSources.isEmpty)
        XCTAssertTrue(restoredSources.contains { $0.name == "AndBible" })
        XCTAssertFalse(restoredSources.contains { $0.name == "Example Repo" })
        XCTAssertTrue(restoredSources.allSatisfy(manager.isDefaultSource))
    }

    /**
     Verifies reset-to-defaults reports a write failure when default config cannot be recreated.

     The manager points at a missing base path that cannot produce a new `InstallMgr.conf`. The
     expected result is a `configWriteFailed` error with the recreation message. A failure means the
     reset UI cannot distinguish successful reset from failed default-source recreation.
     */
    func testRepositorySourceManagerResetToDefaultsReportsRecreationFailure() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let invalidBasePath = tempDir.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("blocking file".utf8).write(to: invalidBasePath)
        let manager = RepositorySourceManager(basePath: invalidBasePath.path)

        XCTAssertThrowsError(try manager.resetToDefaults()) { error in
            guard case .configWriteFailed(let message) = error as? RepositorySourceManagementError else {
                return XCTFail("Expected configWriteFailed, got \(error)")
            }
            XCTAssertFalse(
                message.isEmpty,
                "Persistence failures must retain an actionable file-system explanation."
            )
        }
    }

    /**
     Verifies replacing a custom SWORD source removes the old row and persists the validated replacement.

     The setup writes `Old Repo`, then replaces it with a validated manifest for `New Repo`. The
     expected result is that only the new source remains after reload. A failure means custom source
     replacement can duplicate or leave stale SWORD rows.
     */
    func testRepositorySourceManagerReplacesCustomSourceInPlace() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Old Repo|old.example|/sword\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let manifestData = """
        {
          "name": "New Repo",
          "description": "Replacement",
          "type": "sword-https",
          "host": "new.example",
          "catalogDirectory": "/catalog"
        }
        """.data(using: .utf8)!

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifestData)
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        let registration = try await manager.replaceCustomSource(
            named: "Old Repo",
            with: "https://new.example/manifest.json"
        )

        XCTAssertEqual(registration.source.name, "New Repo")

        let sourceNames = manager.loadSources().map(\.name)
        XCTAssertTrue(sourceNames.contains("New Repo"))
        XCTAssertFalse(sourceNames.contains("Old Repo"))
    }

    /**
     Ensures replacing a missing custom source fails before any network validation or config mutation.

     The request handler intentionally fails the test if invoked. The expected result is a
     `sourceNotFound` error and unchanged config bytes. A failure means replacement can validate or
     write a new repository when the user-selected source no longer exists.
     */
    func testRepositorySourceManagerRejectsReplacingMissingCustomSource() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        InstallManager.ensureDefaultConfigPublic(at: tempDir.path)
        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        let initialConfig = try String(contentsOf: configURL, encoding: .utf8)

        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            XCTFail("Replacing a missing source should fail before validating the replacement URL.")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let manager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession()
        )

        do {
            _ = try await manager.replaceCustomSource(
                named: "Missing Repo",
                with: "https://new.example/manifest.json"
            )
            XCTFail("Expected replacing a missing source to fail.")
        } catch RepositorySourceManagementError.sourceNotFound(let name) {
            XCTAssertEqual(name, "Missing Repo")
        }

        let config = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertEqual(config, initialConfig)
        XCTAssertFalse(manager.loadSources().contains { $0.name == "New Repo" })
    }

    /**
     Verifies every two-store repository mutation rolls back byte-for-byte when its second write fails.

     Each case starts from the same visible custom SWORD source and injects one failure specifically
     for `CustomRepositories.json`, after `InstallMgr.conf` has already changed. Add, edit, delete,
     Android-backup replacement, and reset must all throw, restore both original files, remove the
     journal, and expose only the original source after constructing a fresh manager. A failure means
     the two persistent stores can diverge under disk-full, permission, or interruption conditions.
     */
    func testRepositorySourceManagerRollsBackEveryTwoStoreMutationAfterSecondWriteFailure() async throws {
        enum Mutation: CaseIterable {
            case add
            case edit
            case delete
            case replaceAll
            case reset
        }

        let replacementManifest = Data(
            """
            {
              "name": "Replacement Repo",
              "description": "Replacement catalog",
              "type": "sword-https",
              "host": "replacement.example",
              "catalogDirectory": "/catalog",
              "packageDirectory": "/packages",
              "manifestUrl": "https://replacement.example/manifest.json"
            }
            """.utf8
        )
        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, replacementManifest)
        }

        for mutation in Mutation.allCases {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            try Self.seedRepositoryPersistence(at: tempDir)

            let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
            let sidecarURL = tempDir.appendingPathComponent("CustomRepositories.json")
            let journalURL = tempDir.appendingPathComponent("RepositorySources.transaction.json")
            let originalConfig = try Data(contentsOf: configURL)
            let originalSidecar = try Data(contentsOf: sidecarURL)
            let failure = RepositorySourceSecondStoreFailure()
            let manager = RepositorySourceManager(
                basePath: tempDir.path,
                session: Self.makeMockedURLSession(),
                persistence: failure.persistence
            )

            do {
                switch mutation {
                case .add:
                    _ = try await manager.addCustomSource(
                        from: "https://replacement.example/manifest.json"
                    )
                case .edit:
                    _ = try await manager.replaceCustomSource(
                        named: "Existing Repo",
                        with: "https://replacement.example/manifest.json"
                    )
                case .delete:
                    try manager.deleteCustomSource(named: "Existing Repo")
                case .replaceAll:
                    try manager.replaceCustomSources(with: [Self.replacementRegistration])
                case .reset:
                    try manager.resetToDefaults()
                }
                XCTFail("Expected injected second-store failure for \(mutation)")
            } catch RepositorySourceManagementError.configWriteFailed {
                // Expected: rollback must complete through the same persistence dependency.
            }

            XCTAssertEqual(try Data(contentsOf: configURL), originalConfig, "mutation=\(mutation)")
            XCTAssertEqual(try Data(contentsOf: sidecarURL), originalSidecar, "mutation=\(mutation)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path), "mutation=\(mutation)")

            let reloaded = RepositorySourceManager(basePath: tempDir.path).loadSources().map(\.name)
            XCTAssertTrue(reloaded.contains("Existing Repo"), "mutation=\(mutation)")
            XCTAssertFalse(reloaded.contains("Replacement Repo"), "mutation=\(mutation)")
        }
    }

    /**
     Verifies a retained transaction journal repairs both repository stores before the next load.

     The fixture fails the sidecar commit and then the immediate config rollback, which simulates a
     process ending with a changed config, an old sidecar, and a durable journal. A fresh manager must
     restore both original byte sequences and remove the journal before returning visible sources.
     A failure means interrupted repository writes can remain split across launches.
     */
    func testRepositorySourceManagerRecoversRetainedJournalBeforeNextLoad() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try Self.seedRepositoryPersistence(at: tempDir)

        let manifest = Data(
            """
            {
              "name": "Replacement Repo",
              "description": "Replacement catalog",
              "type": "sword-https",
              "host": "replacement.example",
              "catalogDirectory": "/catalog",
              "packageDirectory": "/packages",
              "manifestUrl": "https://replacement.example/manifest.json"
            }
            """.utf8
        )
        RepositorySourceManagerMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, manifest)
        }

        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        let sidecarURL = tempDir.appendingPathComponent("CustomRepositories.json")
        let journalURL = tempDir.appendingPathComponent("RepositorySources.transaction.json")
        let originalConfig = try Data(contentsOf: configURL)
        let originalSidecar = try Data(contentsOf: sidecarURL)
        let failure = RepositorySourceInterruptedTransactionFailure()
        let interruptedManager = RepositorySourceManager(
            basePath: tempDir.path,
            session: Self.makeMockedURLSession(),
            persistence: failure.persistence
        )

        do {
            _ = try await interruptedManager.addCustomSource(
                from: "https://replacement.example/manifest.json"
            )
            XCTFail("Expected the injected commit and rollback failures.")
        } catch RepositorySourceManagementError.configWriteFailed(let message) {
            XCTAssertTrue(message.contains("rollback failed"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertNotEqual(try Data(contentsOf: configURL), originalConfig)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), originalSidecar)

        let recoveredNames = RepositorySourceManager(basePath: tempDir.path).loadSources().map(\.name)

        XCTAssertEqual(try Data(contentsOf: configURL), originalConfig)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), originalSidecar)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(recoveredNames.contains("Existing Repo"))
        XCTAssertFalse(recoveredNames.contains("Replacement Repo"))
    }

    /** Seeds matching SWORD config and sidecar bytes for repository transaction tests. */
    private static func seedRepositoryPersistence(at directory: URL) throws {
        InstallManager.ensureDefaultConfigPublic(at: directory.path)
        let configURL = directory.appendingPathComponent("InstallMgr.conf")
        var config = try String(contentsOf: configURL, encoding: .utf8)
        config += "\nHTTPSource=Existing Repo|existing.example|/catalog\n"
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let sidecar = Data(
            """
            {
              "version": 1,
              "repositories": [
                {
                  "name": "Existing Repo",
                  "description": "Existing catalog",
                  "type": "sword-https",
                  "host": "existing.example",
                  "catalogDirectory": "/catalog",
                  "packageDirectory": "/packages",
                  "manifestURL": "https://existing.example/manifest.json",
                  "sourceURL": "https://existing.example/catalog"
                }
              ]
            }
            """.utf8
        )
        try sidecar.write(to: directory.appendingPathComponent("CustomRepositories.json"))
    }

    /** Replacement registration used by the restore-style transaction case. */
    private static var replacementRegistration: RepositorySourceRegistration {
        RepositorySourceRegistration(
            source: SourceConfig(
                name: "Replacement Repo",
                type: "HTTP",
                host: "replacement.example",
                catalogPath: "/catalog",
                repositoryType: SourceConfig.swordHTTPSRepositoryType,
                description: "Replacement catalog",
                packageDirectory: "/packages",
                manifestURL: URL(string: "https://replacement.example/manifest.json"),
                sourceURL: URL(string: "https://replacement.example/catalog")
            ),
            description: "Replacement catalog",
            packageDirectory: "/packages",
            manifestURL: URL(string: "https://replacement.example/manifest.json")!,
            sourceURL: URL(string: "https://replacement.example/catalog")!,
            type: SourceConfig.swordHTTPSRepositoryType
        )
    }

    /**
     Creates an ephemeral URL session that routes repository manifest validation through the local
     URLProtocol fixture.

     - Returns: A `URLSession` whose network requests are handled entirely in-process.
     - Side effects: none beyond allocating an ephemeral session.
     - Failure modes: test requests fail fast if `RepositorySourceManagerMockURLProtocol` has no
       handler installed for the current test.
     */
    private static func makeMockedURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RepositorySourceManagerMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/** Injects exactly one failure when a transaction first mutates its sidecar store. */
private final class RepositorySourceSecondStoreFailure {
    private var didFail = false

    var persistence: RepositorySourcePersistence {
        RepositorySourcePersistence(
            write: { [weak self] data, destination in
                if destination.lastPathComponent == "CustomRepositories.json",
                   self?.consumeFailure() == true {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try data.write(to: destination, options: .atomic)
            },
            remove: { [weak self] destination in
                if destination.lastPathComponent == "CustomRepositories.json",
                   self?.consumeFailure() == true {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: destination)
            }
        )
    }

    /** Returns true once so rollback writes use the normal atomic path. */
    private func consumeFailure() -> Bool {
        guard !didFail else { return false }
        didFail = true
        return true
    }
}

/** Leaves a durable journal by failing both the sidecar commit and first rollback write. */
private final class RepositorySourceInterruptedTransactionFailure {
    private var didFailSidecarCommit = false
    private var didFailConfigRollback = false

    var persistence: RepositorySourcePersistence {
        RepositorySourcePersistence { [weak self] data, destination in
            guard let self else {
                return try data.write(to: destination, options: .atomic)
            }
            if destination.lastPathComponent == "CustomRepositories.json",
               !didFailSidecarCommit {
                didFailSidecarCommit = true
                throw CocoaError(.fileWriteOutOfSpace)
            }
            if destination.lastPathComponent == "InstallMgr.conf",
               didFailSidecarCommit,
               !didFailConfigRollback {
                didFailConfigRollback = true
                throw CocoaError(.fileWriteNoPermission)
            }
            try data.write(to: destination, options: .atomic)
        }
    }
}

/**
 URLProtocol fixture used by repository-source manager tests to replace network access.

 Each test installs a `requestHandler` that validates the expected URL and returns an HTTP response
 plus data. `tearDown` clears the handler to prevent cross-test leakage; a missing handler is a test
 setup failure because repository validation should never reach the real network in this package
 lane.
 */
private final class RepositorySourceManagerMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            fatalError("RepositorySourceManagerMockURLProtocol.requestHandler must be set before use")
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
