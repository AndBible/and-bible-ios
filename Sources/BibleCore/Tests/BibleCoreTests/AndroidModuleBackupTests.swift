import Foundation
import XCTest
@testable import BibleCore
import SwordKit

/**
 Verifies Android-compatible module backup import/export behavior in the BibleCore package target.

 The suite builds in-memory ZIP archives and temporary SWORD module roots to exercise
 `AndroidModuleBackupService` without the app host. Failures indicate Android module backup
 parity regressions, unsafe file overwrite behavior, or broken iOS/Android round-trip export
 compatibility. Temporary files are registered in `temporaryFilePaths` and removed after each
 test to keep package-test runs deterministic.
 */
final class AndroidModuleBackupTests: XCTestCase {
    private var temporaryFilePaths: [String] = []

    /**
     Removes temporary SWORD roots and archive files created by each test.

     The cleanup mirrors the former app-host `AndBibleTests` teardown dependency locally so this
     package suite does not retain UI-heavy app test support. Cleanup failures are ignored because
     failed assertions should report the behavior regression while temporary-directory cleanup is
     best-effort after test completion.
     */
    override func tearDown() {
        let fileManager = FileManager.default
        for path in temporaryFilePaths {
            try? fileManager.removeItem(atPath: path)
        }
        temporaryFilePaths.removeAll()
        super.tearDown()
    }

    /**
     Verifies that Android module backups are recognized by suffix and do not trust a database
     manifest to suppress otherwise valid module content.

     Setup:
     - checks Android's module-backup filename suffix
     - builds a ZIP with `AndBibleBackupManifest.json` declaring `DB_BACKUP` before a MyBible file

     Expected result:
     - `.abmd.zip` recognition is case-insensitive
     - the module backup service follows Android's legacy inference and discovers the module file

     Failure meaning:
     - iOS would trust a manifest Android explicitly treats as advisory and reject restorable data.
     */
    func testAndroidModuleBackupTreatsDatabaseManifestAsLegacyModuleArchive() throws {
        XCTAssertTrue(AndroidModuleBackupService.isAndroidModuleBackupFileName("AndBibleModulesBackup.abmd.zip"))
        XCTAssertTrue(AndroidModuleBackupService.isAndroidModuleBackupFileName("ANDBIBLEMODULESBACKUP.ABMD.ZIP"))
        XCTAssertFalse(AndroidModuleBackupService.isAndroidModuleBackupFileName("AndBibleDatabaseBackup.abdb.zip"))

        let archiveData = try makeAndroidModuleBackupArchiveData(
            manifestBackupType: "DB_BACKUP",
            entries: [("mybible/Book.SQLite3", Data("module".utf8))]
        )
        let service = AndroidModuleBackupService(moduleDirectory: try makeTemporaryAndroidModuleBackupRoot())

        let inspection = try service.inspectArchive(from: archiveData)

        XCTAssertEqual(inspection.manifest.backupType, "MODULE_BACKUP")
        XCTAssertEqual(inspection.supportedModuleNames, ["MyBible-Book"])
        XCTAssertEqual(inspection.supportedEntryCount, 1)
    }

