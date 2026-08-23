import XCTest
import CLibSword
@testable import BibleCore
@testable import SwordKit
import SwiftData
import SQLite3

/// SQLite destructor sentinel used by package fixture writers to make SQLite copy bound bytes/text.
private let androidDatabaseBackupTestSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Package-level Android database backup restore, import, export, and validation tests.

 These tests protect Android `.abdb.zip` behavior through BibleCore services without launching the
 app-host test bundle. Presentation-only backup copy belongs in `BibleUITests`; this suite owns the
 archive formats, SQLite schemas, category apply semantics, version gates, and cleanup contracts.
 */
final class AndroidDatabaseBackupTests: XCTestCase {
    private var temporaryPaths: [String] = []

    /**
     Removes temporary Android backup archives and repository fixtures created by each test.

     The app-host test suite previously shared cleanup state through `AndBibleTests`; after moving
     this behavior into the package target, the migrated suite owns its file cleanup explicitly so
     package execution remains isolated and repeatable.

     - Side effects: Deletes paths recorded in `temporaryPaths` and clears the list after each test.
     - Failure modes: Individual cleanup failures are ignored because failed deletion should not mask
       the test assertion that already completed.
     */
    override func tearDown() {
        for path in temporaryPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
        temporaryPaths.removeAll()
        super.tearDown()
    }

    /**
     Verifies the iOS JSword KJVA compatibility contract used by Android backup progress rows.

     Setup:
     - reads the local `JSwordKJVAVersification` constants derived from JSword's `SystemKJVA`
       and `Versification.maximumOrdinal()` implementation

     Expected result:
     - the contract names Android's `KJVA` versification
     - the ordinal domain includes JSword introduction addresses and ends at `maximumOrdinal()`
     - zero and values past JSword's final ordinal are rejected

     Failure meaning:
     - iOS would validate Android progress ordinals against an implicit or SWORD-only range instead
       of the same JSword KJVA address space Android writes into `progress.sqlite3`.
     */
    func testJSwordKJVAVersificationExposesAndroidProgressOrdinalDomain() {
        XCTAssertEqual(JSwordKJVAVersification.name, "KJVA")
        XCTAssertEqual(JSwordKJVAVersification.bookCount, 83)
        XCTAssertEqual(JSwordKJVAVersification.canonicalBookCount, 80)
        XCTAssertEqual(JSwordKJVAVersification.chapterCount, 1_371)
        XCTAssertEqual(JSwordKJVAVersification.verseCount, 36_819)
        XCTAssertEqual(JSwordKJVAVersification.maximumOrdinal, 38_272)
        XCTAssertEqual(JSwordKJVAVersification.ordinalRange, 0...38_272)
        XCTAssertEqual(JSwordKJVAVersification.progressOrdinalRange, 1...38_272)
        XCTAssertTrue(JSwordKJVAVersification.containsOrdinal(0))
        XCTAssertFalse(JSwordKJVAVersification.containsProgressOrdinal(0))
        XCTAssertTrue(JSwordKJVAVersification.containsProgressOrdinal(1))
        XCTAssertTrue(JSwordKJVAVersification.containsProgressOrdinal(38_272))
        XCTAssertFalse(JSwordKJVAVersification.containsProgressOrdinal(38_273))
    }

