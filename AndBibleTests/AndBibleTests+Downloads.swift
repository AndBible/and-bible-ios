import XCTest
import CLibSword
@testable import BibleCore
import SQLite3
@testable import SwordKit
@testable import BibleUI

private let searchIndexFixtureSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension AndBibleTests {
    func testModuleBrowserRowActionConfirmationUsesFriendlyModuleDescription() {
        let module = RemoteModuleInfo(
            name: "KJV",
            description: "King James Version",
            category: .bible,
            language: "en",
            sourceName: "CrossWire"
        )

        let uninstall = ModuleBrowserRowActionConfirmation(kind: .uninstall, module: module)
        let deleteIndex = ModuleBrowserRowActionConfirmation(kind: .deleteIndex, module: module)

        XCTAssertEqual(uninstall.message, "Remove King James Version from this device?")
        XCTAssertEqual(deleteIndex.message, "Delete the search index for King James Version?")
    }

    func testSearchIndexDeleteIndexAwaitsQueuedMutation() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        let queuedMutationStarted = expectation(description: "queued fixture mutation started")
        let releaseQueuedMutation = DispatchSemaphore(value: 0)

        let fixtureTask = Task {
            try await service.performIndexMutationForTesting { db in
                queuedMutationStarted.fulfill()
                releaseQueuedMutation.wait()
                try self.seedSearchIndexFixture(moduleName: "KJV", db: db)
            }
        }

        await fulfillment(of: [queuedMutationStarted], timeout: 1.0)
        let deleteTask = Task {
            await service.deleteIndex(for: "KJV")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            releaseQueuedMutation.signal()
        }
        try await fixtureTask.value
        await deleteTask.value

        let deletedCounts = try searchIndexFixtureCounts(moduleName: "KJV", databaseURL: databaseURL)
        XCTAssertEqual(deletedCounts.rows, 0)
        XCTAssertEqual(deletedCounts.metadata, 0)
    }

    func testModuleBrowserDownloadActivityDrivesAndroidProgressAndErrorStatus() {
        let modules = [
            RemoteModuleInfo(
                name: "KJV",
                description: "King James Version",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            ),
            RemoteModuleInfo(
                name: "WEB",
                description: "World English Bible",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "2.0"
            ),
            RemoteModuleInfo(
                name: "REC",
                description: "Recommended Bible",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            ),
            RemoteModuleInfo(
                name: "WARN",
                description: "Active warning module",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            ),
            RemoteModuleInfo(
                name: "FAIL",
                description: "Failed module",
                category: .bible,
                language: "en",
                sourceName: "CrossWire",
                version: "1.0"
            )
        ]
        let installed = [
            ModuleInfo(name: "KJV", description: "King James Version", category: .bible, language: "en", version: "1.0"),
            ModuleInfo(name: "WEB", description: "World English Bible", category: .bible, language: "en", version: "1.0")
        ]
        let recommended = ModuleDownloadConfiguration(
            bibles: ["en": ["REC::CrossWire"]]
        )
        let activities: [String: ModuleBrowserDownloadActivity] = [
            "WARN": .inProgress(0.37),
            "FAIL": .failed("testdict.idx download failed (HTTP 500)")
        ]

        let filtered = ModuleBrowserView.filteredDownloadModules(
            modules,
            selectedCategory: nil,
            selectedLanguage: "en",
            searchText: "",
            installedModules: installed,
            downloadActivities: activities,
            recommendedDocuments: recommended,
            badDocuments: nil
        )

        XCTAssertEqual(filtered.map(\.name), ["WARN", "WEB", "KJV", "REC", "FAIL"])
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: modules[3],
                installedModules: installed,
                downloadActivities: activities
            ),
            .beingInstalled(progressPercent: 37)
        )
        XCTAssertEqual(
            ModuleBrowserView.displayStatus(
                for: modules[4],
                installedModules: installed,
                downloadActivities: activities
            ),
            .errorDownloading(message: "testdict.idx download failed (HTTP 500)")
        )
    }

    func testModuleBrowserAutoRefreshesOnlyMissingOrStaleCatalogs() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "TestRepo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw"
        )
        let repository = ModuleRepository(
            basePath: tempDir.path,
            swordPath: swordDir.path,
            session: makeModuleRepositoryDownloadMockSession()
        )

        XCTAssertFalse(
            ModuleBrowserView.shouldAutoRefreshCatalogs(sources: [], repository: repository),
            "Downloads should not start a refresh loop when no repository sources are configured."
        )
        XCTAssertTrue(
            ModuleBrowserView.shouldAutoRefreshCatalogs(sources: [source], repository: repository),
            "Missing source cache should refresh after the sheet opens, matching Android's first-load behavior."
        )

        try writeModuleRepositoryCatalogCache(sourceName: source.name, timestamp: Date(), under: tempDir)
        XCTAssertFalse(
            ModuleBrowserView.shouldAutoRefreshCatalogs(sources: [source], repository: repository),
            "Recent source cache should open from cache without immediately refreshing."
        )

        try writeModuleRepositoryCatalogCache(
            sourceName: source.name,
            timestamp: Date(timeIntervalSinceNow: -(ModuleBrowserView.downloadCatalogStaleInterval + 1)),
            under: tempDir
        )
        XCTAssertTrue(
            ModuleBrowserView.shouldAutoRefreshCatalogs(sources: [source], repository: repository),
            "Stale source cache should refresh after the cached list has been restored."
        )
    }

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
        do {
            let reader = try XCTUnwrap(MyBibleReader(filePath: installedDatabaseURL.path))
            XCTAssertTrue(reader.isBible)
            XCTAssertEqual(reader.moduleDescription, "Finnish RK")
            XCTAssertEqual(reader.language, "fi")
            XCTAssertEqual(reader.getVerse(book: 10, chapter: 1, verse: 1), "Alussa loi Jumala")
        }

        try repository.uninstallModule(named: "MyBible-finrk_SQLite3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: moduleDir.path))
        XCTAssertTrue(repository.loadInstalledMyBibleModules().isEmpty)
    }

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
        let reader = try XCTUnwrap(MyBibleReader(filePath: installedDatabaseURL.path))
        XCTAssertEqual(reader.getVerse(book: 10, chapter: 1, verse: 1), "Alussa loi Jumala")
    }

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
            catalogPath: "/raw"
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
            case "/raw/modules/lexdict/rawld/testdict/testdict.dat":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data("dictionary-data".utf8)
            case "/raw/modules/lexdict/rawld/testdict/testdict.idx":
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
            XCTFail("Expected failed required data-file download to fail the module install.")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("testdict.idx"),
                "Failure should identify the required file that could not be downloaded."
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
            "A failed fresh module download should clean up staged data files."
        )
    }

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
            catalogPath: "/raw"
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
            case "/raw/modules/lexdict/rawld/testdict/testdict.dat":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data("new-dictionary-data".utf8)
            case "/raw/modules/lexdict/rawld/testdict/testdict.idx":
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
            XCTFail("Expected failed update to throw.")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("testdict.idx"),
                "Failure should identify the required file that could not be downloaded."
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

    func testModuleRepositoryInstallsSingleTestamentModuleWhenOptionalGroupIsMissing() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let source = SourceConfig(
            name: "TestRepo",
            type: "HTTP",
            host: "example.test",
            catalogPath: "/raw"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(
            moduleName: "NTONLY",
            category: "Biblical Texts",
            modDrv: "zText",
            dataPath: "./modules/texts/ztext/ntonly/"
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
            case "/raw/modules/texts/ztext/ntonly/ot.bzs":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            case "/raw/modules/texts/ztext/ntonly/nt.bzs",
                "/raw/modules/texts/ztext/ntonly/nt.bzz",
                "/raw/modules/texts/ztext/ntonly/nt.bzv":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data("new-testament-data-\(request.url!.lastPathComponent)".utf8)
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

        XCTAssertFalse(
            requestedPaths.contains("/raw/modules/texts/ztext/ntonly/ot.bzz"),
            "A missing optional OT group should skip the rest of that testament's files."
        )
        XCTAssertFalse(
            requestedPaths.contains("/raw/modules/texts/ztext/ntonly/ot.bzv"),
            "A missing optional OT group should not fail single-testament NT installs."
        )

        let localDir = swordDir
            .appendingPathComponent("modules", isDirectory: true)
            .appendingPathComponent("texts", isDirectory: true)
            .appendingPathComponent("ztext", isDirectory: true)
            .appendingPathComponent("ntonly", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: localDir.appendingPathComponent("ot.bzs").path),
            "Missing optional testament files should not be created locally."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent("nt.bzs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent("nt.bzz").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent("nt.bzv").path))

        let confPath = swordDir
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("ntonly.conf")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: confPath.path),
            "A single-testament install with at least one complete data group should publish its .conf marker."
        )
    }

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
            catalogPath: "/raw"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(
            moduleName: "BARNES",
            category: "Commentaries",
            modDrv: "zCom",
            dataPath: "./modules/comments/zcom/barnes/",
            extraConf: "BlockType=CHAPTER"
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
            case "/raw/modules/comments/zcom/barnes/ot.czs":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
            case "/raw/modules/comments/zcom/barnes/nt.czs",
                "/raw/modules/comments/zcom/barnes/nt.czz",
                "/raw/modules/comments/zcom/barnes/nt.czv":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data("commentary-data-\(request.url!.lastPathComponent)".utf8)
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

        XCTAssertFalse(
            requestedPaths.contains { $0.hasSuffix(".bzs") || $0.hasSuffix(".bzz") || $0.hasSuffix(".bzv") },
            "Chapter-block compressed commentaries should request c-extension data files, not b-extension files."
        )
        XCTAssertTrue(requestedPaths.contains("/raw/modules/comments/zcom/barnes/nt.czs"))
        XCTAssertTrue(requestedPaths.contains("/raw/modules/comments/zcom/barnes/nt.czz"))
        XCTAssertTrue(requestedPaths.contains("/raw/modules/comments/zcom/barnes/nt.czv"))

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

    func testModuleRepositoryFallsBackToPackageZipWhenRawDataFilesAreUnavailable() async throws {
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
            case "/andbible-extra/modules/comments/rawcom/augustin/ot",
                "/andbible-extra/modules/comments/rawcom/augustin/nt":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
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

        XCTAssertTrue(
            requestedPaths.contains("/andbible-extra/zip/Augustin.zip"),
            "Package-backed repositories should fall back to the module ZIP when raw data files are unavailable."
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
            "A package ZIP fallback should still publish the catalog .conf marker through the staged installer."
        )
    }

    func testModuleRepositoryUsesAndroidDefaultPackageDirectoryForPackageFallback() async throws {
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
            case "/catalog/modules/lexdict/rawld/stepmod/stepmod.dat":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
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
            case "/catalog/modules/lexdict/rawld/custom/custom.dat":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data()
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
            "Persisted custom package directories must take precedence over legacy zip heuristics."
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
            catalogPath: "/raw"
        )
        let catalogData = try makeModuleRepositoryCatalogArchive(moduleName: "TESTDICT")
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
            case "/raw/modules/lexdict/rawld/testdict/testdict.dat":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data("dictionary-data".utf8)
            case "/raw/modules/lexdict/rawld/testdict/testdict.idx":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data("index-data".utf8)
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
            requestedPaths.contains("/raw/modules/lexdict/rawld/testdict/testdict.idx"),
            "Cancellation after the first required file should stop before requesting the next file."
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
            "A cancelled fresh module download should clean up staged data files."
        )
    }

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
            catalogPath: "/raw"
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
            case "/raw/modules/lexdict/rawld/testdict/testdict.dat":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data("dictionary-data".utf8)
            case "/raw/modules/lexdict/rawld/testdict/testdict.idx":
                response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                data = Data("index-data".utf8)
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
            "Cancelling after the final staged file should not publish staged module data."
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

    private func writeModuleRepositoryCatalogCache(sourceName: String, timestamp: Date, under baseDir: URL) throws {
        let cacheDir = baseDir.appendingPathComponent("catalog-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let json = """
        {
          "timestamp": \(timestamp.timeIntervalSinceReferenceDate),
          "modules": []
        }
        """
        try Data(json.utf8).write(to: cacheDir.appendingPathComponent("\(sourceName).json"))
    }

    private func seedSearchIndexFixture(moduleName: String, databaseURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw SearchIndexFixtureError.openFailed
        }
        defer { sqlite3_close(db) }

        try seedSearchIndexFixture(moduleName: moduleName, db: db)
    }

    private func seedSearchIndexFixture(moduleName: String, db: OpaquePointer?) throws {
        let escapedModuleName = moduleName.replacingOccurrences(of: "'", with: "''")
        let sql = """
        INSERT INTO verse_fts (verse_key, plain_text, module_name)
        VALUES ('Genesis 1:1', 'created', '\(escapedModuleName)');
        INSERT INTO indexed_modules (module_name, verse_count, indexed_at, schema_version)
        VALUES ('\(escapedModuleName)', 1, datetime('now'), 1);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SearchIndexFixtureError.writeFailed
        }
    }

    private func searchIndexFixtureCounts(moduleName: String, databaseURL: URL) throws -> (rows: Int, metadata: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SearchIndexFixtureError.openFailed
        }
        defer { sqlite3_close(db) }

        return (
            rows: try searchIndexFixtureCount(
                db: db,
                sql: "SELECT COUNT(*) FROM verse_fts WHERE module_name = ?",
                moduleName: moduleName
            ),
            metadata: try searchIndexFixtureCount(
                db: db,
                sql: "SELECT COUNT(*) FROM indexed_modules WHERE module_name = ?",
                moduleName: moduleName
            )
        )
    }

    private func searchIndexFixtureCount(db: OpaquePointer?, sql: String, moduleName: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchIndexFixtureError.readFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, moduleName, -1, searchIndexFixtureSQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw SearchIndexFixtureError.readFailed
        }
        return Int(sqlite3_column_int(stmt, 0))
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
}

private enum ModuleRepositoryDownloadTestError: Error {
    case compressionFailed
}

private enum SearchIndexFixtureError: Error {
    case openFailed
    case readFailed
    case writeFailed
}

private enum MyBibleFixtureError: Error {
    case openFailed
    case writeFailed
}

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