    /**
     Verifies alternate Android path spellings cannot target one normalized destination twice.

     Failure means backslashes or benign dot components can bypass duplicate detection and make
     restore behavior depend on ZIP entry order.
     */
    func testAndroidModuleBackupRejectsNormalizedDuplicateEntrySpellings() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d\\kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("./mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("modules/texts/rawtext/kjv/ot", Data("Genesis content".utf8)),
        ])

        XCTAssertThrowsError(try service.inspectArchive(from: archiveData)) { error in
            XCTAssertEqual(
                error as? AndroidModuleBackupError,
                .duplicateEntry("mods.d/kjv.conf")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: moduleRoot.appendingPathComponent("mods.d/kjv.conf").path))
    }

    /**
     Verifies one Android backup restores SWORD and MyBible content as one complete transaction.

     The fixture combines a SWORD config/payload with a real MyBible SQLite database. Inspection
     and restore must report both identities, publish both byte-exact payloads, and leave the
     restored database readable through the production adapter. Failure means iOS silently omits
     one Android family or claims an invalid SQLite payload was restored.
     */
    func testAndroidModuleBackupRestoresMixedSwordAndMyBibleContent() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let myBibleData = try Data(contentsOf: sqliteDocumentReaderFixtureURL(
            "mybible-bible.SQLite3"
        ))
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("modules/texts/rawtext/kjv/ot", Data("Genesis content".utf8)),
            ("mybible/mybible-bible.SQLite3", myBibleData),
        ])

        let inspection = try service.inspectArchive(from: archiveData)
        let report = try service.restoreArchive(from: archiveData)

        XCTAssertEqual(inspection.supportedModuleNames, ["KJV", "MyBible-mybible_bible"])
        XCTAssertEqual(report.installedModuleNames, inspection.supportedModuleNames)
        XCTAssertEqual(
            try Data(contentsOf: moduleRoot.appendingPathComponent("mybible/mybible-bible.SQLite3")),
            myBibleData
        )
        let restoredReader = try MyBibleReader(
            fileURL: moduleRoot.appendingPathComponent("mybible/mybible-bible.SQLite3")
        )
        XCTAssertEqual(restoredReader.metadata.initials, "MyBible-mybible_bible")
        XCTAssertEqual(
            restoredReader.getVerse(book: 10, chapter: 1, verse: 1),
            "<title canonical=\"false\">Creation</title>In the <J>beginning</J>"
        )
        XCTAssertEqual(
            try String(
                contentsOf: moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot"),
                encoding: .utf8
            ),
            "Genesis content"
        )
    }

    /**
     Verifies one malformed SWORD config cannot hide an independently valid SQLite family.

     The file-backed archive combines a parseable MyBible database with a config missing every
     ownership field. Restore must transactionally publish the valid database and generated
     registration, omit the malformed config, and report that omission without weakening ZIP
     digest verification.

     - Side effects: Writes and removes one archive, then publishes into an isolated module root.
     - Failure modes: Fixture I/O is thrown; fail-fast parsing, partial publication, or missing
       diagnostics fail exact assertions.
     */
    func testAndroidModuleBackupRestoresValidFamilyBesideMalformedSwordConfiguration() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let myBibleData = try Data(contentsOf: sqliteDocumentReaderFixtureURL(
            "mybible-bible.SQLite3"
        ))
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/broken.conf", Data("[BROKEN]\nDescription=Missing ownership\n".utf8)),
            ("mybible/mybible-bible.SQLite3", myBibleData),
        ])
        let archiveURL = moduleRoot.appendingPathComponent("mixed-malformed.abmd.zip")
        try archiveData.write(to: archiveURL, options: .atomic)
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)

        let report = try service.restoreArchive(fromArchiveAt: archiveURL)

        XCTAssertEqual(report.installedModuleNames, ["MyBible-mybible_bible"])
        XCTAssertEqual(report.installedEntryCount, 1)
        XCTAssertEqual(
            report.diagnostics.map { $0.family },
            [AndroidModuleBackupContentFamily.swordConfiguration]
        )
        XCTAssertEqual(
            report.diagnostics.map { $0.relativePath },
            ["mods.d/broken.conf"]
        )
        XCTAssertEqual(
            try Data(contentsOf: moduleRoot.appendingPathComponent(
                "mybible/mybible-bible.SQLite3"
            )),
            myBibleData
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: moduleRoot.appendingPathComponent("mods.d/broken.conf").path
        ))
        XCTAssertEqual(
            ModuleStoreInstalledRegistrationReader.read(modulePath: moduleRoot.path)
                .map(\.moduleInfo.name),
            ["MyBible-mybible_bible"]
        )
    }

    /**
     Verifies safe unowned members retain Android's generic extraction behavior during restore.

     A valid MyBible document makes the legacy ZIP installable while unrelated safe files sit under
     Android-owned module roots. Those ambient files are not registrations, but Android extracts
     them and iOS must publish them in the same transaction instead of rejecting the archive.

     - Side effects: Publishes three files and one generated registration below a temporary root.
     - Failure modes: Fixture or restore errors are thrown; over-strict classification leaves either
       ambient byte sequence absent and fails the assertions.
     */
    func testAndroidModuleBackupPublishesSafeAmbientAndroidRootFiles() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let myBibleData = try Data(contentsOf: sqliteDocumentReaderFixtureURL(
            "mybible-bible.SQLite3"
        ))
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mybible/mybible-bible.SQLite3", myBibleData),
            ("mybible/readme.txt", Data("Android sidecar".utf8)),
            ("modules/texts/rawtext/orphan/ot", Data("ambient payload".utf8)),
        ])
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)

        let report = try service.restoreArchive(from: archiveData)

        XCTAssertEqual(report.installedModuleNames, ["MyBible-mybible_bible"])
        XCTAssertEqual(report.installedEntryCount, 3)
        XCTAssertEqual(
            try Data(contentsOf: moduleRoot.appendingPathComponent("mybible/readme.txt")),
            Data("Android sidecar".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: moduleRoot.appendingPathComponent(
                "modules/texts/rawtext/orphan/ot"
            )),
            Data("ambient payload".utf8)
        )
    }

    /**
     Verifies cross-family identity arbitration follows JSword exact and case lookup precedence.

     Duplicate incoming display names are legal because Android checks only the new initials before
     registration. Later initials must still collide with any existing initials or full name, and
     an exact full-name lookup must beat an earlier case-insensitive initials match.

     - Side effects: Mutates only an in-memory registry.
     - Failure modes: Incorrect claim or lookup precedence fails the exact family assertions.
     */
    func testAndroidModuleBackupIdentityUsesInitialsAndFullNameWithJSwordPrecedence() {
        var registry = AndroidModuleBackupIdentityRegistry()
        let sword = AndroidModuleBackupInstalledContent(
            initials: "CASE",
            displayName: "Shared Full Name",
            language: "en",
            family: .swordConfiguration
        )
        let epub = AndroidModuleBackupInstalledContent(
            initials: "Epub-Other",
            displayName: "case",
            language: "en",
            family: .epub
        )
        let background = AndroidModuleBackupInstalledContent(
            initials: "BGIMG_Second",
            displayName: "Shared Full Name",
            language: "",
            family: .background
        )

        XCTAssertTrue(registry.claim(sword))
        XCTAssertTrue(registry.claim(epub))
        XCTAssertTrue(registry.claim(background))
        XCTAssertEqual(registry.content(matching: "case")?.family, .epub)
        XCTAssertEqual(registry.content(matching: "Shared Full Name")?.family, .background)
        XCTAssertFalse(registry.claim(AndroidModuleBackupInstalledContent(
            initials: "shared full name",
            displayName: "Different",
            language: "en",
            family: .myBible
        )))
        XCTAssertFalse(registry.claim(AndroidModuleBackupInstalledContent(
            initials: "Case",
            displayName: "Different Again",
            language: "en",
            family: .mySword
        )))
    }

    /**
     Verifies Android module backup restore can inspect and install from a file URL.

     Setup:
     - writes an Android-shaped `.abmd.zip` fixture to disk
     - inspects and restores through file-backed service APIs instead of retaining raw `Data`

     Expected result:
     - inspection reports the supported module from the file URL
     - restore writes the supported SWORD payload into the module root

     Failure meaning:
     - the Documents restore/import target would keep the same whole-file memory behavior that
       blocks large Android backups and diverges from Android's file-backed restore path.
     */
    func testAndroidModuleBackupRestoresArchiveFromFileURL() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("modules/texts/rawtext/kjv/ot", Data("Genesis content".utf8)),
        ])
        let archiveURL = try writeTemporaryAndroidModuleBackupArchive(archiveData)

        let inspection = try service.inspectArchive(fromArchiveAt: archiveURL)
        let report = try service.restoreArchive(fromArchiveAt: archiveURL)

        XCTAssertEqual(inspection.supportedModuleNames, ["KJV"])
        XCTAssertEqual(report.installedModuleNames, ["KJV"])
        XCTAssertEqual(
            try String(contentsOf: moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot"), encoding: .utf8),
            "Genesis content"
        )
    }

    /**
     Verifies file-backed Android module restores enforce the shared download storage reserve.

     Setup supplies a valid archive and a deterministic zero-capacity provider. The inspection must
     still report the exact expanded size, while restore must reserve both the staging and live copy
     on their shared filesystem and throw the public insufficient-storage error before creating
     config or payload files. Failure means the preflight can pass even though publication cannot
     coexist with staging.
     */
    func testAndroidModuleBackupRejectsLowStorageBeforeFileBackedStaging() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let payload = Data("Genesis content".utf8)
        let config = makeAndroidModuleBackupConf(moduleName: "KJV")
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/kjv.conf", config),
            ("modules/texts/rawtext/kjv/ot", payload),
        ])
        let archiveURL = try writeTemporaryAndroidModuleBackupArchive(archiveData)
        let service = AndroidModuleBackupService(
            moduleDirectory: moduleRoot,
            storagePreflight: ModuleStoragePreflight(capacityProvider: { _ in 0 })
        )

        let inspection = try service.inspectArchive(fromArchiveAt: archiveURL)
        XCTAssertEqual(
            inspection.estimatedExpandedBytes,
            Int64(config.count + payload.count)
        )

        XCTAssertThrowsError(try service.restoreArchive(fromArchiveAt: archiveURL)) { error in
            guard case ModuleRepositoryError.insufficientStorage(let required, let available) = error else {
                return XCTFail("Expected insufficient-storage error, got \(error)")
            }
            XCTAssertEqual(
                required,
                ModuleStoragePreflight.androidMinimumAvailableBytes
                    + (inspection.estimatedExpandedBytes * 2)
            )
            XCTAssertEqual(available, 0)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: moduleRoot.appendingPathComponent("mods.d/kjv.conf").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot").path
            )
        )
    }

    /**
     Verifies that Android RawLD4 dictionary modules restore when their `DataPath` names a file
     stem instead of the containing directory.

     Setup:
     - builds an Android-shaped `.abmd.zip` fixture with a `RawLD4` config matching Android
       production backups
     - stores `.dat` and `.idx` files under the containing SWORD data directory
     - inspects and restores through file-backed APIs, matching external file import

     Expected result:
     - inspection treats the RawLD4 file stem as present when sibling data files exist
     - restore writes the config and RawLD4 payload files into the module root

     Failure meaning:
     - iOS rejects valid Android production module backups with "references missing data path"
       even though Android and SWORD store RawLD4 data as file-stem payloads.
     */
    func testAndroidModuleBackupRestoresRawLD4FileStemModuleFromFileURL() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/acdcref.conf", makeAndroidRawLD4ModuleBackupConf()),
            ("modules/lexdict/rawld4/acdcref/acdcref.dat", Data("dictionary data".utf8)),
            ("modules/lexdict/rawld4/acdcref/acdcref.idx", Data("dictionary index".utf8)),
        ])
        let archiveURL = try writeTemporaryAndroidModuleBackupArchive(archiveData)

        let inspection = try service.inspectArchive(fromArchiveAt: archiveURL)
        let report = try service.restoreArchive(fromArchiveAt: archiveURL)

        XCTAssertEqual(inspection.supportedModuleNames, ["ACDCref"])
        XCTAssertEqual(report.installedModuleNames, ["ACDCref"])
        XCTAssertEqual(report.installedEntryCount, 3)
        XCTAssertEqual(
            try String(
                contentsOf: moduleRoot.appendingPathComponent("modules/lexdict/rawld4/acdcref/acdcref.dat"),
                encoding: .utf8
            ),
            "dictionary data"
        )
        XCTAssertEqual(
            try String(
                contentsOf: moduleRoot.appendingPathComponent("modules/lexdict/rawld4/acdcref/acdcref.idx"),
                encoding: .utf8
            ),
            "dictionary index"
        )
    }

    /**
     Verifies that file-backed Android module backup restore announces the installed-module store
     change immediately after publishing SWORD files.

     Setup:
     - writes a valid Android `.abmd.zip` fixture to disk
     - observes the module-store change notification that open reader and downloads views use to
       rebuild stale `SwordManager` snapshots

     Expected result:
     - restore posts a visible module-store change after successful file publication

     Failure meaning:
     - restored modules can remain hidden in already-open UI surfaces until app restart, because
       SWORD's disk cache was invalidated without notifying long-lived in-memory module caches.
     */
    func testAndroidModuleBackupRestoreFromFileURLNotifiesModuleStoreChange() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/esv.conf", makeAndroidModuleBackupConf(moduleName: "ESV")),
            ("modules/texts/rawtext/esv/ot", Data("Genesis content".utf8)),
        ])
        let archiveURL = try writeTemporaryAndroidModuleBackupArchive(archiveData)
        let notificationExpectation = expectation(
            forNotification: SwordModuleStore.modulesDidChangeNotification,
            object: nil
        )

        _ = try service.restoreArchive(fromArchiveAt: archiveURL)

        wait(for: [notificationExpectation], timeout: 0.2)
    }

    /**
     Verifies that overwrite protection matches the UI confirmation contract for Android module
     backup restore.

     Setup:
     - creates an existing local module data file
     - builds an Android backup that would replace that same file

     Expected result:
     - inspection reports the existing file path for confirmation UI
     - restore with overwrites disabled fails without changing the local file
     - restore with overwrites enabled replaces the file

     Failure meaning:
     - iOS could overwrite installed module data without confirmation or fail to apply the user's
       confirmed overwrite choice.
     */
    func testAndroidModuleBackupReportsAndControlsExistingFileOverwrite() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let existingURL = moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot")
        let obsoleteURL = moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/nt")
        try FileManager.default.createDirectory(
            at: existingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("local".utf8).write(to: existingURL)
        try Data("obsolete".utf8).write(to: obsoleteURL)

        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("modules/texts/rawtext/kjv/ot", Data("remote".utf8)),
        ])

        let inspection = try service.inspectArchive(from: archiveData)
        XCTAssertEqual(
            inspection.existingEntryPaths,
            ["modules/texts/rawtext/kjv/ot"]
        )

        XCTAssertThrowsError(
            try service.restoreArchive(from: archiveData)
        ) { error in
            XCTAssertEqual(
                error as? AndroidModuleBackupError,
                .moduleFilesAlreadyExist(["modules/texts/rawtext/kjv/ot"])
            )
        }
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "local")
        XCTAssertEqual(try String(contentsOf: obsoleteURL, encoding: .utf8), "obsolete")

        _ = try service.restoreArchive(
            from: archiveData,
            overwritePolicy: .replaceExisting(inspection.overwriteAuthorization)
        )
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "remote")
        XCTAssertEqual(try String(contentsOf: obsoleteURL, encoding: .utf8), "obsolete")
    }

    /**
     Verifies Android module backup restore overwrites installed files whose casing differs from
     the Android archive entry.

     Setup:
     - creates an existing lowercase SWORD config
     - restores a file-backed Android backup containing the same config path with uppercase module
       initials

     Expected result:
     - inspection reports the uppercase archive path as an existing entry
     - restore replaces the lowercase installed file with the archive-cased file instead of
       failing during publish

     Failure meaning:
     - iOS rejects valid Android production module backups when installed modules differ only by
       filename casing from Android's backup entries.
    */
    func testAndroidModuleBackupOverwritesCaseVariantExistingFileFromFileURL() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let existingConfigURL = moduleRoot.appendingPathComponent("mods.d/acdcref.conf")
        try makeAndroidRawLD4ModuleBackupConf().write(to: existingConfigURL)
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/ACDCREF.conf", makeAndroidRawLD4ModuleBackupConf()),
            ("modules/lexdict/rawld4/acdcref/acdcref.dat", Data("dictionary data".utf8)),
            ("modules/lexdict/rawld4/acdcref/acdcref.idx", Data("dictionary index".utf8)),
        ])
        let archiveURL = try writeTemporaryAndroidModuleBackupArchive(archiveData)

        let inspection = try service.inspectArchive(fromArchiveAt: archiveURL)
        _ = try service.restoreArchive(
            fromArchiveAt: archiveURL,
            overwritePolicy: .replaceExisting(inspection.overwriteAuthorization)
        )

        let configNames = try FileManager.default.contentsOfDirectory(
            atPath: moduleRoot.appendingPathComponent("mods.d").path
        )
        XCTAssertEqual(inspection.existingEntryPaths, ["mods.d/ACDCREF.conf"])
        XCTAssertTrue(configNames.contains("ACDCREF.conf"))
        XCTAssertFalse(configNames.contains("acdcref.conf"))
        XCTAssertEqual(
            try String(contentsOf: moduleRoot.appendingPathComponent("mods.d/ACDCREF.conf"), encoding: .utf8),
            String(data: makeAndroidRawLD4ModuleBackupConf(), encoding: .utf8)
        )
    }

    /**
     Verifies an EPUB-only Android backup restores both its authoritative tree and native index.

     A real unoptimized Android EPUB directory is archived beneath `epub/<displayName>`. Restore
     must publish every raw file, report Android's EPUB initials, and reconcile a browseable reader
     into an isolated iOS library. Failure means an Android EPUB backup is accepted structurally
     but remains undiscoverable or unreadable after restore.
     */
    func testAndroidModuleBackupRestoresEpubOnlyContent() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let displayName = "Restored Book.epub"
        let fixtureDirectory = moduleRoot
            .appendingPathComponent("_fixture", isDirectory: true)
            .appendingPathComponent(displayName, isDirectory: true)
        let libraryRoot = moduleRoot.appendingPathComponent("_epub-library", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeRawTree(
            at: fixtureDirectory,
            label: "Restored"
        )
        let packageURL = fixtureDirectory.appendingPathComponent("OPS/package.opf")
        let package = try String(contentsOf: packageURL, encoding: .utf8)
            .replacingOccurrences(
                of: "<dc:creator>Android Fixture</dc:creator>",
                with: "<dc:creator>Android Fixture</dc:creator>\n    <dc:description>Restored package description</dc:description>"
            )
            .replacingOccurrences(
                of: "<dc:language>en</dc:language>",
                with: "<dc:language>fr-CA</dc:language>"
            )
        try Data(package.utf8).write(to: packageURL, options: .atomic)
        let archiveData = try makeAndroidModuleBackupArchiveData(
            entries: try archiveEntries(
                beneath: fixtureDirectory,
                archiveRootPath: "epub/\(displayName)"
            )
        )
        let service = AndroidModuleBackupService(
            moduleDirectory: moduleRoot,
            epubLibraryRootURL: libraryRoot
        )

        let inspection = try service.inspectArchive(from: archiveData)
        let report = try service.restoreArchive(from: archiveData)

        XCTAssertEqual(inspection.supportedModuleNames, ["Epub-Restored_Book_epub"])
        XCTAssertEqual(report.installedModuleNames, inspection.supportedModuleNames)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: moduleRoot.appendingPathComponent(
                "epub/\(displayName)/META-INF/container.xml"
            ).path
        ))
        let installed = try XCTUnwrap(EpubReader.installedEpubs(libraryRootURL: libraryRoot).first)
        let reader = try XCTUnwrap(EpubReader(identifier: installed.identifier, libraryRootURL: libraryRoot))
        XCTAssertEqual(reader.initials, "Epub-Restored_Book_epub")
        XCTAssertEqual(reader.title, "Restored Android Book")
        XCTAssertEqual(reader.language, "fr-CA")
        let generatedConfigurationURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: moduleRoot.appendingPathComponent("mods.d", isDirectory: true),
                includingPropertiesForKeys: nil
            ).first
        )
        let generatedConfiguration = try String(
            contentsOf: generatedConfigurationURL,
            encoding: .utf8
        )
        XCTAssertTrue(generatedConfiguration.contains("Description=Restored Android Book\n"))
        XCTAssertTrue(generatedConfiguration.contains("About=Restored package description\n"))
        XCTAssertTrue(generatedConfiguration.contains("Lang=fr-CA\n"))
        XCTAssertTrue(try XCTUnwrap(reader.content(forKey: "chapter-1")).html.contains(
            "Restored raw opening."
        ))
    }

    /**
     Verifies Android module backups normalize Windows path separators before safety validation.

     Android's shared installer replaces backslashes with slashes. This fixture must restore to the
     canonical SWORD layout while traversal checks remain active. Failure rejects an Android-accepted
     backup produced or repackaged on Windows.
     */
    func testAndroidModuleBackupNormalizesAndroidBackslashPaths() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d\\kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("modules\\texts\\rawtext\\kjv\\ot", Data("Genesis".utf8)),
        ])

        let report = try service.restoreArchive(from: archiveData)
        XCTAssertEqual(report.installedModuleNames, ["KJV"])
        XCTAssertEqual(
            try String(
                contentsOf: moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot"),
                encoding: .utf8
            ),
            "Genesis"
        )
    }

    /**
     Verifies file-backed Android backup consent cannot authorize a swapped provider archive.

     The test preflights a conflicting archive, atomically replaces the same URL with different
     valid bytes, and restores using the retained authorization. Digest mismatch must fail before
     staging publication and preserve the installed payload. Failure exposes overwrite TOCTOU.
     */
    func testAndroidModuleBackupRejectsArchiveSwapAfterOverwriteConfirmation() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let existingURL = moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot")
        try FileManager.default.createDirectory(
            at: existingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("installed".utf8).write(to: existingURL)

        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveURL = try writeTemporaryAndroidModuleBackupArchive(
            makeAndroidModuleBackupArchiveData(entries: [
                ("mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
                ("modules/texts/rawtext/kjv/ot", Data("first".utf8)),
            ])
        )
        let inspection = try service.inspectArchive(fromArchiveAt: archiveURL)
        let swappedData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("modules/texts/rawtext/kjv/ot", Data("swapped".utf8)),
        ])
        try swappedData.write(to: archiveURL, options: .atomic)

        XCTAssertThrowsError(
            try service.restoreArchive(
                fromArchiveAt: archiveURL,
                overwritePolicy: .replaceExisting(inspection.overwriteAuthorization)
            )
        ) { error in
            guard case AndroidModuleBackupError.invalidArchive(let message) = error else {
                return XCTFail("Expected archive-identity failure, got \(error)")
            }
            XCTAssertTrue(message.contains("changed after overwrite confirmation"))
        }
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "installed")
    }

    /**
     Verifies overwrite confirmation cannot authorize a conflict created after preflight.

     Inspection sees only the existing config destination. A second writer then creates the
     incoming payload destination before restore. Restore must reject the expanded conflict set
     without changing either file. Failure means concurrent module activity can silently broaden
     the exact paths the user approved.
     */
    func testAndroidModuleBackupRejectsConflictAddedAfterOverwriteConfirmation() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let configURL = moduleRoot.appendingPathComponent("mods.d/kjv.conf")
        let payloadURL = moduleRoot.appendingPathComponent("modules/texts/rawtext/kjv/ot")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("installed-config".utf8).write(to: configURL)

        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
            ("modules/texts/rawtext/kjv/ot", Data("incoming".utf8)),
        ])
        let inspection = try service.inspectArchive(from: archiveData)
        XCTAssertEqual(inspection.existingEntryPaths, ["mods.d/kjv.conf"])

        try FileManager.default.createDirectory(
            at: payloadURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("concurrent".utf8).write(to: payloadURL)

        XCTAssertThrowsError(
            try service.restoreArchive(
                from: archiveData,
                overwritePolicy: .replaceExisting(inspection.overwriteAuthorization)
            )
        ) { error in
            guard case AndroidModuleBackupError.moduleFilesAlreadyExist(let paths) = error else {
                return XCTFail("Expected newly appeared conflict, got \(error)")
            }
            XCTAssertEqual(
                paths,
                ["mods.d/kjv.conf", "modules/texts/rawtext/kjv/ot"]
            )
        }
        XCTAssertEqual(try Data(contentsOf: configURL), Data("installed-config".utf8))
        XCTAssertEqual(try Data(contentsOf: payloadURL), Data("concurrent".utf8))
    }

    /**
     Verifies every raw config `DataPath` attack is rejected during Android archive inspection.

     Failure means a backup can defer traversal detection until publication or plant a config that
     later drives uninstall outside the canonical `modules/` root.
     */
    func testAndroidModuleBackupRejectsUnsafeConfigDataPathsBeforeStaging() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let unsafePaths = [
            "",
            ".",
            "..",
            "../../outside",
            "/modules/texts/rawtext/bad",
            "././modules/texts/rawtext/bad",
            "modules\\texts\\rawtext\\bad",
            "modules/%2e%2e/outside",
        ]

        for dataPath in unsafePaths {
            let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
                ("mods.d/bad.conf", makeAndroidModuleBackupConf(
                    moduleName: "BAD",
                    dataPath: dataPath
                )),
                ("modules/texts/rawtext/bad/ot", Data("payload".utf8)),
            ])
            XCTAssertThrowsError(try service.inspectArchive(from: archiveData)) { error in
                guard let backupError = error as? AndroidModuleBackupError,
                      case .invalidModuleLayout = backupError else {
                    return XCTFail("Expected invalid module layout for \(dataPath), received \(error).")
                }
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: moduleRoot.appendingPathComponent("mods.d/bad.conf").path
        ))
    }

    /**
     Verifies activated Android SWORD configs form one complete, non-overlapping ownership map.

     Safe unowned files follow Android's generic extraction path and are covered separately. A
     configuration with no owned payload or overlapping config roots must still fail before staging.
     */
    func testAndroidModuleBackupRejectsUnboundAndCrossModuleOwnership() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)
        let invalidEntrySets: [[(String, Data)]] = [
            [
                ("mods.d/kjv.conf", makeAndroidModuleBackupConf(moduleName: "KJV")),
                ("modules/texts/rawtext/asv/ot", Data("unowned".utf8)),
            ],
            [
                ("mods.d/one.conf", makeAndroidModuleBackupConf(
                    moduleName: "ONE",
                    dataPath: "./modules/texts/rawtext/shared/"
                )),
                ("mods.d/two.conf", makeAndroidModuleBackupConf(
                    moduleName: "TWO",
                    dataPath: "./modules/texts/rawtext/shared/"
                )),
                ("modules/texts/rawtext/shared/ot", Data("shared".utf8)),
            ],
        ]

        for entries in invalidEntrySets {
            let archiveData = try makeAndroidModuleBackupArchiveData(entries: entries)
            XCTAssertThrowsError(try service.inspectArchive(from: archiveData)) { error in
                guard let backupError = error as? AndroidModuleBackupError,
                      case .invalidModuleLayout = backupError else {
                    return XCTFail("Expected ownership rejection, received \(error).")
                }
            }
        }
    }

    /**
     Verifies Android restore and an independent remote publisher serialize at typed checkpoints.

     Failure means BibleCore and SwordKit hold different root locks, allowing backup rollback to
     remove a concurrent remote winner or publish a mismatched config/payload pair.
     */
    func testAndroidModuleBackupVersusRemotePublishSerializesDeterministically() async throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let archiveData = try makeAndroidModuleBackupArchiveData(entries: [
            ("mods.d/race.conf", makeAndroidModuleBackupConf(moduleName: "RACE")),
            ("modules/texts/rawtext/race/ot", Data("android".utf8)),
        ])
        let service = AndroidModuleBackupServiceSendableBox(
            AndroidModuleBackupService(moduleDirectory: moduleRoot)
        )
        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        temporaryFilePaths.append(stagingRoot.path)
        let stagedConfigURL = stagingRoot.appendingPathComponent("mods.d/race.conf")
        let stagedPayloadURL = stagingRoot.appendingPathComponent("modules/texts/rawtext/race/ot")
        try FileManager.default.createDirectory(
            at: stagedConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: stagedPayloadURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let remoteConfig = makeAndroidModuleBackupConf(moduleName: "RACE")
        try remoteConfig.write(to: stagedConfigURL)
        try Data("remote".utf8).write(to: stagedPayloadURL)
        let publisher = ModuleStoreTransactionPublisher(moduleRootURL: moduleRoot)
        let remotePlan = try publisher.validateStagedInstall(
            configurations: [ModuleStoreStagedConfiguration(
                relativePath: "mods.d/race.conf",
                content: try String(contentsOf: stagedConfigURL, encoding: .utf8)
            )],
            payloadRelativePaths: ["modules/texts/rawtext/race/ot"]
        )
        let gate = AndroidModuleBackupTransactionGate()
        let observation = ModuleStoreMutationCoordinator.observeTransactions(
            forModuleRoot: moduleRoot,
            observer: { event in gate.observe(event) }
        )
        defer { observation.cancel() }

        let restoreTask = Task.detached {
            try service.value.restoreArchive(from: archiveData)
        }
        try gate.waitForFirstMutationBoundary()
        let remoteTask = Task.detached {
            try publisher.publishStagedInstall(
                remotePlan,
                from: stagingRoot,
                allowOverwrite: true,
                kind: .remoteSword
            )
        }
        try gate.waitForSecondWriterToQueue()
        gate.releaseFirstWriter()
        _ = try await restoreTask.value
        try await remoteTask.value

        XCTAssertEqual(
            try String(
                contentsOf: moduleRoot.appendingPathComponent("modules/texts/rawtext/race/ot"),
                encoding: .utf8
            ),
            "remote"
        )
        let entries = try FileManager.default.contentsOfDirectory(atPath: moduleRoot.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".module-transaction-") })
        try gate.assertFirstCommitPrecedesSecondMutation()
    }

    /**
     Verifies that iOS exports installed SWORD modules in Android's module-backup ZIP shape.

     Setup:
     - creates a local SWORD config and data file under a temporary module root
     - streams the module through the production file-backed export API
     - re-reads the ZIP with the production `ZipArchiveReader`

     Expected result:
     - the archive filename uses Android's `.abmd.zip` name
     - the manifest declares `MODULE_BACKUP`
     - the config and data entries are relative to the module root, matching Android's export

     Failure meaning:
     - Android would be unable to restore an iOS-created module backup, breaking round-trip parity.
     */
    func testAndroidModuleBackupExportsInstalledSwordModulesWithAndroidManifest() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        try writeAndroidModuleBackupInstalledModule(
            moduleRoot: moduleRoot,
            moduleName: "KJV",
            data: Data("exported".utf8)
        )
        let service = AndroidModuleBackupService(
            moduleDirectory: moduleRoot,
            producerVersion: 777
        )

        let export = try service.exportArchiveFile(moduleNames: ["KJV"])
        defer { try? FileManager.default.removeItem(at: export.fileURL) }

        XCTAssertEqual(export.fileName, AndroidModuleBackupService.moduleBackupFileName)
        XCTAssertEqual(export.moduleNames, ["KJV"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.fileURL.path))
        let entries = try ZipArchiveReader.entries(in: Data(contentsOf: export.fileURL))
        let entriesByName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.data) })
        XCTAssertEqual(
            String(data: try XCTUnwrap(entriesByName["AndBibleBackupManifest.json"]), encoding: .utf8),
            #"{"backupType":"MODULE_BACKUP","contains":null,"manifestVersion":1,"andBibleVersion":777}"#
        )
        XCTAssertEqual(
            String(data: try XCTUnwrap(entriesByName["mods.d/kjv.conf"]), encoding: .utf8),
            String(data: makeAndroidModuleBackupConf(moduleName: "KJV"), encoding: .utf8)
        )
        XCTAssertEqual(
            String(data: try XCTUnwrap(entriesByName["modules/texts/rawtext/kjv/ot"]), encoding: .utf8),
            "exported"
        )
    }

    /**
     Verifies that Android-compatible ZIP exports mark entry names as UTF-8.

     Setup:
     - writes a minimal stored ZIP archive through `ZipArchiveWriter`
     - reads the general-purpose bit flag from both local and central-directory headers

     Expected result:
     - both headers set the ZIP EFS/UTF-8 flag that Android's Java ZIP readers use for path
       decoding

     Failure meaning:
     - Android restore could reinterpret iOS-exported module paths with a platform-default
       encoding, especially for localized module filenames.
     */
    func testZipArchiveWriterMarksEntryNamesAsUTF8ForAndroidReaders() throws {
        let archiveData = try ZipArchiveWriter.storedArchive(entries: [
            ZipArchiveWriterEntry(name: "mods.d/kjv.conf", data: Data("payload".utf8)),
        ])
        let expectedFlag: UInt16 = 0x0800
        let endOfCentralDirectoryOffset = archiveData.count - 22
        let centralDirectoryOffset = Int(try readZipUInt32(archiveData, at: endOfCentralDirectoryOffset + 16))

        XCTAssertEqual(try readZipUInt32(archiveData, at: endOfCentralDirectoryOffset), 0x0605_4b50)
        XCTAssertEqual(try readZipUInt32(archiveData, at: centralDirectoryOffset), 0x0201_4b50)
        XCTAssertEqual(try readZipUInt16(archiveData, at: 6), expectedFlag)
        XCTAssertEqual(try readZipUInt16(archiveData, at: centralDirectoryOffset + 8), expectedFlag)
    }

    /**
     Verifies that Android-compatible module export honors the selected-module list.

     Setup:
     - creates two installed SWORD modules under a temporary root
     - requests export of only one module, matching Android's multiselect backup flow

     Expected result:
     - the generated archive includes the selected module config/data
     - the unselected module does not appear in the archive

     Failure meaning:
     - iOS would present a selectable module backup UI but still export unselected documents,
       breaking Android parity and user intent.
     */
    func testAndroidModuleBackupExportsOnlySelectedInstalledModules() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        try writeAndroidModuleBackupInstalledModule(
            moduleRoot: moduleRoot,
            moduleName: "KJV",
            data: Data("selected".utf8)
        )
        try writeAndroidModuleBackupInstalledModule(
            moduleRoot: moduleRoot,
            moduleName: "ASV",
            data: Data("unselected".utf8)
        )
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)

        let export = try service.exportArchiveFile(moduleNames: ["KJV"])
        defer { try? FileManager.default.removeItem(at: export.fileURL) }

        XCTAssertEqual(export.moduleNames, ["KJV"])
        let entryNames = Set(try ZipArchiveReader.entries(in: Data(contentsOf: export.fileURL)).map(\.name))
        XCTAssertTrue(entryNames.contains("mods.d/kjv.conf"))
        XCTAssertTrue(entryNames.contains("modules/texts/rawtext/kjv/ot"))
        XCTAssertFalse(entryNames.contains("mods.d/asv.conf"))
        XCTAssertFalse(entryNames.contains("modules/texts/rawtext/asv/ot"))
    }

    /**
     Verifies installed discovery omits a limit-plus-one configuration without aborting inventory.

     The installed config is a regular contained file but one byte larger than the one MiB metadata
     contract. Android skips independently malformed registrations, so this sibling cannot abort
     catalog discovery or reach archive materialization.
     */
    func testAndroidModuleBackupOmitsConfigurationAtMetadataLimitPlusOne() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        try writeAndroidModuleBackupInstalledModule(
            moduleRoot: moduleRoot,
            moduleName: "KJV",
            data: Data("selected payload".utf8)
        )
        let configURL = moduleRoot.appendingPathComponent("mods.d/oversized.conf")
        try Data(repeating: 0x41, count: 1024 * 1024 + 1).write(to: configURL)
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)

        XCTAssertEqual(try service.installedContentCatalog().map(\.initials), ["KJV"])
        let export = try service.exportArchiveFile(moduleNames: ["KJV"])
        defer { try? FileManager.default.removeItem(at: export.fileURL) }
        XCTAssertEqual(export.moduleNames, ["KJV"])
        XCTAssertEqual(
            Set(try ZipArchiveReader.entryNames(inArchiveAt: export.fileURL)),
            [
                "AndBibleBackupManifest.json",
                "mods.d/kjv.conf",
                "modules/texts/rawtext/kjv/ot",
            ]
        )
    }

    /**
     Verifies selection precedes selected-artifact validation during export materialization.

     Both SWORD registrations are readable, but the unselected ASV payload is replaced by a symlink
     after discovery metadata is written. Exporting KJV must never validate or dereference ASV,
     while selecting ASV must still fail the containment check.

     - Side effects: Creates temporary module files, one external file, one symlink, and one archive.
     - Failure modes: Fixture I/O is thrown; eager whole-catalog validation aborts the KJV export,
       while missing selected validation lets the ASV export succeed.
     */
    func testAndroidModuleBackupValidatesArtifactsOnlyAfterSelection() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        try writeAndroidModuleBackupInstalledModule(
            moduleRoot: moduleRoot,
            moduleName: "KJV",
            data: Data("selected".utf8)
        )
        try writeAndroidModuleBackupInstalledModule(
            moduleRoot: moduleRoot,
            moduleName: "ASV",
            data: Data("unselected".utf8)
        )
        let asvPayload = moduleRoot.appendingPathComponent("modules/texts/rawtext/asv/ot")
        try FileManager.default.removeItem(at: asvPayload)
        let outside = moduleRoot.deletingLastPathComponent().appendingPathComponent(
            "outside-\(UUID().uuidString)"
        )
        try Data("outside".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: asvPayload, withDestinationURL: outside)
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)

        XCTAssertEqual(
            try service.installedContentCatalog().map(\.initials),
            ["ASV", "KJV"]
        )
        let export = try service.exportArchiveFile(moduleNames: ["KJV"])
        defer { try? FileManager.default.removeItem(at: export.fileURL) }
        XCTAssertEqual(export.moduleNames, ["KJV"])
        XCTAssertThrowsError(try service.exportArchiveFile(moduleNames: ["ASV"]))
    }

    /**
     Verifies one file-backed export preserves every Android module family and restores byte-exactly.

     Setup creates a SWORD module, real MyBible/MySword/e-Sword databases, recursive font and
     background resources, an omitted prompt pack, an authoritative raw EPUB tree, and an isolated
     native EPUB generation. The exported archive must put the literal manifest first, survive
     production inspection, and restore every emitted path into a second module root. Failure means
     an Android family is omitted, discovery depth differs from Android, or the streaming archive
     changes source bytes or paths.
     */
    func testAndroidModuleBackupExportsAndRestoresEveryFamilyWithByteExactPaths() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let epubLibraryRoot = moduleRoot.appendingPathComponent("_epub-library", isDirectory: true)
        let fixture = try writeAndroidModuleBackupExportFixture(
            moduleRoot: moduleRoot,
            epubLibraryRoot: epubLibraryRoot
        )
        let service = AndroidModuleBackupService(
            moduleDirectory: moduleRoot,
            epubLibraryRootURL: epubLibraryRoot
        )

        let export = try service.exportArchiveFile()
        defer { try? FileManager.default.removeItem(at: export.fileURL) }
        let archiveEntries = try ZipArchiveReader.entries(in: Data(contentsOf: export.fileURL))
        var archivedDataByPath: [String: Data] = [:]
        for entry in archiveEntries {
            XCTAssertNil(archivedDataByPath.updateValue(entry.data, forKey: entry.name))
        }

        XCTAssertEqual(archiveEntries.first?.name, "AndBibleBackupManifest.json")
        XCTAssertEqual(export.entryCount, fixture.fileDataByArchivePath.count + 1)
        XCTAssertEqual(export.moduleNames, fixture.orderedModuleNames)
        XCTAssertEqual(
            Set(archiveEntries.dropFirst().map(\.name)),
            Set(fixture.fileDataByArchivePath.keys)
        )
        for (path, expectedData) in fixture.fileDataByArchivePath {
            XCTAssertEqual(archivedDataByPath[path], expectedData, path)
        }
        for path in fixture.excludedArchivePaths {
            XCTAssertNil(archivedDataByPath[path], path)
        }

        let inspection = try service.inspectArchive(fromArchiveAt: export.fileURL)
        XCTAssertEqual(
            Set(inspection.supportedModuleNames),
            Set(fixture.archivePathsByModuleName.keys)
        )
        XCTAssertEqual(inspection.supportedEntryCount, fixture.fileDataByArchivePath.count)
        XCTAssertEqual(inspection.manifest.backupType, "MODULE_BACKUP")

        let restoredRoot = try makeTemporaryAndroidModuleBackupRoot()
        let restoredEpubLibrary = restoredRoot.appendingPathComponent(
            "_epub-library",
            isDirectory: true
        )
        let restoreService = AndroidModuleBackupService(
            moduleDirectory: restoredRoot,
            epubLibraryRootURL: restoredEpubLibrary
        )
        let report = try restoreService.restoreArchive(fromArchiveAt: export.fileURL)

        XCTAssertEqual(
            Set(report.installedModuleNames),
            Set(fixture.archivePathsByModuleName.keys)
        )
        XCTAssertEqual(report.installedEntryCount, fixture.fileDataByArchivePath.count)
        for (path, expectedData) in fixture.fileDataByArchivePath {
            XCTAssertEqual(
                try Data(contentsOf: restoredRoot.appendingPathComponent(path)),
                expectedData,
                path
            )
        }
        XCTAssertEqual(
            Set(EpubReader.installedEpubs(libraryRootURL: restoredEpubLibrary).map(\.initials)),
            ["Epub-Native_Book_epub", "Epub-Raw_Book_epub"]
        )
        let restoredManager = try XCTUnwrap(SwordManager(modulePath: restoredRoot.path))
        XCTAssertNotNil(restoredManager.module(named: "TTF_Reader Font"))
        XCTAssertNotNil(restoredManager.module(named: "BGIMG_Blue_Sky"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: restoredRoot.appendingPathComponent("prompts/Study Pack.csv").path
        ))
    }

    /**
     Verifies Android-compatible initials select each exported family independently.

     The complete mixed fixture is exported once per discovered identity using lowercase selection
     input. Each archive must contain only that identity's files plus the manifest. The in-memory
     compatibility API is also exercised for an unselected prompt identity. Failure means a
     non-SWORD reader cannot participate in the same module-selection contract as Android's backup
     UI, or Android's non-emittable prompt source leaks into export.
     */
    func testAndroidModuleBackupSelectsEveryExportFamilyByAndroidInitials() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let epubLibraryRoot = moduleRoot.appendingPathComponent("_epub-library", isDirectory: true)
        let fixture = try writeAndroidModuleBackupExportFixture(
            moduleRoot: moduleRoot,
            epubLibraryRoot: epubLibraryRoot
        )
        let service = AndroidModuleBackupService(
            moduleDirectory: moduleRoot,
            epubLibraryRootURL: epubLibraryRoot
        )

        for moduleName in fixture.archivePathsByModuleName.keys.sorted() {
            let export = try service.exportArchiveFile(moduleNames: [moduleName.lowercased()])
            let entryNames = Set(
                try ZipArchiveReader.entries(in: Data(contentsOf: export.fileURL)).map(\.name)
            )
            try? FileManager.default.removeItem(at: export.fileURL)

            XCTAssertEqual(export.moduleNames, [moduleName])
            XCTAssertEqual(
                entryNames,
                try XCTUnwrap(fixture.archivePathsByModuleName[moduleName])
                    .union(["AndBibleBackupManifest.json"]),
                moduleName
            )
        }

        XCTAssertThrowsError(
            try service.exportArchive(moduleNames: ["prompts_study pack"])
        ) { error in
            guard case AndroidModuleBackupError.noExportableModules = error else {
                return XCTFail("Expected omitted Android prompt source, received \(error)")
            }
        }
    }

    /**
     Verifies generic SWORD category ownership takes precedence over synthetic family discovery.

     A dictionary config points to a file stem inside `mybible/`, so Android owns the stem's parent
     directory and every regular descendant. Export must emit those files once under the real SWORD
     initials, and production reinspection must not invent a MyBible identity for the SQLite file.
     Failure duplicates an archive destination or changes the module-selection contract. Temporary
     files and the streamed archive are removed by the test's normal cleanup paths.
     */
    func testAndroidModuleBackupKeepsGenericSwordOwnershipForCustomFamilyPath() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let config = Data(
            """
            [CUSTOM]
            DataPath=./mybible/owned/stem
            ModDrv=RawLD
            Category=Lexicons / Dictionaries
            Description=Custom dictionary

            """.utf8
        )
        try writeAndroidModuleBackupFixtureFile(
            config,
            relativePath: "mods.d/custom.conf",
            moduleRoot: moduleRoot
        )
        try writeAndroidModuleBackupFixtureFile(
            Data("dictionary index".utf8),
            relativePath: "mybible/owned/stem.idx",
            moduleRoot: moduleRoot
        )
        let sqliteData = try Data(
            contentsOf: sqliteDocumentReaderFixtureURL("mybible-bible.SQLite3")
        )
        try writeAndroidModuleBackupFixtureFile(
            sqliteData,
            relativePath: "mybible/owned/book.SQLite3",
            moduleRoot: moduleRoot
        )
        let service = AndroidModuleBackupService(moduleDirectory: moduleRoot)

        let export = try service.exportArchiveFile()
        defer { try? FileManager.default.removeItem(at: export.fileURL) }
        let entries = try ZipArchiveReader.entries(in: Data(contentsOf: export.fileURL))
        let dataByPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.data) })

        XCTAssertEqual(export.moduleNames, ["CUSTOM"])
        XCTAssertEqual(entries.first?.name, "AndBibleBackupManifest.json")
        XCTAssertEqual(
            Set(entries.dropFirst().map(\.name)),
            [
                "mods.d/custom.conf",
                "mybible/owned/book.SQLite3",
                "mybible/owned/stem.idx",
            ]
        )
        XCTAssertEqual(dataByPath["mods.d/custom.conf"], config)
        XCTAssertEqual(dataByPath["mybible/owned/book.SQLite3"], sqliteData)
        XCTAssertEqual(dataByPath["mybible/owned/stem.idx"], Data("dictionary index".utf8))

        let inspection = try service.inspectArchive(fromArchiveAt: export.fileURL)
        XCTAssertEqual(inspection.supportedModuleNames, ["CUSTOM"])
        XCTAssertEqual(inspection.supportedEntryCount, 3)
    }

    /**
     Verifies a raw Android EPUB tree is authoritative over a native generation with the same identity.

     Both sources use the display name `Shared Book.epub` but embed different bytes. Selection must
     emit the module-root tree once and omit the native package rather than producing duplicate ZIP
     destinations. Failure loses Android optimization artifacts or makes output depend on duplicate
     source ordering.
     */
    func testAndroidModuleBackupPrefersAuthoritativeRawEpubExportTree() throws {
        let moduleRoot = try makeTemporaryAndroidModuleBackupRoot()
        let epubLibraryRoot = moduleRoot.appendingPathComponent("_epub-library", isDirectory: true)
        let rawTree = moduleRoot.appendingPathComponent(
            "epub/Shared Book.epub",
            isDirectory: true
        )
        let nativeSource = moduleRoot.appendingPathComponent(
            "_native-source/Shared Book.epub",
            isDirectory: true
        )
        try EpubAndroidModuleBackupTestFixture.writeRawTree(at: nativeSource, label: "Native")
        _ = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: nativeSource,
            libraryRootURL: epubLibraryRoot
        )
        try EpubAndroidModuleBackupTestFixture.writeOptimizedTree(
            at: rawTree,
            label: "Authoritative"
        )
        let expectedEntries = try archiveEntries(
            beneath: rawTree,
            archiveRootPath: "epub/Shared Book.epub"
        )
        let service = AndroidModuleBackupService(
            moduleDirectory: moduleRoot,
            epubLibraryRootURL: epubLibraryRoot
        )

        let export = try service.exportArchiveFile(moduleNames: ["Epub-Shared_Book_epub"])
        defer { try? FileManager.default.removeItem(at: export.fileURL) }
        let entries = try ZipArchiveReader.entries(in: Data(contentsOf: export.fileURL))
        let exportedData = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.data) })

        XCTAssertEqual(export.moduleNames, ["Epub-Shared_Book_epub"])
        XCTAssertEqual(entries.first?.name, "AndBibleBackupManifest.json")
        XCTAssertEqual(Set(entries.dropFirst().map(\.name)), Set(expectedEntries.map(\.0)))
        for (path, data) in expectedEntries {
            XCTAssertEqual(exportedData[path], data, path)
        }
    }

    /**
     Verifies export rejects unsafe installed state without leaving destination artifacts.

     Separate fixtures provide a selected symbolic-link SWORD payload, an unrelated symbolic-link
     configuration root beside a valid raw database, and a selected config with no owned payload.
     Selected unsafe state must fail without an archive, while malformed unselected registration
     state cannot abort the valid database export. Every completed or failed path is cleaned up.
     */
    func testAndroidModuleBackupExportValidationLeavesNoPartialArchive() throws {
        let fileManager = FileManager.default

        let symlinkRoot = try makeTemporaryAndroidModuleBackupRoot()
        let symlinkTemporary = symlinkRoot.appendingPathComponent("_export-temp", isDirectory: true)
        let symlinkLibrary = symlinkRoot.appendingPathComponent("_epub-library", isDirectory: true)
        let symlinkTarget = symlinkRoot.appendingPathComponent("_outside-sword", isDirectory: true)
        let symlinkURL = symlinkRoot.appendingPathComponent(
            "modules/texts/rawtext/kjv",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: symlinkTarget,
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: symlinkTarget.appendingPathComponent("ot"))
        try fileManager.createDirectory(at: symlinkTemporary, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: symlinkURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: symlinkTarget)
        try makeAndroidModuleBackupConf(moduleName: "KJV").write(
            to: symlinkRoot.appendingPathComponent("mods.d/kjv.conf")
        )
        let symlinkService = AndroidModuleBackupService(
            moduleDirectory: symlinkRoot,
            temporaryDirectory: symlinkTemporary,
            epubLibraryRootURL: symlinkLibrary
        )

        XCTAssertThrowsError(
            try symlinkService.exportArchiveFile(moduleNames: ["KJV"])
        ) { error in
            guard case AndroidModuleBackupError.invalidModuleLayout = error else {
                return XCTFail("Expected symbolic-link layout rejection, got \(error)")
            }
        }
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: symlinkTemporary.path), [])

        let configSymlinkRoot = try makeTemporaryAndroidModuleBackupRoot()
        let configSymlinkTemporary = configSymlinkRoot.appendingPathComponent(
            "_export-temp",
            isDirectory: true
        )
        let configTarget = configSymlinkRoot.appendingPathComponent(
            "_linked-configs",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: configSymlinkTemporary,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: configTarget, withIntermediateDirectories: true)
        try makeAndroidModuleBackupConf(moduleName: "KJV").write(
            to: configTarget.appendingPathComponent("kjv.conf")
        )
        let configRoot = configSymlinkRoot.appendingPathComponent("mods.d", isDirectory: true)
        try fileManager.removeItem(at: configRoot)
        try fileManager.createSymbolicLink(at: configRoot, withDestinationURL: configTarget)
        try writeAndroidModuleBackupFixtureFile(
            Data(contentsOf: sqliteDocumentReaderFixtureURL("mybible-bible.SQLite3")),
            relativePath: "mybible/Book.SQLite3",
            moduleRoot: configSymlinkRoot
        )
        let configSymlinkService = AndroidModuleBackupService(
            moduleDirectory: configSymlinkRoot,
            temporaryDirectory: configSymlinkTemporary,
            epubLibraryRootURL: configSymlinkRoot.appendingPathComponent("_epub-library")
        )

        let configSymlinkExport = try configSymlinkService.exportArchiveFile(
            moduleNames: ["MyBible-Book"]
        )
        XCTAssertEqual(configSymlinkExport.moduleNames, ["MyBible-Book"])
        try fileManager.removeItem(at: configSymlinkExport.fileURL)
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: configSymlinkTemporary.path),
            []
        )

        let missingRoot = try makeTemporaryAndroidModuleBackupRoot()
        let missingTemporary = missingRoot.appendingPathComponent("_export-temp", isDirectory: true)
        try fileManager.createDirectory(at: missingTemporary, withIntermediateDirectories: true)
        try makeAndroidModuleBackupConf(moduleName: "KJV").write(
            to: missingRoot.appendingPathComponent("mods.d/kjv.conf")
        )
        let missingService = AndroidModuleBackupService(
            moduleDirectory: missingRoot,
            temporaryDirectory: missingTemporary,
            epubLibraryRootURL: missingRoot.appendingPathComponent("_epub-library")
        )

        XCTAssertThrowsError(try missingService.exportArchiveFile(moduleNames: ["KJV"])) { error in
            XCTAssertEqual(
                error as? AndroidModuleBackupError,
                .missingExportData(
                    moduleName: "KJV",
                    dataPath: "modules/texts/rawtext/kjv"
                )
            )
        }
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: missingTemporary.path), [])

    }

    /**
     Verifies duplicate non-ASCII background names receive Android's deterministic suffix.

     Two nested resources share the same visible filename and carry the durable registrations
     created when Android restore allocated `BGIMG_image` and `_2`. Export must preserve picker
     selection order and restore both bytes to their exact nested destinations. Failure means
     registration-backed nested inventory drops one resource or renames a path.
     */
    func testAndroidModuleBackupAllocatesBackgroundSuffixForNestedNonASCIINameCollision() throws {
        let sourceRoot = try makeTemporaryAndroidModuleBackupRoot()
        let firstName = "BGIMG_image"
        let secondName = "BGIMG_image_2"
        try writeAndroidModuleBackupFixtureFile(
            Data("first".utf8),
            relativePath: "background/first/夜空.png",
            moduleRoot: sourceRoot
        )
        try writeAndroidModuleBackupFixtureFile(
            Data("second".utf8),
            relativePath: "background/second/夜空.png",
            moduleRoot: sourceRoot
        )
        try writeAndroidModuleBackupFixtureFile(
            Data(
                """
                [BGIMG_image]
                Description=夜空
                Category=And Bible
                ModDrv=RawGenBook
                DataPath=./background/first/
                AndBibleIOSGeneratedRegistration=true
                AndBibleIOSRegistrationFamily=background
                AndBibleIOSRegistrationPath=background/first/夜空.png
                AndBibleProvidesBackgroundImage=夜空;夜空.png

                """.utf8
            ),
            relativePath: "mods.d/background_first.conf",
            moduleRoot: sourceRoot
        )
        try writeAndroidModuleBackupFixtureFile(
            Data(
                """
                [BGIMG_image_2]
                Description=夜空
                Category=And Bible
                ModDrv=RawGenBook
                DataPath=./background/second/
                AndBibleIOSGeneratedRegistration=true
                AndBibleIOSRegistrationFamily=background
                AndBibleIOSRegistrationPath=background/second/夜空.png
                AndBibleProvidesBackgroundImage=夜空;夜空.png

                """.utf8
            ),
            relativePath: "mods.d/background_second.conf",
            moduleRoot: sourceRoot
        )
        let service = AndroidModuleBackupService(
            moduleDirectory: sourceRoot,
            epubLibraryRootURL: sourceRoot.appendingPathComponent("_epub-library")
        )

        let catalog = try service.installedContentCatalog()
        XCTAssertEqual(catalog.map(\.initials), [firstName, secondName])
        let export = try service.exportArchiveFile(
            orderedModuleNames: [secondName, firstName]
        )
        defer { try? FileManager.default.removeItem(at: export.fileURL) }
        XCTAssertEqual(export.moduleNames, [secondName, firstName])

        let restoredRoot = try makeTemporaryAndroidModuleBackupRoot()
        let report = try AndroidModuleBackupService(
            moduleDirectory: restoredRoot,
            epubLibraryRootURL: restoredRoot.appendingPathComponent("_epub-library")
        ).restoreArchive(fromArchiveAt: export.fileURL)
        XCTAssertEqual(report.installedModuleNames, [firstName, secondName])
        XCTAssertEqual(
            try Data(contentsOf: restoredRoot.appendingPathComponent("background/first/夜空.png")),
            Data("first".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: restoredRoot.appendingPathComponent("background/second/夜空.png")),
            Data("second".utf8)
        )
    }

    /**
     Creates a temporary SWORD module root for Android module-backup tests.

     - Returns: Empty module root URL with `mods.d/` present.
     - Side effects: Creates a temporary directory and registers it for teardown cleanup.
     - Failure modes: Rethrows file-system directory creation failures.
     */
    private func makeTemporaryAndroidModuleBackupRoot() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let root = packageRoot
            .appendingPathComponent(".build/android-module-backup-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("mods.d", isDirectory: true),
            withIntermediateDirectories: true
        )
        temporaryFilePaths.append(root.path)
        return root
    }

    /**
     Builds an Android-shaped module backup ZIP fixture.

     - Parameters:
       - manifestBackupType: Manifest `backupType` value to emit.
       - entries: Additional archive entries after the manifest.
     - Returns: Stored ZIP data readable by production archive services.
     - Side effects: none.
     - Failure modes: Rethrows `ZipArchiveWriter` size failures.
     */
    private func makeAndroidModuleBackupArchiveData(
        manifestBackupType: String = "MODULE_BACKUP",
        entries: [(String, Data)]
    ) throws -> Data {
        let manifest = Data(#"{"backupType":"\#(manifestBackupType)","manifestVersion":1}"#.utf8)
        let zipEntries = [ZipArchiveWriterEntry(name: "AndBibleBackupManifest.json", data: manifest)]
            + entries.map { ZipArchiveWriterEntry(name: $0.0, data: $0.1) }
        return try ZipArchiveWriter.storedArchive(entries: zipEntries)
    }

    /** Returns one checked-in real SQLite document fixture URL. */
    private func sqliteDocumentReaderFixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("SQLiteDocumentReaders", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    /**
     Reads every regular file under a fixture directory into deterministic archive paths.

     - Parameters:
       - directoryURL: Root whose descendants supply payload bytes.
       - archiveRootPath: Forward-slash destination prefix for the root.
     - Returns: Lexically ordered archive path/data pairs, excluding directory entries.
     - Side effects: Enumerates and reads fixture files without modifying them.
     - Throws: Enumeration, metadata, or file-read failures.
     */
    private func archiveEntries(
        beneath directoryURL: URL,
        archiveRootPath: String
    ) throws -> [(String, Data)] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw AndroidModuleBackupTestFixtureError.unreadableFixtureDirectory
        }
        let rootComponentCount = directoryURL.standardizedFileURL.pathComponents.count
        var entries: [(String, Data)] = []
        for case let fileURL as URL in enumerator {
            guard try fileURL.resourceValues(forKeys: Set(keys)).isRegularFile == true else {
                continue
            }
            let components = fileURL.standardizedFileURL.pathComponents.dropFirst(rootComponentCount)
            let relativePath = components.joined(separator: "/")
            entries.append((
                "\(archiveRootPath)/\(relativePath)",
                try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            ))
        }
        return entries.sorted { $0.0 < $1.0 }
    }

    /**
     Writes one complete mixed-family installed fixture and records exact expected archive ownership.

     - Parameters:
       - moduleRoot: Empty module root that receives SWORD and Android-native family files.
       - epubLibraryRoot: Isolated native EPUB library populated with one immutable generation.
     - Returns: Exact bytes and per-identity path ownership expected from production export.
     - Side effects: Writes module files and installs one native EPUB generation below caller-owned
       test directories.
     - Throws: Fixture read/write, SQLite copy, EPUB install, or generation acquisition failures.
     */
    private func writeAndroidModuleBackupExportFixture(
        moduleRoot: URL,
        epubLibraryRoot: URL
    ) throws -> AndroidModuleBackupExportFixture {
        var fileDataByArchivePath: [String: Data] = [:]
        var archivePathsByModuleName: [String: Set<String>] = [:]
        let includeFile: (String, String, Data) throws -> Void = { moduleName, path, data in
            try self.writeAndroidModuleBackupFixtureFile(
                data,
                relativePath: path,
                moduleRoot: moduleRoot
            )
            fileDataByArchivePath[path] = data
            archivePathsByModuleName[moduleName, default: []].insert(path)
        }
        let includeExistingEntries: (String, [(String, Data)]) -> Void = { moduleName, entries in
            for (path, data) in entries {
                fileDataByArchivePath[path] = data
                archivePathsByModuleName[moduleName, default: []].insert(path)
            }
        }

        let swordConfig = makeAndroidModuleBackupConf(moduleName: "KJV")
        try includeFile("KJV", "mods.d/kjv.conf", swordConfig)
        try includeFile("KJV", "modules/texts/rawtext/kjv/ot", Data("SWORD bytes".utf8))

        try includeFile(
            "MyBible-My_Bible",
            "mybible/nested/My Bible.SQLite3",
            Data(contentsOf: sqliteDocumentReaderFixtureURL("mybible-bible.SQLite3"))
        )
        try includeFile(
            "MySword-Sample_bbl",
            "mysword/deep/Sample.bbl.mybible",
            Data(contentsOf: sqliteDocumentReaderFixtureURL("sample.bbl.mybible"))
        )
        try includeFile(
            "ESword-Sample_Name_",
            "esword/Sample[Name].bbli",
            Data(contentsOf: sqliteDocumentReaderFixtureURL("sample.bbli"))
        )
        try includeFile(
            "TTF_Reader Font",
            "ttf/locale/Reader Font.ttf",
            Data([0x00, 0x01, 0x00, 0x00, 0x54, 0x54, 0x46])
        )
        try writeAndroidModuleBackupFixtureFile(
            Data(
                """
                [TTF_Reader Font]
                Description=Reader Font
                Category=And Bible
                ModDrv=RawGenBook
                DataPath=./ttf/locale/
                AndBibleIOSGeneratedRegistration=true
                AndBibleIOSRegistrationFamily=ttf
                AndBibleIOSRegistrationPath=ttf/locale/Reader Font.ttf
                AndBibleProvidesFont=Reader Font;Reader Font.ttf

                """.utf8
            ),
            relativePath: "mods.d/font_reader.conf",
            moduleRoot: moduleRoot
        )
        try includeFile(
            "BGIMG_Blue_Sky",
            "background/themes/Blue Sky.WEBP",
            Data("background-image-bytes".utf8)
        )
        try writeAndroidModuleBackupFixtureFile(
            Data(
                """
                [BGIMG_Blue_Sky]
                Description=Blue Sky
                Category=And Bible
                ModDrv=RawGenBook
                DataPath=./background/themes/
                AndBibleIOSGeneratedRegistration=true
                AndBibleIOSRegistrationFamily=background
                AndBibleIOSRegistrationPath=background/themes/Blue Sky.WEBP
                AndBibleProvidesBackgroundImage=Blue Sky;Blue Sky.WEBP

                """.utf8
            ),
            relativePath: "mods.d/background_blue_sky.conf",
            moduleRoot: moduleRoot
        )
        try writeAndroidModuleBackupFixtureFile(
            Data("name;promptTemplate\nStudy;Read closely".utf8),
            relativePath: "prompts/Study Pack.csv",
            moduleRoot: moduleRoot
        )

        let rawTree = moduleRoot.appendingPathComponent("epub/Raw Book.epub", isDirectory: true)
        try EpubAndroidModuleBackupTestFixture.writeRawTree(at: rawTree, label: "Raw")
        _ = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: rawTree,
            libraryRootURL: epubLibraryRoot
        )
        includeExistingEntries(
            "Epub-Raw_Book_epub",
            try archiveEntries(beneath: rawTree, archiveRootPath: "epub/Raw Book.epub")
        )

        let nativeSource = moduleRoot.appendingPathComponent(
            "_native-source/Native Book.epub",
            isDirectory: true
        )
        try EpubAndroidModuleBackupTestFixture.writeRawTree(at: nativeSource, label: "Native")
        let nativeIdentifier = try EpubReader.installAndroidModuleBackup(
            epubDirectoryURL: nativeSource,
            libraryRootURL: epubLibraryRoot
        )
        guard let nativeGeneration = EpubReader.acquireCurrentGeneration(
            identifier: nativeIdentifier,
            libraryRootURL: epubLibraryRoot
        ) else {
            throw AndroidModuleBackupTestFixtureError.missingEpubGeneration
        }
        defer {
            EpubReader.releaseGeneration(nativeGeneration, libraryRootURL: epubLibraryRoot)
        }
        includeExistingEntries(
            "Epub-Native_Book_epub",
            try archiveEntries(
                beneath: nativeGeneration.packageRootURL,
                archiveRootPath: "epub/Native Book.epub"
            )
        )

        let excludedArchivePaths: Set<String> = [
            "esword/nested/Hidden.bblx",
            "mods.d/background_blue_sky.conf",
            "mods.d/font_reader.conf",
            "prompts/Study Pack.csv",
            "prompts/nested/Hidden.csv",
        ]
        try writeAndroidModuleBackupFixtureFile(
            Data("nested e-Sword file".utf8),
            relativePath: "esword/nested/Hidden.bblx",
            moduleRoot: moduleRoot
        )
        try writeAndroidModuleBackupFixtureFile(
            Data("nested prompt".utf8),
            relativePath: "prompts/nested/Hidden.csv",
            moduleRoot: moduleRoot
        )

        return AndroidModuleBackupExportFixture(
            fileDataByArchivePath: fileDataByArchivePath,
            archivePathsByModuleName: archivePathsByModuleName,
            orderedModuleNames: [
                "KJV",
                "MyBible-My_Bible",
                "MySword-Sample_bbl",
                "ESword-Sample_Name_",
                "Epub-Native_Book_epub",
                "Epub-Raw_Book_epub",
                "TTF_Reader Font",
                "BGIMG_Blue_Sky",
            ],
            excludedArchivePaths: excludedArchivePaths
        )
    }

    /**
     Writes one fixture payload at an archive-shaped location below the module root.

     - Parameters:
       - data: Exact bytes to persist.
       - relativePath: Forward-slash module-root-relative file path.
       - moduleRoot: Caller-owned fixture root.
     - Side effects: Creates parent directories and writes or replaces the destination file.
     - Throws: File-system directory or write failures.
     */
    private func writeAndroidModuleBackupFixtureFile(
        _ data: Data,
        relativePath: String,
        moduleRoot: URL
    ) throws {
        let destination = moduleRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
    }

    /**
     Writes an Android module backup fixture to a temporary file.

     - Parameter archiveData: ZIP bytes to persist.
     - Returns: Temporary `.abmd.zip` URL registered for teardown cleanup.
     - Side effects: Writes `archiveData` under the process temporary directory.
     - Failure modes: Rethrows file write errors.
     */
    private func writeTemporaryAndroidModuleBackupArchive(_ archiveData: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-module-backup-\(UUID().uuidString).abmd.zip")
        try archiveData.write(to: url)
        temporaryFilePaths.append(url.path)
        return url
    }

    /**
     Builds a minimal SWORD config for module backup restore/export tests.

     - Parameters:
       - moduleName: Module initials to place in the config section.
       - dataPath: Optional raw path override used by security fixtures.
     - Returns: UTF-8 SWORD config bytes with `RawText` data under `modules/texts/rawtext`.
     - Side effects: none.
     - Failure modes: none.
     */
    private func makeAndroidModuleBackupConf(
        moduleName: String,
        dataPath: String? = nil
    ) -> Data {
        let resolvedDataPath = dataPath
            ?? "./modules/texts/rawtext/\(moduleName.lowercased())/"
        return Data(
            """
            [\(moduleName)]
            DataPath=\(resolvedDataPath)
            ModDrv=RawText
            Description=\(moduleName)

            """.utf8
        )
    }

    /**
     Builds a RawLD4 SWORD config matching Android production module-backup dictionaries.

     - Returns: UTF-8 config bytes whose `DataPath` points to a RawLD4 file stem.
     - Side effects: none.
     - Failure modes: none.
     */
    private func makeAndroidRawLD4ModuleBackupConf() -> Data {
        Data(
            """
            [ACDCref]
            DataPath=./modules/lexdict/rawld4/acdcref/acdcref
            ModDrv=RawLD4
            Description=ACDCREF

            """.utf8
        )
    }

    /**
     Writes a minimal installed SWORD module fixture under a temporary module root.

     - Parameters:
       - moduleRoot: Temporary SWORD root.
       - moduleName: Module initials for the config filename and section.
       - data: Module data payload to write.
     - Side effects: Creates config and data files under `moduleRoot`.
     - Failure modes: Rethrows file-system write failures.
     */
    private func writeAndroidModuleBackupInstalledModule(
        moduleRoot: URL,
        moduleName: String,
        data: Data
    ) throws {
        let confURL = moduleRoot
            .appendingPathComponent("mods.d", isDirectory: true)
            .appendingPathComponent("\(moduleName.lowercased()).conf")
        try makeAndroidModuleBackupConf(moduleName: moduleName).write(to: confURL)

        let dataURL = moduleRoot
            .appendingPathComponent("modules/texts/rawtext/\(moduleName.lowercased())", isDirectory: true)
            .appendingPathComponent("ot")
        try FileManager.default.createDirectory(
            at: dataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: dataURL)
    }

    /**
     Reads a little-endian UInt16 from a ZIP fixture at an exact byte offset.

     - Parameters:
       - data: ZIP fixture bytes.
       - offset: Zero-based byte offset of the two-byte integer.
     - Returns: Decoded UInt16 value.
     - Side effects: none.
     - Failure modes: Throws a test-fixture error if the offset is outside the fixture.
     */
    private func readZipUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
        let bytes = [UInt8](data)
        guard offset >= 0, offset + 1 < bytes.count else {
            throw AndroidModuleBackupTestFixtureError.invalidZipOffset
        }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    /**
     Reads a little-endian UInt32 from a ZIP fixture at an exact byte offset.

     - Parameters:
       - data: ZIP fixture bytes.
       - offset: Zero-based byte offset of the four-byte integer.
     - Returns: Decoded UInt32 value.
     - Side effects: none.
     - Failure modes: Throws a test-fixture error if the offset is outside the fixture.
     */
    private func readZipUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        let bytes = [UInt8](data)
        guard offset >= 0, offset + 3 < bytes.count else {
            throw AndroidModuleBackupTestFixtureError.invalidZipOffset
        }
        return UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    /** Exact expected export inventory for one mixed-family installed fixture. */
    private struct AndroidModuleBackupExportFixture {
        /// Source bytes keyed by their exact Android archive destination.
        let fileDataByArchivePath: [String: Data]

        /// Exact archive destinations owned by each Android-compatible identity.
        let archivePathsByModuleName: [String: Set<String>]

        /// Android registrar order shared by the catalog, picker, manifest payloads, and exporter.
        let orderedModuleNames: [String]

        /// Valid nested files ignored by Android readers that discover only direct children.
        let excludedArchivePaths: Set<String>
    }

    /**
     Reports malformed local ZIP fixtures as XCTest failures instead of runtime traps.
     */
    private enum AndroidModuleBackupTestFixtureError: Error {
        /// The fixture root could not be enumerated.
        case unreadableFixtureDirectory

        /// A native EPUB fixture was installed without an acquirable current generation.
        case missingEpubGeneration

        /// A test attempted to read outside a generated ZIP buffer.
        case invalidZipOffset
    }
}

