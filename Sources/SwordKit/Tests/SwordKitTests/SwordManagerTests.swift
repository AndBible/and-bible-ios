// SwordManagerTests.swift — Tests for SwordKit

import XCTest
@testable import SwordKit

final class SwordManagerTests: XCTestCase {
    /**
     Verifies manager-level unlock rejects invalid requests without manufacturing module state.

     The setup uses an empty SWORD root so the contract is deterministic with both the real and stub
     bridge. A failure means picker unlock could report success for a missing module or empty key.
     */
    func testUnlockModuleRejectsMissingModuleAndEmptyCipherKey() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: moduleRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        let manager = try XCTUnwrap(SwordManager(modulePath: moduleRoot.path))

        XCTAssertFalse(manager.unlockModule(named: "MISSING", withCipherKey: "secret"))
        XCTAssertFalse(manager.unlockModule(named: "MISSING", withCipherKey: ""))
    }

    /**
     Verifies decrypted Bible, commentary, dictionary, and general-book entries must form
     renderable OSIS before a key is accepted.

     - Setup: Supplies representative in-memory OSIS fragments for every encrypted SWORD document
       category; no native backend state is mocked.
     - Expected result: Each category-specific fragment parses into renderable document content.
     - Side effects: Parses in-memory fixtures only.
     - Failure meaning: A category can persist unauthenticated ciphertext despite the native
       backend returning success.
     */
    func testCipherEntryValidationAcceptsRenderableAndroidDocumentFormats() {
        let fixtures: [(ModuleCategory, String)] = [
            (.bible, #"<verse osisID="Gen.1.1">In the beginning</verse>"#),
            (.commentary, #"<verse osisID="Gen.1.1"><p>Commentary text</p></verse>"#),
            (.dictionary, #"<entryFree><orth>agape</orth><p>Love</p></entryFree>"#),
            (.generalBook, #"<div><title>Introduction</title><p>Book text</p></div>"#),
        ]

        for (category, content) in fixtures {
            XCTAssertTrue(
                SwordManager.cipherEntryIsStructurallyReadable(
                    osisFragment: content,
                    category: category,
                    moduleInitials: "LOCKED"
                ),
                "Expected structurally valid \(category.rawValue) content to pass."
            )
        }
    }

    /**
     Verifies empty, control-corrupted, and malformed decrypted bytes fail independently of SWORD's
     backend error flag.

     - Setup: Supplies replacement/control scalars plus empty and truncated OSIS fragments.
     - Expected result: Raw plausibility and category-aware structural checks reject every fixture.
     - Side effects: Parses in-memory fixtures only.
     - Failure meaning: A wrong raw-module key can still be persisted when ciphertext happens not to
       trigger `SWModule_popError`.
     */
    func testCipherEntryValidationRejectsUnauthenticatedGarbage() {
        XCTAssertFalse(SwordManager.isPlausibleDecryptedModuleText("bad\u{0097}text"))
        XCTAssertFalse(SwordManager.isPlausibleDecryptedModuleText("bad\u{E000}text"))
        XCTAssertFalse(SwordManager.cipherEntryIsStructurallyReadable(
            osisFragment: "",
            category: .bible,
            moduleInitials: "LOCKED"
        ))
        XCTAssertFalse(SwordManager.cipherEntryIsStructurallyReadable(
            osisFragment: "<p>cipher\u{0001}text</p>",
            category: .dictionary,
            moduleInitials: "LOCKED"
        ))
        XCTAssertFalse(SwordManager.cipherEntryIsStructurallyReadable(
            osisFragment: "<entryFree><p>truncated",
            category: .generalBook,
            moduleInitials: "LOCKED"
        ))
    }

    /**
     Verifies a real encrypted RawLD module rejects a wrong key without persistence and remains
     retryable with the correct key.

     - Setup: Loads a native Sapphire II encrypted RawLD record through libsword with an empty
       `CipherKey`, then submits an ordinary wrong passphrase before the fixture's real key.
     - Expected result: The wrong key leaves byte-identical config and locked inventory; the correct
       retry decrypts content and persists the verified key.
     - Side effects: Writes a native RawLD index/record, encrypts the entry with SWORD's Sapphire II
       format, loads it through libsword, and rewrites only the temporary config after success.
     - Failure meaning: Wrong keys can mark encrypted modules unlocked, poison durable config, or
       prevent a later correct-key retry.
     */
    func testEncryptedRawLDWrongKeyIsUnpersistedAndCorrectKeyRemainsRetryable() throws {
        let fixture = try makeEncryptedRawLDFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let originalConfig = try Data(contentsOf: fixture.configURL)
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let initiallyLocked = try XCTUnwrap(
            manager.installedModules().first { $0.name == "LOCKED" }
        )
        XCTAssertTrue(initiallyLocked.isEncrypted)
        XCTAssertFalse(initiallyLocked.isUnlocked)

        XCTAssertFalse(
            manager.unlockModule(named: "LOCKED", withCipherKey: "wrong-test-key")
        )
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), originalConfig)
        XCTAssertFalse(
            manager.installedModules().first { $0.name == "LOCKED" }?.isUnlocked ?? true
        )

        XCTAssertTrue(manager.unlockModule(named: "LOCKED", withCipherKey: fixture.cipherKey))
        let persistedConfig = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(persistedConfig.contains("CipherKey=\(fixture.cipherKey)"))
        XCTAssertTrue(
            manager.installedModules().first { $0.name == "LOCKED" }?.isUnlocked ?? false
        )
        let module = try XCTUnwrap(manager.module(named: "LOCKED"))
        module.begin()
        XCTAssertTrue(module.rawEntry().contains("Encrypted dictionary entry"))
    }

    /**
     Verifies a failed replacement key leaves an already-unlocked module and its durable key intact.

     - Setup: Builds a native encrypted RawLD fixture, persists its correct key before manager
       creation, and proves the live module can decrypt the entry.
     - Expected result: A wrong candidate fails structural validation in an isolated manager while
       the original config bytes and live-manager plaintext remain unchanged.
     - Side effects: Creates and removes a temporary SWORD root; no shared module state is touched.
     - Failure meaning: Retrying unlock can replace a working key before validation or leave the
       current reader poisoned by a failed candidate.
     */
    func testEncryptedRawLDFailedReplacementRestoresExistingKeyAndReadableSession() throws {
        let fixture = try makeEncryptedRawLDFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var persistedConfiguration = try String(contentsOf: fixture.configURL, encoding: .utf8)
        persistedConfiguration = persistedConfiguration.replacingOccurrences(
            of: "CipherKey=",
            with: "CipherKey=\(fixture.cipherKey)"
        )
        try persistedConfiguration.write(
            to: fixture.configURL,
            atomically: true,
            encoding: .utf8
        )
        let originalConfig = try Data(contentsOf: fixture.configURL)
        let manager = try XCTUnwrap(SwordManager(modulePath: fixture.root.path))
        let module = try XCTUnwrap(manager.module(named: "LOCKED"))
        module.begin()
        XCTAssertTrue(module.rawEntry().contains("Encrypted dictionary entry"))

        XCTAssertFalse(manager.unlockModule(named: "LOCKED", withCipherKey: "wrong-test-key"))

        XCTAssertEqual(try Data(contentsOf: fixture.configURL), originalConfig)
        module.begin()
        XCTAssertTrue(module.rawEntry().contains("Encrypted dictionary entry"))
        XCTAssertTrue(
            manager.installedModules().first { $0.name == "LOCKED" }?.isUnlocked ?? false
        )
    }

    /**
     Verifies a content-verified key is durably written to the exact module config section.

     A read-back failure means a picker unlock could work only for the current manager session and
     regress to locked after relaunch.
     */
    func testPersistVerifiedCipherKeySurvivesConfigReload() throws {
        let moduleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = moduleRoot.appendingPathComponent("mods.d", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: moduleRoot) }
        let configURL = configDirectory.appendingPathComponent("locked.conf")
        try """
        [LOCKED]
        ModDrv=RawText
        DataPath=./modules/texts/rawtext/locked/
        CipherKey=
        """.write(to: configURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(
            SwordManager.persistVerifiedCipherKey(
                "secret-key",
                moduleName: "locked",
                modulePath: moduleRoot.path
            )
        )

        let reloaded = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(reloaded.contains("CipherKey=secret-key"))
    }

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

    /**
     Verifies installed module rows retain Android `CommonUtils.showAbout` metadata from SWORD config.

     JSword reloads `SwordBookMetaData` before opening About and exposes fields such as `About`,
     copyright, version history, versification, OSIS ID, bad-document state, and version date. iOS must
     project those config values into `ModuleInfo` so reader-picker and Downloads About dialogs show
     real metadata instead of iOS-only substitutes.
     */
    func testSwordModuleConfigProjectsAndroidAboutMetadataIntoModuleInfo() throws {
        let config = try XCTUnwrap(SwordModuleConfig.parse("""
        [TEST]
        Description=Test Bible
        Category=Biblical Texts
        ModDrv=zText
        Lang=en
        Version=2.0
        SwordVersionDate=2024-01-02
        About=First line\\par Second line
        ShortPromo=Short promo
        ShortCopyright=Short copyright
        Copyright=Long copyright
        DistributionLicense=GPL
        UnlockInfo=Request a key
        History_1.0=First release
        History_2.0=Second release
        Versification=KJVA
        BadDocument=true
        """))

        let info = config.moduleInfo

        XCTAssertEqual(info.aboutMetadata.about, "First line\\par Second line")
        XCTAssertEqual(info.aboutMetadata.shortPromo, "Short promo")
        XCTAssertEqual(info.aboutMetadata.shortCopyright, "Short copyright")
        XCTAssertEqual(info.aboutMetadata.copyright, "Long copyright")
        XCTAssertEqual(info.aboutMetadata.distributionLicense, "GPL")
        XCTAssertEqual(info.aboutMetadata.unlockInfo, "Request a key")
        XCTAssertEqual(info.aboutMetadata.history, ["1.0 First release", "2.0 Second release"])
        XCTAssertEqual(info.aboutMetadata.versification, "KJVA")
        XCTAssertEqual(info.aboutMetadata.osisId, "TEST")
        XCTAssertTrue(info.aboutMetadata.isBadDocument)
        XCTAssertEqual(info.aboutMetadata.swordVersionDate, "2024-01-02")
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
        XCTAssertEqual(bdbt.moduleDriver, "MyBibleDictionary")
        XCTAssertTrue(bdbt.features.contains(.greekDef))
        XCTAssertTrue(bdbt.features.contains(.hebrewDef))
        XCTAssertTrue(manager.installedModules(category: .dictionary).contains { $0.name == "BDBT" })
    }

    /**
     Verifies both installed-book APIs reject the same malformed metadata JSword excludes.

     - Setup: Writes a real RawLD payload referenced by three configs: one known driver with an
       unknown versification, one unknown driver, and one missing `ModDrv`.
     - Expected result: Neither enumeration nor direct name lookup exposes any invalid module.
     - Failure meaning: A malformed non-Bible module can enter iOS pickers or Downloads despite being
       absent from Android's `Books.installed()` registry.
     - Side effects: Creates and removes one isolated temporary SWORD root.
     */
    func testInstalledBookAPIsRejectUnknownDriverAndVersificationMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let modsDir = tempDir.appendingPathComponent("mods.d", isDirectory: true)
        let dataDir = tempDir.appendingPathComponent(
            "modules/lexdict/rawld/invalid",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let record = Data("entry\r\nvalue".utf8)
        let recordSize = UInt16(record.count)
        try (record + Data([0x0A])).write(to: dataDir.appendingPathComponent("invalid.dat"))
        try Data([
            0x00, 0x00, 0x00, 0x00,
            UInt8(recordSize & 0x00FF), UInt8(recordSize >> 8),
        ]).write(to: dataDir.appendingPathComponent("invalid.idx"))

        let sharedConfig = """
        Description=Invalid Dictionary
        Category=Lexicons / Dictionaries
        DataPath=./modules/lexdict/rawld/invalid/invalid
        Lang=en
        """
        try """
        [UNKNOWNV11N]
        \(sharedConfig)
        ModDrv=RawLD
        Versification=NotAVersification
        """.write(
            to: modsDir.appendingPathComponent("unknownv11n.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [UNKNOWNDRIVER]
        \(sharedConfig)
        ModDrv=MadeUpDictionary
        """.write(
            to: modsDir.appendingPathComponent("unknowndriver.conf"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [MISSINGDRIVER]
        \(sharedConfig)
        """.write(
            to: modsDir.appendingPathComponent("missingdriver.conf"),
            atomically: true,
            encoding: .utf8
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: tempDir.path))
        let invalidNames = Set(["UNKNOWNV11N", "UNKNOWNDRIVER", "MISSINGDRIVER"])

        XCTAssertTrue(invalidNames.isDisjoint(with: manager.installedModules().map(\.name)))
        for name in invalidNames {
            XCTAssertNil(manager.module(named: name), "Expected \(name) to fail closed")
        }
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
     Verifies installed And Bible add-on modules expose Android-compatible reading-plan providers.

     Android's `AndBibleAddons.providedReadingPlans` reads repeated
     `AndBibleProvidesReadingPlan` config values, resolves those files relative to the installed
     book location, and carries `AndBibleReadingPlanDateBased`, `Versification`, and `ShortPromo`
     metadata into `ReadingPlanTextFileDao`. This test writes a minimal add-on config plus one
     readable `.properties` file under the SWORD root. The expected result proves iOS can discover
     the same provider contract while ignoring unsafe or missing provider entries.
     */
    func testReadingPlanProvidersExposeReadableAddonPlansAndMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let swordDir = tempDir.appendingPathComponent("sword", isDirectory: true)
        let modsDir = swordDir.appendingPathComponent("mods.d", isDirectory: true)
        let addonDir = swordDir
            .appendingPathComponent("modules/genbook/rawgenbook/planaddon", isDirectory: true)
        try FileManager.default.createDirectory(at: modsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: addonDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        # Add-on plan
        Versification=NRSVA
        1=Matt.1
        """.write(
            to: addonDir.appendingPathComponent("addon_plan.properties"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [PLANADDON]
        Description=Add-on Reading Plans
        Category=And Bible
        ModDrv=RawGenBook
        DataPath=./modules/genbook/rawgenbook/planaddon/
        Lang=en
        ShortPromo=Plans supplied by an add-on module.
        Versification=NRSVA
        AndBibleReadingPlanDateBased=True
        AndBibleProvidesReadingPlan=addon_plan.properties
        AndBibleProvidesReadingPlan=missing.properties
        AndBibleProvidesReadingPlan=../escape.properties
        """.write(
            to: modsDir.appendingPathComponent("planaddon.conf"),
            atomically: true,
            encoding: .utf8
        )

        let providers = SwordManager.readingPlanProviders(modulePath: swordDir.path)

        XCTAssertEqual(providers.map(\.planCode), ["addon_plan"])
        let provider = try XCTUnwrap(providers.first)
        XCTAssertEqual(provider.name, "Add-on Reading Plans")
        XCTAssertEqual(provider.description, "Plans supplied by an add-on module.")
        XCTAssertEqual(provider.fileURL, addonDir.appendingPathComponent("addon_plan.properties").standardizedFileURL)
        XCTAssertEqual(provider.versification, "NRSVA")
        XCTAssertTrue(provider.isDateBased)
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
        XCTAssertEqual(finrk.aboutMetadata.versification, "KJVA")
        XCTAssertTrue(finrk.isSupported)
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

    /**
     Builds a native encrypted RawLD fixture whose ciphertext contains no embedded NUL.

     - Returns: Temporary SWORD root, config location, and the correct key.
     - Side effects: Creates one config plus RawLD `.dat` and six-byte `.idx` files in a unique
       temporary directory.
     - Failure Modes: Propagates filesystem errors, rejects oversized records, or fails if the
       bounded key search cannot produce C-string-safe fixture ciphertext.
     */
    private func makeEncryptedRawLDFixture() throws -> SwordManagerEncryptedFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configDirectory = root.appendingPathComponent("mods.d", isDirectory: true)
        let dataDirectory = root.appendingPathComponent(
            "modules/lexdict/rawld/locked",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

        let plaintext = Data(
            "<entryFree><orth>cipher</orth><p>Encrypted dictionary entry.</p></entryFree>".utf8
        )
        var selectedKey: String?
        var encrypted = Data()
        for candidateIndex in 0..<256 {
            let candidateKey = "cipherkey\(candidateIndex)"
            var cipher = SwordManagerTestSapphire(key: Array(candidateKey.utf8))
            let candidateCiphertext = Data(plaintext.map { cipher.encrypt($0) })
            if !candidateCiphertext.contains(0) {
                selectedKey = candidateKey
                encrypted = candidateCiphertext
                break
            }
        }
        guard let cipherKey = selectedKey else {
            throw SwordManagerEncryptedFixtureError.ciphertextContainsNUL
        }
        let keyPrefix = Data("ENTRY\r\n".utf8)
        let recordSize = keyPrefix.count + encrypted.count
        guard recordSize <= Int(UInt16.max) else {
            throw SwordManagerEncryptedFixtureError.entryTooLarge
        }
        var record = keyPrefix
        record.append(encrypted)
        record.append(0x0A)
        let dataPrefix = dataDirectory.appendingPathComponent("locked")
        try record.write(to: dataPrefix.appendingPathExtension("dat"))
        var index = Data([0, 0, 0, 0])
        let entrySize = UInt16(recordSize)
        index.append(UInt8(entrySize & 0x00ff))
        index.append(UInt8((entrySize >> 8) & 0x00ff))
        try index.write(to: dataPrefix.appendingPathExtension("idx"))

        let configURL = configDirectory.appendingPathComponent("locked.conf")
        try """
        [LOCKED]
        Description=Encrypted RawLD Fixture
        Category=Lexicons / Dictionaries
        ModDrv=RawLD
        DataPath=./modules/lexdict/rawld/locked/locked
        SourceType=OSIS
        Encoding=UTF-8
        CipherKey=
        """.write(to: configURL, atomically: true, encoding: .utf8)
        return SwordManagerEncryptedFixture(
            root: root,
            configURL: configURL,
            cipherKey: cipherKey
        )
    }

    private static func makePseudoBooksMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PseudoBooksMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/**
 Carries the temporary paths and verified key for one native encrypted-module unlock test.

 The value owns no resources itself; its test creates and removes `root`. Construction performs no
 I/O, cannot fail, and is deterministic for the supplied values.
 */
private struct SwordManagerEncryptedFixture {
    /// SWORD root containing the encrypted RawLD module.
    let root: URL

    /// Config whose `CipherKey` persistence is asserted.
    let configURL: URL

    /// Plain key used to produce the fixture ciphertext.
    let cipherKey: String

}

/**
 Describes deterministic failures while constructing a native encrypted RawLD fixture.

 Cases identify fixture limitations rather than production unlock failures. The enum has no side
 effects and is used only to fail a test before libsword is invoked.
 */
private enum SwordManagerEncryptedFixtureError: Error {
    /// RawLD cannot represent the fixture entry in its two-byte length field.
    case entryTooLarge

    /// No bounded test key produced RawLD ciphertext without an embedded C-string terminator.
    case ciphertextContainsNUL

}

/**
 Test-only Sapphire II encryptor matching libsword's `Sapphire::encrypt` state transitions.

 Production decryption remains entirely inside libsword. This implementation only creates realistic
 ciphertext at runtime so unlock tests exercise a native RawLD SWORD backend.
 */
private struct SwordManagerTestSapphire {
    private var cards = [UInt8](repeating: 0, count: 256)
    private var rotor: UInt8 = 0
    private var ratchet: UInt8 = 0
    private var avalanche: UInt8 = 0
    private var lastPlain: UInt8 = 0
    private var lastCipher: UInt8 = 0

    /**
     Initializes the exact keyed card permutation used by libsword.

     - Parameter key: One to 255 key bytes used to seed the Sapphire II permutation.
     - Side effects: Initializes only this value's stream state.
     - Failure modes: Traps when `key` is empty or exceeds Sapphire II's one-byte key length.
     - Postcondition: The next `encrypt` call emits the first byte of a deterministic keyed stream.
     */
    init(key: [UInt8]) {
        precondition(!key.isEmpty && key.count <= 255)
        for index in cards.indices {
            cards[index] = UInt8(index)
        }
        var toSwap: UInt8 = 0
        var keyPosition = 0
        var runningSum: UInt8 = 0
        for index in stride(from: 255, through: 0, by: -1) {
            toSwap = keyRandom(
                limit: index,
                key: key,
                runningSum: &runningSum,
                keyPosition: &keyPosition
            )
            cards.swapAt(index, Int(toSwap))
        }
        rotor = cards[1]
        ratchet = cards[3]
        avalanche = cards[5]
        lastPlain = cards[7]
        lastCipher = cards[Int(runningSum)]
    }

    /**
     Encrypts one byte with the fixture's Sapphire II state.

     - Parameter plaintext: Next plaintext byte in stream order.
     - Returns: Corresponding ciphertext byte.
     - Side effects: Advances the mutable card, rotor, ratchet, avalanche, and history state.
     - Failure modes: None after valid initialization; callers must preserve byte order.
     */
    mutating func encrypt(_ plaintext: UInt8) -> UInt8 {
        ratchet = ratchet &+ cards[Int(rotor)]
        rotor = rotor &+ 1
        let swapTemporary = cards[Int(lastCipher)]
        cards[Int(lastCipher)] = cards[Int(ratchet)]
        cards[Int(ratchet)] = cards[Int(lastPlain)]
        cards[Int(lastPlain)] = cards[Int(rotor)]
        cards[Int(rotor)] = swapTemporary
        avalanche = avalanche &+ cards[Int(swapTemporary)]

        let firstIndex = Int(cards[Int(ratchet)] &+ cards[Int(rotor)])
        let nestedIndex = Int(
            cards[Int(lastPlain)] &+ cards[Int(lastCipher)] &+ cards[Int(avalanche)]
        )
        lastCipher = plaintext ^ cards[firstIndex] ^ cards[Int(cards[nestedIndex])]
        lastPlain = plaintext
        return lastCipher
    }

    /**
     Selects one keyed permutation index using libsword's bounded retry rule.

     - Parameters:
       - limit: Inclusive upper bound used to construct the selection mask.
       - key: Non-empty Sapphire key bytes.
       - runningSum: Mutable key-schedule accumulator.
       - keyPosition: Mutable cursor into `key`.
     - Returns: One permutation index no greater than `limit`.
     - Side effects: Advances `runningSum` and `keyPosition` deterministically.
     - Failure modes: None; initialization enforces a non-empty key and supplies nonnegative limits.
     */
    private mutating func keyRandom(
        limit: Int,
        key: [UInt8],
        runningSum: inout UInt8,
        keyPosition: inout Int
    ) -> UInt8 {
        guard limit > 0 else { return 0 }
        var mask = 1
        while mask < limit {
            mask = (mask << 1) + 1
        }
        var retryCount = 0
        while true {
            runningSum = cards[Int(runningSum)] &+ key[keyPosition]
            keyPosition += 1
            if keyPosition >= key.count {
                keyPosition = 0
                runningSum = runningSum &+ UInt8(key.count)
            }
            retryCount += 1
            var candidate = mask & Int(runningSum)
            if retryCount > 11 {
                candidate %= limit
            }
            if candidate <= limit {
                return UInt8(candidate)
            }
        }
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