    /**
     Verifies KJVA verse ordinal lookup uses cached JSword-derived offsets.

     The passage chooser progress bars resolve KJVA ranges for many visible cells. The values must
     still match Android/JSword exactly, but lookup should not repeatedly walk the full KJVA table
     while SwiftUI renders book, chapter, and verse grids.
    */
    func testJSwordKJVAVersificationUsesPrecomputedOrdinalIndexForProgressRendering() throws {
        let relativePath = "Sources/BibleCore/Sources/BibleCore/Services/JSwordKJVAVersification.swift"
        let sourceURL = try repositoryRoot(containing: relativePath).appendingPathComponent(relativePath)
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let ordinalFunctionStart = try XCTUnwrap(source.range(of: "public static func verseOrdinal("))
        let ordinalFunctionEnd = try XCTUnwrap(
            source.range(of: "\n    public static func ", range: ordinalFunctionStart.upperBound..<source.endIndex)
        )
        let ordinalFunctionSource = source[ordinalFunctionStart.lowerBound..<ordinalFunctionEnd.lowerBound]

        XCTAssertTrue(source.contains("private static let ordinalIndexByBookIndex"))
        XCTAssertFalse(ordinalFunctionSource.contains("JSwordKJVAVersificationData.bookTable.enumerated()"))
        XCTAssertEqual(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1), 4)
        XCTAssertEqual(JSwordKJVAVersification.verseOrdinal(osisId: "Rev", chapter: 22, verse: 21), 38_272)
    }

    /**
     Verifies chapter superscription (verse 0) ordinals match JSword's reserved intro slot.

     JSword addresses a chapter superscription as verse 0 with the ordinal immediately before
     verse 1 (`chapterStart - 1`), and divergent canons map Psalm-title verses onto it (e.g. Synodal
     Ps 50:1 -> KJVA Ps 51:0). `chapterIntroOrdinal` must return that reserved slot so cross-canon
     bookmark storage matches Android's `Versification.getOrdinal`. A failure means superscription
     bookmarks would land on the wrong ordinal (or fall back to a raw source ordinal).
     */
    func testJSwordKJVAVersificationChapterIntroOrdinalMatchesReservedSlot() throws {
        let genesisOneVerseOne = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1))
        XCTAssertEqual(JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Gen", chapter: 1), genesisOneVerseOne - 1)

        let psalm51VerseOne = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Ps", chapter: 51, verse: 1))
        let psalm51Intro = try XCTUnwrap(JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 51))
        XCTAssertEqual(psalm51Intro, psalm51VerseOne - 1)
        XCTAssertGreaterThan(psalm51Intro, 0, "A chapter superscription is a real positive ordinal, not the Bible-intro sentinel 0.")

        XCTAssertNil(JSwordKJVAVersification.chapterIntroOrdinal(osisId: "NotABook", chapter: 1))
        XCTAssertNil(JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 0))
    }

    /**
     Verifies that iOS reads Android `.abdb.zip` archives by database file discovery and exposes
     both restorable and unsupported database sections.

     Setup:
     - builds a stored ZIP with Android's `AndBibleBackupManifest.json`
     - includes supported `bookmarks.sqlite3` and restore-only `settings.sqlite3`, plus manifest-only
       `MODULES` category

     Expected result:
     - the bookmark section is selectable for restore/import
     - the settings section remains visible and restorable because Android includes it in DB backup
     - manifest-only non-database categories do not appear in the DB restore section list

     Failure meaning:
     - iOS would either hide valid Android backup contents or offer a section it cannot safely map.
     */
    func testAndroidDatabaseBackupLoadExposesSupportedAndUnsupportedSections() throws {
        let bookmarkDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: UUID(uuidString: "15000000-0000-0000-0000-000000000001")!, name: "Prayer", colour: 7),
            ]
        )
        try setSQLiteUserVersion(12, at: bookmarkDatabaseURL)
        let settingsDatabaseURL = try makeEmptySQLiteDatabase(userVersion: 1)
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "bookmarks.sqlite3": bookmarkDatabaseURL,
                "settings.sqlite3": settingsDatabaseURL,
            ],
            contains: [.bookmarks, .settings, .modules]
        )

        let archive = try AndroidDatabaseBackupService().loadArchive(from: archiveData)

        XCTAssertEqual(archive.manifest?.backupType, "DB_BACKUP")
        XCTAssertEqual(archive.manifest?.manifestVersion, 1)
        XCTAssertEqual(archive.manifest?.contains, [.bookmarks, .settings, .modules])
        XCTAssertEqual(archive.sections.map(\.category), [.bookmarks, .settings])
        XCTAssertEqual(archive.sections.first { $0.category == .bookmarks }?.support, .supported)
        XCTAssertEqual(archive.sections.first { $0.category == .settings }?.support, .supported)
    }

    /**
     Verifies Android database backup restore can stage archives from a file URL.

     Setup:
     - builds a valid Android `.abdb.zip` fixture on disk
     - loads the archive through the file-backed service API instead of `Data(contentsOf:)`

     Expected result:
     - the same bookmark section is discovered from the file URL
     - the staged SQLite URL points at a temporary extracted file

     Failure meaning:
     - production restore would still rely on eager whole-file memory loading and fail on large
       Android backups that Android itself can restore from storage.
     */
    func testAndroidDatabaseBackupLoadsArchiveFromFileURL() throws {
        let bookmarkDatabaseURL = try makeAndroidBookmarksDatabase(labels: [])
        try setSQLiteUserVersion(12, at: bookmarkDatabaseURL)
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "bookmarks.sqlite3": bookmarkDatabaseURL,
            ],
            contains: [.bookmarks]
        )
        let archiveURL = try writeTemporaryAndroidBackupArchive(
            archiveData,
            suffix: AndroidDatabaseBackupService.databaseBackupSuffix
        )

        let archive = try AndroidDatabaseBackupService().loadArchive(fromArchiveAt: archiveURL)

        XCTAssertEqual(archive.sections.map(\.category), [.bookmarks])
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.sections[0].databaseFileURL.path))
    }

    /**
     Verifies Android-parity section discovery when a database backup has no manifest.

     Setup:
     - builds a manifestless stored ZIP containing valid Android database filenames in a shuffled
       central-directory order
     - includes supported iOS-mapped databases and Android's restore-only Settings database

     Expected result:
     - iOS infers a DB backup from valid SQLite entries under `db/`
     - sections are returned in Android `ALL_DB_FILENAMES` order, not ZIP order or localized label
       order
     - discovered sections are marked as found in the archive rather than declared by a manifest

     Failure meaning:
     - iOS would reject pre-manifest Android DB backups or present section ordering that differs
       from Android's restore dialog.
     */
    func testAndroidDatabaseBackupLoadsManifestlessArchiveFromDatabaseEntriesInAndroidOrder() throws {
        let bookmarkDatabaseURL = try makeAndroidBookmarksDatabase(labels: [])
        try setSQLiteUserVersion(12, at: bookmarkDatabaseURL)
        let readingPlanDatabaseURL = try makeEmptySQLiteDatabase(userVersion: 1)
        let workspaceDatabaseURL = try makeEmptySQLiteDatabase(userVersion: 24)
        let settingsDatabaseURL = try makeEmptySQLiteDatabase(userVersion: 1)
        let archiveData = try makeStoredZip(entries: [
            ("db/settings.sqlite3", try Data(contentsOf: settingsDatabaseURL)),
            ("db/workspaces.sqlite3", try Data(contentsOf: workspaceDatabaseURL)),
            ("db/bookmarks.sqlite3", try Data(contentsOf: bookmarkDatabaseURL)),
            ("db/readingplans.sqlite3", try Data(contentsOf: readingPlanDatabaseURL)),
        ])

        let archive = try AndroidDatabaseBackupService().loadArchive(from: archiveData)

        XCTAssertNil(archive.manifest)
        XCTAssertEqual(archive.sections.map(\.category), [.bookmarks, .readingPlans, .workspaces, .settings])
        XCTAssertTrue(archive.sections.allSatisfy { !$0.declaredInManifest })
        XCTAssertEqual(archive.sections.first { $0.category == .bookmarks }?.support, .supported)
        XCTAssertEqual(archive.sections.first { $0.category == .readingPlans }?.support, .supported)
        XCTAssertEqual(archive.sections.first { $0.category == .workspaces }?.support, .supported)
        XCTAssertEqual(archive.sections.first { $0.category == .settings }?.support, .supported)
    }

    /** Rejects a workspace backup generation that Android does not preserve as a Room export. */
    func testAndroidDatabaseBackupRejectsWorkspaceGenerationWithoutRoomExport() throws {
        let workspaceDatabaseURL = try makeEmptySQLiteDatabase(userVersion: 10)
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: ["workspaces.sqlite3": workspaceDatabaseURL],
            contains: [.workspaces]
        )

        let archive = try AndroidDatabaseBackupService().loadArchive(from: archiveData)

        XCTAssertEqual(
            archive.sections.first { $0.category == .workspaces }?.support,
            .unsupportedVersion(version: 10, supported: 24)
        )
    }

    /**
     Verifies the production file-backed restore path accepts Android `ZipOutputStream` database
     entries without a manifest.

     Setup:
     - creates a real SQLite bookmark database
     - writes it as a raw-deflated ZIP entry with data-descriptor sizes, matching Android
       `ZipOutputStream`
     - loads the backup through `loadArchive(fromArchiveAt:)`

     Expected result:
     - the service streams and inflates the SQLite entry from disk
     - the bookmark section is discovered without materializing the whole archive in memory

     Failure meaning:
     - iOS would still reject valid Android DB backups produced with deflated data-descriptor
       entries on the real document-picker restore path.
     */
    func testAndroidDatabaseBackupLoadsManifestlessDeflatedDatabaseFromFileURL() throws {
        let bookmarkDatabaseURL = try makeAndroidBookmarksDatabase(labels: [])
        try setSQLiteUserVersion(12, at: bookmarkDatabaseURL)
        let databaseData = try Data(contentsOf: bookmarkDatabaseURL)
        let archiveData = try makeDeflatedDescriptorZip(entries: [
            (
                name: "db/bookmarks.sqlite3",
                compressedData: try makeRawDeflateData(databaseData),
                uncompressedData: databaseData
            ),
        ])
        let archiveURL = try writeTemporaryAndroidBackupArchive(
            archiveData,
            suffix: AndroidDatabaseBackupService.databaseBackupSuffix
        )

        let archive = try AndroidDatabaseBackupService().loadArchive(fromArchiveAt: archiveURL)

        XCTAssertNil(archive.manifest)
        XCTAssertEqual(archive.sections.map(\.category), [.bookmarks])
        XCTAssertEqual(archive.sections.first?.databaseVersion, 12)
        XCTAssertEqual(archive.sections.first?.support, .supported)
        XCTAssertEqual(try Data(contentsOf: archive.sections[0].databaseFileURL).prefix(16), databaseData.prefix(16))
    }

    /**
     Verifies that future Android manifest categories do not block known database sections.

     Setup:
     - builds a valid bookmark database backup
     - writes Android's manifest with one known category and one unknown future category string

     Expected result:
     - the archive still loads
     - known categories remain available for restore/import
     - unknown category strings are ignored rather than surfacing as invalid manifests

     Failure meaning:
     - iOS would reject otherwise restorable Android backups when Android adds a new backup
       category before the iOS app learns how to display it.
     */
    func testAndroidDatabaseBackupIgnoresUnknownManifestCategories() throws {
        let bookmarkDatabaseURL = try makeAndroidBookmarksDatabase(labels: [])
        try setSQLiteUserVersion(12, at: bookmarkDatabaseURL)
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "bookmarks.sqlite3": bookmarkDatabaseURL,
            ],
            containsRawValues: [
                AndroidDatabaseBackupCategory.bookmarks.rawValue,
                "FUTURE_ANDROID_CATEGORY",
            ]
        )

        let archive = try AndroidDatabaseBackupService().loadArchive(from: archiveData)

        XCTAssertEqual(archive.manifest?.contains, [.bookmarks])
        XCTAssertEqual(archive.sections.map(\.category), [.bookmarks])
        XCTAssertEqual(archive.sections.first?.support, .supported)
    }

    /**
     Verifies Android-parity DB restore when a present manifest is malformed or not a DB manifest.

     Setup:
     - builds two ZIPs with valid `db/bookmarks.sqlite3` entries
     - one ZIP contains malformed manifest JSON, and the other contains a module-backup manifest

     Expected result:
     - valid Android database filenames remain authoritative
     - bad manifest metadata is ignored rather than blocking restore section discovery
     - sections are marked archive-discovered rather than manifest-declared

     Failure meaning:
     - iOS would preserve a manifest-gated restore path that Android does not use for database
       restore, rejecting user backups that Android can restore.
     */
    func testAndroidDatabaseBackupTreatsPresentManifestAsAdvisoryMetadata() throws {
        let bookmarkDatabaseURL = try makeAndroidBookmarksDatabase(labels: [])
        try setSQLiteUserVersion(12, at: bookmarkDatabaseURL)
        let databaseData = try Data(contentsOf: bookmarkDatabaseURL)
        let malformedManifestArchive = try makeStoredZip(entries: [
            ("AndBibleBackupManifest.json", Data("{".utf8)),
            ("db/bookmarks.sqlite3", databaseData),
        ])
        let wrongTypeManifestArchive = try makeStoredZip(entries: [
            ("AndBibleBackupManifest.json", Data(#"{"backupType":"MODULE_BACKUP","manifestVersion":99}"#.utf8)),
            ("db/bookmarks.sqlite3", databaseData),
        ])

        let malformedArchive = try AndroidDatabaseBackupService().loadArchive(from: malformedManifestArchive)
        let wrongTypeArchive = try AndroidDatabaseBackupService().loadArchive(from: wrongTypeManifestArchive)

        XCTAssertNil(malformedArchive.manifest)
        XCTAssertEqual(malformedArchive.sections.map(\.category), [.bookmarks])
        XCTAssertFalse(malformedArchive.sections[0].declaredInManifest)
        XCTAssertNil(wrongTypeArchive.manifest)
        XCTAssertEqual(wrongTypeArchive.sections.map(\.category), [.bookmarks])
        XCTAssertFalse(wrongTypeArchive.sections[0].declaredInManifest)
    }

    /**
     Verifies that iOS exports Android-compatible manual database backup archives.

     Setup:
     - creates local rows across the supported export model graph
     - exports through `AndroidDatabaseBackupService`
     - re-reads the generated ZIP through the existing Android backup loader

     Expected result:
     - the export uses Android's canonical `.abdb.zip` filename and manifest
     - supported category databases are written under `db/`
     - each SQLite database declares the Android-compatible `user_version`
     - at least one real bookmark label row is present in `bookmarks.sqlite3`

     Failure meaning:
     - iOS would still be exporting a custom JSON backup or an archive Android cannot validate as
       a manual database backup.
     */
    func testAndroidDatabaseBackupExportCreatesAndroidCompatibleArchive() throws {
        let container = try makeAndroidDatabaseBackupExportModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let labelID = UUID(uuidString: "15000000-0000-0000-0000-000000000301")!
        let readingPlanID = UUID(uuidString: "15000000-0000-0000-0000-000000000302")!
        let workspaceID = UUID(uuidString: "15000000-0000-0000-0000-000000000303")!
        let documentID = UUID(uuidString: "15000000-0000-0000-0000-000000000304")!
        let pageID = UUID(uuidString: "15000000-0000-0000-0000-000000000305")!
        let repositoryBaseURL = try temporaryRepositorySourceBaseURL()
        let repositoryManager = RepositorySourceManager(basePath: repositoryBaseURL.path)
        try repositoryManager.replaceCustomSources(
            with: [
                RepositorySourceRegistration(
                    source: SourceConfig(
                        name: "Custom SWORD",
                        type: "HTTP",
                        host: "example.org",
                        catalogPath: "/sword",
                        repositoryType: SourceConfig.swordHTTPSRepositoryType,
                        description: "Custom SWORD catalog",
                        packageDirectory: "/sword/packages",
                        manifestURL: URL(string: "https://example.org/manifest.json")!,
                        sourceURL: URL(string: "https://example.org/sword")!
                    ),
                    description: "Custom SWORD catalog",
                    packageDirectory: "/sword/packages",
                    manifestURL: URL(string: "https://example.org/manifest.json")!,
                    sourceURL: URL(string: "https://example.org/sword")!,
                    type: SourceConfig.swordHTTPSRepositoryType
                ),
            ]
        )
        defer {
            UserDefaults.standard.removeObject(forKey: AppPreferenceKey.localePref.rawValue)
        }

        modelContext.insert(Label(id: labelID, name: "Prayer", color: 7, favourite: true))
        modelContext.insert(
            ReadingPlan(
                id: readingPlanID,
                planCode: "ios-test-plan",
                planName: "iOS Test Plan",
                startDate: Date(timeIntervalSince1970: 1_700_000_000),
                currentDay: 1,
                totalDays: 1
            )
        )
        modelContext.insert(Workspace(id: workspaceID, name: "Study", orderNumber: 0))
        let document = MyDocument(
            id: documentID,
            name: "Sermon Notes",
            initials: "IOSDOC",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let page = MyDocumentPage(
            id: pageID,
            title: "Outline",
            pageKey: "outline",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let content = MyDocumentPageContent(pageId: pageID, content: "# Outline")
        page.document = document
        page.pageContent = content
        document.pages = [page]
        modelContext.insert(document)
        modelContext.insert(page)
        modelContext.insert(content)
        try modelContext.save()
        settingsStore.setBool(.screenKeepOnPref, value: true)
        settingsStore.setString(.localePref, value: "fi")
        _ = try ReadingProgressStore(settingsStore: settingsStore).recordChapterRead(
            bookInitials: "KJV",
            identity: try XCTUnwrap(
                ReadingProgressKJVAIdentity(androidKJVBookOrdinal: 2, chapter: 1)
            ),
            source: .manual,
            readAt: 1_700_000_200
        )
        try MemorizationProgressStore(settingsStore: settingsStore).markAsMemorized(
            verifiedKJVARange(start: 15, end: 15)
        )
        try MemorizationProgressStore(settingsStore: settingsStore).addMemorizationTarget(
            verifiedKJVARange(start: 20, end: 21)
        )

        let service = AndroidDatabaseBackupService(repositorySourceManager: repositoryManager)
        let export = try service.exportArchive(modelContext: modelContext, settingsStore: settingsStore)
        let entriesByName = Dictionary(uniqueKeysWithValues: try ZipArchiveReader.entries(in: export.data).map { ($0.name, $0.data) })
        let expectedCategories: [AndroidDatabaseBackupCategory] = [
            .bookmarks,
            .readingPlans,
            .workspaces,
            .repositories,
            .settings,
            .myDocuments,
            .progress,
        ]
        let expectedEntryNames: Set<String> = [
            "AndBibleBackupManifest.json",
            "db/bookmarks.sqlite3",
            "db/readingplans.sqlite3",
            "db/workspaces.sqlite3",
            "db/repositories.sqlite3",
            "db/settings.sqlite3",
            "db/mydocuments.sqlite3",
            "db/progress.sqlite3",
        ]

        XCTAssertEqual(export.fileName, AndroidDatabaseBackupService.databaseBackupFileName)
        XCTAssertEqual(export.categories, expectedCategories)
        XCTAssertEqual(export.entryCount, expectedEntryNames.count)
        XCTAssertEqual(Set(entriesByName.keys), expectedEntryNames)

        let manifestData = try XCTUnwrap(entriesByName["AndBibleBackupManifest.json"])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["backupType"] as? String, "DB_BACKUP")
        XCTAssertEqual(manifest["manifestVersion"] as? Int, 1)
        XCTAssertEqual(manifest["contains"] as? [String], expectedCategories.map(\.rawValue))

        let loadedArchive = try service.loadArchive(from: export.data)
        defer { service.cleanup(loadedArchive) }
        XCTAssertEqual(loadedArchive.manifest?.backupType, "DB_BACKUP")
        XCTAssertEqual(loadedArchive.sections.map(\.category), expectedCategories)
        XCTAssertTrue(loadedArchive.sections.allSatisfy { $0.support == .supported })

        let materializedDatabases = try materializeExportedDatabases(entriesByName: entriesByName)
        defer {
            for databaseURL in materializedDatabases.values {
                try? FileManager.default.removeItem(at: databaseURL)
            }
        }
        XCTAssertEqual(try readSQLiteUserVersion(at: materializedDatabases["bookmarks.sqlite3"]!), 12)
        XCTAssertEqual(try readSQLiteUserVersion(at: materializedDatabases["readingplans.sqlite3"]!), 1)
        XCTAssertEqual(try readSQLiteUserVersion(at: materializedDatabases["workspaces.sqlite3"]!), 24)
        XCTAssertEqual(try readSQLiteUserVersion(at: materializedDatabases["repositories.sqlite3"]!), 1)
        XCTAssertEqual(try readSQLiteUserVersion(at: materializedDatabases["settings.sqlite3"]!), 1)
        XCTAssertEqual(
            try readSQLiteUserVersion(at: materializedDatabases["mydocuments.sqlite3"]!),
            RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
        )
        XCTAssertEqual(try readSQLiteUserVersion(at: materializedDatabases["progress.sqlite3"]!), 9)
        XCTAssertEqual(
            try readSQLiteInteger(
                "SELECT COUNT(*) FROM Label WHERE name = 'Prayer';",
                at: materializedDatabases["bookmarks.sqlite3"]!
            ),
            1
        )
        XCTAssertEqual(
            try readSQLiteInteger(
                "SELECT COUNT(*) FROM CustomRepository WHERE name = 'Custom SWORD';",
                at: materializedDatabases["repositories.sqlite3"]!
            ),
            1
        )
        XCTAssertEqual(
            try readSQLiteInteger(
                "SELECT COUNT(*) FROM BooleanSetting WHERE `key` = 'screen_keep_on_pref' AND value = 1;",
                at: materializedDatabases["settings.sqlite3"]!
            ),
            1
        )
        XCTAssertEqual(
            try readSQLiteInteger(
                "SELECT COUNT(*) FROM StringSetting WHERE `key` = 'locale_pref' AND value = 'fi';",
                at: materializedDatabases["settings.sqlite3"]!
            ),
            1
        )
        XCTAssertEqual(
            try readSQLiteInteger(
                "SELECT COUNT(*) FROM ChapterReadHistory WHERE kjvBookOrdinal = 2 AND chapter = 1;",
                at: materializedDatabases["progress.sqlite3"]!
            ),
            1
        )
        XCTAssertEqual(
            try readSQLiteInteger(
                "SELECT COUNT(*) FROM MemorizedVerse WHERE kjvOrdinal = 15;",
                at: materializedDatabases["progress.sqlite3"]!
            ),
            1
        )
        XCTAssertEqual(
            try readSQLiteInteger(
                "SELECT COUNT(*) FROM MemorizationTarget WHERE kjvOrdinalStart = 20 AND kjvOrdinalEnd = 21;",
                at: materializedDatabases["progress.sqlite3"]!
            ),
            1
        )
    }

    /**
     Verifies Android AI Settings databases are preserved as Android-owned state.

     Setup:
     - imports an Android `ai_settings.sqlite3` database through manual database restore
     - exports a new manual database backup through the same service instance

     Expected result:
     - AI Settings is exposed as a supported restore-only category
     - Import mode is rejected because Android treats this database as replacement-only
     - the exported `ai_settings.sqlite3` bytes match the restored Android database exactly

     Failure meaning:
     - iOS would either keep treating a real Android backup category as unsupported or would invent
       merge semantics that Android does not provide for this database.
     */
    func testAndroidDatabaseBackupRestoreAiSettingsPreservesAndroidOwnedDatabaseForRoundTrip() throws {
        let container = try makeAndroidDatabaseBackupExportModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let preservedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-ai-settings-preserved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: preservedRoot) }
        let preservedStore = AndroidDatabaseBackupPreservedDatabaseStore(rootDirectory: preservedRoot)
        let aiSettingsDatabaseURL = try makeEmptySQLiteDatabase(userVersion: 22)
        let aiSettingsBytes = try Data(contentsOf: aiSettingsDatabaseURL)
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "ai_settings.sqlite3": aiSettingsDatabaseURL,
            ],
            contains: [.aiSettings]
        )
        let service = AndroidDatabaseBackupService(preservedDatabaseStore: preservedStore)
        let archive = try service.loadArchive(from: archiveData)
        defer { service.cleanup(archive) }
        let section = try XCTUnwrap(archive.sections.first { $0.category == .aiSettings })

        XCTAssertEqual(section.support, .supported)
        XCTAssertEqual(AndroidDatabaseBackupCategory.aiSettings.supportedApplyModes, [.restore])
        XCTAssertThrowsError(
            try service.apply(
                archive: archive,
                selections: [.init(category: .aiSettings, mode: .import)],
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? AndroidDatabaseBackupError,
                .unsupportedSelectedSection(
                    .aiSettings,
                    "AI Settings can only be restored because Android treats ai_settings.sqlite3 as a restore-only database."
                )
            )
        }

        let applyReport = try service.apply(
            archive: archive,
            selections: [.init(category: .aiSettings, mode: .restore)],
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(applyReport.sections, [
            AndroidDatabaseBackupAppliedSectionReport(category: .aiSettings, mode: .restore, summary: "1 database"),
        ])

        let export = try service.exportArchive(modelContext: modelContext, settingsStore: settingsStore)
        let entriesByName = Dictionary(uniqueKeysWithValues: try ZipArchiveReader.entries(in: export.data).map { ($0.name, $0.data) })

        XCTAssertEqual(
            export.categories,
            [.bookmarks, .readingPlans, .workspaces, .repositories, .settings, .aiSettings, .myDocuments, .progress]
        )
        XCTAssertEqual(entriesByName["db/ai_settings.sqlite3"], aiSettingsBytes)
        let manifestData = try XCTUnwrap(entriesByName["AndBibleBackupManifest.json"])
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(
            manifest["contains"] as? [String],
            export.categories.map(\.rawValue)
        )
    }

    /**
     Verifies Android BackupActivity reset parity for preserved AI Settings.

     Setup:
     - stores an Android AI Settings database through the preservation store
     - runs the native reset service for the AI Settings category
     - exports a manual database backup afterward

     Expected result:
     - reset removes the preserved Android-owned database
     - later exports omit `AI_SETTINGS` rather than emitting a fake empty database

     Failure meaning:
     - reset would either leave stale Android-only data behind or export placeholder data that does
       not correspond to any real iOS/Android state.
     */
    func testAndroidBackupResetAiSettingsRemovesPreservedAndroidDatabase() throws {
        let container = try makeAndroidDatabaseBackupExportModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let preservedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-ai-settings-reset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: preservedRoot) }
        let preservedStore = AndroidDatabaseBackupPreservedDatabaseStore(rootDirectory: preservedRoot)
        let aiSettingsDatabaseURL = try makeEmptySQLiteDatabase(userVersion: 22)
        try preservedStore.restoreDatabase(from: aiSettingsDatabaseURL, category: .aiSettings)

        let resetReport = try AndroidBackupResetService(preservedDatabaseStore: preservedStore).reset(
            .aiSettings,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let export = try AndroidDatabaseBackupService(preservedDatabaseStore: preservedStore)
            .exportArchive(modelContext: modelContext, settingsStore: settingsStore)
        let entriesByName = Dictionary(uniqueKeysWithValues: try ZipArchiveReader.entries(in: export.data).map { ($0.name, $0.data) })

        XCTAssertEqual(resetReport.category, .aiSettings)
        XCTAssertFalse(preservedStore.hasDatabase(for: .aiSettings))
        XCTAssertFalse(export.categories.contains(.aiSettings))
        XCTAssertNil(entriesByName["db/ai_settings.sqlite3"])
    }

    /**
     Verifies Android-parity restore semantics for a selected database backup section.

     Setup:
     - starts with local bookmark data and pre-existing remote-sync bookkeeping
     - loads an Android backup containing bookmarks plus an unsupported Settings section
     - applies only the Bookmarks section in Restore mode

     Expected result:
     - local bookmark rows are replaced by the Android bookmark database
     - unsupported sections are ignored when not selected
     - affected remote-sync toggle, bootstrap state, patch progress, and patch statuses are cleared

     Failure meaning:
     - iOS would not match Android's destructive Restore behavior or would leave stale sync metadata
       after a manual backup restore.
     */
    func testAndroidDatabaseBackupRestoreBookmarksReplacesLocalDataAndClearsSyncState() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let remoteSettingsStore = RemoteSyncSettingsStore(settingsStore: settingsStore)
        let syncStateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        let legacyLabel = Label(name: "Legacy")
        modelContext.insert(legacyLabel)
        let legacyBookmark = BibleBookmark(kjvOrdinalStart: 1, kjvOrdinalEnd: 1)
        legacyBookmark.book = "Genesis"
        modelContext.insert(legacyBookmark)
        try modelContext.save()

        remoteSettingsStore.setSyncEnabled(true, for: .bookmarks)
        syncStateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/sync/bookmarks",
                deviceFolderID: "/sync/bookmarks/ios",
                secretFileName: "device-known-ios"
            ),
            for: .bookmarks
        )
        syncStateStore.setProgressState(
            RemoteSyncProgressState(lastPatchWritten: 100, lastSynchronized: 200, disabledForVersion: 1),
            for: .bookmarks
        )
        patchStatusStore.addStatus(
            RemoteSyncPatchStatus(sourceDevice: "android", patchNumber: 1, sizeBytes: 50, appliedDate: 300),
            for: .bookmarks
        )

        let remoteLabelID = UUID(uuidString: "15000000-0000-0000-0000-000000000010")!
        let remoteBookmarkID = UUID(uuidString: "15000000-0000-0000-0000-000000000020")!
        let bookmarkDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteLabelID, name: "Prayer", colour: 9),
            ],
            bibleBookmarks: [
                .init(
                    id: remoteBookmarkID,
                    kjvOrdinalStart: 15,
                    kjvOrdinalEnd: 15,
                    ordinalStart: 15,
                    ordinalEnd: 15,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    primaryLabelID: remoteLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_000_100)
                ),
            ],
            bibleNotes: [
                .init(bookmarkID: remoteBookmarkID, notes: "Android note", contentType: "MARKDOWN"),
            ],
            bibleLinks: [
                .init(bookmarkID: remoteBookmarkID, labelID: remoteLabelID, orderNumber: 0, indentLevel: 0, expandContent: false),
            ]
        )
        try setSQLiteUserVersion(12, at: bookmarkDatabaseURL)
        let settingsDatabaseURL = try makeEmptySQLiteDatabase(userVersion: 1)
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "bookmarks.sqlite3": bookmarkDatabaseURL,
                "settings.sqlite3": settingsDatabaseURL,
            ],
            contains: [.bookmarks, .settings]
        )
        let service = AndroidDatabaseBackupService()
        let archive = try service.loadArchive(from: archiveData)

        let report = try service.apply(
            archive: archive,
            selections: [.init(category: .bookmarks, mode: .restore)],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report.sections,
            [
                .init(category: .bookmarks, mode: .restore, summary: "1 bookmarks, 4 labels"),
            ]
        )
        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertNil(labels.first { $0.name == "Legacy" })
        XCTAssertEqual(labels.first { $0.name == "Prayer" }?.id, remoteLabelID)

        let bookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks.first?.id, remoteBookmarkID)
        XCTAssertEqual(bookmarks.first?.notes?.notes, "Android note")
        XCTAssertEqual(bookmarks.first?.notes?.contentType, "MARKDOWN")

        XCTAssertFalse(remoteSettingsStore.isSyncEnabled(for: .bookmarks))
        XCTAssertEqual(syncStateStore.bootstrapState(for: .bookmarks), RemoteSyncBootstrapState())
        XCTAssertEqual(syncStateStore.progressState(for: .bookmarks), RemoteSyncProgressState())
        XCTAssertTrue(patchStatusStore.statuses(for: .bookmarks).isEmpty)
    }

    /**
     Verifies that Android BackupActivity bookmark reset uses the same storage boundary as restore.

     Setup:
     - seeds local bookmark and label rows that should be removed
     - seeds every category-scoped remote-sync side store that can make a later sync think deleted
       rows are already reconciled

     Expected result:
     - the bookmark category is reset through an empty Android-shaped snapshot
     - user-created bookmark rows disappear while required system label rows may be recreated
     - sync toggle, bootstrap/progress state, patch status, log entries, and row fingerprints are
       cleared for bookmarks

     Failure meaning:
     - iOS would treat Android's Reset Databases action as a narrow row-delete shortcut instead of
       the same category replacement boundary used by Android backup restore.
     */
    func testAndroidBackupResetBookmarksClearsLocalDataAndSyncBookkeeping() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let remoteSettingsStore = RemoteSyncSettingsStore(settingsStore: settingsStore)
        let syncStateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)

        let legacyLabel = Label(name: "Legacy")
        modelContext.insert(legacyLabel)
        let legacyBookmark = BibleBookmark(kjvOrdinalStart: 1, kjvOrdinalEnd: 1)
        legacyBookmark.book = "Genesis"
        modelContext.insert(legacyBookmark)
        try modelContext.save()

        let bookmarkIDValue = RemoteSyncSQLiteValue.blob(
            RemoteSyncBookmarkSnapshotService.uuidBlob(legacyBookmark.id)
        )
        remoteSettingsStore.setSyncEnabled(true, for: .bookmarks)
        syncStateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/sync/bookmarks",
                deviceFolderID: "/sync/bookmarks/ios",
                secretFileName: "device-known-ios"
            ),
            for: .bookmarks
        )
        syncStateStore.setProgressState(
            RemoteSyncProgressState(lastPatchWritten: 100, lastSynchronized: 200, disabledForVersion: 1),
            for: .bookmarks
        )
        patchStatusStore.addStatus(
            RemoteSyncPatchStatus(sourceDevice: "android", patchNumber: 1, sizeBytes: 50, appliedDate: 300),
            for: .bookmarks
        )
        logEntryStore.addEntry(
            RemoteSyncLogEntry(
                tableName: "BibleBookmark",
                entityID1: bookmarkIDValue,
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 400,
                sourceDevice: "ios"
            ),
            for: .bookmarks
        )
        fingerprintStore.setFingerprint(
            "legacy-hash",
            for: .bookmarks,
            tableName: "BibleBookmark",
            entityID1: bookmarkIDValue,
            entityID2: .null()
        )

        let report = try AndroidBackupResetService().reset(
            .bookmarks,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report, AndroidBackupResetReport(category: .bookmarks))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<BibleBookmark>()).isEmpty)
        XCTAssertNil(try modelContext.fetch(FetchDescriptor<Label>()).first { $0.name == "Legacy" })
        XCTAssertFalse(remoteSettingsStore.isSyncEnabled(for: .bookmarks))
        XCTAssertEqual(syncStateStore.bootstrapState(for: .bookmarks), RemoteSyncBootstrapState())
        XCTAssertEqual(syncStateStore.progressState(for: .bookmarks), RemoteSyncProgressState())
        XCTAssertTrue(patchStatusStore.statuses(for: .bookmarks).isEmpty)
        XCTAssertTrue(logEntryStore.entries(for: .bookmarks).isEmpty)
        XCTAssertNil(
            fingerprintStore.fingerprint(
                for: .bookmarks,
                tableName: "BibleBookmark",
                entityID1: bookmarkIDValue,
                entityID2: .null()
            )
        )
    }

    /**
     Verifies Android BackupActivity progress reset clears iOS's local progress stores.

     Setup:
     - seeds chapter-reading and memorization progress settings in the local settings table

     Expected result:
     - reset reports the Progress category and removes both local progress payloads
     - unrelated settings are not required for this local-only category

     Failure meaning:
     - iOS would expose Android's Progress reset category while leaving native progress data
       untouched, making the user-visible reset action misleading.
     */
    func testAndroidBackupResetProgressClearsLocalProgressStores() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        settingsStore.setString(ReadingProgressStore.settingsKey, value: #"{"history":[1]}"#)
        settingsStore.setString(MemorizationProgressStore.settingsKey, value: #"{"targets":[1]}"#)

        let report = try AndroidBackupResetService().reset(
            .progress,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report, AndroidBackupResetReport(category: .progress))
        XCTAssertNil(settingsStore.getString(ReadingProgressStore.settingsKey))
        XCTAssertNil(settingsStore.getString(MemorizationProgressStore.settingsKey))
    }

    /**
     Verifies Android BackupActivity repository reset clears legacy rows and recreates defaults.

     Setup:
     - seeds one local SwiftData repository row
     - points `RepositorySourceManager` at a temporary install-manager directory

     Expected result:
     - SwiftData repository rows are deleted
     - `InstallMgr.conf` exists after reset because the manager recreated packaged defaults

     Failure meaning:
     - iOS would expose Android's repository reset category but leave either legacy repository
       metadata or SWORD source configuration in the pre-reset state.
     */
    func testAndroidBackupResetRepositoriesClearsRowsAndRecreatesDefaultSources() throws {
        let schema = Schema([
            Repository.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        modelContext.insert(Repository(name: "Legacy", url: "https://example.test/repo"))
        try modelContext.save()

        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-backup-reset-repositories-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseURL) }

        let report = try AndroidBackupResetService(
            repositorySourceManager: RepositorySourceManager(basePath: baseURL.path)
        ).reset(
            .repositories,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report, AndroidBackupResetReport(category: .repositories))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<Repository>()).isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: baseURL.appendingPathComponent("InstallMgr.conf").path
            )
        )
    }

    /**
     Verifies repository reset preserves legacy rows when source configuration reset fails.

     Setup:
     - seeds one local SwiftData repository row
     - injects a deterministic atomic-writer failure for the live `InstallMgr.conf` replacement

     Expected result:
     - reset throws the repository-source failure before deleting SwiftData rows
     - the legacy repository row is still present after the failed reset

     Failure meaning:
     - iOS could partially reset repositories by deleting legacy metadata before failing to restore
       Android-compatible SWORD source configuration.
     */
    func testAndroidBackupResetRepositoriesPreservesRowsWhenSourceResetFails() throws {
        let schema = Schema([
            Repository.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        modelContext.insert(Repository(name: "Legacy", url: "https://example.test/repo"))
        try modelContext.save()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-backup-reset-repositories-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("InstallMgr.conf")
        let persistence = RepositorySourcePersistence(
            write: { data, destination in
                if destination.standardizedFileURL == configURL.standardizedFileURL {
                    throw NSError(
                        domain: "AndroidDatabaseBackupTests",
                        code: 9001,
                        userInfo: [NSLocalizedDescriptionKey: "repository write blocked"]
                    )
                }
                try data.write(to: destination, options: .atomic)
            }
        )
        let service = AndroidBackupResetService(
            repositorySourceManager: RepositorySourceManager(
                basePath: tempDir.path,
                persistence: persistence
            )
        )

        XCTAssertThrowsError(
            try service.reset(
                .repositories,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            guard case .configWriteFailed(let message) = error as? RepositorySourceManagementError else {
                return XCTFail("Expected repository config write failure, got \(error)")
            }
            XCTAssertTrue(message.contains("repository write blocked"), message)
        }
        let repositories = try modelContext.fetch(FetchDescriptor<Repository>())
        XCTAssertEqual(repositories.map(\.name), ["Legacy"])
    }

    /**
     Verifies Android-parity Import mode for Android bookmark database backups.

     Setup:
     - first restores a local bookmark snapshot
     - adds one legacy bookmark without trustworthy source metadata
     - then imports an Android backup containing one duplicate bookmark and one new bookmark

     Expected result:
     - duplicate local rows keep their local note content and note content type
     - new backup rows are added with their Android note content type
     - the quarantined local row survives even though trusted snapshot projection omits it

     Failure meaning:
     - iOS Import would drift from Android's `INSERT OR IGNORE` semantics by overwriting local rows
       or skipping valid backup rows, including Android's nullable note `TextContentType`.
     */
    func testAndroidDatabaseBackupImportBookmarksKeepsExistingRowsAndAddsMissingRows() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = AndroidDatabaseBackupService()
        let labelID = UUID(uuidString: "15000000-0000-0000-0000-000000000101")!
        let existingBookmarkID = UUID(uuidString: "15000000-0000-0000-0000-000000000102")!
        let newBookmarkID = UUID(uuidString: "15000000-0000-0000-0000-000000000103")!
        let quarantinedBookmarkID = UUID(uuidString: "15000000-0000-0000-0000-000000000104")!

        let localArchive = try service.loadArchive(
            from: makeAndroidBookmarkOnlyBackupData(
                labelID: labelID,
                bookmarks: [
                    (existingBookmarkID, 20, "Local note"),
                ],
                noteContentType: "MARKDOWN"
            )
        )
        _ = try service.apply(
            archive: localArchive,
            selections: [.init(category: .bookmarks, mode: .restore)],
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let quarantinedBookmark = BibleBookmark(
            id: quarantinedBookmarkID,
            kjvOrdinalStart: 22,
            kjvOrdinalEnd: 22
        )
        modelContext.insert(quarantinedBookmark)
        try modelContext.save()

        let importArchive = try service.loadArchive(
            from: makeAndroidBookmarkOnlyBackupData(
                labelID: labelID,
                bookmarks: [
                    (existingBookmarkID, 20, "Backup replacement"),
                    (newBookmarkID, 21, "Backup addition"),
                ],
                noteContentType: "HTML"
            )
        )
        _ = try service.apply(
            archive: importArchive,
            selections: [.init(category: .bookmarks, mode: .import)],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let bookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(
            Set(bookmarks.map(\.id)),
            Set([existingBookmarkID, newBookmarkID, quarantinedBookmarkID])
        )
        XCTAssertEqual(bookmarks.first { $0.id == existingBookmarkID }?.notes?.notes, "Local note")
        XCTAssertEqual(bookmarks.first { $0.id == existingBookmarkID }?.notes?.contentType, "MARKDOWN")
        XCTAssertEqual(bookmarks.first { $0.id == newBookmarkID }?.notes?.notes, "Backup addition")
        XCTAssertEqual(bookmarks.first { $0.id == newBookmarkID }?.notes?.contentType, "HTML")
        XCTAssertEqual(
            bookmarks.first { $0.id == quarantinedBookmarkID }?.ordinalTrustState,
            .legacyUnresolved
        )
    }

    /**
     Preserves Java-distinct canonical spellings during Android My Documents Import.

     - Setup: Seeds a local document/page with composed initials and page key, then imports a
       backup containing a canonically equivalent decomposed document plus a decomposed page key
       under the existing document id.
     - Expected result: Import retains both document initials and both page keys because Android
       SQLite BINARY and Java `String.equals` treat their UTF-16 sequences as distinct.
     - Failure meaning: Swift canonical-equivalence collapsed a valid imported document or page
       before the authoritative restore service could publish the merged graph.
     - Side effects: Creates two in-memory SwiftData graphs and one temporary backup archive tree.
     */
    func testAndroidDatabaseBackupImportPreservesJavaDistinctMyDocumentIdentities() throws {
        let localContainer = try makeAndroidDatabaseBackupExportModelContainer()
        let localContext = ModelContext(localContainer)
        let importedContainer = try makeAndroidDatabaseBackupExportModelContainer()
        let importedContext = ModelContext(importedContainer)
        let composed = "Manual-Caf\u{00E9}"
        let decomposed = "Manual-Cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf16), Array(decomposed.utf16))

        let existingDocumentID = UUID()
        let localDocument = MyDocument(
            id: existingDocumentID,
            name: "Local",
            initials: composed
        )
        let localPage = MyDocumentPage(id: UUID(), title: "Local", pageKey: composed)
        localPage.document = localDocument
        localDocument.pages = [localPage]
        localContext.insert(localDocument)
        localContext.insert(localPage)
        try localContext.save()

        let importedExistingDocument = MyDocument(
            id: existingDocumentID,
            name: "Imported existing",
            initials: composed
        )
        let importedPage = MyDocumentPage(id: UUID(), title: "Imported", pageKey: decomposed)
        importedPage.document = importedExistingDocument
        importedExistingDocument.pages = [importedPage]
        let importedDistinctDocument = MyDocument(
            id: UUID(),
            name: "Imported distinct",
            initials: decomposed
        )
        importedContext.insert(importedExistingDocument)
        importedContext.insert(importedPage)
        importedContext.insert(importedDistinctDocument)
        try importedContext.save()

        let repositoryRoot = try temporaryRepositorySourceBaseURL()
        let service = AndroidDatabaseBackupService(
            repositorySourceManager: RepositorySourceManager(basePath: repositoryRoot.path)
        )
        let export = try service.exportArchive(
            modelContext: importedContext,
            settingsStore: SettingsStore(modelContext: importedContext)
        )
        let archive = try service.loadArchive(from: export.data)
        defer { service.cleanup(archive) }
        _ = try service.apply(
            archive: archive,
            selections: [.init(category: .myDocuments, mode: .import)],
            modelContext: localContext,
            settingsStore: SettingsStore(modelContext: localContext)
        )

        let documents = try localContext.fetch(FetchDescriptor<MyDocument>())
        XCTAssertEqual(Set(documents.map { Array($0.initials.utf16) }), Set([
            Array(composed.utf16),
            Array(decomposed.utf16),
        ]))
        let existing = try XCTUnwrap(documents.first { $0.id == existingDocumentID })
        let existingPages = existing.pages ?? []
        XCTAssertEqual(Set(existingPages.map { Array($0.pageKey.utf16) }), Set([
            Array(composed.utf16),
            Array(decomposed.utf16),
        ]))
    }

    /**
     Verifies Android settings database restore replaces the registered iOS application preferences.

     Setup:
     - seeds local app preferences that should be cleared by destructive Settings restore
     - loads Android's `settings.sqlite3` shape with Boolean, Long, and String preference tables

     Expected result:
     - the Settings section is supported and restore applies Android-backed registered preferences
     - registered local values absent from the backup return to Android defaults
     - UserDefaults-backed preferences such as locale route through the same registry as the UI

     Failure meaning:
     - iOS would preserve the artificial Settings unsupported gate or perform a partial restore
       that leaves stale iOS-only preference values after Android's raw-copy restore boundary.
     */
    func testAndroidDatabaseBackupRestoreSettingsReplacesRegisteredAppPreferences() throws {
        let schema = Schema([Setting.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        defer {
            UserDefaults.standard.removeObject(forKey: AppPreferenceKey.localePref.rawValue)
        }
        settingsStore.setBool(.autoFullscreenPref, value: true)
        settingsStore.setBool(.volumeKeysScroll, value: false)
        settingsStore.setString(.localePref, value: "en")

        let settingsDatabaseURL = try makeAndroidSettingsDatabase(
            booleanSettings: [
                AppPreferenceKey.screenKeepOnPref.rawValue: true,
            ],
            longSettings: [
                AppPreferenceKey.fontSizeMultiplier.rawValue: 125,
            ],
            stringSettings: [
                AppPreferenceKey.nightModePref3.rawValue: "dark",
                AppPreferenceKey.localePref.rawValue: "fi",
                AppPreferenceKey.notesContentType.rawValue: "MARKDOWN",
                AppPreferenceKey.disabledWordLookupDictionaries.rawValue: "KJV,ESV",
            ]
        )
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "settings.sqlite3": settingsDatabaseURL,
            ],
            contains: [.settings]
        )
        let service = AndroidDatabaseBackupService()
        let archive = try service.loadArchive(from: archiveData)

        let report = try service.apply(
            archive: archive,
            selections: [.init(category: .settings, mode: .restore)],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(archive.sections.first?.support, .supported)
        XCTAssertEqual(report.sections, [.init(category: .settings, mode: .restore, summary: "6 settings")])
        XCTAssertTrue(settingsStore.getBool(.screenKeepOnPref))
        XCTAssertEqual(settingsStore.getInt(.fontSizeMultiplier), 125)
        XCTAssertEqual(settingsStore.getString(.nightModePref3), "dark")
        XCTAssertEqual(settingsStore.getString(.notesContentType), "MARKDOWN")
        XCTAssertEqual(settingsStore.getString(.localePref), "fi")
        XCTAssertEqual(settingsStore.getStringSet(.disabledWordLookupDictionaries), ["ESV", "KJV"])
        XCTAssertFalse(settingsStore.getBool(.autoFullscreenPref))
        XCTAssertTrue(settingsStore.getBool(.volumeKeysScroll))
    }

    /**
     Verifies Android settings restore rejects integer preference values outside Android's domain.

     Setup:
     - seeds local application preferences that would be cleared by a destructive Settings restore
     - loads Android's `settings.sqlite3` with a `LongSetting` value that Android's settings UI
       cannot create for `font_size_multiplier`

     Expected result:
     - restore fails with `invalidSQLiteDatabase("settings.sqlite3")`
     - existing local preferences remain intact because validation happens before reset/apply

     Failure meaning:
     - iOS would accept corrupt Android preference payloads and persist values that Android cannot
       produce, or it would clear local settings before discovering the backup is invalid.
     */
    func testAndroidDatabaseBackupRejectsSettingsIntOutsideAndroidPreferenceRangeBeforeReset() throws {
        let schema = Schema([Setting.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        settingsStore.setBool(.autoFullscreenPref, value: true)
        settingsStore.setInt(.fontSizeMultiplier, value: 125)

        let settingsDatabaseURL = try makeAndroidSettingsDatabase(
            longSettings: [
                AppPreferenceKey.fontSizeMultiplier.rawValue: Int64.max,
            ]
        )
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "settings.sqlite3": settingsDatabaseURL,
            ],
            contains: [.settings]
        )
        let service = AndroidDatabaseBackupService()
        let archive = try service.loadArchive(from: archiveData)

        XCTAssertThrowsError(
            try service.apply(
                archive: archive,
                selections: [.init(category: .settings, mode: .restore)],
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(error as? AndroidDatabaseBackupError, .invalidSQLiteDatabase("settings.sqlite3"))
        }
        XCTAssertTrue(settingsStore.getBool(.autoFullscreenPref))
        XCTAssertEqual(settingsStore.getInt(.fontSizeMultiplier), 125)
    }

    /**
     Verifies Android restore-only databases cannot be applied through Import mode.

     Setup:
     - loads Android Settings and Repositories database sections, which Android raw-copies instead
       of sending through `importDatabaseFile`

     Expected result:
     - both sections are visible and supported for Restore
     - selecting Import fails before mutating local settings or repository state

     Failure meaning:
     - iOS would invent Import semantics for Android raw-copy databases and drift from Android's
       restore/import choice boundary.
     */
    func testAndroidDatabaseBackupRejectsImportForRestoreOnlyDatabases() throws {
        let schema = Schema([
            Repository.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let settingsDatabaseURL = try makeAndroidSettingsDatabase(
            booleanSettings: [AppPreferenceKey.screenKeepOnPref.rawValue: true]
        )
        let repositoriesDatabaseURL = try makeAndroidRepositoriesDatabase(
            customRepositories: [
                .init(
                    name: "Custom SWORD",
                    description: "Custom SWORD catalog",
                    type: SourceConfig.swordHTTPSRepositoryType,
                    host: "example.org",
                    catalogDirectory: "/sword",
                    packageDirectory: "/sword/packages",
                    manifestURL: "https://example.org/manifest.json"
                ),
            ]
        )
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "settings.sqlite3": settingsDatabaseURL,
                "repositories.sqlite3": repositoriesDatabaseURL,
            ],
            contains: [.settings, .repositories]
        )
        let service = AndroidDatabaseBackupService(
            repositorySourceManager: RepositorySourceManager(basePath: try temporaryRepositorySourceBaseURL().path)
        )
        let archive = try service.loadArchive(from: archiveData)

        XCTAssertEqual(archive.sections.map(\.support), [.supported, .supported])
        XCTAssertThrowsError(
            try service.apply(
                archive: archive,
                selections: [.init(category: .settings, mode: .import)],
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? AndroidDatabaseBackupError,
                .unsupportedSelectedSection(
                    .settings,
                    "Settings can only be restored because Android treats settings.sqlite3 as a restore-only database."
                )
            )
        }
        XCTAssertThrowsError(
            try service.apply(
                archive: archive,
                selections: [.init(category: .repositories, mode: .import)],
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? AndroidDatabaseBackupError,
                .unsupportedSelectedSection(
                    .repositories,
                    "Repositories can only be restored because Android treats repositories.sqlite3 as a restore-only database."
                )
            )
        }
    }

    /**
     Verifies Android repository database restore replaces custom repository source configuration.

     Setup:
     - seeds a legacy SwiftData repository row
     - loads Android's `repositories.sqlite3` with a SWORD HTTPS custom repository row
     - points the repository source manager at an isolated InstallMgr directory

     Expected result:
     - the Repositories section is supported and restore reports the imported custom source
     - legacy repository rows are removed after source persistence succeeds
     - the restored SWORD source is available through the normal Downloads source loader

     Failure meaning:
     - iOS would keep platform-specific repository backup semantics instead of restoring Android's
       user-visible custom repository database into the iOS source configuration boundary.
     */
    func testAndroidDatabaseBackupRestoreRepositoriesReplacesCustomSourceConfiguration() throws {
        let schema = Schema([
            Repository.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        modelContext.insert(Repository(name: "Legacy", url: "https://legacy.example.test/repo"))
        try modelContext.save()

        let baseURL = try temporaryRepositorySourceBaseURL()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let repositoryManager = RepositorySourceManager(basePath: baseURL.path)
        let repositoriesDatabaseURL = try makeAndroidRepositoriesDatabase(
            customRepositories: [
                .init(
                    name: "Custom SWORD",
                    description: "Custom SWORD catalog",
                    type: SourceConfig.swordHTTPSRepositoryType,
                    host: "example.org",
                    catalogDirectory: "/sword",
                    packageDirectory: "/sword/packages",
                    manifestURL: "https://example.org/manifest.json"
                ),
            ]
        )
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "repositories.sqlite3": repositoriesDatabaseURL,
            ],
            contains: [.repositories]
        )
        let service = AndroidDatabaseBackupService(repositorySourceManager: repositoryManager)
        let archive = try service.loadArchive(from: archiveData)

        let report = try service.apply(
            archive: archive,
            selections: [.init(category: .repositories, mode: .restore)],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(archive.sections.first?.support, .supported)
        XCTAssertEqual(report.sections, [.init(category: .repositories, mode: .restore, summary: "1 repositories")])
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<Repository>()).isEmpty)
        let restoredSource = try XCTUnwrap(repositoryManager.loadSources().first { $0.name == "Custom SWORD" })
        XCTAssertEqual(restoredSource.repositoryType, SourceConfig.swordHTTPSRepositoryType)
        XCTAssertEqual(restoredSource.host, "example.org")
        XCTAssertEqual(restoredSource.catalogPath, "/sword")
        XCTAssertEqual(restoredSource.packageDirectory, "/sword/packages")
        XCTAssertEqual(restoredSource.manifestURL?.absoluteString, "https://example.org/manifest.json")
    }

    /**
     Verifies Android progress restore replaces native iOS progress snapshots with KJV-global data.

     Setup:
     - seeds local chapter reading history and module-specific memorization progress
     - restores Android's `progress.sqlite3` with chapter history, memorized verses, targets, and
       the singleton global progress settings row

     Expected result:
     - Progress is a supported section
     - reading history/settings are replaced by Android rows
     - memorized and target ordinals imported from Android apply across module identities because
       Android stores KJV-normalized global ordinals

     Failure meaning:
     - iOS would preserve the unsupported Progress gate or map Android progress into a
       module-specific fallback that does not match Android's KJV-global behavior.
     */
    func testAndroidDatabaseBackupRestoreProgressReplacesSnapshotsWithKJVGlobalState() throws {
        let schema = Schema([Setting.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let readingStore = ReadingProgressStore(settingsStore: settingsStore)
        let memorizationStore = MemorizationProgressStore(settingsStore: settingsStore)
        _ = try readingStore.recordChapterRead(
            bookInitials: "ESV",
            identity: try XCTUnwrap(
                ReadingProgressKJVAIdentity(androidKJVBookOrdinal: 2, chapter: 1)
            ),
            source: .manual,
            readAt: 1_700_000_000
        )
        try memorizationStore.markAsMemorized(verifiedKJVARange(start: 100, end: 100))

        let historyID = UUID(uuidString: "15000000-0000-0000-0000-000000000601")!
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000000602")!
        let targetID = UUID(uuidString: "15000000-0000-0000-0000-000000000603")!
        let settingsID = UUID(uuidString: "b2000000-0000-0000-0000-000000000001")!
        let progressDatabaseURL = try makeAndroidProgressDatabase(
            memorizedVerses: [
                .init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 1_700_000_100),
            ],
            memorizationTargets: [
                .init(id: targetID, kjvOrdinalStart: 20, kjvOrdinalEnd: 22, createdAt: 1_700_000_200),
            ],
            chapterHistory: [
                .init(
                    id: historyID,
                    kjvBookOrdinal: 2,
                    chapter: 2,
                    cycle: 3,
                    readAt: 1_700_000_300,
                    bookInitials: "",
                    source: .autoTts
                ),
            ],
            settings: .init(
                id: settingsID,
                autoTrackReading: true,
                autoMarkMemorized: false,
                memorizeTypeFullWords: true,
                memorizeWordVisibility: "hidden",
                memorizeErrorHeatmap: false,
                memorizeScrambleHideUsed: true,
                memorizeIncludeReference: false,
                activeCycle: 3
            )
        )
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "progress.sqlite3": progressDatabaseURL,
            ],
            contains: [.progress]
        )
        let service = AndroidDatabaseBackupService()
        let archive = try service.loadArchive(from: archiveData)

        let report = try service.apply(
            archive: archive,
            selections: [.init(category: .progress, mode: .restore)],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(archive.sections.first?.support, .supported)
        XCTAssertEqual(report.sections, [.init(category: .progress, mode: .restore, summary: "1 readings, 1 memorized verses, 1 targets")])
        let readingSnapshot = readingStore.snapshot()
        XCTAssertEqual(readingSnapshot.history.map(\.id), [historyID])
        XCTAssertEqual(readingSnapshot.history.first?.bookInitials, "")
        XCTAssertEqual(readingSnapshot.history.first?.source, .autoTts)
        XCTAssertEqual(readingSnapshot.settings.activeCycle, 3)
        XCTAssertTrue(readingSnapshot.settings.autoTrackReading)
        XCTAssertFalse(readingSnapshot.settings.autoMarkMemorized)
        XCTAssertEqual(memorizationStore.snapshot().memorizedVerses.map(\.id), [memorizedID])
        XCTAssertEqual(memorizationStore.memorizedOrdinals(bookInitials: "ESV", startOrdinal: 15, endOrdinal: 15), [15])
        XCTAssertEqual(memorizationStore.memorizedOrdinals(bookInitials: "KJV", startOrdinal: 15, endOrdinal: 15), [15])
        XCTAssertEqual(memorizationStore.targetOrdinals(bookInitials: "FinRK", startOrdinal: 20, endOrdinal: 22), [20, 21, 22])
        XCTAssertEqual(memorizationStore.memorizedOrdinals(bookInitials: "ESV", startOrdinal: 100, endOrdinal: 100), [])
    }

    /**
     Verifies Android progress Import keeps local rows and adds only missing backup rows.

     Setup:
     - seeds local reading history and KJV-global memorization progress
     - imports an Android `progress.sqlite3` containing duplicate and new chapter/memorization rows

     Expected result:
     - duplicate history UUIDs and memorized ordinals keep local values
     - new Android rows are added
     - existing local settings remain local-first, matching Android `INSERT OR IGNORE`

     Failure meaning:
     - iOS Progress Import would overwrite local progress or fail to add missing Android rows,
       drifting from Android's table-level `INSERT OR IGNORE` import behavior.
     */
    func testAndroidDatabaseBackupImportProgressKeepsLocalRowsAndAddsMissingRows() throws {
        let schema = Schema([Setting.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let readingStore = ReadingProgressStore(settingsStore: settingsStore)
        let memorizationStore = MemorizationProgressStore(settingsStore: settingsStore)
        let duplicateHistoryID = UUID(uuidString: "15000000-0000-0000-0000-000000000701")!
        let newHistoryID = UUID(uuidString: "15000000-0000-0000-0000-000000000702")!
        let duplicateMemorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000000703")!
        let newMemorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000000704")!
        let targetID = UUID(uuidString: "15000000-0000-0000-0000-000000000705")!
        let settingsID = UUID(uuidString: "b2000000-0000-0000-0000-000000000001")!
        settingsStore.setString(
            ReadingProgressStore.settingsKey,
            value: """
            {"history":[{"id":"\(duplicateHistoryID.uuidString)","bookInitials":"ESV","startOrdinal":10,"kjvBookOrdinal":2,"chapter":1,"cycle":1,"readAt":1000,"source":"MANUAL"}],"settings":{"autoTrackReading":false,"activeCycle":1,"autoMarkMemorized":true,"memorizeTypeFullWords":false,"memorizeWordVisibility":"light","memorizeErrorHeatmap":true,"memorizeScrambleHideUsed":false,"memorizeIncludeReference":true}}
            """
        )
        settingsStore.setString(
            MemorizationProgressStore.settingsKey,
            value: #"{"memorizedRanges":[{"bookInitials":"","startOrdinal":15,"endOrdinal":15}],"targetRanges":[]}"#
        )

        let progressDatabaseURL = try makeAndroidProgressDatabase(
            memorizedVerses: [
                .init(id: duplicateMemorizedID, kjvOrdinal: 15, memorizedAt: 1_700_000_100),
                .init(id: newMemorizedID, kjvOrdinal: 16, memorizedAt: 1_700_000_200),
            ],
            memorizationTargets: [
                .init(id: targetID, kjvOrdinalStart: 21, kjvOrdinalEnd: 22, createdAt: 1_700_000_300),
            ],
            chapterHistory: [
                .init(
                    id: duplicateHistoryID,
                    kjvBookOrdinal: 2,
                    chapter: 1,
                    cycle: 1,
                    readAt: 9_999,
                    bookInitials: "KJV",
                    source: .autoScroll
                ),
                .init(
                    id: newHistoryID,
                    kjvBookOrdinal: 2,
                    chapter: 2,
                    cycle: 1,
                    readAt: 2_000,
                    bookInitials: "KJV",
                    source: .manual
                ),
            ],
            settings: .init(
                id: settingsID,
                autoTrackReading: true,
                autoMarkMemorized: false,
                memorizeTypeFullWords: true,
                memorizeWordVisibility: "hidden",
                memorizeErrorHeatmap: false,
                memorizeScrambleHideUsed: true,
                memorizeIncludeReference: false,
                activeCycle: 9
            )
        )
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "progress.sqlite3": progressDatabaseURL,
            ],
            contains: [.progress]
        )
        let service = AndroidDatabaseBackupService()
        let archive = try service.loadArchive(from: archiveData)

        let report = try service.apply(
            archive: archive,
            selections: [.init(category: .progress, mode: .import)],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.sections, [.init(category: .progress, mode: .import, summary: "2 readings, 2 memorized verses, 1 targets")])
        let readingSnapshot = readingStore.snapshot()
        XCTAssertEqual(Set(readingSnapshot.history.map(\.id)), Set([duplicateHistoryID, newHistoryID]))
        XCTAssertEqual(readingSnapshot.history.first { $0.id == duplicateHistoryID }?.readAt, 1000)
        XCTAssertEqual(readingSnapshot.history.first { $0.id == duplicateHistoryID }?.source, .manual)
        XCTAssertEqual(readingSnapshot.history.first { $0.id == newHistoryID }?.readAt, 2_000)
        XCTAssertEqual(readingSnapshot.settings.activeCycle, 1)
        XCTAssertFalse(readingSnapshot.settings.autoTrackReading)
        XCTAssertEqual(memorizationStore.memorizedOrdinals(bookInitials: "ESV", startOrdinal: 15, endOrdinal: 16), [15, 16])
        XCTAssertEqual(memorizationStore.targetOrdinals(bookInitials: "KJV", startOrdinal: 21, endOrdinal: 22), [21, 22])
    }

    /**
     Verifies Android progress restore rejects ordinals outside JSword's KJVA domain.

     Setup:
     - builds Android's `progress.sqlite3` schema with memorized and target rows whose ordinals
       exceed the maximum addressable KJVA ordinal derived from JSword `SystemKJVA`
     - applies the archive through the normal destructive restore workflow

     Expected result:
     - the Android Room contract validator rejects the first out-of-domain ordinal as an invalid
       `MemorizedVerse.kjvOrdinal` row value
     - no local progress snapshots are persisted after the failed restore

     Failure meaning:
     - iOS would accept progress rows Android cannot normally create and could later expand
       unbounded ordinal ranges during Android backup export or reporting.
     */
    func testAndroidDatabaseBackupRejectsProgressOrdinalsOutsideAndroidKJVADomain() throws {
        let schema = Schema([Setting.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000000801")!
        let targetID = UUID(uuidString: "15000000-0000-0000-0000-000000000802")!
        let settingsID = UUID(uuidString: "b2000000-0000-0000-0000-000000000001")!
        let progressDatabaseURL = try makeAndroidProgressDatabase(
            memorizedVerses: [
                .init(id: memorizedID, kjvOrdinal: 100_000, memorizedAt: 1_700_000_100),
            ],
            memorizationTargets: [
                .init(id: targetID, kjvOrdinalStart: 20, kjvOrdinalEnd: 100_000, createdAt: 1_700_000_200),
            ],
            chapterHistory: [],
            settings: .init(
                id: settingsID,
                autoTrackReading: false,
                autoMarkMemorized: true,
                memorizeTypeFullWords: false,
                memorizeWordVisibility: "light",
                memorizeErrorHeatmap: true,
                memorizeScrambleHideUsed: false,
                memorizeIncludeReference: true,
                activeCycle: 1
            )
        )
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "progress.sqlite3": progressDatabaseURL,
            ],
            contains: [.progress]
        )
        let service = AndroidDatabaseBackupService()
        let archive = try service.loadArchive(from: archiveData)

        XCTAssertThrowsError(
            try service.apply(
                archive: archive,
                selections: [.init(category: .progress, mode: .restore)],
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            guard let contractError = error as? RemoteSyncAndroidDatabaseContractError else {
                return XCTFail("Unexpected progress rejection error: \(String(reflecting: error))")
            }
            XCTAssertEqual(
                contractError,
                .invalidRowValue(table: "MemorizedVerse", column: "kjvOrdinal")
            )
        }
        XCTAssertNil(settingsStore.getString(ReadingProgressStore.settingsKey))
        XCTAssertNil(settingsStore.getString(MemorizationProgressStore.settingsKey))
    }

    /**
     Verifies Android backup loader failures for malformed archive inputs.

     Setup:
     - passes bytes that are not ZIP-shaped into the Android backup loader
     - builds one ZIP whose bookmark entry is not a SQLite database

     Expected result:
     - malformed ZIP inputs surface a clean user-facing archive reason
     - invalid SQLite entries fail before section selection or restore can start

     Failure meaning:
     - iOS would allow ambiguous or corrupt Android backup files into a destructive restore path.
     */
    func testAndroidDatabaseBackupRejectsMalformedArchiveAndInvalidSQLite() throws {
        let service = AndroidDatabaseBackupService()
        XCTAssertThrowsError(try service.loadArchive(from: Data("not zip".utf8))) { error in
            XCTAssertEqual(
                error as? AndroidDatabaseBackupError,
                .invalidArchive("The file is not a ZIP archive or its central directory is missing.")
            )
        }

        let invalidSQLiteArchive = try makeAndroidDatabaseBackupArchiveData(
            rawDatabaseDataByName: [
                "bookmarks.sqlite3": Data("not sqlite".utf8),
            ],
            contains: [.bookmarks]
        )

        XCTAssertThrowsError(try service.loadArchive(from: invalidSQLiteArchive)) { error in
            XCTAssertEqual(error as? AndroidDatabaseBackupError, .invalidSQLiteDatabase("bookmarks.sqlite3"))
        }
    }

    /**
     Verifies that Android backup restore rejects duplicate ZIP member paths before selecting
     manifest or database payloads.

     Setup:
     - builds a stored ZIP fixture with two central-directory entries named
       `AndBibleBackupManifest.json`

     Expected result:
     - backup loading fails with a deterministic invalid-archive reason before manifest decoding or
       SQLite staging begins

     Failure meaning:
     - iOS could accept an ambiguous Android backup where a later duplicate member silently replaces
       the manifest or database bytes that were read earlier.
     */
    func testAndroidDatabaseBackupRejectsDuplicateArchiveEntries() throws {
        let service = AndroidDatabaseBackupService()
        let manifestData = Data(#"{"backupType":"DB_BACKUP","manifestVersion":1,"contains":[]}"#.utf8)
        let duplicateManifestArchive = try makeStoredZip(entries: [
            ("AndBibleBackupManifest.json", manifestData),
            ("AndBibleBackupManifest.json", manifestData),
        ])

        XCTAssertThrowsError(try service.loadArchive(from: duplicateManifestArchive)) { error in
            XCTAssertEqual(
                error as? AndroidDatabaseBackupError,
                .invalidArchive("ZIP archive contains duplicate entry AndBibleBackupManifest.json.")
            )
        }
    }

    /**
     Verifies fail-closed ZIP parsing for malformed central-directory metadata.

     Setup:
     - builds a valid Android-style stored ZIP fixture
     - corrupts the end-of-central-directory size so declared central-directory bounds no longer
       contain the declared entry
     - corrupts a central-directory filename to invalid UTF-8 while leaving the local header intact
     - corrupts an end-of-central-directory entry count to ZIP64's sentinel value without adding
       the required ZIP64 locator and end record

     Expected result:
     - central-directory size mismatches fail before the reader walks into bytes outside the
       declared directory
     - invalid central-directory names fail as malformed ZIP data rather than being silently skipped
     - ZIP64 sentinels require the canonical locator and end record instead of being interpreted as
       classic metadata

     Failure meaning:
     - iOS could treat corrupted Android backup archives as incomplete but valid inputs, producing
       misleading backup errors or hiding required entries.
     */
    func testZipArchiveReaderRejectsMalformedCentralDirectoryBoundsAndNames() throws {
        let archive = try makeStoredZip(entries: [
            ("AndBibleBackupManifest.json", Data("{}".utf8)),
        ])

        var invalidSizeArchive = archive
        let sizeRecordOffset = try endOfCentralDirectoryOffset(in: invalidSizeArchive)
        replaceUInt32(0, at: sizeRecordOffset + 12, in: &invalidSizeArchive)

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: invalidSizeArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("Central-directory entry count is inconsistent")
            )
        }

        var invalidNameArchive = archive
        let nameRecordOffset = try endOfCentralDirectoryOffset(in: invalidNameArchive)
        let centralDirectoryOffset = Int(readUInt32(invalidNameArchive, at: nameRecordOffset + 16))
        invalidNameArchive[centralDirectoryOffset + 46] = 0xff

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: invalidNameArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("ZIP entry name is empty or not UTF-8")
            )
        }

        var zip64EntryCountArchive = archive
        let zip64RecordOffset = try endOfCentralDirectoryOffset(in: zip64EntryCountArchive)
        replaceUInt16(UInt16.max, at: zip64RecordOffset + 10, in: &zip64EntryCountArchive)

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: zip64EntryCountArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("ZIP64 locator is missing or describes multiple disks")
            )
        }
    }

    /**
     Verifies fail-closed ZIP parsing for spanned-archive end records.

     Setup:
     - builds a valid single-disk stored ZIP fixture
     - mutates the end-of-central-directory disk number and per-disk entry count fields

     Expected result:
     - the reader rejects the archive before using central-directory offsets or entry counts

     Failure meaning:
     - iOS could parse a multi-disk or inconsistent ZIP as though it were the single-disk Android
       backup shape, which would make offsets and payload selection unreliable.
     */
    func testZipArchiveReaderRejectsMultiDiskEndRecords() throws {
        let archive = try makeStoredZip(entries: [
            ("AndBibleBackupManifest.json", Data("{}".utf8)),
        ])

        var nonZeroDiskArchive = archive
        let nonZeroDiskEndRecordOffset = try endOfCentralDirectoryOffset(in: nonZeroDiskArchive)
        replaceUInt16(1, at: nonZeroDiskEndRecordOffset + 4, in: &nonZeroDiskArchive)

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: nonZeroDiskArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("Multi-disk ZIP archives are not supported")
            )
        }

        var mismatchedEntryCountArchive = archive
        let mismatchedEntryCountEndRecordOffset = try endOfCentralDirectoryOffset(in: mismatchedEntryCountArchive)
        replaceUInt16(0, at: mismatchedEntryCountEndRecordOffset + 8, in: &mismatchedEntryCountArchive)

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: mismatchedEntryCountArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("Multi-disk ZIP archives are not supported")
            )
        }
    }

    /**
     Verifies oversized central declarations cannot bypass local-header boundary validation.

     Setup:
     - builds small ZIP fixtures and rewrites only central-directory sizes to oversized values
     - keeps local headers and payloads unchanged so the declarations are contradictory

     Expected result:
     - a single contradictory declaration fails before extraction
     - multiple contradictory declarations fail at the first local/central mismatch
     - Android backup service error mapping preserves the exact structural reason

     Failure meaning:
     - iOS could trust attacker-controlled central sizes that do not describe the local payload.
     */
    func testZipArchiveReaderRejectsOversizedDeclaredPayloadsBeforeExtraction() throws {
        var oversizedEntryArchive = try makeStoredZip(entries: [
            ("db/bookmarks.sqlite3", Data([0x01])),
        ])
        try replaceCentralDirectorySizes(
            compressedSize: UInt32(300 * 1024 * 1024),
            uncompressedSize: UInt32(300 * 1024 * 1024),
            for: "db/bookmarks.sqlite3",
            in: &oversizedEntryArchive
        )

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: oversizedEntryArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("ZIP local and central entry sizes differ")
            )
        }

        var oversizedTotalArchive = try makeStoredZip(entries: [
            ("db/bookmarks.sqlite3", Data([0x01])),
            ("db/workspaces.sqlite3", Data([0x02])),
            ("db/mydocuments.sqlite3", Data([0x03])),
        ])
        for entryName in ["db/bookmarks.sqlite3", "db/workspaces.sqlite3", "db/mydocuments.sqlite3"] {
            try replaceCentralDirectorySizes(
                compressedSize: UInt32(200 * 1024 * 1024),
                uncompressedSize: UInt32(200 * 1024 * 1024),
                for: entryName,
                in: &oversizedTotalArchive
            )
        }

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: oversizedTotalArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("ZIP local and central entry sizes differ")
            )
        }

        let service = AndroidDatabaseBackupService()
        XCTAssertThrowsError(try service.loadArchive(from: oversizedEntryArchive)) { error in
            XCTAssertEqual(
                error as? AndroidDatabaseBackupError,
                .invalidArchive("ZIP local and central entry sizes differ")
            )
        }
    }

    /**
     Verifies file-backed ZIP metadata scanning does not inherit the eager reader's memory cap.

     Setup:
     - creates a sparse Android-shaped ZIP file with one stored entry declaring a 691 MiB payload
     - scans only central-directory and local-header metadata from the file URL

     Expected result:
     - the file-backed reader returns the entry metadata without trying to allocate or copy payload
       bytes
     - the declared size remains visible to callers for later streaming extraction

     Failure meaning:
     - iOS restore would continue rejecting valid large Android backups before it even reaches
       SQLite validation, preserving an iOS-only size policy Android does not impose.
     */
    func testZipArchiveReaderScansFileBackedEntriesAboveEagerLimitWithoutMaterializingPayload() throws {
        let payloadByteCount = UInt32(691 * 1024 * 1024)
        let archiveURL = try makeSparseStoredZipFile(
            entryName: "db/bookmarks.sqlite3",
            declaredPayloadByteCount: payloadByteCount
        )

        let entries = try ZipArchiveReader.fileEntries(inArchiveAt: archiveURL)

        XCTAssertEqual(entries.map(\.name), ["db/bookmarks.sqlite3"])
        XCTAssertEqual(entries.first?.compressedSize, UInt64(payloadByteCount))
        XCTAssertEqual(entries.first?.uncompressedSize, UInt64(payloadByteCount))
    }

    /**
     Verifies fail-closed ZIP parsing when central-directory sizes do not match materialized data.

     Setup:
     - mutates a stored entry so compressed and uncompressed size declarations disagree
     - mutates a deflated entry so inflated bytes are smaller than the central-directory declaration

     Expected result:
     - stored entries require identical compressed and uncompressed sizes
     - deflated entries require actual inflated byte count to match declared uncompressed size

     Failure meaning:
     - ZIP bomb accounting could be bypassed, or iOS could accept truncated Android backup payloads
       as valid import data.
     */
    func testZipArchiveReaderRejectsInconsistentDeclaredPayloadSizes() throws {
        var storedMismatchArchive = try makeStoredZip(entries: [
            ("db/bookmarks.sqlite3", Data([0x01, 0x02, 0x03])),
        ])
        try replaceZIPEntrySizesEverywhere(
            compressedSize: 3,
            uncompressedSize: 2,
            for: "db/bookmarks.sqlite3",
            in: &storedMismatchArchive
        )

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: storedMismatchArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("Stored ZIP entry size metadata is inconsistent")
            )
        }

        let payload = Data("deflated backup payload".utf8)
        let compressedPayload = Data([
            75, 73, 77, 203, 73, 44, 73, 77, 81, 72, 74, 76, 206,
            46, 45, 80, 40, 72, 172, 204, 201, 79, 76, 1, 0,
        ])
        var deflatedMismatchArchive = try makeDeflatedDescriptorZip(
            name: "db/bookmarks.sqlite3",
            compressedData: compressedPayload,
            uncompressedData: payload
        )
        try replaceZIPEntrySizesEverywhere(
            compressedSize: UInt32(compressedPayload.count),
            uncompressedSize: UInt32(payload.count + 1),
            for: "db/bookmarks.sqlite3",
            in: &deflatedMismatchArchive
        )

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: deflatedMismatchArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("Deflated ZIP entry size metadata is inconsistent")
            )
        }
    }

    /**
     Verifies Android-style deflated ZIP entries whose local headers use data descriptors.

     Setup:
     - builds one ZIP entry with compression method 8
     - writes zero sizes in the local file header and the real sizes in the central directory
     - appends a data descriptor after the compressed payload, matching Android `ZipOutputStream`
       archives that cannot know sizes before compression finishes

     Expected result:
     - the reader uses central-directory metadata to locate and inflate the entry payload

     Failure meaning:
     - iOS would reject valid Android `.abdb.zip` backups that contain deflated entries with data
       descriptors instead of local-header sizes.
     */
    func testZipArchiveReaderInflatesDescriptorBackedDeflatedEntries() throws {
        let payload = Data("deflated backup payload".utf8)
        let compressedPayload = Data([
            75, 73, 77, 203, 73, 44, 73, 77, 81, 72, 74, 76, 206,
            46, 45, 80, 40, 72, 172, 204, 201, 79, 76, 1, 0,
        ])
        let archive = try makeDeflatedDescriptorZip(
            name: "db/bookmarks.sqlite3",
            compressedData: compressedPayload,
            uncompressedData: payload
        )

        let entries = try ZipArchiveReader.entries(in: archive)

        XCTAssertEqual(entries, [.init(name: "db/bookmarks.sqlite3", data: payload)])
    }

    /**
     Verifies file-backed deflate extraction continues when an input chunk exactly fills the
     inflater output buffer.

     Setup:
     - builds a valid Android-style ZIP entry with data-descriptor sizes
     - crafts the raw deflate payload so zlib consumes one 64 KiB input chunk while producing
       exactly one 64 KiB output chunk before the stream's final block arrives
     - extracts through `ZipArchiveReader.data(for:inArchiveAt:)`, matching file-backed restore

     Expected result:
     - extraction reads the next input chunk instead of calling zlib again with zero input
     - the restored payload matches the declared uncompressed bytes

     Failure meaning:
     - iOS rejects valid large Android ZIP entries with `decompressionFailed` when a stream boundary
       lands on the file-backed inflater's chunk size.
     */
    func testZipArchiveReaderStreamsDeflatedEntryAcrossFullOutputChunkBoundary() throws {
        let payload = Data(repeating: 0x41, count: 65_536)
        let archiveData = try makeDeflatedDescriptorZip(
            name: "db/bookmarks.sqlite3",
            compressedData: makeBoundaryFillingRawDeflateData(),
            uncompressedData: payload
        )
        let archiveURL = try writeTemporaryAndroidBackupArchive(
            archiveData,
            suffix: AndroidDatabaseBackupService.databaseBackupSuffix
        )
        let entry = try XCTUnwrap(ZipArchiveReader.fileEntries(inArchiveAt: archiveURL).first)

        let restoredData = try ZipArchiveReader.data(
            for: entry,
            inArchiveAt: archiveURL,
            maximumByteCount: payload.count
        )

        XCTAssertEqual(restoredData, payload)
    }

    /**
     Verifies that newer Android database versions are visible but cannot be applied.

     Setup:
     - builds a bookmark database whose SQLite `user_version` exceeds the supported Android schema

     Expected result:
     - the archive loads so the user can see the section
     - the section is marked unsupported by version and apply refuses it

     Failure meaning:
     - iOS would either hide actionable compatibility information or risk restoring a schema it
       cannot safely decode.
     */
    func testAndroidDatabaseBackupBlocksUnsupportedDatabaseVersion() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let bookmarkDatabaseURL = try makeAndroidBookmarksDatabase(labels: [])
        try setSQLiteUserVersion(99, at: bookmarkDatabaseURL)
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "bookmarks.sqlite3": bookmarkDatabaseURL,
            ],
            contains: [.bookmarks]
        )
        let service = AndroidDatabaseBackupService()
        let archive = try service.loadArchive(from: archiveData)

        XCTAssertEqual(
            archive.sections.first?.support,
            .unsupportedVersion(version: 99, supported: 12)
        )
        XCTAssertThrowsError(
            try service.apply(
                archive: archive,
                selections: [.init(category: .bookmarks, mode: .restore)],
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? AndroidDatabaseBackupError,
                .unsupportedSelectedSection(.bookmarks, "Requires database version 99; this app supports up to 12.")
            )
        }
    }

    /**
     Verifies supported preserved Android databases still obey Android schema version gates.

     Setup:
     - builds an Android AI Settings database with a `user_version` newer than this build supports
     - loads it through the manual database backup parser

     Expected result:
     - the archive still exposes the AI Settings section
     - the section is blocked by version, not hidden or treated as an unsupported category

     Failure meaning:
     - iOS could accept an Android-owned database that Android itself would consider newer than the
       local restore implementation understands.
     */
    func testAndroidDatabaseBackupPreservedCategoriesObeyVersionGate() throws {
        let settingsDatabaseURL = try makeEmptySQLiteDatabase(userVersion: 99)
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "ai_settings.sqlite3": settingsDatabaseURL,
            ],
            contains: [.aiSettings]
        )

        let archive = try AndroidDatabaseBackupService().loadArchive(from: archiveData)

        XCTAssertEqual(
            archive.sections.first { $0.category == .aiSettings }?.support,
            .unsupportedVersion(version: 99, supported: 22)
        )
    }

    private struct AndroidCustomRepositoryFixture {
        let name: String
        let description: String
        let type: String
        let host: String
        let catalogDirectory: String
        let packageDirectory: String
        let manifestURL: String?
    }

    private struct AndroidMemorizedVerseFixture {
        let id: UUID
        let kjvOrdinal: Int
        let memorizedAt: Int64
    }

    private struct AndroidMemorizationTargetFixture {
        let id: UUID
        let kjvOrdinalStart: Int
        let kjvOrdinalEnd: Int
        let createdAt: Int64
    }

    private struct AndroidChapterReadHistoryFixture {
        let id: UUID
        let kjvBookOrdinal: Int
        let chapter: Int
        let cycle: Int
        let readAt: Int64
        let bookInitials: String
        let source: ReadingProgressSource
    }

    private struct AndroidGlobalProgressSettingsFixture {
        let id: UUID
        let autoTrackReading: Bool
        let autoMarkMemorized: Bool
        let memorizeTypeFullWords: Bool
        let memorizeWordVisibility: String
        let memorizeErrorHeatmap: Bool
        let memorizeScrambleHideUsed: Bool
        let memorizeIncludeReference: Bool
        let activeCycle: Int
    }

    /**
     Builds Android's split Settings database shape for backup restore tests.

     - Parameters:
       - booleanSettings: Rows for Android's `BooleanSetting` table.
       - longSettings: Rows for Android's `LongSetting` table.
       - stringSettings: Rows for Android's `StringSetting` table.
       - doubleSettings: Rows for Android's `DoubleSetting` table.
     - Returns: Temporary SQLite database URL with `user_version = 1`.
     - Side effects: writes a temporary SQLite file under the process temporary directory.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when fixture
       creation, statement preparation, binding, or stepping fails.
     */
    private func makeAndroidSettingsDatabase(
        booleanSettings: [String: Bool] = [:],
        longSettings: [String: Int64] = [:],
        stringSettings: [String: String] = [:],
        doubleSettings: [String: Double] = [:]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-backup-settings-\(UUID().uuidString).sqlite3")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        defer { sqlite3_close(database) }

        try executeSQLite(
            """
            CREATE TABLE BooleanSetting (`key` TEXT NOT NULL PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE LongSetting (`key` TEXT NOT NULL PRIMARY KEY, value INTEGER NOT NULL);
            CREATE TABLE StringSetting (`key` TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE DoubleSetting (`key` TEXT NOT NULL PRIMARY KEY, value REAL NOT NULL);
            """,
            on: database,
            fileName: url.lastPathComponent
        )

        for row in booleanSettings.sorted(by: { $0.key < $1.key }) {
            try insertSQLiteKeyValue(
                tableName: "BooleanSetting",
                key: row.key,
                bindValue: { statement in sqlite3_bind_int(statement, 2, row.value ? 1 : 0) },
                on: database,
                fileName: url.lastPathComponent
            )
        }
        for row in longSettings.sorted(by: { $0.key < $1.key }) {
            try insertSQLiteKeyValue(
                tableName: "LongSetting",
                key: row.key,
                bindValue: { statement in sqlite3_bind_int64(statement, 2, row.value) },
                on: database,
                fileName: url.lastPathComponent
            )
        }
        for row in stringSettings.sorted(by: { $0.key < $1.key }) {
            try insertSQLiteKeyValue(
                tableName: "StringSetting",
                key: row.key,
                bindValue: { statement in self.bindOptionalText(row.value, to: statement, index: 2) },
                on: database,
                fileName: url.lastPathComponent
            )
        }
        for row in doubleSettings.sorted(by: { $0.key < $1.key }) {
            try insertSQLiteKeyValue(
                tableName: "DoubleSetting",
                key: row.key,
                bindValue: { statement in sqlite3_bind_double(statement, 2, row.value) },
                on: database,
                fileName: url.lastPathComponent
            )
        }

        try setSQLiteUserVersion(1, on: database, fileName: url.lastPathComponent)
        return url
    }

    /**
     Builds Android's Repositories database shape for backup restore tests.

     - Parameter customRepositories: Android `CustomRepository` rows to persist.
     - Returns: Temporary SQLite database URL with `user_version = 1`.
     - Side effects: writes a temporary SQLite file under the process temporary directory.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when fixture
       creation or row insertion fails.
     */
    private func makeAndroidRepositoriesDatabase(
        customRepositories: [AndroidCustomRepositoryFixture]
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-backup-repositories-\(UUID().uuidString).sqlite3")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        defer { sqlite3_close(database) }

        try executeSQLite(
            """
            CREATE TABLE CustomRepository (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL,
                description TEXT NOT NULL,
                type TEXT NOT NULL,
                host TEXT NOT NULL,
                catalogDirectory TEXT NOT NULL,
                packageDirectory TEXT NOT NULL,
                manifestUrl TEXT
            );
            CREATE UNIQUE INDEX index_CustomRepository_name ON CustomRepository (name);
            CREATE TABLE SwordDocumentInfo (
                initials TEXT NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                abbreviation TEXT NOT NULL,
                language TEXT NOT NULL,
                repository TEXT NOT NULL,
                cipherKey TEXT
            );
            """,
            on: database,
            fileName: url.lastPathComponent
        )

        let sql = """
        INSERT INTO CustomRepository (
            name,
            description,
            type,
            host,
            catalogDirectory,
            packageDirectory,
            manifestUrl
        ) VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        for repository in customRepositories {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
            }
            bindOptionalText(repository.name, to: statement, index: 1)
            bindOptionalText(repository.description, to: statement, index: 2)
            bindOptionalText(repository.type, to: statement, index: 3)
            bindOptionalText(repository.host, to: statement, index: 4)
            bindOptionalText(repository.catalogDirectory, to: statement, index: 5)
            bindOptionalText(repository.packageDirectory, to: statement, index: 6)
            bindOptionalText(repository.manifestURL, to: statement, index: 7)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        try setSQLiteUserVersion(1, on: database, fileName: url.lastPathComponent)
        return url
    }

    /**
     Builds Android's Progress database shape for backup restore/import tests.

     - Parameters:
       - memorizedVerses: Android `MemorizedVerse` rows keyed by KJV ordinal.
       - memorizationTargets: Android `MemorizationTarget` rows keyed by UUID.
       - chapterHistory: Android `ChapterReadHistory` rows keyed by UUID.
       - settings: Android singleton `GlobalReadingProgressSettings` row.
     - Returns: Temporary SQLite database URL with `user_version = 9`.
     - Side effects: writes a temporary SQLite file under the process temporary directory.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when fixture
       creation or row insertion fails.
     */
    private func makeAndroidProgressDatabase(
        memorizedVerses: [AndroidMemorizedVerseFixture],
        memorizationTargets: [AndroidMemorizationTargetFixture],
        chapterHistory: [AndroidChapterReadHistoryFixture],
        settings: AndroidGlobalProgressSettingsFixture
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-backup-progress-\(UUID().uuidString).sqlite3")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        defer { sqlite3_close(database) }

        try executeSQLite(
            """
            CREATE TABLE MemorizedVerse (
                id BLOB NOT NULL PRIMARY KEY,
                kjvOrdinal INTEGER NOT NULL,
                memorizedAt INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX index_MemorizedVerse_kjvOrdinal ON MemorizedVerse (kjvOrdinal);
            CREATE TABLE MemorizationTarget (
                id BLOB NOT NULL PRIMARY KEY,
                kjvOrdinalStart INTEGER NOT NULL,
                kjvOrdinalEnd INTEGER NOT NULL,
                createdAt INTEGER NOT NULL
            );
            CREATE TABLE ChapterReadHistory (
                id BLOB NOT NULL PRIMARY KEY,
                kjvBookOrdinal INTEGER NOT NULL,
                chapter INTEGER NOT NULL,
                cycle INTEGER NOT NULL,
                readAt INTEGER NOT NULL,
                bookInitials TEXT NOT NULL,
                source TEXT NOT NULL DEFAULT 'MANUAL'
            );
            CREATE INDEX index_ChapterReadHistory_kjvBookOrdinal_chapter_cycle
                ON ChapterReadHistory (kjvBookOrdinal, chapter, cycle);
            CREATE TABLE GlobalReadingProgressSettings (
                id BLOB NOT NULL PRIMARY KEY,
                autoTrackReading INTEGER NOT NULL DEFAULT 0,
                autoMarkMemorized INTEGER NOT NULL DEFAULT 1,
                memorizeTypeFullWords INTEGER NOT NULL DEFAULT 0,
                memorizeWordVisibility TEXT NOT NULL DEFAULT 'light',
                memorizeErrorHeatmap INTEGER NOT NULL DEFAULT 1,
                memorizeScrambleHideUsed INTEGER NOT NULL DEFAULT 0,
                memorizeIncludeReference INTEGER NOT NULL DEFAULT 1,
                activeCycle INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE LogEntry (
                tableName TEXT NOT NULL,
                entityId1 BLOB NOT NULL,
                entityId2 BLOB NOT NULL,
                type TEXT NOT NULL,
                lastUpdated INTEGER NOT NULL DEFAULT 0,
                sourceDevice TEXT NOT NULL,
                PRIMARY KEY(tableName, entityId1, entityId2)
            );
            CREATE INDEX index_LogEntry_lastUpdated ON LogEntry (lastUpdated);
            CREATE INDEX index_LogEntry_sourceDevice ON LogEntry (sourceDevice);
            CREATE TABLE SyncConfiguration (
                keyName TEXT NOT NULL PRIMARY KEY,
                stringValue TEXT,
                longValue INTEGER,
                booleanValue INTEGER
            );
            CREATE TABLE SyncStatus (
                sourceDevice TEXT NOT NULL,
                patchNumber INTEGER NOT NULL,
                sizeBytes INTEGER NOT NULL,
                appliedDate INTEGER NOT NULL,
                PRIMARY KEY(sourceDevice, patchNumber)
            );
            CREATE TABLE room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT);
            INSERT OR REPLACE INTO room_master_table (id, identity_hash)
            VALUES (42, '76330d8367020840e56e6b92d921522a');
            """,
            on: database,
            fileName: url.lastPathComponent
        )

        for verse in memorizedVerses {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO MemorizedVerse (id, kjvOrdinal, memorizedAt) VALUES (?, ?, ?);",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
            }
            bindUUIDBlob(verse.id, to: statement, index: 1)
            sqlite3_bind_int(statement, 2, Int32(verse.kjvOrdinal))
            sqlite3_bind_int64(statement, 3, verse.memorizedAt)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for target in memorizationTargets {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO MemorizationTarget (id, kjvOrdinalStart, kjvOrdinalEnd, createdAt) VALUES (?, ?, ?, ?);",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
            }
            bindUUIDBlob(target.id, to: statement, index: 1)
            sqlite3_bind_int(statement, 2, Int32(target.kjvOrdinalStart))
            sqlite3_bind_int(statement, 3, Int32(target.kjvOrdinalEnd))
            sqlite3_bind_int64(statement, 4, target.createdAt)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for history in chapterHistory {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                """
                INSERT INTO ChapterReadHistory (
                    id,
                    kjvBookOrdinal,
                    chapter,
                    cycle,
                    readAt,
                    bookInitials,
                    source
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
            }
            bindUUIDBlob(history.id, to: statement, index: 1)
            sqlite3_bind_int(statement, 2, Int32(history.kjvBookOrdinal))
            sqlite3_bind_int(statement, 3, Int32(history.chapter))
            sqlite3_bind_int(statement, 4, Int32(history.cycle))
            sqlite3_bind_int64(statement, 5, history.readAt)
            bindOptionalText(history.bookInitials, to: statement, index: 6)
            bindOptionalText(history.source.rawValue, to: statement, index: 7)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            """
            INSERT INTO GlobalReadingProgressSettings (
                id,
                autoTrackReading,
                autoMarkMemorized,
                memorizeTypeFullWords,
                memorizeWordVisibility,
                memorizeErrorHeatmap,
                memorizeScrambleHideUsed,
                memorizeIncludeReference,
                activeCycle
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        bindUUIDBlob(settings.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, settings.autoTrackReading ? 1 : 0)
        sqlite3_bind_int(statement, 3, settings.autoMarkMemorized ? 1 : 0)
        sqlite3_bind_int(statement, 4, settings.memorizeTypeFullWords ? 1 : 0)
        bindOptionalText(settings.memorizeWordVisibility, to: statement, index: 5)
        sqlite3_bind_int(statement, 6, settings.memorizeErrorHeatmap ? 1 : 0)
        sqlite3_bind_int(statement, 7, settings.memorizeScrambleHideUsed ? 1 : 0)
        sqlite3_bind_int(statement, 8, settings.memorizeIncludeReference ? 1 : 0)
        sqlite3_bind_int(statement, 9, Int32(settings.activeCycle))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)

        try setSQLiteUserVersion(9, on: database, fileName: url.lastPathComponent)
        return url
    }

    /**
     Creates an isolated repository-source base directory for backup restore tests.

     - Returns: Existing temporary directory that callers may pass to `RepositorySourceManager`.
     - Side effects: creates the directory and records it for test teardown.
     - Failure modes: Rethrows file-system creation failures.
     */
    private func temporaryRepositorySourceBaseURL() throws -> URL {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-backup-repositories-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        temporaryPaths.append(baseURL.path)
        return baseURL
    }

    /**
     Finds the repository root containing a source-controlled path used by source-string guardrails.

     Package tests live several directories below the repository root, and their exact depth changes
     when app-host tests migrate into package targets. Walking upward keeps the guardrail stable
     without hard-coding a target-specific number of parent directories.

     - Parameter relativePath: Repo-relative path that must exist under the root.
     - Parameter filePath: Starting test file path for the upward search.
     - Returns: Directory URL for the repository root.
     - Side effects: Performs read-only filesystem existence checks.
     - Failure modes: Throws when no parent directory contains `relativePath`.
     */
    private func repositoryRoot(containing relativePath: String, from filePath: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while true {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(relativePath).path) {
                return directory
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                throw NSError(
                    domain: "AndroidDatabaseBackupTests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unable to locate repository root containing \(relativePath) from \(filePath)"
                    ]
                )
            }
            directory = parent
        }
    }

    /**
     Executes schema SQL while building Android SQLite fixtures.

     - Parameters:
       - sql: SQL batch to execute.
       - database: Open SQLite fixture connection.
       - fileName: Fixture name used for failure mapping.
     - Side effects: mutates the open SQLite fixture.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite rejects
       the batch.
     */
    private func executeSQLite(_ sql: String, on database: OpaquePointer, fileName: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
    }

    /**
     Binds a UUID using Android's 16-byte SQLite blob representation.

     - Parameters:
       - uuid: UUID value to bind.
       - statement: SQLite statement receiving the value.
       - index: One-based parameter index.
     - Side effects: Mutates the prepared SQLite statement binding state.
     - Failure modes: This helper cannot fail; SQLite reports binding/step failures later.
     */
    private func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let blob = RemoteSyncBookmarkSnapshotService.uuidBlob(uuid)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(blob.count),
                androidDatabaseBackupTestSQLiteTransient
            )
        }
    }

    /**
     Binds optional text into a SQLite fixture statement.

     - Parameters:
       - value: Optional string to bind, or nil for SQLite NULL.
       - statement: SQLite statement receiving the value.
       - index: One-based parameter index.
     - Side effects: Mutates the prepared SQLite statement binding state.
     - Failure modes: This helper cannot fail; SQLite reports binding/step failures later.
     */
    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, androidDatabaseBackupTestSQLiteTransient)
    }

    /**
     Inserts one Android settings key-value fixture row.

     - Parameters:
       - tableName: Android settings table name.
       - key: Preference key to insert.
       - bindValue: Closure that binds the table-specific value at parameter index 2.
       - database: Open SQLite fixture connection.
       - fileName: Fixture name used for failure mapping.
     - Side effects: prepares, binds, steps, and finalizes one SQLite insert statement.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite rejects
       statement preparation or stepping.
     */
    private func insertSQLiteKeyValue(
        tableName: String,
        key: String,
        bindValue: (OpaquePointer?) -> Void,
        on database: OpaquePointer,
        fileName: String
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO \(tableName) (`key`, value) VALUES (?, ?);",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        bindOptionalText(key, to: statement, index: 1)
        bindValue(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            sqlite3_finalize(statement)
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        sqlite3_finalize(statement)
    }

    /**
     Builds a one-section Android bookmark backup archive for restore/import tests.

     - Parameters:
       - labelID: Android label ID linked to every generated bookmark.
       - bookmarks: Tuples of bookmark ID, verse ordinal, and note text.
       - noteContentType: Optional Android note `TextContentType` assigned to every generated note.
     - Returns: Raw ZIP archive bytes with Android manifest and `db/bookmarks.sqlite3`.
     - Side effects: writes a temporary SQLite database through `makeAndroidBookmarksDatabase`.
     - Failure modes: Rethrows SQLite fixture and ZIP construction failures.
     */
    private func makeAndroidBookmarkOnlyBackupData(
        labelID: UUID,
        bookmarks: [(id: UUID, ordinal: Int, note: String)],
        noteContentType: String? = nil
    ) throws -> Data {
        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: labelID, name: "Prayer", colour: 8),
            ],
            bibleBookmarks: bookmarks.map {
                .init(
                    id: $0.id,
                    kjvOrdinalStart: $0.ordinal,
                    kjvOrdinalEnd: $0.ordinal,
                    ordinalStart: $0.ordinal,
                    ordinalEnd: $0.ordinal,
                    createdAt: Date(timeIntervalSince1970: 1_700_100_000 + Double($0.ordinal)),
                    primaryLabelID: labelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_200_000 + Double($0.ordinal))
                )
            },
            bibleNotes: bookmarks.map {
                .init(bookmarkID: $0.id, notes: $0.note, contentType: noteContentType)
            },
            bibleLinks: bookmarks.map {
                .init(bookmarkID: $0.id, labelID: labelID, orderNumber: $0.ordinal, indentLevel: 0, expandContent: false)
            }
        )
        try setSQLiteUserVersion(12, at: databaseURL)
        return try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "bookmarks.sqlite3": databaseURL,
            ],
            contains: [.bookmarks]
        )
    }

    /**
     Builds a raw Android database backup ZIP from SQLite database files.

     - Parameters:
       - databaseURLsByName: Database filenames, such as `bookmarks.sqlite3`, mapped to local files.
       - contains: Android manifest categories to write into `contains`.
     - Returns: Stored ZIP archive bytes.
     - Side effects: reads the supplied SQLite database files.
     - Failure modes: Rethrows file reads and ZIP construction failures.
     */
    private func makeAndroidDatabaseBackupArchiveData(
        databaseURLsByName: [String: URL],
        contains: [AndroidDatabaseBackupCategory]
    ) throws -> Data {
        let databaseData = try databaseURLsByName.mapValues { try Data(contentsOf: $0) }
        return try makeAndroidDatabaseBackupArchiveData(
            rawDatabaseDataByName: databaseData,
            containsRawValues: contains.map(\.rawValue)
        )
    }

    /**
     Builds a raw Android database backup ZIP from SQLite database files and raw manifest category names.

     - Parameters:
       - databaseURLsByName: Database filenames, such as `bookmarks.sqlite3`, mapped to local files.
       - containsRawValues: Raw Android manifest category names to write into `contains`.
     - Returns: Stored ZIP archive bytes.
     - Side effects: reads the supplied SQLite database files.
     - Failure modes: Rethrows file reads and ZIP construction failures.
     */
    private func makeAndroidDatabaseBackupArchiveData(
        databaseURLsByName: [String: URL],
        containsRawValues: [String]
    ) throws -> Data {
        let databaseData = try databaseURLsByName.mapValues { try Data(contentsOf: $0) }
        return try makeAndroidDatabaseBackupArchiveData(
            rawDatabaseDataByName: databaseData,
            containsRawValues: containsRawValues
        )
    }

    /**
     Builds a raw Android database backup ZIP from already-materialized database payloads.

     - Parameters:
       - rawDatabaseDataByName: Database filenames mapped to entry bytes.
       - contains: Android manifest categories to write into `contains`.
     - Returns: Stored ZIP archive bytes.
     - Side effects: none.
     - Failure modes: Rethrows JSON manifest encoding or ZIP construction failures.
     */
    private func makeAndroidDatabaseBackupArchiveData(
        rawDatabaseDataByName: [String: Data],
        contains: [AndroidDatabaseBackupCategory]
    ) throws -> Data {
        return try makeAndroidDatabaseBackupArchiveData(
            rawDatabaseDataByName: rawDatabaseDataByName,
            containsRawValues: contains.map(\.rawValue)
        )
    }

    /**
     Builds a raw Android database backup ZIP from already-materialized payloads and raw category names.

     - Parameters:
       - rawDatabaseDataByName: Database filenames mapped to entry bytes.
       - containsRawValues: Raw Android manifest category names to write into `contains`.
     - Returns: Stored ZIP archive bytes.
     - Side effects: none.
     - Failure modes: Rethrows JSON manifest encoding or ZIP construction failures.
     */
    private func makeAndroidDatabaseBackupArchiveData(
        rawDatabaseDataByName: [String: Data],
        containsRawValues: [String]
    ) throws -> Data {
        let manifest: [String: Any] = [
            "backupType": "DB_BACKUP",
            "contains": containsRawValues,
            "manifestVersion": 1,
            "andBibleVersion": 99_999,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let databaseEntries = rawDatabaseDataByName
            .sorted { $0.key < $1.key }
            .map { ("db/\($0.key)", $0.value) }
        return try makeStoredZip(entries: [("AndBibleBackupManifest.json", manifestData)] + databaseEntries)
    }

    /**
     Builds an in-memory model container containing every model needed by supported backup export categories.

     Android database backup export reads bookmarks, reading plans, workspaces, My Documents,
     settings, repositories, and progress in one pass. This fixture keeps that graph in one
     container so the export test exercises the same `ModelContext` shape the Settings screen
     supplies.

     - Returns: In-memory SwiftData container for supported Android database backup export models.
     - Side effects: none.
     - Failure modes: Rethrows SwiftData container initialization failures.
     */
    private func makeAndroidDatabaseBackupExportModelContainer() throws -> ModelContainer {
        let schema = Schema([
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
            ReadingPlan.self,
            ReadingPlanDay.self,
            ReadingPlanDefinitionPublicationState.self,
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
            MyDocument.self,
            MyDocumentPage.self,
            MyDocumentPageContent.self,
            AiPageCacheEntry.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /**
     Writes exported ZIP database entries to temporary files for SQLite assertions.

     - Parameter entriesByName: Exported ZIP entries keyed by archive path.
     - Returns: Temporary SQLite file URLs keyed by Android database filename.
     - Side effects: writes temporary SQLite files under the process temporary directory.
     - Failure modes: Throws when an expected database entry is absent or cannot be written.
     */
    private func materializeExportedDatabases(entriesByName: [String: Data]) throws -> [String: URL] {
        let databaseNames = [
            "bookmarks.sqlite3",
            "readingplans.sqlite3",
            "workspaces.sqlite3",
            "repositories.sqlite3",
            "settings.sqlite3",
            "mydocuments.sqlite3",
            "progress.sqlite3",
        ]
        var urlsByName: [String: URL] = [:]
        for databaseName in databaseNames {
            let data = try XCTUnwrap(entriesByName["db/\(databaseName)"])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("android-backup-export-\(UUID().uuidString)-\(databaseName)")
            try data.write(to: url, options: .atomic)
            urlsByName[databaseName] = url
        }
        return urlsByName
    }

    /**
     Reads one integer value from a materialized SQLite database.

     The export test uses this to prove generated databases contain real Android-shaped table
     content, not only valid SQLite headers and `user_version` pragmas.

     - Parameters:
       - sql: Single-row, single-column SQL statement returning an integer.
       - url: SQLite database URL to inspect.
     - Returns: First column from the first result row as an integer.
     - Side effects: opens the database read-only and finalizes the prepared statement.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite cannot
       open, prepare, or step the statement.
     */
    private func readSQLiteInteger(_ sql: String, at url: URL) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            if let database {
                sqlite3_close(database)
            }
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    /**
     Creates a temporary SQLite database with only a `user_version` marker.

     Unsupported Android backup sections are validated for SQLite shape and version before iOS
     explains that no safe mapper exists, so these tests do not need Android's full Settings schema.

     - Parameter userVersion: SQLite `PRAGMA user_version` to write.
     - Returns: Temporary SQLite database URL.
     - Side effects: writes a temporary file under the process temporary directory.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite setup fails.
     */
    private func makeEmptySQLiteDatabase(userVersion: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-backup-empty-\(UUID().uuidString).sqlite3")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE Placeholder (id INTEGER PRIMARY KEY);", nil, nil, nil) == SQLITE_OK else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        try setSQLiteUserVersion(userVersion, on: database, fileName: url.lastPathComponent)
        return url
    }

    /**
     Sets SQLite `user_version` for a temporary Android database fixture.

     - Parameters:
       - userVersion: Version number to write.
       - url: SQLite database URL.
     - Side effects: opens and mutates the database file.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite rejects
       the file or pragma.
     */
    private func setSQLiteUserVersion(_ userVersion: Int, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        defer { sqlite3_close(database) }
        try setSQLiteUserVersion(userVersion, on: database, fileName: url.lastPathComponent)
    }

    /**
     Writes SQLite `user_version` on an open fixture connection.

     - Parameters:
       - userVersion: Version number to write.
       - database: Open SQLite connection.
       - fileName: Name used in thrown validation errors.
     - Side effects: mutates the open SQLite database.
     - Failure modes: Throws when SQLite rejects the pragma.
     */
    private func setSQLiteUserVersion(_ userVersion: Int, on database: OpaquePointer, fileName: String) throws {
        guard sqlite3_exec(database, "PRAGMA user_version = \(userVersion);", nil, nil, nil) == SQLITE_OK else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
    }

    /**
     Builds a minimal stored ZIP archive understood by `ZipArchiveReader`.

     The test helper writes central-directory metadata because Android `ZipOutputStream` archives
     rely on central-directory sizes when local headers use descriptors. Test archives use stored
     entries to keep fixtures deterministic and independent of compression libraries.

     - Parameter entries: Entry names and uncompressed payloads.
     - Returns: Raw ZIP bytes.
     - Side effects: none.
     - Failure modes: Throws when entry names or sizes exceed the non-ZIP64 limits supported by the
       production reader.
     */
    private func makeStoredZip(entries: [(name: String, data: Data)]) throws -> Data {
        var archive = Data()
        var localHeaderOffsets: [UInt32] = []
        localHeaderOffsets.reserveCapacity(entries.count)

        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8),
                  nameData.count <= Int(UInt16.max),
                  entry.data.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                throw ZipArchiveReaderError.invalidArchive("Test ZIP entry is too large")
            }
            localHeaderOffsets.append(UInt32(archive.count))
            let checksum = ArchiveCRC32.checksum(of: entry.data)
            appendUInt32(0x0403_4b50, to: &archive)
            appendUInt16(20, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(checksum, to: &archive)
            appendUInt32(UInt32(entry.data.count), to: &archive)
            appendUInt32(UInt32(entry.data.count), to: &archive)
            appendUInt16(UInt16(nameData.count), to: &archive)
            appendUInt16(0, to: &archive)
            archive.append(nameData)
            archive.append(entry.data)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        var centralDirectory = Data()
        for (index, entry) in entries.enumerated() {
            guard let nameData = entry.name.data(using: .utf8) else {
                throw ZipArchiveReaderError.invalidArchive("Test ZIP entry is missing a local header")
            }
            let checksum = ArchiveCRC32.checksum(of: entry.data)
            appendUInt32(0x0201_4b50, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(checksum, to: &centralDirectory)
            appendUInt32(UInt32(entry.data.count), to: &centralDirectory)
            appendUInt32(UInt32(entry.data.count), to: &centralDirectory)
            appendUInt16(UInt16(nameData.count), to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(0, to: &centralDirectory)
            appendUInt32(localHeaderOffsets[index], to: &centralDirectory)
            centralDirectory.append(nameData)
        }
        guard centralDirectory.count <= Int(UInt32.max), entries.count <= Int(UInt16.max) else {
            throw ZipArchiveReaderError.invalidArchive("Test ZIP central directory is too large")
        }
        archive.append(centralDirectory)
        appendUInt32(0x0605_4b50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt32(UInt32(centralDirectory.count), to: &archive)
        appendUInt32(centralDirectoryOffset, to: &archive)
        appendUInt16(0, to: &archive)
        return archive
    }

    /**
     Builds one deflated ZIP entry that uses data-descriptor sizes in the local file area.

     The production reader should rely on central-directory sizes, matching Android-created ZIPs
     whose local headers do not know the compressed size until after compression has completed.

     - Parameters:
       - name: Entry path to write into the local and central headers.
       - compressedData: Raw deflate bytes for the entry payload.
       - uncompressedData: Expected inflated payload, used only for central-directory sizing.
     - Returns: Raw ZIP bytes with one deflated entry.
     - Side effects: none.
     - Failure modes: Throws if the entry exceeds this test helper's non-ZIP64 fixture limits.
     */
    private func makeDeflatedDescriptorZip(
        name: String,
        compressedData: Data,
        uncompressedData: Data
    ) throws -> Data {
        return try makeDeflatedDescriptorZip(entries: [
            (name: name, compressedData: compressedData, uncompressedData: uncompressedData),
        ])
    }

    /**
     Builds a raw-deflated ZIP archive whose entries use data-descriptor sizes.

     Android's `ZipOutputStream` writes deflated database payloads in this shape. The helper allows
     service-level tests to cover multi-entry and file-backed restore paths without invoking shell
     zip tools or storing binary fixtures.

     - Parameter entries: Entry paths with raw deflate bytes and their expected uncompressed data.
     - Returns: Raw ZIP bytes with central-directory metadata for all entries.
     - Side effects: none.
     - Failure modes: Throws if any fixture entry exceeds this helper's non-ZIP64 limits.
     */
    private func makeDeflatedDescriptorZip(
        entries: [(name: String, compressedData: Data, uncompressedData: Data)]
    ) throws -> Data {
        guard entries.count <= Int(UInt16.max) else {
            throw ZipArchiveReaderError.invalidArchive("Test ZIP contains too many entries")
        }
        var archive = Data()
        var centralDirectory = Data()
        var localHeaderOffsets: [UInt32] = []

        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8),
                  nameData.count <= Int(UInt16.max),
                  entry.compressedData.count <= Int(UInt32.max),
                  entry.uncompressedData.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                throw ZipArchiveReaderError.invalidArchive("Test ZIP entry is too large")
            }

            localHeaderOffsets.append(UInt32(archive.count))
            appendUInt32(0x0403_4b50, to: &archive)
            appendUInt16(20, to: &archive)
            appendUInt16(0x0008, to: &archive)
            appendUInt16(8, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(0, to: &archive)
            appendUInt32(0, to: &archive)
            appendUInt32(0, to: &archive)
            appendUInt16(UInt16(nameData.count), to: &archive)
            appendUInt16(0, to: &archive)
            archive.append(nameData)
            archive.append(entry.compressedData)
            let checksum = ArchiveCRC32.checksum(of: entry.uncompressedData)
            appendUInt32(0x0807_4b50, to: &archive)
            appendUInt32(checksum, to: &archive)
            appendUInt32(UInt32(entry.compressedData.count), to: &archive)
            appendUInt32(UInt32(entry.uncompressedData.count), to: &archive)
        }

        guard archive.count <= Int(UInt32.max) else {
            throw ZipArchiveReaderError.invalidArchive("Test ZIP central directory offset is too large")
        }
        let centralDirectoryOffset = UInt32(archive.count)
        for (index, entry) in entries.enumerated() {
            guard let nameData = entry.name.data(using: .utf8) else {
                throw ZipArchiveReaderError.invalidArchive("Test ZIP entry name is malformed")
            }
            appendUInt32(0x0201_4b50, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(0x0008, to: &centralDirectory)
            appendUInt16(8, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(ArchiveCRC32.checksum(of: entry.uncompressedData), to: &centralDirectory)
            appendUInt32(UInt32(entry.compressedData.count), to: &centralDirectory)
            appendUInt32(UInt32(entry.uncompressedData.count), to: &centralDirectory)
            appendUInt16(UInt16(nameData.count), to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(0, to: &centralDirectory)
            appendUInt32(localHeaderOffsets[index], to: &centralDirectory)
            centralDirectory.append(nameData)
        }

        guard centralDirectory.count <= Int(UInt32.max) else {
            throw ZipArchiveReaderError.invalidArchive("Test ZIP central directory is too large")
        }
        archive.append(centralDirectory)
        appendUInt32(0x0605_4b50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt32(UInt32(centralDirectory.count), to: &archive)
        appendUInt32(centralDirectoryOffset, to: &archive)
        appendUInt16(0, to: &archive)
        return archive
    }

    /**
     Converts test payload bytes into the raw deflate stream used by ZIP compression method 8.

     The CLibSword bridge exposes gzip compression for tests; raw ZIP deflate is the gzip body
     without the ten-byte header and eight-byte trailer.

     - Parameter data: Uncompressed fixture payload.
     - Returns: Raw deflate bytes suitable for a ZIP deflated entry.
     - Side effects: Allocates and frees a temporary C compression buffer.
     - Failure modes: Throws when the C compressor fails or returns malformed gzip output.
     */
    private func makeRawDeflateData(_ data: Data) throws -> Data {
        let gzipData = try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw ZipArchiveReaderError.invalidArchive("Test compression failed")
            }

            var outputLength: UInt = 0
            guard let output = gzip_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &outputLength
            ) else {
                throw ZipArchiveReaderError.invalidArchive("Test compression failed")
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLength))
        }
        guard gzipData.count > 18 else {
            throw ZipArchiveReaderError.invalidArchive("Test compression failed")
        }
        return Data(gzipData.dropFirst(10).dropLast(8))
    }

    /**
     Builds a raw-deflate stream that exposes the file-backed inflater's full-output-buffer
     boundary condition.

     The stream emits empty non-final blocks before a fixed-Huffman payload block so the first
     extraction read consumes 64 KiB of compressed input and produces exactly 64 KiB of output.
     A final empty stored block follows in the next input chunk, making the stream valid while
     forcing the extractor to return to the outer read loop before invoking zlib again.

     - Returns: Valid raw deflate bytes that inflate to 65,536 ASCII `A` bytes.
     - Side effects: none.
     - Failure modes: none.
     */
    private func makeBoundaryFillingRawDeflateData() -> Data {
        var writer = DeflateBitWriter()
        for _ in 0..<13_023 {
            appendEmptyStoredDeflateBlock(final: false, to: &writer)
        }
        appendEmptyFixedHuffmanDeflateBlock(final: false, to: &writer)
        appendEmptyFixedHuffmanDeflateBlock(final: false, to: &writer)
        appendBoundaryPayloadFixedHuffmanBlock(final: false, to: &writer)
        appendEmptyStoredDeflateBlock(final: true, to: &writer)
        return writer.data()
    }

    /**
     Appends an empty stored deflate block to a bit-level fixture writer.

     - Parameters:
       - final: Whether to mark this as the stream's final block.
       - writer: Mutable deflate bit writer.
     - Side effects: Appends block header, alignment padding, and zero-length block metadata.
     - Failure modes: none.
     */
    private func appendEmptyStoredDeflateBlock(final: Bool, to writer: inout DeflateBitWriter) {
        writer.appendBit(final ? 1 : 0)
        writer.appendBit(0)
        writer.appendBit(0)
        writer.alignToByte()
        writer.appendBits(0, count: 16)
        writer.appendBits(0xffff, count: 16)
    }

    /**
     Appends an empty fixed-Huffman deflate block to a bit-level fixture writer.

     - Parameters:
       - final: Whether to mark this as the stream's final block.
       - writer: Mutable deflate bit writer.
     - Side effects: Appends a fixed-Huffman block header and end-of-block symbol.
     - Failure modes: none.
     */
    private func appendEmptyFixedHuffmanDeflateBlock(final: Bool, to writer: inout DeflateBitWriter) {
        writer.appendBit(final ? 1 : 0)
        writer.appendBit(1)
        writer.appendBit(0)
        appendFixedHuffmanSymbol(256, to: &writer)
    }

    /**
     Appends a fixed-Huffman deflate block that expands to exactly 65,536 `A` bytes.

     - Parameters:
       - final: Whether to mark this as the stream's final block.
       - writer: Mutable deflate bit writer.
     - Side effects: Appends one literal, repeat-distance pairs, and an end-of-block symbol.
     - Failure modes: none.
     */
    private func appendBoundaryPayloadFixedHuffmanBlock(final: Bool, to writer: inout DeflateBitWriter) {
        writer.appendBit(final ? 1 : 0)
        writer.appendBit(1)
        writer.appendBit(0)
        appendFixedHuffmanSymbol(65, to: &writer)
        for _ in 0..<254 {
            appendFixedHuffmanSymbol(285, to: &writer)
            writer.appendBits(0, count: 5)
        }
        appendFixedHuffmanSymbol(257, to: &writer)
        writer.appendBits(0, count: 5)
        appendFixedHuffmanSymbol(256, to: &writer)
    }

    /**
     Appends one fixed-Huffman deflate symbol using least-significant-bit wire order.

     - Parameters:
       - symbol: Deflate literal/length/end symbol in the fixed-Huffman alphabet.
       - writer: Mutable deflate bit writer.
     - Side effects: Appends the symbol code bits.
     - Failure modes: none.
     */
    private func appendFixedHuffmanSymbol(_ symbol: Int, to writer: inout DeflateBitWriter) {
        let code = fixedHuffmanCode(for: symbol)
        writer.appendBits(code.value, count: code.bitCount)
    }

    /**
     Returns the fixed-Huffman code for one deflate symbol.

     - Parameter symbol: Deflate literal/length/end symbol.
     - Returns: Bit-reversed wire value and bit count.
     - Side effects: none.
     - Failure modes: Callers must pass a fixed-Huffman symbol in `0...287`.
     */
    private func fixedHuffmanCode(for symbol: Int) -> (value: Int, bitCount: Int) {
        if symbol <= 143 {
            return (reversedBits(0x30 + symbol, count: 8), 8)
        }
        if symbol <= 255 {
            return (reversedBits(0x190 + symbol - 144, count: 9), 9)
        }
        if symbol <= 279 {
            return (reversedBits(symbol - 256, count: 7), 7)
        }
        return (reversedBits(0xc0 + symbol - 280, count: 8), 8)
    }

    /**
     Reverses the low-order bits of a deflate Huffman code for wire emission.

     - Parameters:
       - value: Canonical Huffman code value.
       - count: Number of bits to reverse.
     - Returns: Bit-reversed value.
     - Side effects: none.
     - Failure modes: none.
     */
    private func reversedBits(_ value: Int, count: Int) -> Int {
        var source = value
        var result = 0
        for _ in 0..<count {
            result = (result << 1) | (source & 1)
            source >>= 1
        }
        return result
    }

    /**
     Writes an Android backup ZIP fixture to a temporary file.

     - Parameters:
       - archiveData: ZIP bytes to persist.
       - suffix: Android backup suffix to use in the temporary filename.
     - Returns: Temporary archive URL registered for teardown cleanup.
     - Side effects: Writes `archiveData` under the process temporary directory.
     - Failure modes: Rethrows file write errors.
     */
    private func writeTemporaryAndroidBackupArchive(_ archiveData: Data, suffix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-backup-\(UUID().uuidString)\(suffix)")
        try archiveData.write(to: url)
        temporaryPaths.append(url.path)
        return url
    }

    /**
     Builds a sparse stored ZIP file whose declared payload exceeds the eager reader cap.

     The helper writes local and central-directory metadata normally, then seeks across the payload
     range before writing the central directory. On APFS this models a large Android backup without
     allocating hundreds of MiB of fixture data.

     - Parameters:
       - entryName: ZIP entry path to publish.
       - declaredPayloadByteCount: Stored-entry compressed and uncompressed byte count.
     - Returns: Temporary sparse archive URL registered for teardown cleanup.
     - Side effects: Creates a sparse ZIP file in the process temporary directory.
     - Failure modes: Throws when file creation, seeking, or writing fails.
     */
    private func makeSparseStoredZipFile(
        entryName: String,
        declaredPayloadByteCount: UInt32
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-backup-sparse-\(UUID().uuidString).abdb.zip")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        temporaryPaths.append(url.path)

        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        guard let nameData = entryName.data(using: .utf8),
              nameData.count <= Int(UInt16.max) else {
            throw ZipArchiveReaderError.invalidArchive("Test ZIP entry name is too large")
        }

        var localHeader = Data()
        appendUInt32(0x0403_4b50, to: &localHeader)
        appendUInt16(20, to: &localHeader)
        appendUInt16(0, to: &localHeader)
        appendUInt16(0, to: &localHeader)
        appendUInt16(0, to: &localHeader)
        appendUInt16(0, to: &localHeader)
        appendUInt32(0, to: &localHeader)
        appendUInt32(declaredPayloadByteCount, to: &localHeader)
        appendUInt32(declaredPayloadByteCount, to: &localHeader)
        appendUInt16(UInt16(nameData.count), to: &localHeader)
        appendUInt16(0, to: &localHeader)
        localHeader.append(nameData)
        try handle.write(contentsOf: localHeader)

        let centralDirectoryOffset = UInt32(localHeader.count) + declaredPayloadByteCount
        try handle.seek(toOffset: UInt64(centralDirectoryOffset))

        var centralDirectory = Data()
        appendUInt32(0x0201_4b50, to: &centralDirectory)
        appendUInt16(20, to: &centralDirectory)
        appendUInt16(20, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt32(0, to: &centralDirectory)
        appendUInt32(declaredPayloadByteCount, to: &centralDirectory)
        appendUInt32(declaredPayloadByteCount, to: &centralDirectory)
        appendUInt16(UInt16(nameData.count), to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt32(0, to: &centralDirectory)
        appendUInt32(0, to: &centralDirectory)
        centralDirectory.append(nameData)
        try handle.write(contentsOf: centralDirectory)

        var endRecord = Data()
        appendUInt32(0x0605_4b50, to: &endRecord)
        appendUInt16(0, to: &endRecord)
        appendUInt16(0, to: &endRecord)
        appendUInt16(1, to: &endRecord)
        appendUInt16(1, to: &endRecord)
        appendUInt32(UInt32(centralDirectory.count), to: &endRecord)
        appendUInt32(centralDirectoryOffset, to: &endRecord)
        appendUInt16(0, to: &endRecord)
        try handle.write(contentsOf: endRecord)
        return url
    }

    /**
     Writes low-level deflate fixture bits in least-significant-bit order.

     The helper is intentionally scoped to ZIP/deflate regression tests so crafted fixtures can
     describe zlib boundary conditions without checking opaque binary blobs into the repository.
     */
    private struct DeflateBitWriter {
        /// Completed bytes ready to publish.
        private var bytes: [UInt8] = []

        /// Partially-filled byte being assembled least-significant bit first.
        private var currentByte: UInt8 = 0

        /// Number of bits already written into `currentByte`.
        private var bitCount = 0

        /**
         Appends one bit to the fixture stream.

         - Parameter bit: Low bit to append; other bits are ignored.
         - Side effects: Mutates the pending byte and flushes it when it becomes full.
         - Failure modes: none.
         */
        mutating func appendBit(_ bit: Int) {
            if bit & 1 == 1 {
                currentByte |= UInt8(1 << bitCount)
            }
            bitCount += 1
            if bitCount == 8 {
                bytes.append(currentByte)
                currentByte = 0
                bitCount = 0
            }
        }

        /**
         Appends the low-order bits of one integer to the fixture stream.

         - Parameters:
           - value: Source integer.
           - count: Number of least-significant bits to append.
         - Side effects: Mutates the fixture stream.
         - Failure modes: none.
         */
        mutating func appendBits(_ value: Int, count: Int) {
            for index in 0..<count {
                appendBit((value >> index) & 1)
            }
        }

        /**
         Pads the fixture stream to the next byte boundary.

         - Side effects: Appends zero bits until the pending byte is flushed.
         - Failure modes: none.
         */
        mutating func alignToByte() {
            while bitCount != 0 {
                appendBit(0)
            }
        }

        /**
         Finalizes the fixture stream as bytes.

         - Returns: Deflate fixture bytes.
         - Side effects: Pads the pending byte with zeros before returning.
         - Failure modes: none.
         */
        mutating func data() -> Data {
            alignToByte()
            return Data(bytes)
        }
    }

    /**
     Appends one little-endian 16-bit integer to a ZIP fixture.
     */
    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    /**
     Appends one little-endian 32-bit integer to a ZIP fixture.
     */
    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    /**
     Replaces one little-endian 16-bit integer inside a ZIP fixture.

     - Parameters:
       - value: Value to write.
       - offset: Byte offset where the integer starts.
       - data: Fixture bytes to mutate.
     - Side effects: Mutates `data` in place.
     - Failure modes: Callers must pass a valid two-byte range.
     */
    private func replaceUInt16(_ value: UInt16, at offset: Int, in data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + 2), with: bytes)
        }
    }

    /**
     Replaces one little-endian 32-bit integer inside a ZIP fixture.

     - Parameters:
       - value: Value to write.
       - offset: Byte offset where the integer starts.
       - data: Fixture bytes to mutate.
     - Side effects: Mutates `data` in place.
     - Failure modes: Callers must pass a valid four-byte range.
     */
    private func replaceUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
    }

    /**
     Rewrites central-directory size metadata for one ZIP fixture entry.

     This helper intentionally leaves local headers and payloads unchanged so tests can model
     malicious central-directory declarations without allocating large fixture data.

     - Parameters:
       - compressedSize: Declared compressed byte count to write.
       - uncompressedSize: Declared uncompressed byte count to write.
       - entryName: Central-directory entry name to mutate.
       - data: ZIP fixture bytes to mutate in place.
     - Side effects: Mutates central-directory size fields inside `data`.
     - Failure modes: Throws if the fixture lacks a valid central directory or matching entry.
     */
    private func replaceCentralDirectorySizes(
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        for entryName: String,
        in data: inout Data
    ) throws {
        let endRecordOffset = try endOfCentralDirectoryOffset(in: data)
        let centralDirectoryOffset = Int(readUInt32(data, at: endRecordOffset + 16))
        let centralDirectorySize = Int(readUInt32(data, at: endRecordOffset + 12))
        let centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize
        var offset = centralDirectoryOffset

        while offset < centralDirectoryEnd {
            guard offset + 46 <= centralDirectoryEnd,
                  readUInt32(data, at: offset) == 0x0201_4b50 else {
                throw ZipArchiveReaderError.invalidArchive("Test ZIP central directory is malformed")
            }

            let nameLength = Int(readUInt16(data, at: offset + 28))
            let extraLength = Int(readUInt16(data, at: offset + 30))
            let commentLength = Int(readUInt16(data, at: offset + 32))
            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= centralDirectoryEnd,
                  let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw ZipArchiveReaderError.invalidArchive("Test ZIP central directory entry name is malformed")
            }

            if name == entryName {
                replaceUInt32(compressedSize, at: offset + 20, in: &data)
                replaceUInt32(uncompressedSize, at: offset + 24, in: &data)
                return
            }

            offset = nameEnd + extraLength + commentLength
        }

        throw ZipArchiveReaderError.invalidArchive("Test ZIP central directory entry is missing")
    }

    /**
     Rewrites matching local, central, and signed-descriptor size metadata for one fixture entry.

     This keeps the ZIP grammar internally consistent so extraction tests reach the intended
     decompressor or stored-size validation rather than stopping at header comparison.

     - Parameters:
       - compressedSize: Coherent compressed byte count to declare.
       - uncompressedSize: Coherent expanded byte count to declare.
       - entryName: Exact UTF-8 central-directory identity to mutate.
       - data: ZIP fixture bytes mutated in place.
     - Side effects: Rewrites local/central size fields and a signed descriptor when present.
     - Failure modes: Throws if ZIP metadata is malformed, missing, or uses an unsigned descriptor.
     */
    private func replaceZIPEntrySizesEverywhere(
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        for entryName: String,
        in data: inout Data
    ) throws {
        let endRecordOffset = try endOfCentralDirectoryOffset(in: data)
        let centralDirectoryOffset = Int(readUInt32(data, at: endRecordOffset + 16))
        let centralDirectorySize = Int(readUInt32(data, at: endRecordOffset + 12))
        let centralDirectoryEnd = centralDirectoryOffset + centralDirectorySize
        var offset = centralDirectoryOffset

        while offset < centralDirectoryEnd {
            guard offset + 46 <= centralDirectoryEnd,
                  readUInt32(data, at: offset) == 0x0201_4b50 else {
                throw ZipArchiveReaderError.invalidArchive("Test ZIP central directory is malformed")
            }
            let nameLength = Int(readUInt16(data, at: offset + 28))
            let extraLength = Int(readUInt16(data, at: offset + 30))
            let commentLength = Int(readUInt16(data, at: offset + 32))
            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= centralDirectoryEnd,
                  let name = String(data: data[nameStart..<nameEnd], encoding: .utf8) else {
                throw ZipArchiveReaderError.invalidArchive(
                    "Test ZIP central directory entry name is malformed"
                )
            }
            if name == entryName {
                let originalCompressedSize = Int(readUInt32(data, at: offset + 20))
                let localHeaderOffset = Int(readUInt32(data, at: offset + 42))
                guard localHeaderOffset + 30 <= data.count,
                      readUInt32(data, at: localHeaderOffset) == 0x0403_4b50 else {
                    throw ZipArchiveReaderError.invalidArchive("Test ZIP local header is malformed")
                }
                replaceUInt32(compressedSize, at: offset + 20, in: &data)
                replaceUInt32(uncompressedSize, at: offset + 24, in: &data)
                let flags = readUInt16(data, at: localHeaderOffset + 6)
                if flags & 0x0008 == 0 {
                    replaceUInt32(compressedSize, at: localHeaderOffset + 18, in: &data)
                    replaceUInt32(uncompressedSize, at: localHeaderOffset + 22, in: &data)
                } else {
                    let localNameLength = Int(readUInt16(data, at: localHeaderOffset + 26))
                    let localExtraLength = Int(readUInt16(data, at: localHeaderOffset + 28))
                    let descriptorOffset = localHeaderOffset + 30 + localNameLength
                        + localExtraLength + originalCompressedSize
                    guard descriptorOffset + 16 <= data.count,
                          readUInt32(data, at: descriptorOffset) == 0x0807_4b50 else {
                        throw ZipArchiveReaderError.invalidArchive(
                            "Test ZIP signed data descriptor is missing"
                        )
                    }
                    replaceUInt32(compressedSize, at: descriptorOffset + 8, in: &data)
                    replaceUInt32(uncompressedSize, at: descriptorOffset + 12, in: &data)
                }
                return
            }
            offset = nameEnd + extraLength + commentLength
        }

        throw ZipArchiveReaderError.invalidArchive("Test ZIP central directory entry is missing")
    }

    /**
     Finds the end-of-central-directory signature in a ZIP fixture.

     - Parameter data: Raw ZIP fixture bytes.
     - Returns: Offset of the EOCD signature.
     - Side effects: none.
     - Failure modes: Throws if the fixture does not contain an EOCD record in the legal search
       range.
     */
    private func endOfCentralDirectoryOffset(in data: Data) throws -> Int {
        let minimumOffset = max(0, data.count - 65_557)
        var offset = data.count - 22
        while offset >= minimumOffset {
            if readUInt32(data, at: offset) == 0x0605_4b50 {
                return offset
            }
            offset -= 1
        }
        throw ZipArchiveReaderError.missingCentralDirectory
    }

    /**
     Creates one deterministic KJVA-identity mapping contract for backup mutation fixtures.

     - Parameters:
       - start: Inclusive source and persisted KJVA start ordinal.
       - end: Inclusive source and persisted KJVA end ordinal.
     - Returns: Verified range accepted by native progress write APIs.
     - Side effects: Reads bundled canon and mapping fixtures only.
     - Failure modes: Throws an XCTest unwrap failure when fixture ordinals are invalid.
     */
    private func verifiedKJVARange(start: Int, end: Int) throws -> VerifiedKJVAOrdinalRange {
        try XCTUnwrap(
            VerifiedKJVAOrdinalRange(
                resolvingSourceBookInitials: "KJVA",
                sourceVersification: "KJVA",
                sourceOrdinalStart: start,
                sourceOrdinalEnd: end
            )
        )
    }

    /**
     Reads one little-endian 16-bit integer from a ZIP fixture.

     - Parameters:
       - data: Fixture bytes.
       - offset: Byte offset where the integer starts.
     - Returns: Decoded integer value.
     - Side effects: none.
     - Failure modes: Callers must pass a valid two-byte range.
     */
    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1]) << 8
        return b0 | b1
    }

    /**
     Reads one little-endian 32-bit integer from a ZIP fixture.

     - Parameters:
       - data: Fixture bytes.
       - offset: Byte offset where the integer starts.
     - Returns: Decoded integer value.
     - Side effects: none.
     - Failure modes: Callers must pass a valid four-byte range.
     */
    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1]) << 8
        let b2 = UInt32(data[offset + 2]) << 16
        let b3 = UInt32(data[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
