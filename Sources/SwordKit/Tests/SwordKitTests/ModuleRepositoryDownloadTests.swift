import CLibSword
import Foundation
import SQLite3
import XCTest
@testable import SwordKit

/**
 App-host-free package coverage for SWORD/MyBible repository download and install behavior.

 These tests protect Android-compatible repository refresh, MyBible package installs, local ZIP
 imports, package-directory inference, rollback, and cancellation contracts in the SwordKit package
 lane. Failures indicate storage/install drift, not app bootstrap or SwiftUI presentation issues.
 */
final class ModuleRepositoryDownloadTests: XCTestCase {
    override func tearDown() {
        ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /**
     Verifies MyBible HTTPS manifests refresh into installable Android-compatible catalog rows.

     Android exposes MyBible manifest entries as downloadable Bible documents. The repository must
     trim language metadata, upgrade legacy HTTP package URLs to HTTPS, and ignore unsupported URL
     schemes so Downloads sees only rows it can install safely.
     */
    func testModuleRepositoryRefreshesMyBibleCatalogFromManifest() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Example MyBible",
            type: "HTTP",
            host: "mybible.example",
            catalogPath: "/manifest.json",
            repositoryType: SourceConfig.myBibleHTTPSRepositoryType,
            description: "Example MyBible catalog",
            manifestURL: URL(string: "https://mybible.example/manifest.json"),
            sourceURL: URL(string: "https://mybible.example/manifest.json")
        )
        let manifestData = """
        {
          "url": "https://mybible.example/manifest.json",
          "file_name": "Example MyBible",
          "description": "Example MyBible catalog",
          "modules": [
            {
              "file_name": "finrk.SQLite3.zip",
              "description": "Finnish RK",
              "download_url": "https://mybible.example/finrk.SQLite3.zip",
              "language_code": "  fi  ",
              "update_date": "2026-05-01",
              "update_info": "initial"
            },
            {
              "file_name": "legacy.SQLite3.zip",
              "description": "Legacy URL",
              "download_url": "http://mybible.example/legacy.SQLite3.zip",
              "language_code": "en",
              "update_date": "2026-05-02",
              "update_info": "http upgraded"
            },
            {
              "file_name": "ignored.SQLite3.zip",
              "description": "Unsupported URL",
              "download_url": "ftp://mybible.example/ignored.SQLite3.zip",
              "language_code": "en",
              "update_date": "2026-05-03",
              "update_info": "ignored"
            }
          ]
        }
        """.data(using: .utf8)!

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://mybible.example/manifest.json")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                manifestData
            )
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        let modules = try await repository.refreshCatalog(for: source)

        XCTAssertEqual(modules.map(\.name), ["MyBible-finrk_SQLite3", "MyBible-legacy_SQLite3"])
        XCTAssertEqual(modules.first?.description, "Finnish RK")
        XCTAssertEqual(modules.first?.category, .bible)
        XCTAssertEqual(modules.first?.language, "fi")
        XCTAssertEqual(modules.first?.sourceName, "Example MyBible")
    }

    /**
     Verifies SWORD-compatible Android custom-driver catalog rows classify by driver.

     Android registers `MyBibleDictionary` as a dictionary `BookType`, so a repository or restored
     catalog row with `Category=Unknown` must still appear in Downloads' dictionary filters.

     - Setup: Serves a `mods.d.tar.gz` containing a BDBT-style `MyBibleDictionary` config.
     - Expected result: Catalog refresh returns BDBT as a dictionary.
     - Failure meaning: Downloads can hide Android-visible dictionaries before install.
     */
    func testModuleRepositoryClassifiesAndroidMyBibleDictionaryCatalogRowsByDriver() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "AndBible",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(
            moduleName: "BDBT",
            category: "Unknown",
            modDrv: "MyBibleDictionary",
            dataPath: "./modules/texts/MyBible/BDBT/",
            extraConf: """
            Feature=GreekDef
            Feature=HebrewDef
            """
        )

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/raw/mods.d.tar.gz")
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                catalogData
            )
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        let modules = try await repository.refreshCatalog(for: source)
        let bdbt = try XCTUnwrap(modules.first { $0.name == "BDBT" })

        XCTAssertEqual(bdbt.category, .dictionary)
        XCTAssertEqual(bdbt.language, "en")
        XCTAssertEqual(bdbt.sourceName, "AndBible")
    }

    /**
     Verifies that MyBible package installs and uninstalls publish installed-module mutations.

     Setup:
     - installs a real fixture MyBible SQLite package through the repository download path
     - removes the same module through the shared uninstall API
     - observes the module-store notification consumed by open reader and Downloads snapshots

     Expected result:
     - both the successful install and successful uninstall announce that installed modules changed

     Failure meaning:
     - MyBible modules can appear or disappear on disk while already-open UI lists keep stale module
       state until app restart or an unrelated refresh.
     */
    func testModuleRepositoryInstallsAndUninstallsMyBiblePackage() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Example MyBible",
            type: "HTTP",
            host: "mybible.example",
            catalogPath: "/manifest.json",
            repositoryType: SourceConfig.myBibleHTTPSRepositoryType,
            description: "Example MyBible catalog",
            manifestURL: URL(string: "https://mybible.example/manifest.json"),
            sourceURL: URL(string: "https://mybible.example/manifest.json")
        )
        let manifestData = """
        {
          "url": "https://mybible.example/manifest.json",
          "file_name": "Example MyBible",
          "description": "Example MyBible catalog",
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
        let myBibleDatabaseURL = tempDir.appendingPathComponent("finrk.SQLite3")
        try makeMyBibleFixtureDatabase(at: myBibleDatabaseURL)
        let packageData = makeModuleRepositoryZip([
            ("finrk.SQLite3", try Data(contentsOf: myBibleDatabaseURL))
        ])

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/manifest.json":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    manifestData
                )
            case "/finrk.SQLite3.zip":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    packageData
                )
            default:
                XCTFail("Unexpected MyBible request: \(request.url?.absoluteString ?? "<nil>")")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        let notificationExpectation = expectation(
            description: "MyBible install and uninstall publish module-store changes"
        )
        notificationExpectation.expectedFulfillmentCount = 2
        let notificationObserver = NotificationCenter.default.addObserver(
            forName: SwordModuleStore.modulesDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationExpectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(notificationObserver)
        }

        try await repository.installModule(named: "MyBible-finrk_SQLite3", from: source)

        let installed = repository.loadInstalledMyBibleModules()
        XCTAssertEqual(installed.map(\.name), ["MyBible-finrk_SQLite3"])
        XCTAssertEqual(installed.first?.description, "Finnish RK")
        XCTAssertEqual(installed.first?.language, "fi")

        let moduleDir = swordDir
            .appendingPathComponent("mybible", isDirectory: true)
            .appendingPathComponent("MyBible-finrk_SQLite3", isDirectory: true)
        let installedDatabaseURL = moduleDir.appendingPathComponent("finrk.SQLite3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedDatabaseURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moduleDir.appendingPathComponent("module.json").path))
        try assertMyBibleFixtureDatabase(at: installedDatabaseURL, expectedDescription: "Finnish RK", expectedLanguage: "fi")
        try repository.uninstallModule(named: "MyBible-finrk_SQLite3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: moduleDir.path))
        XCTAssertTrue(repository.loadInstalledMyBibleModules().isEmpty)
        await fulfillment(of: [notificationExpectation], timeout: 0.2)
    }

    /**
     Verifies MyBible package installation accepts deflated ZIP entries.

     Android MyBible package mirrors commonly serve compressed SQLite payloads. The install path must
     inflate those entries and publish the same sidecar/payload layout as stored packages without
     depending only on uncompressed ZIP fixtures.
     */
    func testModuleRepositoryInstallsDeflatedMyBiblePackage() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Example MyBible",
            type: "HTTP",
            host: "mybible.example",
            catalogPath: "/manifest.json",
            repositoryType: SourceConfig.myBibleHTTPSRepositoryType,
            description: "Example MyBible catalog",
            manifestURL: URL(string: "https://mybible.example/manifest.json"),
            sourceURL: URL(string: "https://mybible.example/manifest.json")
        )
        let manifestData = """
        {
          "url": "https://mybible.example/manifest.json",
          "file_name": "Example MyBible",
          "description": "Example MyBible catalog",
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
        let myBibleDatabaseURL = tempDir.appendingPathComponent("finrk.SQLite3")
        try makeMyBibleFixtureDatabase(at: myBibleDatabaseURL)
        let databaseData = try Data(contentsOf: myBibleDatabaseURL)
        let packageData = try makeModuleRepositoryZipWithCentralDirectory([
            (
                name: "finrk.SQLite3",
                body: databaseData,
                compressionMethod: 8,
                compressedBody: makeModuleRepositoryRawDeflateData(databaseData)
            )
        ])

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/manifest.json":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    manifestData
                )
            case "/finrk.SQLite3.zip":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    packageData
                )
            default:
                XCTFail("Unexpected MyBible request: \(request.url?.absoluteString ?? "<nil>")")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try await repository.installModule(named: "MyBible-finrk_SQLite3", from: source)

        let moduleDir = swordDir
            .appendingPathComponent("mybible", isDirectory: true)
            .appendingPathComponent("MyBible-finrk_SQLite3", isDirectory: true)
        let installedDatabaseURL = moduleDir.appendingPathComponent("finrk.SQLite3")
        try assertMyBibleFixtureDatabase(at: installedDatabaseURL, expectedDescription: "Finnish RK", expectedLanguage: "fi")
    }

    /**
     Verifies MyBible package HTTP failures use the public repository error surface.

     MyBible installs download Android-compatible ZIP packages through the same Downloads API as SWORD
     modules. A package server failure should therefore surface as `ModuleRepositoryError.downloadFailed`
     instead of leaking the private HTTP-status helper used inside the download delegate.
     */
    func testModuleRepositoryMyBiblePackageHTTPFailureUsesPublicDownloadError() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Example MyBible",
            type: "HTTP",
            host: "mybible.example",
            catalogPath: "/manifest.json",
            repositoryType: SourceConfig.myBibleHTTPSRepositoryType,
            description: "Example MyBible catalog",
            manifestURL: URL(string: "https://mybible.example/manifest.json"),
            sourceURL: URL(string: "https://mybible.example/manifest.json")
        )
        let manifestData = """
        {
          "url": "https://mybible.example/manifest.json",
          "file_name": "Example MyBible",
          "description": "Example MyBible catalog",
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

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/manifest.json":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    manifestData
                )
            case "/finrk.SQLite3.zip":
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data("server error".utf8)
                )
            default:
                XCTFail("Unexpected MyBible request: \(request.url?.absoluteString ?? "<nil>")")
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 404,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        do {
            try await repository.installModule(named: "MyBible-finrk_SQLite3", from: source)
            XCTFail("Expected MyBible package HTTP failure to abort install.")
        } catch {
            guard case ModuleRepositoryError.downloadFailed(let message) = error else {
                XCTFail("Expected public downloadFailed wrapping, got \(type(of: error)): \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("finrk.SQLite3.zip download failed (HTTP 503)"),
                "MyBible package HTTP failures should identify the failed ZIP through the public error."
            )
        }

        let moduleDir = swordDir
            .appendingPathComponent("mybible", isDirectory: true)
            .appendingPathComponent("MyBible-finrk_SQLite3", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: moduleDir.path),
            "A failed MyBible package download must not publish an installed module directory."
        )
    }

    /**
     Local SWORD ZIP install accepts Android-style deflated entries with data descriptors.

     Android's `ZipOutputStream` writes deflated entries before it knows their final sizes, leaving
     zero sizes in local headers and publishing the real sizes in the central directory and trailing
     data descriptors. iOS must read the central directory, matching Android's `ZipInputStream`,
     when installing user-opened SWORD ZIPs and module-backup shaped archives.

     Failure means valid Android-created ZIPs can surface as misleading decompression failures or
     install incomplete module payloads.
     */
    func testModuleRepositoryInstallFromZipAcceptsAndroidDataDescriptorEntries() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let conf = Data(
            """
            [FINRK]
            Description=Finnish RK
            Category=Biblical Texts
            Lang=fi
            ModDrv=RawText
            DataPath=./modules/texts/rawtext/finrk/
            Version=1.0
            InstallSize=1
            """.utf8
        )
        let moduleData = Data("genesis-through-revelation".utf8)
        let zipData = try makeModuleRepositoryZipWithDataDescriptors([
            (
                name: "mods.d/finrk.conf",
                body: conf,
                compressedBody: makeModuleRepositoryRawDeflateData(conf)
            ),
            (
                name: "modules/texts/rawtext/finrk/ot",
                body: moduleData,
                compressedBody: makeModuleRepositoryRawDeflateData(moduleData)
            ),
        ])
        let archiveURL = tempDir.appendingPathComponent("FinRK.zip")
        try zipData.write(to: archiveURL)
        let repository = ModuleRepository(basePath: tempDir.path, swordPath: swordDir.path)

        let installedModuleName = try repository.installFromZip(at: archiveURL)

        XCTAssertEqual(installedModuleName, "FINRK")
        XCTAssertEqual(
            try Data(contentsOf: swordDir.appendingPathComponent("mods.d/finrk.conf")),
            conf
        )
        XCTAssertEqual(
            try Data(contentsOf: swordDir.appendingPathComponent("modules/texts/rawtext/finrk/ot")),
            moduleData
        )
    }

    /**
     Verifies that local SWORD ZIP installation announces the installed-module store mutation.

     Setup:
     - builds an Android-compatible data-descriptor ZIP package
     - installs it through `ModuleRepository.installFromZip(at:)`, the same storage path used by
       Files/Settings SWORD ZIP imports
     - observes the shared module-store notification consumed by open reader and Downloads views

     Expected result:
     - a successful ZIP install posts the module-store change notification once files are published

     Failure meaning:
     - newly imported modules can remain absent from already-open UI caches until app restart or a
       coincidental Downloads sheet refresh.
     */
    func testModuleRepositoryInstallFromZipNotifiesModuleStoreChange() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let conf = Data(
            """
            [FINRK]
            Description=Finnish RK
            Category=Biblical Texts
            Lang=fi
            ModDrv=RawText
            DataPath=./modules/texts/rawtext/finrk/
            Version=1.0
            InstallSize=1
            """.utf8
        )
        let moduleData = Data("genesis-through-revelation".utf8)
        let zipData = try makeModuleRepositoryZipWithDataDescriptors([
            (
                name: "mods.d/finrk.conf",
                body: conf,
                compressedBody: makeModuleRepositoryRawDeflateData(conf)
            ),
            (
                name: "modules/texts/rawtext/finrk/ot",
                body: moduleData,
                compressedBody: makeModuleRepositoryRawDeflateData(moduleData)
            ),
        ])
        let archiveURL = tempDir.appendingPathComponent("FinRK.zip")
        try zipData.write(to: archiveURL)
        let repository = ModuleRepository(basePath: tempDir.path, swordPath: swordDir.path)
        let notificationExpectation = expectation(
            forNotification: SwordModuleStore.modulesDidChangeNotification,
            object: nil
        )

        _ = try repository.installFromZip(at: archiveURL)

        wait(for: [notificationExpectation], timeout: 0.2)
    }

    /**
     Verifies failed fresh downloads do not publish an installed-module marker.

     Android only makes a module visible after the repository package ZIP installs. If the package
     fails, iOS must throw an actionable error, avoid writing the `.conf` file, and avoid leaving
     module data that would make the incomplete module appear installed.
     */
    func testModuleRepositoryDownloadFailsWithoutInstalledMarkerWhenRequiredFileFails() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "TestRepo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "TESTDICT")

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/TESTDICT.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data("server error".utf8)
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)

        do {
            try await repository.installModule(named: "TESTDICT", from: source)
            XCTFail("Expected failed package download to fail the module install.")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("TESTDICT.zip"),
                "Failure should identify the package ZIP that could not be downloaded."
            )
        }

        let confPath = swordDir
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("testdict.conf")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: confPath.path),
            "A failed module download must not leave a .conf file that marks the module installed."
        )
        let localDir = moduleRepositoryLocalDir(for: "TESTDICT", under: swordDir)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: localDir.appendingPathComponent("testdict.dat").path
            ),
            "A failed fresh package download should not publish module data files."
        )
    }

    /**
     Verifies failed updates preserve the previously installed module atomically.

     Android update failures leave the old document usable. The repository should stage package
     replacement data separately and keep the old data files plus `.conf` marker when a downloaded
     package fails before publish.
     */
    func testModuleRepositoryFailedUpdatePreservesExistingInstalledFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "TestRepo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "TESTDICT")
        let localDir = moduleRepositoryLocalDir(for: "TESTDICT", under: swordDir)
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        try Data("old-dictionary-data".utf8).write(to: localDir.appendingPathComponent("testdict.dat"))
        try Data("old-index-data".utf8).write(to: localDir.appendingPathComponent("testdict.idx"))

        let modsDir = swordDir.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        let oldConf = """
        [TESTDICT]
        Description=Old Test Dictionary
        Category=Lexicons / Dictionaries
        Lang=en
        ModDrv=RawLD
        DataPath=./modules/lexdict/rawld/testdict/testdict
        Version=0.9
        InstallSize=1
        """
        let confPath = modsDir.appendingPathComponent("testdict.conf")
        try oldConf.write(to: confPath, atomically: true, encoding: .utf8)

        let zipData = makeModuleRepositoryZipWithCentralDirectory([
            (
                name: "modules/lexdict/rawld/testdict/testdict.dat",
                body: Data("new-dictionary-data".utf8),
                compressionMethod: 0,
                compressedBody: Data("new-dictionary-data".utf8)
            ),
            (
                name: "modules/lexdict/rawld/testdict/testdict.idx",
                body: Data("new-index-data".utf8),
                compressionMethod: 99,
                compressedBody: Data("new-index-data".utf8)
            )
        ])

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/TESTDICT.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "\(zipData.count)"]
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)

        do {
            try await repository.installModule(named: "TESTDICT", from: source)
            XCTFail("Expected failed update to throw.")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("Unsupported ZIP compression method 99"),
                "Failure should identify the staged package entry that could not be extracted."
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("testdict.dat")),
            Data("old-dictionary-data".utf8),
            "A failed update must not overwrite the installed data file."
        )
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("testdict.idx")),
            Data("old-index-data".utf8),
            "A failed update must preserve the installed index file."
        )
        XCTAssertEqual(
            try String(contentsOf: confPath, encoding: .utf8),
            oldConf,
            "A failed update must preserve the installed module config marker."
        )
    }

    /**
     Verifies commit-time config-backup failures restore the previous installed data directory.

     Setup:
     - preinstalls TESTDICT data plus its `.conf` marker
     - serves a valid replacement package so download and extraction both succeed
     - removes write permission from `mods.d` so the commit path fails while backing up the old marker

     Expected result:
     - the commit helper restores the old data directory and leaves the old marker readable

     Failure meaning:
     - a filesystem error after the existing data directory is backed up can leave an installed
       module without its prior data, which is the update-corruption case Android's package installer
       avoids.
     */
    func testModuleRepositoryCommitFailureRestoresExistingInstalledFiles() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "TestRepo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "TESTDICT")
        let localDir = moduleRepositoryLocalDir(for: "TESTDICT", under: swordDir)
        try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        try Data("old-dictionary-data".utf8).write(to: localDir.appendingPathComponent("testdict.dat"))
        try Data("old-index-data".utf8).write(to: localDir.appendingPathComponent("testdict.idx"))

        let modsDir = swordDir.appendingPathComponent("mods.d", isDirectory: true)
        try fm.createDirectory(at: modsDir, withIntermediateDirectories: true)
        let oldConf = """
        [TESTDICT]
        Description=Old Test Dictionary
        Category=Lexicons / Dictionaries
        Lang=en
        ModDrv=RawLD
        DataPath=./modules/lexdict/rawld/testdict/testdict
        Version=0.9
        InstallSize=1
        """
        let confPath = modsDir.appendingPathComponent("testdict.conf")
        try oldConf.write(to: confPath, atomically: true, encoding: .utf8)

        let zipData = makeModuleRepositoryZip([
            ("modules/lexdict/rawld/testdict/testdict.dat", Data("new-dictionary-data".utf8)),
            ("modules/lexdict/rawld/testdict/testdict.idx", Data("new-index-data".utf8))
        ])

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/TESTDICT.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "\(zipData.count)"]
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: modsDir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: modsDir.path)
        }

        do {
            try await repository.installModule(named: "TESTDICT", from: source)
            XCTFail("Expected config backup to fail when mods.d is not writable.")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(
                nsError.domain,
                NSCocoaErrorDomain,
                "Fixture drifted away from the intended filesystem permission failure."
            )
            XCTAssertEqual(
                nsError.code,
                CocoaError.fileWriteNoPermission.rawValue,
                "The rollback fixture should fail while writing in read-only mods.d."
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("testdict.dat")),
            Data("old-dictionary-data".utf8),
            "Commit-time rollback must restore the previous data file."
        )
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("testdict.idx")),
            Data("old-index-data".utf8),
            "Commit-time rollback must restore the previous index file."
        )
        XCTAssertEqual(
            try String(contentsOf: confPath, encoding: .utf8),
            oldConf,
            "Commit-time rollback must preserve the previous installed module marker."
        )
    }

    /**
     Verifies post-staging publish failures remove newly placed package data.

     Setup:
     - installs FRESHDICT from a valid package with no previous module directory or marker
     - removes write permission from `mods.d` before install so staged data can move into place but
       the final `.conf` marker write fails

     Expected result:
     - the commit helper removes the newly placed data directory and leaves no installed marker

     Failure meaning:
     - a filesystem error after staging moves into the live module path can publish data without the
       marker contract that `SwordManager` uses to recognize installed modules.
     */
    func testModuleRepositoryCommitFailureRemovesFreshlyStagedInstall() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "TestRepo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "FRESHDICT")
        let localDir = moduleRepositoryLocalDir(for: "FRESHDICT", under: swordDir)
        let modsDir = swordDir.appendingPathComponent("mods.d", isDirectory: true)
        try fm.createDirectory(at: modsDir, withIntermediateDirectories: true)
        let confPath = modsDir.appendingPathComponent("freshdict.conf")
        let zipData = makeModuleRepositoryZip([
            ("modules/lexdict/rawld/freshdict/freshdict.dat", Data("new-dictionary-data".utf8)),
            ("modules/lexdict/rawld/freshdict/freshdict.idx", Data("new-index-data".utf8))
        ])

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/FRESHDICT.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "\(zipData.count)"]
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: modsDir.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: modsDir.path)
        }

        do {
            try await repository.installModule(named: "FRESHDICT", from: source)
            XCTFail("Expected marker write to fail when mods.d is not writable.")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(
                nsError.domain,
                NSCocoaErrorDomain,
                "Fixture drifted away from the intended filesystem permission failure."
            )
            XCTAssertEqual(
                nsError.code,
                CocoaError.fileWriteNoPermission.rawValue,
                "The rollback fixture should fail while writing the final marker in read-only mods.d."
            )
        }

        XCTAssertFalse(
            fm.fileExists(atPath: localDir.path),
            "Post-staging rollback must remove the newly placed data directory after marker write fails."
        )
        XCTAssertFalse(
            fm.fileExists(atPath: confPath.path),
            "Post-staging rollback must not leave an installed module marker after marker write fails."
        )
    }

    /**
     Verifies single-testament zText packages install without synthetic OT files.

     Android installs SWORD modules from ZIP packages and does not require raw OT/NT file probing to
     distinguish full and single-testament modules. The package may legitimately contain only NT
     data; iOS should publish exactly that package content without requesting raw OT files.
     */
    func testModuleRepositoryInstallsSingleTestamentPackageWithoutSyntheticOldTestamentFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "TestRepo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(
            moduleName: "NTONLY",
            category: "Biblical Texts",
            modDrv: "zText",
            dataPath: "./modules/texts/ztext/ntonly/"
        )
        let zipData = makeModuleRepositoryZip([
            ("mods.d/ntonly.conf", Data("placeholder".utf8)),
            ("modules/texts/ztext/ntonly/nt.bzs", Data("new-testament-zs".utf8)),
            ("modules/texts/ztext/ntonly/nt.bzz", Data("new-testament-zz".utf8)),
            ("modules/texts/ztext/ntonly/nt.bzv", Data("new-testament-zv".utf8))
        ])
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/NTONLY.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try await repository.installModule(named: "NTONLY", from: source)

        XCTAssertEqual(
            requestedPaths.filter { $0 != "/raw/mods.d.tar.gz" },
            ["/packages/NTONLY.zip"],
            "Remote SWORD installs should use the package ZIP and avoid raw testament probes."
        )

        let localDir = swordDir
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("texts", isDirectory: true)
            .appendingPathComponent("ztext", isDirectory: true)
            .appendingPathComponent("ntonly", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: localDir.appendingPathComponent("ot.bzs").path),
            "Package installs should not synthesize missing testament files."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent("nt.bzs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent("nt.bzz").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent("nt.bzv").path))

        let confPath = swordDir
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("ntonly.conf")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: confPath.path),
            "A single-testament package that contains module data should publish its .conf marker."
        )
    }

    /**
     Verifies chapter-block compressed commentaries publish package data files.

     Android installs commentaries from package ZIPs. A package containing `.czs/.czz/.czv`
     chapter-block data should publish those files exactly, without iOS trying to reconstruct raw
     filenames from `BlockType`.
     */
    func testModuleRepositoryInstallsChapterBlockCompressedCommentary() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "CrossWire",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(
            moduleName: "BARNES",
            category: "Commentaries",
            modDrv: "zCom",
            dataPath: "./modules/comments/zcom/barnes/",
            extraConf: "BlockType=CHAPTER"
        )
        let zipData = makeModuleRepositoryZip([
            ("mods.d/barnes.conf", Data("placeholder".utf8)),
            ("modules/comments/zcom/barnes/nt.czs", Data("commentary-czs".utf8)),
            ("modules/comments/zcom/barnes/nt.czz", Data("commentary-czz".utf8)),
            ("modules/comments/zcom/barnes/nt.czv", Data("commentary-czv".utf8))
        ])
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/BARNES.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try await repository.installModule(named: "BARNES", from: source)

        XCTAssertEqual(
            requestedPaths.filter { $0 != "/raw/mods.d.tar.gz" },
            ["/packages/BARNES.zip"],
            "Remote commentary installs should use the package ZIP and avoid raw data-file probes."
        )

        let localDir = swordDir
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("comments", isDirectory: true)
            .appendingPathComponent("zcom", isDirectory: true)
            .appendingPathComponent("barnes", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent("nt.czs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent("nt.czz").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent("nt.czv").path))

        let confPath = swordDir
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("barnes.conf")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: confPath.path),
            "A chapter-block compressed commentary should publish its .conf marker after data files are staged."
        )
    }

    /**
     Verifies built-in package-backed repositories install from Android's package directory.

     Android gives the SWORD installer a package ZIP location for built-in repositories. iOS should
     use that package without raw data-file probes so packaged modules are installed atomically.
     */
    func testModuleRepositoryInstallsBuiltInPackageZipWithoutRawDataFileProbes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "AndBible Extra",
            type: "HTTP",
            host: "andbible.github.io",
            catalogPath: "/andbible-extra"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(
            moduleName: "Augustin",
            category: "Commentaries",
            modDrv: "RawCom4",
            dataPath: "./modules/comments/rawcom/augustin/"
        )
        let zipData = makeModuleRepositoryZip([
            (
                "mods.d/augustin.conf",
                Data(
                    """
                    [Augustin]
                    Description=Augustin
                    Category=Commentaries
                    Lang=en
                    ModDrv=RawCom4
                    DataPath=./modules/comments/rawcom/augustin/
                    Version=1.0
                    InstallSize=1
                    """.utf8
                )
            ),
            ("modules/comments/rawcom/augustin/nt", Data("raw-commentary-data".utf8))
        ])
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/andbible-extra/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/andbible-extra/zip/Augustin.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try await repository.installModule(named: "Augustin", from: source)

        XCTAssertEqual(
            requestedPaths.filter { $0 != "/andbible-extra/mods.d.tar.gz" },
            ["/andbible-extra/zip/Augustin.zip"],
            "Package-backed repositories should use Android's package ZIP without raw data files."
        )

        let localDir = swordDir
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("comments", isDirectory: true)
            .appendingPathComponent("rawcom", isDirectory: true)
            .appendingPathComponent("augustin", isDirectory: true)
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("nt")),
            Data("raw-commentary-data".utf8)
        )

        let confPath = swordDir
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("augustin.conf")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: confPath.path),
            "A package ZIP install should still publish the catalog .conf marker through the staged installer."
        )
    }

    /**
     Verifies SWORD installs request an explicit package by default.

     Android's SWORD installer receives one package directory per repository. When custom metadata
     has that directory, iOS should follow the same package path for normal Downloads.
     */
    func testModuleRepositoryInstallsExplicitPackageZipByDefault() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Package Repo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(
            moduleName: "FULL",
            category: "Biblical Texts",
            modDrv: "zText",
            dataPath: "./modules/texts/ztext/full/"
        )
        let zipData = makeModuleRepositoryZip([
            ("mods.d/full.conf", Data("placeholder".utf8)),
            ("modules/texts/ztext/full/ot.bzs", Data("old-testament-zs".utf8)),
            ("modules/texts/ztext/full/ot.bzz", Data("old-testament-zz".utf8)),
            ("modules/texts/ztext/full/ot.bzv", Data("old-testament-zv".utf8)),
            ("modules/texts/ztext/full/nt.bzs", Data("new-testament-zs".utf8)),
            ("modules/texts/ztext/full/nt.bzz", Data("new-testament-zz".utf8)),
            ("modules/texts/ztext/full/nt.bzv", Data("new-testament-zv".utf8))
        ])
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/FULL.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try await repository.installModule(named: "FULL", from: source)

        XCTAssertEqual(
            requestedPaths.filter { $0 != "/raw/mods.d.tar.gz" },
            ["/packages/FULL.zip"],
            "Package-preferred installs should not probe raw OT/NT files after the package succeeds."
        )

        let localDir = moduleRepositoryTextDir(for: "FULL", under: swordDir)
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("ot.bzs")),
            Data("old-testament-zs".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("nt.bzs")),
            Data("new-testament-zs".utf8)
        )
    }

    /**
     Verifies direct SWORD catalog custom repositories install from `catalogPath/packages`.

     Android's custom repository editor accepts a direct SWORD catalog only when both
     `mods.d.tar.gz` and a sibling `packages` directory are readable. iOS should follow that
     package-directory rule for remote installs instead of requiring pre-existing sidecar metadata
     or probing raw data files.
     */
    func testModuleRepositoryInstallsDirectCatalogPackageDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Direct Catalog",
            type: "HTTP",
            host: "custom.example",
            catalogPath: "/catalog"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "CUSTOM")
        let zipData = makeModuleRepositoryZip([
            ("mods.d/custom.conf", Data("placeholder".utf8)),
            ("modules/lexdict/rawld/custom/custom.dat", Data("dictionary-data".utf8)),
            ("modules/lexdict/rawld/custom/custom.idx", Data("index-data".utf8))
        ])
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/catalog/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/catalog/packages/CUSTOM.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try await repository.installModule(named: "CUSTOM", from: source)

        XCTAssertEqual(
            requestedPaths.filter { $0 != "/catalog/mods.d.tar.gz" },
            ["/catalog/packages/CUSTOM.zip"]
        )

        let localDir = moduleRepositoryLocalDir(for: "CUSTOM", under: swordDir)
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("custom.dat")),
            Data("dictionary-data".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("custom.idx")),
            Data("index-data".utf8)
        )
    }

    /**
     Verifies remote SWORD installs fail without raw data-file probes when the package ZIP is absent.

     Downloads installs are Android package-backed remote installs. If the package is missing, iOS
     must fail visibly instead of probing optional raw testament files and risking a module that
     opens Matthew but cannot open Genesis.
     */
    func testModuleRepositoryPackageInstallDoesNotProbeRawDataFilesWhenZipIsMissing() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Package Repo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(
            moduleName: "FULL",
            category: "Biblical Texts",
            modDrv: "zText",
            dataPath: "./modules/texts/ztext/full/"
        )
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/FULL.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            default:
                XCTFail("Package installs should not request raw data files: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        do {
            try await repository.installModule(named: "FULL", from: source)
            XCTFail("Expected package install to fail when the package ZIP is missing.")
        } catch {
            XCTAssertEqual(
                requestedPaths.filter { $0 != "/raw/mods.d.tar.gz" },
                ["/packages/FULL.zip"]
            )
        }

        let confPath = swordDir
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("full.conf")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: confPath.path),
            "A package failure must not leave an installed marker."
        )
    }

    /**
     Verifies remote SWORD installs fail on package server errors without raw data-file probes.

     Raw data-file installs can publish partial full-Bible content when a mirror is inconsistent.
     This fixture returns HTTP 500 for the package and fails the test if any raw data file is
     requested. A failure means remote installs can regress to the partial-download surface that
     caused issue 354.
     */
    func testModuleRepositoryPackageInstallDoesNotProbeRawDataFilesWhenZipReturnsServerError() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Package Repo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(
            moduleName: "FULL",
            category: "Biblical Texts",
            modDrv: "zText",
            dataPath: "./modules/texts/ztext/full/"
        )
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/FULL.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            default:
                XCTFail("Package installs should not request raw data files: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        do {
            try await repository.installModule(named: "FULL", from: source)
            XCTFail("Expected package install to fail when the package ZIP returns a server error.")
        } catch {
            guard case ModuleRepositoryError.downloadFailed(let message) = error else {
                XCTFail("Expected public downloadFailed wrapping, got \(type(of: error)): \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("FULL.zip download failed (HTTP 500)"),
                "Package HTTP failures should be reported through ModuleRepositoryError.downloadFailed."
            )
            XCTAssertEqual(
                requestedPaths.filter { $0 != "/raw/mods.d.tar.gz" },
                ["/packages/FULL.zip"]
            )
        }

        let confPath = swordDir
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("full.conf")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: confPath.path),
            "A package failure must not leave an installed marker."
        )
    }

    /**
     Verifies built-in repositories use Android's default package directory for ZIP installs.

     STEP and similar repositories publish package ZIPs outside the catalog directory. The repository
     must use Android's configured package directory before deriving catalog-relative guesses.
     */
    func testModuleRepositoryUsesAndroidDefaultPackageDirectoryForPackageInstall() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "STEP Bible (Tyndale)",
            type: "HTTP",
            host: "public.modules.stepbible.org",
            catalogPath: "/catalog"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "STEPMOD")
        let zipData = makeModuleRepositoryZip([
            ("mods.d/stepmod.conf", Data("placeholder".utf8)),
            ("modules/lexdict/rawld/stepmod/stepmod.dat", Data("dictionary-data".utf8)),
            ("modules/lexdict/rawld/stepmod/stepmod.idx", Data("index-data".utf8))
        ])
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/catalog/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/STEPMOD.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try await repository.installModule(named: "STEPMOD", from: source)

        XCTAssertTrue(
            requestedPaths.contains("/packages/STEPMOD.zip"),
            "Default repositories should use Android's explicit package directory, not derive it from the catalog path."
        )
        XCTAssertFalse(
            requestedPaths.contains("/catalog/packages/STEPMOD.zip"),
            "STEP's Android package directory is /packages, not /catalog/packages."
        )

        let localDir = moduleRepositoryLocalDir(for: "STEPMOD", under: swordDir)
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("stepmod.dat")),
            Data("dictionary-data".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("stepmod.idx")),
            Data("index-data".utf8)
        )
    }

    /**
     Verifies custom repository package-directory metadata wins over catalog-directory inference.

     Android stores one package directory for a repository. When custom metadata exists, iOS must use
     that durable directory and avoid probing alternative catalog-relative paths that Android would not
     request.
     */
    func testModuleRepositoryUsesPersistedCustomPackageDirectoryBeforeHeuristics() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Custom Repo",
            type: "HTTP",
            host: "custom.example",
            catalogPath: "/catalog",
            packageDirectory: "/android/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "CUSTOM")
        let zipData = makeModuleRepositoryZip([
            ("mods.d/custom.conf", Data("placeholder".utf8)),
            ("modules/lexdict/rawld/custom/custom.dat", Data("dictionary-data".utf8)),
            ("modules/lexdict/rawld/custom/custom.idx", Data("index-data".utf8))
        ])
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/catalog/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/android/packages/CUSTOM.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try await repository.installModule(named: "CUSTOM", from: source)

        XCTAssertTrue(
            requestedPaths.contains("/android/packages/CUSTOM.zip"),
            "Custom repositories should use their persisted Android package directory first."
        )
        XCTAssertFalse(
            requestedPaths.contains("/catalog/packages/CUSTOM.zip"),
            "Persisted custom package directories must not be replaced with catalog-relative heuristics."
        )
        XCTAssertFalse(
            requestedPaths.contains("/catalog/zip/CUSTOM.zip"),
            "Persisted custom package directories must take precedence over legacy zip guesses."
        )

        let localDir = moduleRepositoryLocalDir(for: "CUSTOM", under: swordDir)
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("custom.dat")),
            Data("dictionary-data".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: localDir.appendingPathComponent("custom.idx")),
            Data("index-data".utf8)
        )
    }

    /**
     Verifies explicit package-directory metadata is normalized before building package ZIP URLs.

     Android gives JSword a repository package directory, not an arbitrary URL fragment. iOS should
     preserve that one authoritative directory while making relative legacy/manifest values safe for
     the `https://host/path/module.zip` request shape.
     */
    func testModuleRepositoryNormalizesRelativeCustomPackageDirectoryForPackageInstall() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Custom Repo",
            type: "HTTP",
            host: "custom.example",
            catalogPath: "/catalog",
            packageDirectory: "android/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "CUSTOM")
        let zipData = makeModuleRepositoryZip([
            ("mods.d/custom.conf", Data("placeholder".utf8)),
            ("modules/lexdict/rawld/custom/custom.dat", Data("dictionary-data".utf8)),
            ("modules/lexdict/rawld/custom/custom.idx", Data("index-data".utf8))
        ])
        var requestedURLs: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/catalog/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/android/packages/CUSTOM.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        try await repository.installModule(named: "CUSTOM", from: source)

        XCTAssertTrue(requestedURLs.contains("https://custom.example/android/packages/CUSTOM.zip"))
        XCTAssertFalse(
            requestedURLs.contains("https://custom.exampleandroid/packages/CUSTOM.zip"),
            "Relative package metadata must not be appended directly to the host."
        )
    }

    /**
     Verifies explicit Android package directories are authoritative for package installs.

     Android gives the installer one package directory per repository. When that explicit directory
     does not contain a ZIP, iOS should surface the install failure instead of probing catalog-relative
     guesses that Android would never use.
     */
    func testModuleRepositoryDoesNotGuessPackageDirectoriesWhenAndroidPackageDirectoryIsExplicit() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "Custom Repo",
            type: "HTTP",
            host: "custom.example",
            catalogPath: "/catalog",
            packageDirectory: "/android/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "CUSTOM")
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/catalog/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/android/packages/CUSTOM.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            default:
                XCTFail("Unexpected package-directory guess: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)
        do {
            try await repository.installModule(named: "CUSTOM", from: source)
            XCTFail("Expected the install to fail after Android's explicit package directory returned 404.")
        } catch {
            XCTAssertTrue(requestedPaths.contains("/android/packages/CUSTOM.zip"))
        }

        XCTAssertFalse(requestedPaths.contains("/catalog/packages/CUSTOM.zip"))
        XCTAssertFalse(requestedPaths.contains("/catalog/zip/CUSTOM.zip"))
        XCTAssertFalse(requestedPaths.contains("/catalog/packages/rawzip/CUSTOM.zip"))
    }

    /**
     Verifies cancellation during package download stops before publishing markers.

     Android cancellation leaves no partially installed module. Cancelling after initial package
     progress must halt installation, remove staged files, and avoid writing the `.conf` marker.
     */
    func testModuleRepositoryCancellationStopsBeforeInstalledMarker() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "TestRepo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "TESTDICT")
        let zipData = makeModuleRepositoryZip([
            ("mods.d/testdict.conf", Data("placeholder".utf8)),
            ("modules/lexdict/rawld/testdict/testdict.dat", Data("dictionary-data".utf8)),
            ("modules/lexdict/rawld/testdict/testdict.idx", Data("index-data".utf8))
        ])
        let zipHeaders = ["Content-Length": "\(zipData.count)"]
        var requestedPaths: [String] = []

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/TESTDICT.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: zipHeaders
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)

        var installTask: Task<Void, Error>?
        installTask = Task {
            try await repository.installModule(named: "TESTDICT", from: source) { progress in
                if progress > 0 {
                    installTask?.cancel()
                }
            }
        }

        do {
            try await installTask?.value
            XCTFail("Expected cancellation to stop the install before completion.")
        } catch is CancellationError {
            // Expected cancellation path.
        }

        XCTAssertFalse(
            requestedPaths.contains { $0.hasPrefix("/raw/modules/") },
            "Cancellation should not reach raw data-file probes."
        )

        let confPath = swordDir
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("testdict.conf")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: confPath.path),
            "A cancelled module download must not leave a .conf file that marks the module installed."
        )
        let localDir = moduleRepositoryLocalDir(for: "TESTDICT", under: swordDir)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: localDir.appendingPathComponent("testdict.dat").path
            ),
            "A cancelled fresh package download should not publish staged data files."
        )
    }

    /**
     Verifies final-progress cancellation still stops before publish.

     A cancellation delivered after the package download reports completion but before publication
     must still prevent the installed marker and staged directory from becoming visible, matching
     Android's all-or-nothing install lifecycle.
     */
    func testModuleRepositoryCancellationAfterFinalFileStopsBeforePublish() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "TestRepo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw",
            packageDirectory: "/packages"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "TESTDICT")
        let zipData = makeModuleRepositoryZip([
            ("mods.d/testdict.conf", Data("placeholder".utf8)),
            ("modules/lexdict/rawld/testdict/testdict.dat", Data("dictionary-data".utf8)),
            ("modules/lexdict/rawld/testdict/testdict.idx", Data("index-data".utf8))
        ])
        let zipHeaders = ["Content-Length": "\(zipData.count)"]

        ModuleRepositoryDownloadMockURLProtocol.requestHandler = { request in
            let response: HTTPURLResponse
            let data: Data
            switch request.url?.path {
            case "/raw/mods.d.tar.gz":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = catalogData
            case "/packages/TESTDICT.zip":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: zipHeaders
                )!
                data = zipData
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "<nil>")")
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            }
            return (response, data)
        }
        defer { ModuleRepositoryDownloadMockURLProtocol.requestHandler = nil }

        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        _ = try await repository.refreshCatalog(for: source)

        var installTask: Task<Void, Error>?
        installTask = Task {
            try await repository.installModule(named: "TESTDICT", from: source) { progress in
                if progress >= 1 {
                    installTask?.cancel()
                }
            }
        }

        do {
            try await installTask?.value
            XCTFail("Expected final-progress cancellation to stop before publishing the install.")
        } catch is CancellationError {
            // Expected cancellation path.
        }

        let confPath = swordDir
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("testdict.conf")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: confPath.path),
            "Cancelling after the final staged file should stop before the .conf marker is published."
        )
        let localDir = moduleRepositoryLocalDir(for: "TESTDICT", under: swordDir)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: localDir.path),
            "Cancelling after the package download should not publish staged module data."
        )
    }

    private func makeModuleRepositoryDownloadMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleRepositoryDownloadMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeModuleRepositoryCatalogArchive(
        moduleName: String,
        category: String = "Lexicons / Dictionaries",
        modDrv: String = "RawLD",
        dataPath: String? = nil,
        extraConf: String = ""
    ) throws -> Data {
        let moduleKey = moduleName.lowercased()
        let resolvedDataPath = dataPath ?? "./modules/lexdict/rawld/\(moduleKey)/\(moduleKey)"
        let conf = """
        [\(moduleName)]
        Description=Test Dictionary
        Category=\(category)
        Lang=en
        ModDrv=\(modDrv)
        DataPath=\(resolvedDataPath)
        \(extraConf)
        Version=1.0
        InstallSize=1
        """
        let tar = makeModuleRepositoryTarEntry(
            name: "mods.d/\(moduleKey).conf",
            data: Data(conf.utf8)
        ) + Data(repeating: 0, count: 1024)
        return try gzipModuleRepositoryTestData(tar)
    }

    private func moduleRepositoryLocalDir(for moduleName: String, under swordDir: URL) -> URL {
        let moduleKey = moduleName.lowercased()
        return swordDir
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("lexdict", isDirectory: true)
            .appendingPathComponent("rawld", isDirectory: true)
            .appendingPathComponent(moduleKey, isDirectory: true)
    }

    /**
     Builds the local zText data directory for a test module.

     - Parameters:
       - moduleName: Catalog abbreviation used as the zText directory name.
       - swordDir: Test SWORD home containing the `modules/` tree.
     - Returns: The expected installed data directory for the module.
     - Side effects: none.
     - Failure modes: none.
     */
    private func moduleRepositoryTextDir(for moduleName: String, under swordDir: URL) -> URL {
        let moduleKey = moduleName.lowercased()
        return swordDir
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("texts", isDirectory: true)
            .appendingPathComponent("ztext", isDirectory: true)
            .appendingPathComponent(moduleKey, isDirectory: true)
    }

    private func makeModuleRepositoryTarEntry(name: String, data: Data) -> Data {
        var header = Data(repeating: 0, count: 512)
        writeModuleRepositoryTarValue(name, into: &header, at: 0, length: 100)
        writeModuleRepositoryTarValue(String(format: "%07o", 0o644), into: &header, at: 100, length: 8)
        writeModuleRepositoryTarValue(String(format: "%07o", 0), into: &header, at: 108, length: 8)
        writeModuleRepositoryTarValue(String(format: "%07o", 0), into: &header, at: 116, length: 8)
        writeModuleRepositoryTarValue(String(format: "%011o", data.count), into: &header, at: 124, length: 12)
        writeModuleRepositoryTarValue(String(format: "%011o", 0), into: &header, at: 136, length: 12)
        writeModuleRepositoryTarValue("        ", into: &header, at: 148, length: 8)
        header[156] = Character("0").asciiValue!
        writeModuleRepositoryTarValue("ustar", into: &header, at: 257, length: 6)

        let checksum = header.reduce(0) { $0 + UInt32($1) }
        writeModuleRepositoryTarValue(String(format: "%06o", checksum) + "\0 ", into: &header, at: 148, length: 8)

        var entry = header
        entry.append(data)
        let padding = (512 - (data.count % 512)) % 512
        entry.append(Data(repeating: 0, count: padding))
        return entry
    }

    private func writeModuleRepositoryTarValue(_ value: String, into data: inout Data, at offset: Int, length: Int) {
        let bytes = Array(value.utf8.prefix(length))
        for index in 0..<bytes.count {
            data[offset + index] = bytes[index]
        }
    }

    private func gzipModuleRepositoryTestData(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw ModuleRepositoryDownloadTestError.compressionFailed
            }

            var outputLength: UInt = 0
            guard let output = gzip_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &outputLength
            ) else {
                throw ModuleRepositoryDownloadTestError.compressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLength))
        }
    }

    private func makeModuleRepositoryZip(_ entries: [(String, Data)]) -> Data {
        var data = Data()

        for (name, body) in entries {
            let nameData = Data(name.utf8)
            data.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            appendModuleRepositoryZipUInt16(20, to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            appendModuleRepositoryZipUInt32(0, to: &data)
            appendModuleRepositoryZipUInt32(UInt32(body.count), to: &data)
            appendModuleRepositoryZipUInt32(UInt32(body.count), to: &data)
            appendModuleRepositoryZipUInt16(UInt16(nameData.count), to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            data.append(nameData)
            data.append(body)
        }

        return data
    }

    private func makeModuleRepositoryZipWithCentralDirectory(
        _ entries: [(name: String, body: Data, compressionMethod: UInt16, compressedBody: Data)]
    ) -> Data {
        var data = Data()
        var centralDirectory = Data()

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let localHeaderOffset = UInt32(data.count)
            let checksum = moduleRepositoryZipCRC32(entry.body)

            data.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            appendModuleRepositoryZipUInt16(20, to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            appendModuleRepositoryZipUInt16(entry.compressionMethod, to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            appendModuleRepositoryZipUInt32(checksum, to: &data)
            appendModuleRepositoryZipUInt32(UInt32(entry.compressedBody.count), to: &data)
            appendModuleRepositoryZipUInt32(UInt32(entry.body.count), to: &data)
            appendModuleRepositoryZipUInt16(UInt16(nameData.count), to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            data.append(nameData)
            data.append(entry.compressedBody)

            centralDirectory.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            appendModuleRepositoryZipUInt16(20, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(20, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(entry.compressionMethod, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt32(checksum, to: &centralDirectory)
            appendModuleRepositoryZipUInt32(UInt32(entry.compressedBody.count), to: &centralDirectory)
            appendModuleRepositoryZipUInt32(UInt32(entry.body.count), to: &centralDirectory)
            appendModuleRepositoryZipUInt16(UInt16(nameData.count), to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt32(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt32(localHeaderOffset, to: &centralDirectory)
            centralDirectory.append(nameData)
        }

        let centralDirectoryOffset = UInt32(data.count)
        data.append(centralDirectory)
        data.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        appendModuleRepositoryZipUInt16(0, to: &data)
        appendModuleRepositoryZipUInt16(0, to: &data)
        appendModuleRepositoryZipUInt16(UInt16(entries.count), to: &data)
        appendModuleRepositoryZipUInt16(UInt16(entries.count), to: &data)
        appendModuleRepositoryZipUInt32(UInt32(centralDirectory.count), to: &data)
        appendModuleRepositoryZipUInt32(centralDirectoryOffset, to: &data)
        appendModuleRepositoryZipUInt16(0, to: &data)

        return data
    }

    /**
     Builds a raw-deflated ZIP archive whose local headers use data descriptors for sizes.

     Android's `ZipOutputStream` emits this shape for deflated entries. The helper mirrors that
     format so `ModuleRepository.installFromZip(at:)` tests cover the same central-directory path as
     user-supplied Android module backups without depending on shell ZIP tools.

     - Parameter entries: ZIP entry names, uncompressed payloads, and raw-deflated payloads.
     - Returns: ZIP bytes with descriptor-based local headers and complete central-directory sizes.
     - Side effects: none.
     - Failure modes: Throws if a fixture value exceeds the non-ZIP64 test helper limits.
     */
    private func makeModuleRepositoryZipWithDataDescriptors(
        _ entries: [(name: String, body: Data, compressedBody: Data)]
    ) throws -> Data {
        guard entries.count <= Int(UInt16.max) else {
            throw ModuleRepositoryDownloadTestError.compressionFailed
        }

        var data = Data()
        var centralDirectory = Data()
        var localHeaderOffsets: [UInt32] = []

        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8),
                  nameData.count <= Int(UInt16.max),
                  entry.body.count <= Int(UInt32.max),
                  entry.compressedBody.count <= Int(UInt32.max),
                  data.count <= Int(UInt32.max) else {
                throw ModuleRepositoryDownloadTestError.compressionFailed
            }
            let localHeaderOffset = UInt32(data.count)
            localHeaderOffsets.append(localHeaderOffset)
            let checksum = moduleRepositoryZipCRC32(entry.body)

            data.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            appendModuleRepositoryZipUInt16(20, to: &data)
            appendModuleRepositoryZipUInt16(0x0008, to: &data)
            appendModuleRepositoryZipUInt16(8, to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            appendModuleRepositoryZipUInt32(0, to: &data)
            appendModuleRepositoryZipUInt32(0, to: &data)
            appendModuleRepositoryZipUInt32(0, to: &data)
            appendModuleRepositoryZipUInt16(UInt16(nameData.count), to: &data)
            appendModuleRepositoryZipUInt16(0, to: &data)
            data.append(nameData)
            data.append(entry.compressedBody)
            appendModuleRepositoryZipUInt32(0x0807_4b50, to: &data)
            appendModuleRepositoryZipUInt32(checksum, to: &data)
            appendModuleRepositoryZipUInt32(UInt32(entry.compressedBody.count), to: &data)
            appendModuleRepositoryZipUInt32(UInt32(entry.body.count), to: &data)
        }

        guard data.count <= Int(UInt32.max) else {
            throw ModuleRepositoryDownloadTestError.compressionFailed
        }
        let centralDirectoryOffset = UInt32(data.count)
        for (index, entry) in entries.enumerated() {
            guard let nameData = entry.name.data(using: .utf8) else {
                throw ModuleRepositoryDownloadTestError.compressionFailed
            }
            let checksum = moduleRepositoryZipCRC32(entry.body)

            centralDirectory.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            appendModuleRepositoryZipUInt16(20, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(20, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0x0008, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(8, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt32(checksum, to: &centralDirectory)
            appendModuleRepositoryZipUInt32(UInt32(entry.compressedBody.count), to: &centralDirectory)
            appendModuleRepositoryZipUInt32(UInt32(entry.body.count), to: &centralDirectory)
            appendModuleRepositoryZipUInt16(UInt16(nameData.count), to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt16(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt32(0, to: &centralDirectory)
            appendModuleRepositoryZipUInt32(localHeaderOffsets[index], to: &centralDirectory)
            centralDirectory.append(nameData)
        }

        data.append(centralDirectory)
        data.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        appendModuleRepositoryZipUInt16(0, to: &data)
        appendModuleRepositoryZipUInt16(0, to: &data)
        appendModuleRepositoryZipUInt16(UInt16(entries.count), to: &data)
        appendModuleRepositoryZipUInt16(UInt16(entries.count), to: &data)
        appendModuleRepositoryZipUInt32(UInt32(centralDirectory.count), to: &data)
        appendModuleRepositoryZipUInt32(centralDirectoryOffset, to: &data)
        appendModuleRepositoryZipUInt16(0, to: &data)

        return data
    }

    private func makeModuleRepositoryRawDeflateData(_ data: Data) throws -> Data {
        let gzipData = try gzipModuleRepositoryTestData(data)
        guard gzipData.count > 18 else {
            throw ModuleRepositoryDownloadTestError.compressionFailed
        }
        return Data(gzipData.dropFirst(10).dropLast(8))
    }

    private func moduleRepositoryZipCRC32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            var lookup = (crc ^ UInt32(byte)) & 0xff
            for _ in 0..<8 {
                if lookup & 1 == 1 {
                    lookup = (lookup >> 1) ^ 0xedb8_8320
                } else {
                    lookup >>= 1
                }
            }
            crc = (crc >> 8) ^ lookup
        }
        return crc ^ 0xffff_ffff
    }

    private func appendModuleRepositoryZipUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private func appendModuleRepositoryZipUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private func makeMyBibleFixtureDatabase(at databaseURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        ) == SQLITE_OK else {
            throw MyBibleFixtureError.openFailed
        }
        defer { sqlite3_close(db) }

        let sql = """
        CREATE TABLE info (name TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE books (book_number INTEGER PRIMARY KEY, long_name TEXT, short_name TEXT);
        CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT);
        INSERT INTO info (name, value) VALUES ('description', 'Finnish RK');
        INSERT INTO info (name, value) VALUES ('language', 'fi');
        INSERT INTO books (book_number, long_name, short_name) VALUES (10, 'Genesis', 'Gen');
        INSERT INTO verses (book_number, chapter, verse, text) VALUES (10, 1, 1, 'Alussa loi Jumala');
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw MyBibleFixtureError.writeFailed
        }
    }

