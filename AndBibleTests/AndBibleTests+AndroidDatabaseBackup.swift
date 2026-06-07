import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import SwordKit
import SwiftData
import SQLite3

extension AndBibleTests {
    /**
     Verifies that iOS reads Android `.abdb.zip` archives through the manifest and exposes both
     restorable and unsupported sections.

     Setup:
     - builds a stored ZIP with Android's `AndBibleBackupManifest.json`
     - includes a supported `bookmarks.sqlite3`, unsupported `settings.sqlite3`, and manifest-only
       `MODULES` category

     Expected result:
     - the bookmark section is selectable for restore/import
     - the settings and modules sections remain visible but disabled with unsupported-category reasons

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

        XCTAssertEqual(archive.manifest.backupType, "DB_BACKUP")
        XCTAssertEqual(archive.manifest.manifestVersion, 1)
        XCTAssertEqual(archive.manifest.contains, [.bookmarks, .settings, .modules])
        XCTAssertEqual(archive.sections.map(\.category), [.bookmarks, .modules, .settings])
        XCTAssertEqual(archive.sections.first { $0.category == .bookmarks }?.support, .supported)
        XCTAssertEqual(
            archive.sections.first { $0.category == .modules }?.support,
            .unsupportedCategory("iOS does not yet have a safe mapper for Android Modules data.")
        )
        XCTAssertEqual(
            archive.sections.first { $0.category == .settings }?.support,
            .unsupportedCategory("iOS does not yet have a safe mapper for Android Settings data.")
        )
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

        XCTAssertEqual(archive.manifest.contains, [.bookmarks])
        XCTAssertEqual(archive.sections.map(\.category), [.bookmarks])
        XCTAssertEqual(archive.sections.first?.support, .supported)
    }

    /**
     Verifies Backup & Restore reset success copy names the category that was reset.
     *
     Setup:
     - reads the BibleUI presentation labels for Android reset categories

     Expected result:
     - repository reset feedback includes repository wording
     - repository reset feedback does not claim that only "Database" was reset

     Failure meaning:
     - the user-visible reset result would be misleading for non-database categories such as
       Repositories, Application Preferences, My Documents, or Progress.
     */
    func testAndroidBackupResetSuccessMessageNamesSelectedCategory() {
        let message = AndroidBackupResetCategory.repositories.localizedBackupResetSuccessMessage

        XCTAssertTrue(message.localizedCaseInsensitiveContains("repositories"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("database has been reset"))
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

        let service = AndroidDatabaseBackupService()
        let export = try service.exportArchive(modelContext: modelContext, settingsStore: settingsStore)
        let entriesByName = Dictionary(uniqueKeysWithValues: try ZipArchiveReader.entries(in: export.data).map { ($0.name, $0.data) })
        let expectedCategories: [AndroidDatabaseBackupCategory] = [
            .bookmarks,
            .readingPlans,
            .workspaces,
            .myDocuments,
        ]
        let expectedEntryNames: Set<String> = [
            "AndBibleBackupManifest.json",
            "db/bookmarks.sqlite3",
            "db/readingplans.sqlite3",
            "db/workspaces.sqlite3",
            "db/mydocuments.sqlite3",
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
        XCTAssertEqual(loadedArchive.manifest.backupType, "DB_BACKUP")
        XCTAssertEqual(loadedArchive.sections.map(\.category), [.bookmarks, .myDocuments, .readingPlans, .workspaces])
        XCTAssertTrue(loadedArchive.sections.allSatisfy { $0.support == .supported })

        let materializedDatabases = try materializeExportedDatabases(entriesByName: entriesByName)
        defer {
            for databaseURL in materializedDatabases.values {
                try? FileManager.default.removeItem(at: databaseURL)
            }
        }
        XCTAssertEqual(try readSQLiteUserVersion(at: materializedDatabases["bookmarks.sqlite3"]!), 12)
        XCTAssertEqual(try readSQLiteUserVersion(at: materializedDatabases["readingplans.sqlite3"]!), 1)
        XCTAssertEqual(try readSQLiteUserVersion(at: materializedDatabases["workspaces.sqlite3"]!), 22)
        XCTAssertEqual(
            try readSQLiteUserVersion(at: materializedDatabases["mydocuments.sqlite3"]!),
            RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
        )
        XCTAssertEqual(
            try readSQLiteInteger(
                "SELECT COUNT(*) FROM Label WHERE name = 'Prayer';",
                at: materializedDatabases["bookmarks.sqlite3"]!
            ),
            1
        )
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
                .init(bookmarkID: remoteBookmarkID, notes: "Android note"),
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
     - points `RepositorySourceManager` at a missing install-manager directory that cannot recreate
       `InstallMgr.conf`

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

        let missingBasePath = tempDir.appendingPathComponent("missing", isDirectory: true)
        let service = AndroidBackupResetService(
            repositorySourceManager: RepositorySourceManager(basePath: missingBasePath.path)
        )

        XCTAssertThrowsError(
            try service.reset(
                .repositories,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RepositorySourceManagementError,
                .configWriteFailed("default configuration was not recreated")
            )
        }
        let repositories = try modelContext.fetch(FetchDescriptor<Repository>())
        XCTAssertEqual(repositories.map(\.name), ["Legacy"])
    }

    /**
     Verifies Android-parity Import mode for Android bookmark database backups.

     Setup:
     - first restores a local bookmark snapshot
     - then imports an Android backup containing one duplicate bookmark and one new bookmark

     Expected result:
     - duplicate local rows keep their local note content
     - new backup rows are added

     Failure meaning:
     - iOS Import would drift from Android's `INSERT OR IGNORE` semantics by overwriting local rows
       or skipping valid backup rows.
     */
    func testAndroidDatabaseBackupImportBookmarksKeepsExistingRowsAndAddsMissingRows() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = AndroidDatabaseBackupService()
        let labelID = UUID(uuidString: "15000000-0000-0000-0000-000000000101")!
        let existingBookmarkID = UUID(uuidString: "15000000-0000-0000-0000-000000000102")!
        let newBookmarkID = UUID(uuidString: "15000000-0000-0000-0000-000000000103")!

        let localArchive = try service.loadArchive(
            from: makeAndroidBookmarkOnlyBackupData(
                labelID: labelID,
                bookmarks: [
                    (existingBookmarkID, 20, "Local note"),
                ]
            )
        )
        _ = try service.apply(
            archive: localArchive,
            selections: [.init(category: .bookmarks, mode: .restore)],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let importArchive = try service.loadArchive(
            from: makeAndroidBookmarkOnlyBackupData(
                labelID: labelID,
                bookmarks: [
                    (existingBookmarkID, 20, "Backup replacement"),
                    (newBookmarkID, 21, "Backup addition"),
                ]
            )
        )
        _ = try service.apply(
            archive: importArchive,
            selections: [.init(category: .bookmarks, mode: .import)],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let bookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(Set(bookmarks.map(\.id)), Set([existingBookmarkID, newBookmarkID]))
        XCTAssertEqual(bookmarks.first { $0.id == existingBookmarkID }?.notes?.notes, "Local note")
        XCTAssertEqual(bookmarks.first { $0.id == newBookmarkID }?.notes?.notes, "Backup addition")
    }

    /**
     Verifies Android backup loader failures for malformed archive inputs.

     Setup:
     - passes bytes that are not ZIP-shaped into the Android backup loader
     - builds one ZIP without `AndBibleBackupManifest.json`
     - builds one ZIP whose bookmark entry is not a SQLite database

     Expected result:
     - malformed ZIP inputs surface a clean user-facing archive reason
     - missing manifests fail as `missingManifest`
     - invalid SQLite entries fail before section selection or restore can start

     Failure meaning:
     - iOS would allow ambiguous or corrupt Android backup files into a destructive restore path.
     */
    func testAndroidDatabaseBackupRejectsMissingManifestAndInvalidSQLite() throws {
        let service = AndroidDatabaseBackupService()
        XCTAssertThrowsError(try service.loadArchive(from: Data("not zip".utf8))) { error in
            XCTAssertEqual(
                error as? AndroidDatabaseBackupError,
                .invalidArchive("The file is not a ZIP archive or its central directory is missing.")
            )
        }

        let missingManifestArchive = try makeStoredZip(entries: [
            ("db/bookmarks.sqlite3", Data()),
        ])

        XCTAssertThrowsError(try service.loadArchive(from: missingManifestArchive)) { error in
            XCTAssertEqual(error as? AndroidDatabaseBackupError, .missingManifest)
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
     - corrupts an end-of-central-directory entry count to ZIP64's sentinel value

     Expected result:
     - central-directory size mismatches fail before the reader walks into bytes outside the
       declared directory
     - invalid central-directory names fail as malformed ZIP data rather than being silently skipped
     - ZIP64 sentinels fail up front because this reader intentionally supports only non-ZIP64
       Android backup archives

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
                .invalidArchive("Central directory entry is truncated")
            )
        }

        var invalidNameArchive = archive
        let nameRecordOffset = try endOfCentralDirectoryOffset(in: invalidNameArchive)
        let centralDirectoryOffset = Int(readUInt32(invalidNameArchive, at: nameRecordOffset + 16))
        invalidNameArchive[centralDirectoryOffset + 46] = 0xff

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: invalidNameArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("Central directory entry name is not UTF-8")
            )
        }

        var zip64EntryCountArchive = archive
        let zip64RecordOffset = try endOfCentralDirectoryOffset(in: zip64EntryCountArchive)
        replaceUInt16(UInt16.max, at: zip64RecordOffset + 10, in: &zip64EntryCountArchive)

        XCTAssertThrowsError(try ZipArchiveReader.entries(in: zip64EntryCountArchive)) { error in
            XCTAssertEqual(
                error as? ZipArchiveReaderError,
                .invalidArchive("ZIP64 archives are not supported")
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
     Verifies ZIP bomb protection before the eager reader extracts or inflates payload bytes.

     Setup:
     - builds small ZIP fixtures and rewrites central-directory size metadata to oversized values
     - keeps local payloads tiny so the test proves rejection is based on declared size guards, not
       actual fixture allocation

     Expected result:
     - a single entry over the per-entry cap fails as malformed archive data
     - multiple entries below the per-entry cap but above the aggregate cap also fail
     - Android backup service error mapping preserves concrete ZIP parser reasons

     Failure meaning:
     - iOS could allocate excessive memory while importing a crafted Android backup archive before
       the restore path reaches SQLite validation.
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
                .invalidArchive("ZIP entry exceeds maximum supported size")
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
                .invalidArchive("ZIP archive exceeds maximum supported size")
            )
        }

        let service = AndroidDatabaseBackupService()
        XCTAssertThrowsError(try service.loadArchive(from: oversizedEntryArchive)) { error in
            XCTAssertEqual(
                error as? AndroidDatabaseBackupError,
                .invalidArchive("ZIP entry exceeds maximum supported size")
            )
        }
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
        try replaceCentralDirectorySizes(
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
        try replaceCentralDirectorySizes(
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
     Verifies that unsupported Android backup categories keep their unsupported-category reason even
     when their SQLite schema version is newer than iOS recognizes.

     Setup:
     - builds an Android Settings database, which iOS intentionally cannot map yet
     - sets its SQLite `user_version` above the known Android Settings schema version

     Expected result:
     - the archive still exposes the Settings section
     - the section reason says iOS lacks a safe mapper rather than implying a version-only blocker

     Failure meaning:
     - the section picker would mislead users into thinking a future iOS version could restore the
       category merely by recognizing the schema version, even though the category has no mapper.
     */
    func testAndroidDatabaseBackupUnsupportedCategoriesIgnoreVersionGate() throws {
        let settingsDatabaseURL = try makeEmptySQLiteDatabase(userVersion: 99)
        let archiveData = try makeAndroidDatabaseBackupArchiveData(
            databaseURLsByName: [
                "settings.sqlite3": settingsDatabaseURL,
            ],
            contains: [.settings]
        )

        let archive = try AndroidDatabaseBackupService().loadArchive(from: archiveData)

        XCTAssertEqual(
            archive.sections.first { $0.category == .settings }?.support,
            .unsupportedCategory("iOS does not yet have a safe mapper for Android Settings data.")
        )
    }

    /**
     Builds a one-section Android bookmark backup archive for restore/import tests.

     - Parameters:
       - labelID: Android label ID linked to every generated bookmark.
       - bookmarks: Tuples of bookmark ID, verse ordinal, and note text.
     - Returns: Raw ZIP archive bytes with Android manifest and `db/bookmarks.sqlite3`.
     - Side effects: writes a temporary SQLite database through `makeAndroidBookmarksDatabase`.
     - Failure modes: Rethrows SQLite fixture and ZIP construction failures.
     */
    private func makeAndroidBookmarkOnlyBackupData(
        labelID: UUID,
        bookmarks: [(id: UUID, ordinal: Int, note: String)]
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
                .init(bookmarkID: $0.id, notes: $0.note)
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

     Android database backup export reads bookmarks, reading plans, workspaces, My Documents, and
     local fidelity settings in one pass. This fixture keeps that graph in one container so the
     export test exercises the same `ModelContext` shape the Settings screen supplies.

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
            "mydocuments.sqlite3",
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
        var localHeaderOffsets: [String: UInt32] = [:]

        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8),
                  nameData.count <= Int(UInt16.max),
                  entry.data.count <= Int(UInt32.max),
                  archive.count <= Int(UInt32.max) else {
                throw ZipArchiveReaderError.invalidArchive("Test ZIP entry is too large")
            }
            localHeaderOffsets[entry.name] = UInt32(archive.count)
            appendUInt32(0x0403_4b50, to: &archive)
            appendUInt16(20, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(0, to: &archive)
            appendUInt32(UInt32(entry.data.count), to: &archive)
            appendUInt32(UInt32(entry.data.count), to: &archive)
            appendUInt16(UInt16(nameData.count), to: &archive)
            appendUInt16(0, to: &archive)
            archive.append(nameData)
            archive.append(entry.data)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        var centralDirectory = Data()
        for entry in entries {
            guard let nameData = entry.name.data(using: .utf8),
                  let localHeaderOffset = localHeaderOffsets[entry.name] else {
                throw ZipArchiveReaderError.invalidArchive("Test ZIP entry is missing a local header")
            }
            appendUInt32(0x0201_4b50, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(0, to: &centralDirectory)
            appendUInt32(UInt32(entry.data.count), to: &centralDirectory)
            appendUInt32(UInt32(entry.data.count), to: &centralDirectory)
            appendUInt16(UInt16(nameData.count), to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(0, to: &centralDirectory)
            appendUInt32(localHeaderOffset, to: &centralDirectory)
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
        guard let nameData = name.data(using: .utf8),
              nameData.count <= Int(UInt16.max),
              compressedData.count <= Int(UInt32.max),
              uncompressedData.count <= Int(UInt32.max) else {
            throw ZipArchiveReaderError.invalidArchive("Test ZIP entry is too large")
        }

        var archive = Data()
        let localHeaderOffset = UInt32(archive.count)
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
        archive.append(compressedData)
        appendUInt32(0x0807_4b50, to: &archive)
        appendUInt32(0, to: &archive)
        appendUInt32(UInt32(compressedData.count), to: &archive)
        appendUInt32(UInt32(uncompressedData.count), to: &archive)

        let centralDirectoryOffset = UInt32(archive.count)
        var centralDirectory = Data()
        appendUInt32(0x0201_4b50, to: &centralDirectory)
        appendUInt16(20, to: &centralDirectory)
        appendUInt16(20, to: &centralDirectory)
        appendUInt16(0x0008, to: &centralDirectory)
        appendUInt16(8, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt32(0, to: &centralDirectory)
        appendUInt32(UInt32(compressedData.count), to: &centralDirectory)
        appendUInt32(UInt32(uncompressedData.count), to: &centralDirectory)
        appendUInt16(UInt16(nameData.count), to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt32(0, to: &centralDirectory)
        appendUInt32(localHeaderOffset, to: &centralDirectory)
        centralDirectory.append(nameData)

        archive.append(centralDirectory)
        appendUInt32(0x0605_4b50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(1, to: &archive)
        appendUInt16(1, to: &archive)
        appendUInt32(UInt32(centralDirectory.count), to: &archive)
        appendUInt32(centralDirectoryOffset, to: &archive)
        appendUInt16(0, to: &archive)
        return archive
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