/** Sendable test ownership wrapper for an immutable backup service instance. */
private final class AndroidModuleBackupServiceSendableBox: @unchecked Sendable {
    let value: AndroidModuleBackupService

    /// Retains one service for a detached transaction task.
    init(_ value: AndroidModuleBackupService) {
        self.value = value
    }
}

/**
 Deterministic cross-writer barrier driven by the shared coordinator's typed transaction events.
 */
private final class AndroidModuleBackupTransactionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let firstBoundarySemaphore = DispatchSemaphore(value: 0)
    private let secondWaitingSemaphore = DispatchSemaphore(value: 0)
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private var events: [ModuleStoreMutationEvent] = []
    private var firstTransactionID: UUID?
    private var secondTransactionID: UUID?

    /** Records events and blocks the first writer at the exact non-cancellable boundary. */
    func observe(_ event: ModuleStoreMutationEvent) {
        var shouldBlock = false
        lock.lock()
        events.append(event)
        if event.stage == .willMutate, firstTransactionID == nil {
            firstTransactionID = event.transactionID
            shouldBlock = true
            firstBoundarySemaphore.signal()
        } else if event.stage == .waiting,
                  let firstTransactionID,
                  event.transactionID != firstTransactionID,
                  secondTransactionID == nil {
            secondTransactionID = event.transactionID
            secondWaitingSemaphore.signal()
        }
        lock.unlock()
        if shouldBlock {
            releaseSemaphore.wait()
        }
    }

    /** Waits for Android restore to reach the first live-tree boundary. */
    func waitForFirstMutationBoundary() throws {
        try wait(firstBoundarySemaphore, checkpoint: "Android mutation boundary")
    }

    /** Waits for the remote writer to queue behind Android restore. */
    func waitForSecondWriterToQueue() throws {
        try wait(secondWaitingSemaphore, checkpoint: "remote writer queue")
    }

    /** Releases the Android writer while it still owns the canonical-root lease. */
    func releaseFirstWriter() {
        releaseSemaphore.signal()
    }

    /** Proves the first commit event precedes the second writer's mutation event. */
    func assertFirstCommitPrecedesSecondMutation() throws {
        lock.lock()
        let snapshot = events
        let firstID = firstTransactionID
        let secondID = secondTransactionID
        lock.unlock()
        let resolvedFirstID = try XCTUnwrap(firstID)
        let resolvedSecondID = try XCTUnwrap(secondID)
        let firstCommit = try XCTUnwrap(snapshot.firstIndex {
            $0.transactionID == resolvedFirstID && $0.stage == .committed
        })
        let secondMutation = try XCTUnwrap(snapshot.firstIndex {
            $0.transactionID == resolvedSecondID && $0.stage == .willMutate
        })
        XCTAssertLessThan(firstCommit, secondMutation)
    }

    /** Uses time only as deadlock protection around event-driven synchronization. */
    private func wait(_ semaphore: DispatchSemaphore, checkpoint: String) throws {
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw AndroidModuleBackupBarrierError.missingCheckpoint(checkpoint)
        }
    }
}

/** Missing typed coordinator events indicate a broken transaction contract. */
private enum AndroidModuleBackupBarrierError: Error {
    case missingCheckpoint(String)
}