/**
 Verifies an installed MyBible fixture remained a readable SQLite Bible payload.

 This keeps the repository install test owned by SwordKit while still proving the extracted file
 retains the Android/MyBible schema and verse data that higher layers will later consume.
 */
private func assertMyBibleFixtureDatabase(
    at databaseURL: URL,
    expectedDescription: String,
    expectedLanguage: String
) throws {
    var db: OpaquePointer?
    guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        throw MyBibleFixtureError.openFailed
    }
    defer { sqlite3_close(db) }

    XCTAssertEqual(
        try myBibleFixtureTextValue(db: db, sql: "SELECT value FROM info WHERE name = 'description'"),
        expectedDescription
    )
    XCTAssertEqual(
        try myBibleFixtureTextValue(db: db, sql: "SELECT value FROM info WHERE name = 'language'"),
        expectedLanguage
    )
    XCTAssertEqual(
        try myBibleFixtureTextValue(
            db: db,
            sql: "SELECT text FROM verses WHERE book_number = 10 AND chapter = 1 AND verse = 1"
        ),
        "Alussa loi Jumala"
    )
}

/**
 Reads one text column from a MyBible SQLite fixture.

 - Parameters:
   - db: Open SQLite handle.
   - sql: Query returning one text column.
 - Returns: The first row's text value.
 - Side effects: Prepares and finalizes one SQLite statement.
 */
private func myBibleFixtureTextValue(db: OpaquePointer?, sql: String) throws -> String {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        throw MyBibleFixtureError.readFailed
    }
    defer { sqlite3_finalize(stmt) }

    guard sqlite3_step(stmt) == SQLITE_ROW,
          let text = sqlite3_column_text(stmt, 0) else {
        throw MyBibleFixtureError.readFailed
    }
    return String(cString: text)
}

}

private enum ModuleRepositoryDownloadTestError: Error {
    case compressionFailed
}


private enum MyBibleFixtureError: Error {
    case openFailed
    case readFailed
    case writeFailed
}


/**
 URL protocol test double for module repository download and manifest requests.

 Tests set `requestHandler` to return deterministic HTTP responses for catalog, package, and raw
 module-data URLs. Leaving the handler unset is a test setup failure because no network access is
 expected in this package lane.
 */
private final class ModuleRepositoryDownloadMockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("ModuleRepositoryDownloadMockURLProtocol.requestHandler must be set before use")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
