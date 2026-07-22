import XCTest
@testable import BibleCore
import SwiftData
import SQLite3

/**
 Behavioral coverage for local custom reading-plan definitions and Android database compatibility.

 Tests cover exact-byte local publication, fail-visible remote sync for definitions Android cannot
 transport, exact Android Room schema export, bounded untrusted archives, and crash-consistent
 graph/file recovery. Custom `.properties` files remain device-local.
 */
final class ReadingPlanDefinitionTests: XCTestCase {
    /**
     Verifies initial upload fails before transport for an active custom plan.

     The fixture imports and starts an Android-readable properties file, then attempts an initial
     reading-plan backup through the production service. Android's reading-plan database carries
     plan state but not custom definition files, so the service must return the typed unsupported-plan
     error without creating a remote upload. Failure means iOS can publish an unusable remote plan.
     */
    func testInitialUploadRejectsActiveCustomPlanBeforeTransport() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = rootDirectory
            .appendingPathComponent("source/jsword/readingplan", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let propertiesText = """
        # Morning and Evening
        # A custom schedule transferred as Java properties.
        Versification=KJV
        1=Gen.1,Matt.1
        2=Gen.2,\\
          Matt.2
        3=Rev.\\u0032\\u0031
        """
        let sourceContainer = try makeReadingPlanRestoreModelContainer()
        let sourceContext = ModelContext(sourceContainer)
        let sourceSettingsStore = SettingsStore(modelContext: sourceContext)
        let sourcePlan = try ReadingPlanService.importAndStartCustomPlan(
            fileName: "Morning and Evening.properties",
            propertiesData: Data(propertiesText.utf8),
            modelContext: sourceContext,
            settingsStore: sourceSettingsStore,
            userPlanDirectory: sourceDirectory
        )
        sourcePlan.startDate = Date(timeIntervalSince1970: 1_735_689_600)
        sourcePlan.currentDay = 2
        try sourceContext.save()

        let syncFolderID = "/reading-plan-definition-round-trip"
        let adapter = ReadingPlanMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(syncFolderID)/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 1_735_690_000_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let sourceSnapshotService = RemoteSyncReadingPlanSnapshotService(
            userPlanDirectory: sourceDirectory
        )
        let uploadService = RemoteSyncInitialBackupUploadService(
            adapter: adapter,
            deviceIdentifier: "source-device",
            readingPlanSnapshotService: sourceSnapshotService,
            temporaryDirectory: rootDirectory,
            retryDirectory: rootDirectory.appendingPathComponent("source/retry"),
            nowProvider: { 1_735_689_900_000 }
        )

        do {
            _ = try await uploadService.uploadInitialBackup(
                for: .readingPlans,
                bootstrapState: RemoteSyncBootstrapState(syncFolderID: syncFolderID),
                modelContext: sourceContext,
                settingsStore: sourceSettingsStore
            )
            XCTFail("Expected unsupported custom-plan failure")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncInitialBackupUploadError,
                .unsupportedCustomReadingPlans([sourcePlan.planCode])
            )
        }
        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(uploadedFiles.isEmpty)
    }



    /**
     Verifies builder-only export preserves custom-plan rows in the exact Android Room schema.

     The manual export path has no remote adapter and mirrors Android's local Room-file backup. It
     must retain the public `ReadingPlan` row so local custom plans remain supported without adding
     iOS-only tables. A failure either regresses local custom-plan backup or breaks Android parity.
     */
    func testManualDatabaseExportUsesExactAndroidReadingPlanTables() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: context)
        let plan = ReadingPlan(
            planCode: "local-custom-plan",
            planName: "Local Custom Plan",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            currentDay: 1,
            totalDays: 1
        )
        context.insert(plan)
        try context.save()

        let databaseURL = try RemoteSyncInitialBackupUploadService
            .buildAndroidDatabaseBackupDatabase(
                for: .readingPlans,
                modelContext: context,
                settingsStore: settingsStore,
                schemaVersion: 1,
                temporaryDirectory: rootDirectory
            )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil),
            SQLITE_OK
        )
        let openDatabase = try XCTUnwrap(database)
        defer { sqlite3_close(openDatabase) }
        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
            openDatabase,
            category: .readingPlans
        )

        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                openDatabase,
                "SELECT planCode FROM ReadingPlan ORDER BY planCode",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        let planStatement = try XCTUnwrap(statement)
        defer { sqlite3_finalize(planStatement) }
        XCTAssertEqual(sqlite3_step(planStatement), SQLITE_ROW)
        XCTAssertEqual(
            String(cString: try XCTUnwrap(sqlite3_column_text(planStatement, 0))),
            plan.planCode
        )
        XCTAssertEqual(sqlite3_step(planStatement), SQLITE_DONE)

        var tableStatement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                openDatabase,
                "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
                -1,
                &tableStatement,
                nil
            ),
            SQLITE_OK
        )
        let schemaStatement = try XCTUnwrap(tableStatement)
        defer { sqlite3_finalize(schemaStatement) }
        var tableNames: [String] = []
        while sqlite3_step(schemaStatement) == SQLITE_ROW {
            tableNames.append(String(cString: try XCTUnwrap(sqlite3_column_text(schemaStatement, 0))))
        }
        XCTAssertEqual(
            tableNames,
            [
                "LogEntry",
                "ReadingPlan",
                "ReadingPlanStatus",
                "SyncConfiguration",
                "SyncStatus",
                "room_master_table",
            ]
        )
    }

    /**
     Verifies a legacy archive cannot silently restore a custom identity without its file.

     The staged database intentionally omits the additive definition table while naming a custom
     plan unavailable on the destination. Restore must surface `unsupportedPlanDefinitions` before
     replacing the existing bundled plan or creating a file. The destination directory and model
     container are fresh and UUID-scoped, making the result independent of host application data.
     */
    func testMissingCustomDefinitionFailsBeforeDestinationMutation() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destinationDirectory = rootDirectory
            .appendingPathComponent("jsword/readingplan", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let bundledTemplate = try XCTUnwrap(ReadingPlanService.availablePlans.first)
        let existingPlan = try ReadingPlanService.startPlan(
            template: bundledTemplate,
            modelContext: modelContext
        )
        let missingCode = "Definition Absent On Fresh Device"
        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(),
                    planCode: missingCode,
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 1
                )
            ],
            statuses: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = RemoteSyncReadingPlanRestoreService(
            userPlanDirectory: destinationDirectory
        )
        let snapshot = try service.readSnapshot(from: databaseURL)

        XCTAssertThrowsError(
            try service.replaceLocalReadingPlans(
                from: snapshot,
                modelContext: modelContext,
                statusStore: statusStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanRestoreError,
                .unsupportedPlanDefinitions([missingCode])
            )
        }

        let remainingPlans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(remainingPlans.map(\.id), [existingPlan.id])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationDirectory
                    .appendingPathComponent(missingCode)
                    .appendingPathExtension("properties")
                    .path
            )
        )
    }



    /**
     Verifies Android restore resolves bundled plans without creating local definition files.

     The staged database contains one dynamically selected bundled plan. Restore must reconstruct
     every bundled day from package resources and must not create any user `.properties` file.
     Dynamic selection avoids coupling this regression control to a particular built-in identity.
     */
    func testBundledDefinitionRestoreRemainsFileFree() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destinationDirectory = rootDirectory
            .appendingPathComponent("jsword/readingplan", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let bundledTemplate = try XCTUnwrap(ReadingPlanService.availablePlans.first)
        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(),
                    planCode: bundledTemplate.code,
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: min(2, bundledTemplate.totalDays)
                )
            ],
            statuses: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let service = RemoteSyncReadingPlanRestoreService(
            userPlanDirectory: destinationDirectory
        )
        let snapshot = try service.readSnapshot(from: databaseURL)

        let report = try service.replaceLocalReadingPlans(
            from: snapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        XCTAssertEqual(report.restoredPlanCodes, [bundledTemplate.code])
        XCTAssertEqual(report.restoredDayCount, bundledTemplate.totalDays)
        let restoredPlan = try XCTUnwrap(
            modelContext.fetch(FetchDescriptor<ReadingPlan>()).first
        )
        let restoredDays = (restoredPlan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertEqual(restoredDays.count, bundledTemplate.totalDays)
        for day in restoredDays {
            XCTAssertEqual(day.readings, bundledTemplate.readingsForDay(day.dayNumber))
        }
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: destinationDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "properties" }.isEmpty
        )
    }

    /**
     Verifies unreferenced definition edits and removals never alter Android patches.

     A baseline is accepted while the model graph is empty, then the exact properties bytes are
     changed and uploaded. Removing the same file must produce the following patch as one definition
     delete. Inspecting both SQLite archives proves filesystem-only changes remain first-class sparse
     sync rows rather than depending on an unrelated plan or status edit. UUID-scoped files are
     removed after the test.
     */
    func testUnreferencedDefinitionChangesDoNotProduceAndroidPatches() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userPlanDirectory = rootDirectory
            .appendingPathComponent("jsword/readingplan", isDirectory: true)
        try FileManager.default.createDirectory(
            at: userPlanDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let planCode = "Definition Only Changes"
        let initialData = Data("1=Gen.1\n".utf8)
        let updatedData = Data("1=Gen.1,Matt.1\n2=Acts.1\n".utf8)
        let definitionURL = userPlanDirectory
            .appendingPathComponent(planCode)
            .appendingPathExtension("properties")
        try initialData.write(to: definitionURL, options: .atomic)

        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let snapshotService = RemoteSyncReadingPlanSnapshotService(
            userPlanDirectory: userPlanDirectory
        )
        try snapshotService.refreshBaselineFingerprintsStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        try updatedData.write(to: definitionURL, options: .atomic)

        let deviceFolderID = "/reading-plan-definitions/source-device"
        let adapter = ReadingPlanMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(deviceFolderID)/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 0,
                timestamp: 3_000,
                parentID: deviceFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let service = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            snapshotService: snapshotService,
            temporaryDirectory: rootDirectory,
            outboxDirectory: rootDirectory.appendingPathComponent("outbox", isDirectory: true),
            nowProvider: { 2_000 }
        )

        let editResult = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: deviceFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertNil(editResult)
        var uploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(uploadedFiles.isEmpty)

        try FileManager.default.removeItem(at: definitionURL)
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "\(deviceFolderID)/2.1.sqlite3.gz",
                name: "2.1.sqlite3.gz",
                size: 0,
                timestamp: 5_000,
                parentID: deviceFolderID,
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )

        let deleteResult = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: deviceFolderID),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertNil(deleteResult)
        uploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(uploadedFiles.isEmpty)
    }



    /**
     Verifies selected-file reads preserve bytes and stop at the shared definition payload limit.

     A Latin-1 fixture must return unchanged, while a sparse file one byte over the accepted bound
     must fail from metadata preflight instead of being allocated into memory.
     */
    func testBoundedDefinitionReaderPreservesBytesAndRejectsOversizedFile() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        var exactBytes = Data("# Caf".utf8)
        exactBytes.append(0xe9)
        exactBytes.append(Data("\n1=Gen.1\n".utf8))
        let exactURL = rootDirectory.appendingPathComponent("Exact.properties")
        try exactBytes.write(to: exactURL)
        XCTAssertEqual(
            try ReadingPlanService.readCustomPlanDefinitionData(from: exactURL),
            exactBytes
        )

        let oversizedURL = rootDirectory.appendingPathComponent("Oversized.properties")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversizedURL.path, contents: Data()))
        let fileHandle = try FileHandle(forWritingTo: oversizedURL)
        try fileHandle.truncate(
            atOffset: UInt64(
                RemoteSyncReadingPlanDefinitionStore.maximumDefinitionByteCount + 1
            )
        )
        try fileHandle.close()
        XCTAssertThrowsError(
            try ReadingPlanService.readCustomPlanDefinitionData(from: oversizedURL)
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanDefinitionError,
                .definitionTooLarge(oversizedURL.deletingPathExtension().lastPathComponent)
            )
        }

        let symlinkURL = rootDirectory.appendingPathComponent("Linked.properties")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: exactURL)
        XCTAssertThrowsError(
            try ReadingPlanService.readCustomPlanDefinitionData(from: symlinkURL)
        ) { error in
            XCTAssertEqual(error as? ReadingPlanImportError, .invalidFileName)
        }
    }

    /**
     Verifies original Latin-1 bytes, rebuilt days, and preserved statuses share one mutation path.

     Failure means a file import can again normalize Android properties bytes or leave a schedule and
     its status payloads describing different definition generations.
     */
    func testExactLatin1ImportRebuildsPlanAndClearsObsoleteStatuses() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userPlanDirectory = rootDirectory.appendingPathComponent("readingplan", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        var originalBytes = Data("# Caf".utf8)
        originalBytes.append(0xe9)
        originalBytes.append(Data("\n1=Gen.1\n2=Matt.1\n".utf8))

        let plan = try ReadingPlanService.importAndStartCustomPlan(
            fileName: "Latin Plan.properties",
            propertiesData: originalBytes,
            modelContext: modelContext,
            settingsStore: settingsStore,
            userPlanDirectory: userPlanDirectory
        )
        XCTAssertEqual(plan.totalDays, 2)
        XCTAssertEqual(
            try Data(contentsOf: userPlanDirectory.appendingPathComponent("Latin Plan.properties")),
            originalBytes
        )

        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        statusStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
            planCode: plan.planCode,
            dayNumber: 2
        )
        plan.currentDay = 2
        try modelContext.save()

        var editedBytes = Data("# Caf".utf8)
        editedBytes.append(0xe9)
        editedBytes.append(Data("\n1=Acts.1\n".utf8))
        let rebuilt = try ReadingPlanService.importAndStartCustomPlan(
            fileName: "Latin Plan.properties",
            propertiesData: editedBytes,
            modelContext: modelContext,
            settingsStore: settingsStore,
            userPlanDirectory: userPlanDirectory
        )

        XCTAssertEqual(rebuilt.id, plan.id)
        XCTAssertEqual(rebuilt.currentDay, 2)
        XCTAssertEqual(rebuilt.totalDays, 1)
        XCTAssertEqual(
            rebuilt.days?.sorted { $0.dayNumber < $1.dayNumber }.map(\.readings),
            Optional(["Acts.1"])
        )
        XCTAssertNil(statusStore.storedStatus(planCode: plan.planCode, dayNumber: 2))
        XCTAssertEqual(
            try Data(contentsOf: userPlanDirectory.appendingPathComponent("Latin Plan.properties")),
            editedBytes
        )
    }

    /**
     Verifies a settings-store commit failure restores custom bytes, plan graphs, active selection,
     and raw progress after the graph store may already have accepted an edited definition schedule.

     The fixture uses separate production-shaped graph and settings SQLite stores. A persistent
     settings trigger rejects the final batch while the edit replaces two old days with one new day.
     Failure means the user can reopen a new definition paired with old status or a partially committed
     active-plan graph even though import reported an error.
     */
    func testCustomDefinitionEditRestoresCompleteGenerationWhenSettingsCommitFails() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeDirectory = rootDirectory.appendingPathComponent("stores", isDirectory: true)
        let userPlanDirectory = rootDirectory.appendingPathComponent("readingplan", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let persistentStore = try makePersistentReadingPlanRestoreStore(in: storeDirectory)
        let modelContext = ModelContext(persistentStore.container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let originalBytes = Data("1=Gen.1\n2=Matt.1\n".utf8)
        let editedBytes = Data("1=Acts.1\n".utf8)
        let customPlan = try ReadingPlanService.importAndStartCustomPlan(
            fileName: "Durable Custom.properties",
            propertiesData: originalBytes,
            modelContext: modelContext,
            settingsStore: settingsStore,
            userPlanDirectory: userPlanDirectory
        )
        customPlan.currentDay = 2
        try modelContext.save()
        RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore).setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
            planCode: customPlan.planCode,
            dayNumber: 2
        )

        let bundledTemplate = try XCTUnwrap(ReadingPlanService.availablePlans.first)
        let bundledPlan = try ReadingPlanService.startPlan(
            template: bundledTemplate,
            modelContext: modelContext
        )
        XCTAssertTrue(bundledPlan.isActive)
        XCTAssertFalse(customPlan.isActive)

        let writeFailure = try ReadingPlanSQLiteStoreWriteFailure(
            databaseURL: persistentStore.settingsStoreURL
        )
        try writeFailure.install()
        XCTAssertThrowsError(
            try ReadingPlanService.importAndStartCustomPlan(
                fileName: "Durable Custom.properties",
                propertiesData: editedBytes,
                modelContext: modelContext,
                settingsStore: settingsStore,
                userPlanDirectory: userPlanDirectory
            )
        )
        writeFailure.remove()

        let reopenedStore = try makePersistentReadingPlanRestoreStore(in: storeDirectory)
        let reopenedContext = ModelContext(reopenedStore.container)
        let reopenedPlans = try reopenedContext.fetch(FetchDescriptor<ReadingPlan>())
        let reopenedCustomPlan = try XCTUnwrap(
            reopenedPlans.first { $0.planCode == customPlan.planCode }
        )
        let reopenedBundledPlan = try XCTUnwrap(
            reopenedPlans.first { $0.planCode == bundledPlan.planCode }
        )
        XCTAssertEqual(reopenedCustomPlan.currentDay, 2)
        XCTAssertFalse(reopenedCustomPlan.isActive)
        XCTAssertEqual(
            reopenedCustomPlan.days?.sorted { $0.dayNumber < $1.dayNumber }.map(\.readings),
            Optional(["Gen.1", "Matt.1"])
        )
        XCTAssertTrue(reopenedBundledPlan.isActive)
        XCTAssertNotNil(
            RemoteSyncReadingPlanStatusStore(
                settingsStore: SettingsStore(modelContext: reopenedContext)
            ).storedStatus(planCode: customPlan.planCode, dayNumber: 2)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: userPlanDirectory.appendingPathComponent(
                    "Durable Custom.properties"
                )
            ),
            originalBytes
        )
    }

    /** Verifies Int32 day bounds plus Android filename mapping and filesystem collision behavior. */
    func testDefinitionValidationRejectsBundledCollisionAndHugeDay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundledCode = try XCTUnwrap(ReadingPlanService.availablePlans.first?.code)

        XCTAssertThrowsError(
            try ReadingPlanService.importCustomPlan(
                fileName: "\(bundledCode).properties",
                propertiesData: Data("1=Gen.1\n".utf8),
                userPlanDirectory: directory
            )
        ) { error in
            XCTAssertEqual(error as? ReadingPlanImportError, .bundledPlanCodeCollision)
        }

        XCTAssertThrowsError(
            try ReadingPlanService.importCustomPlan(
                fileName: "Huge Day.properties",
                propertiesData: Data("9223372036854775807=Gen.1\n".utf8),
                userPlanDirectory: directory
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanDefinitionError,
                .dayNumberOutOfRange("Huge Day")
            )
        }

        let sparse = try ReadingPlanService.importCustomPlan(
            fileName: "Escaped Sparse Day.properties",
            propertiesData: Data(
                "1=Gen.1\n\\u0031\\u0030\\u0030\\u0030\\u0031=Matt.1\n".utf8
            ),
            userPlanDirectory: directory
        )
        XCTAssertEqual(sparse.dayNumbers, [1, 10_001])
        XCTAssertEqual(sparse.totalDays, 10_001)
        XCTAssertEqual(sparse.readingsForDay(2), "")
        XCTAssertEqual(sparse.readingsForDay(10_001), "Matt.1")

        let hidden = try ReadingPlanService.importCustomPlan(
            fileName: ".Hidden Plan.properties",
            propertiesData: Data("1=Gen.1\n".utf8),
            userPlanDirectory: directory
        )
        XCTAssertEqual(hidden.code, ".Hidden Plan")

        let repeatedSuffix = try ReadingPlanService.importCustomPlan(
            fileName: "Repeated.properties.properties",
            propertiesData: Data("1=Matt.1\n".utf8),
            userPlanDirectory: directory
        )
        XCTAssertEqual(repeatedSuffix.code, "Repeated")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Repeated.properties").path
            )
        )

        _ = try ReadingPlanService.importCustomPlan(
            fileName: "Case Plan.properties",
            propertiesData: Data("1=Luke.1\n".utf8),
            userPlanDirectory: directory
        )
        XCTAssertThrowsError(
            try ReadingPlanService.importCustomPlan(
                fileName: "case plan.properties",
                propertiesData: Data("1=John.1\n".utf8),
                userPlanDirectory: directory
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanDefinitionError,
                .filesystemIdentityCollision("case plan")
            )
        }
    }

    /**
     Verifies decoded keys and Latin-1 control/spacing bytes follow Java-properties rules exactly.

     Escaping the leading space keeps the apparent day-two key nonnumeric. NEL remains inside day
     one's value, and NBSP at the start of a continuation is not stripped like Java's space, tab, or
     form-feed continuation whitespace. Failure means iOS can build a different schedule from bytes
     Android accepts.
     */
    func testJavaPropertiesParsingPreservesExactDecodedKeyAndLatin1WhitespaceSemantics() throws {
        var bytes = Data(#"\ 2=Matt.1"#.utf8)
        bytes.append(Data("\r\n1=Gen.1".utf8))
        bytes.append(0x85)
        bytes.append(Data("tail\r\n3=Luke.1\\\r\n".utf8))
        bytes.append(0xa0)
        bytes.append(Data(",Mark.1\r\n".utf8))
        let text = try XCTUnwrap(String(data: bytes, encoding: .isoLatin1))

        let readings = ReadingPlanService.parseProperties(text)

        XCTAssertNil(readings[2])
        XCTAssertEqual(readings[1], "Gen.1\u{0085}tail")
        XCTAssertEqual(readings[3], "Luke.1\u{00a0},Mark.1")
    }

    /** Verifies Android plan rows resolve a same-code device-local custom definition. */
    func testAndroidArchiveUsesSameCodeLocalCustomDefinition() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = rootDirectory.appendingPathComponent("readingplan", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let planCode = "Local Alias"
        let localBytes = Data("1=Gen.1\n".utf8)
        try localBytes.write(to: directory.appendingPathComponent("\(planCode).properties"))
        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [.init(id: UUID(), planCode: planCode, startDate: Date(), currentDay: 1)],
            statuses: []
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: context)
        let service = RemoteSyncReadingPlanRestoreService(userPlanDirectory: directory)
        let snapshot = try service.readSnapshot(from: databaseURL)
        _ = try service.replaceLocalReadingPlans(
            from: snapshot,
            modelContext: context,
            statusStore: RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        )
        let restoredPlan = try XCTUnwrap(
            context.fetch(FetchDescriptor<ReadingPlan>()).first { $0.planCode == planCode }
        )
        XCTAssertEqual(restoredPlan.days?.map(\.readings), ["Gen.1"])
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("\(planCode).properties")),
            localBytes
        )
    }

    /** Verifies sparse upload rejects active custom plans before remote discovery or journal writes. */
    func testPatchUploadRejectsActiveCustomPlanBeforeTransport() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = rootDirectory.appendingPathComponent("readingplan", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: context)
        let plan = try ReadingPlanService.importAndStartCustomPlan(
            fileName: "Unsyncable Custom.properties",
            propertiesData: Data("1=Gen.1\n".utf8),
            modelContext: context,
            settingsStore: settingsStore,
            userPlanDirectory: directory
        )
        let adapter = ReadingPlanMockRemoteSyncAdapter()
        let service = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            snapshotService: RemoteSyncReadingPlanSnapshotService(userPlanDirectory: directory),
            temporaryDirectory: rootDirectory,
            outboxDirectory: rootDirectory.appendingPathComponent("outbox", isDirectory: true)
        )

        do {
            _ = try await service.uploadPendingPatch(
                bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/device"),
                modelContext: context,
                settingsStore: settingsStore
            )
            XCTFail("Expected unsupported custom-plan failure")
        } catch {
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanPatchUploadError,
                .unsupportedCustomReadingPlans([plan.planCode])
            )
        }
        let events = await adapter.eventsSnapshot()
        let uploads = await adapter.uploadedFilesSnapshot()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(uploads.isEmpty)
    }



    /** Verifies an oversized gzip declaration fails before inflate or SQLite access. */
    func testPatchRejectsExpandedArchiveBeforeInflation() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let archiveURL = rootDirectory.appendingPathComponent("oversized.sqlite3.gz")
        let oversized: UInt32 = 64 * 1_024 * 1_024 + 1
        var bytes = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0xff, 0x03, 0x00])
        bytes.append(contentsOf: [0, 0, 0, 0])
        bytes.append(contentsOf: [
            UInt8(oversized & 0xff),
            UInt8((oversized >> 8) & 0xff),
            UInt8((oversized >> 16) & 0xff),
            UInt8((oversized >> 24) & 0xff),
        ])
        try bytes.write(to: archiveURL)
        let staged = RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: "source",
                patchNumber: 1,
                schemaVersion: 1,
                file: RemoteSyncFile(
                    id: "/source/1.1.sqlite3.gz",
                    name: "1.1.sqlite3.gz",
                    size: Int64(bytes.count),
                    timestamp: 1,
                    parentID: "/source",
                    mimeType: "application/gzip"
                )
            ),
            archiveFileURL: archiveURL
        )
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)

        XCTAssertThrowsError(
            try RemoteSyncReadingPlanPatchApplyService(temporaryDirectory: rootDirectory)
                .applyPatchArchives(
                    [staged],
                    modelContext: context,
                    settingsStore: SettingsStore(modelContext: context)
                )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanPatchApplyError,
                .expandedArchiveTooLarge(UInt64(oversized))
            )
        }
    }

    /** Verifies compressed patch size is rejected from file metadata before gzip header parsing. */
    func testPatchRejectsCompressedArchiveBeforeReadingPayload() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let archiveURL = rootDirectory.appendingPathComponent("compressed-limit.sqlite3.gz")
        XCTAssertTrue(FileManager.default.createFile(atPath: archiveURL.path, contents: Data()))
        let oversized = RemoteSyncArchiveStagingService.maximumCompressedPatchByteCount + 1
        let handle = try FileHandle(forWritingTo: archiveURL)
        try handle.truncate(atOffset: UInt64(oversized))
        try handle.close()
        let staged = RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: "source",
                patchNumber: 1,
                schemaVersion: 1,
                file: RemoteSyncFile(
                    id: "/source/1.1.sqlite3.gz",
                    name: "1.1.sqlite3.gz",
                    size: Int64(oversized),
                    timestamp: 1,
                    parentID: "/source",
                    mimeType: NextCloudSyncAdapter.gzipMimeType
                )
            ),
            archiveFileURL: archiveURL
        )
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)

        XCTAssertThrowsError(
            try RemoteSyncReadingPlanPatchApplyService(temporaryDirectory: rootDirectory)
                .applyPatchArchives(
                    [staged],
                    modelContext: context,
                    settingsStore: SettingsStore(modelContext: context)
                )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanPatchApplyError,
                .compressedArchiveTooLarge(Int64(oversized))
            )
        }
    }

    /**
     Verifies cumulative expanded SQLite declarations are bounded before any member is inflated.

     Five tiny strict gzip frames each declare the allowed per-file maximum. Their aggregate exceeds
     the batch ceiling, so replay must fail during preflight without opening SQLite or publishing.
     */
    func testPatchRejectsCumulativeExpandedArchivesBeforeInflation() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let declaredExpandedSize = UInt32(
            RemoteSyncArchiveStagingService.maximumExpandedPatchByteCount
        )
        var frame = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0, 0xff, 0x03, 0x00])
        frame.append(contentsOf: [0, 0, 0, 0])
        frame.append(contentsOf: [
            UInt8(declaredExpandedSize & 0xff),
            UInt8((declaredExpandedSize >> 8) & 0xff),
            UInt8((declaredExpandedSize >> 16) & 0xff),
            UInt8((declaredExpandedSize >> 24) & 0xff),
        ])
        var archives: [RemoteSyncStagedPatchArchive] = []
        for patchNumber in 1...5 {
            let archiveURL = rootDirectory.appendingPathComponent(
                "\(patchNumber).1.sqlite3.gz"
            )
            try frame.write(to: archiveURL)
            archives.append(
                RemoteSyncStagedPatchArchive(
                    patch: RemoteSyncDiscoveredPatch(
                        sourceDevice: "source",
                        patchNumber: Int64(patchNumber),
                        schemaVersion: 1,
                        file: RemoteSyncFile(
                            id: "/source/\(patchNumber).1.sqlite3.gz",
                            name: "\(patchNumber).1.sqlite3.gz",
                            size: Int64(frame.count),
                            timestamp: Int64(patchNumber),
                            parentID: "/source",
                            mimeType: NextCloudSyncAdapter.gzipMimeType
                        )
                    ),
                    archiveFileURL: archiveURL
                )
            )
        }
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)

        XCTAssertThrowsError(
            try RemoteSyncReadingPlanPatchApplyService(temporaryDirectory: rootDirectory)
                .applyPatchArchives(
                    archives,
                    modelContext: context,
                    settingsStore: SettingsStore(modelContext: context)
                )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncReadingPlanPatchApplyError,
                .cumulativeArchiveTooLarge(UInt64(declaredExpandedSize) * 5)
            )
        }
    }



    /**
     Verifies every durable publication boundary recovers according to the graph-colocated marker.

     The production checkpoint throws as a process-termination surrogate after each journal, rename,
     and graph-commit boundary. A fresh store must restore old bytes before graph commit, retain new
     bytes after graph commit, remove all publication artifacts, and make a second recovery a no-op.
     */
    func testDefinitionPublicationRecoveryUsesCommittedGenerationMarker() throws {
        let cases: [(RemoteSyncReadingPlanDefinitionStore.PublicationBoundary, String, Bool)] = [
            (.prepared, "prepared", false),
            (.oldMoved, "old-moved", false),
            (.newPublished, "new-published", false),
            (.graphCommitted, "graph-committed", true),
        ]
        let fileName = "Recoverable.properties"
        let oldBytes = Data("1=Gen.1\n".utf8)
        let newBytes = Data("1=Matt.1\n".utf8)

        for (boundary, label, graphCommitted) in cases {
            let rootDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let storeDirectory = rootDirectory.appendingPathComponent("stores", isDirectory: true)
            let directory = rootDirectory.appendingPathComponent("readingplan", isDirectory: true)
            try FileManager.default.createDirectory(
                at: storeDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try oldBytes.write(to: directory.appendingPathComponent(fileName))

            let persistentStore = try makePersistentReadingPlanRestoreStore(in: storeDirectory)
            let context = ModelContext(persistentStore.container)
            let settingsStore = SettingsStore(modelContext: context)
            let interruptedStore = RemoteSyncReadingPlanDefinitionStore(
                userPlanDirectory: directory,
                publicationCheckpoint: { observedBoundary in
                    if observedBoundary == boundary { throw CancellationError() }
                }
            )
            XCTAssertThrowsError(
                try interruptedStore.withPublishingLocalDefinition(
                    .init(planCode: "Recoverable", propertiesData: newBytes),
                    modelContext: context,
                    settingsStore: settingsStore
                ) { changed in
                    XCTAssertTrue(changed, label)
                    return true
                },
                label
            )

            let recoveryContext = ModelContext(persistentStore.container)
            let recoverySettingsStore = SettingsStore(modelContext: recoveryContext)
            let recoveryStore = RemoteSyncReadingPlanDefinitionStore(
                userPlanDirectory: directory
            )
            try recoveryStore.recoverPendingPublication(settingsStore: recoverySettingsStore)
            XCTAssertEqual(
                try Data(contentsOf: directory.appendingPathComponent(fileName)),
                graphCommitted ? newBytes : oldBytes,
                label
            )

            let publicationRows = try recoveryContext.fetch(
                FetchDescriptor<ReadingPlanDefinitionPublicationState>()
            )
            XCTAssertEqual(publicationRows.count, graphCommitted ? 1 : 0, label)
            XCTAssertEqual(publicationRows.first?.committedGeneration != nil, graphCommitted, label)
            let artifacts = try FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)
                .filter { $0.hasPrefix(".readingplan.definition-") }
            XCTAssertTrue(artifacts.isEmpty, "\(label): \(artifacts)")

            try recoveryStore.recoverPendingPublication(settingsStore: recoverySettingsStore)
            XCTAssertEqual(
                try Data(contentsOf: directory.appendingPathComponent(fileName)),
                graphCommitted ? newBytes : oldBytes,
                label
            )
            try? FileManager.default.removeItem(at: rootDirectory)
        }
    }

    /**
     Verifies recovery rejects journal-controlled paths and symlinks before deleting any artifact.

     A forged basename, an exact-name staging symlink, and a symlinked journal each target retained
     data. Recovery must fail closed and preserve both the live definition and every external target.
     */
    func testDefinitionRecoveryRejectsUnsafeJournalArtifactsBeforeDeletion() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = rootDirectory.appendingPathComponent("readingplan", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let liveURL = directory.appendingPathComponent("Retained.properties")
        let liveData = Data("1=Gen.1\n".utf8)
        try liveData.write(to: liveURL)
        let victimURL = rootDirectory.appendingPathComponent("retained-victim", isDirectory: true)
        try FileManager.default.createDirectory(at: victimURL, withIntermediateDirectories: true)
        let victimFileURL = victimURL.appendingPathComponent("sentinel")
        let victimData = Data("retain".utf8)
        try victimData.write(to: victimFileURL)
        let journalURL = rootDirectory.appendingPathComponent(
            ".readingplan.definition-publication.json"
        )
        let identifier = UUID().uuidString.lowercased()
        let validStagingName = ".readingplan.definition-staging-\(identifier)"
        let validBackupName = ".readingplan.definition-backup-\(identifier)"

        func journalData(stagingName: String) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: [
                    "identifier": identifier,
                    "stagingName": stagingName,
                    "backupName": validBackupName,
                    "hadLiveDirectory": true,
                    "previousDefinitionDigest": String(repeating: "0", count: 64),
                    "publishedDefinitionDigest": String(repeating: "1", count: 64),
                    "phase": "prepared",
                ],
                options: [.sortedKeys]
            )
        }

        let container = try makeReadingPlanRestoreModelContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        let store = RemoteSyncReadingPlanDefinitionStore(userPlanDirectory: directory)
        try journalData(stagingName: "../retained-victim").write(to: journalURL)
        XCTAssertThrowsError(try store.recoverPendingPublication(settingsStore: settingsStore)) {
            XCTAssertEqual(
                $0 as? RemoteSyncReadingPlanDefinitionError,
                .recoveryFailed("readingplan")
            )
        }
        XCTAssertEqual(try Data(contentsOf: victimFileURL), victimData)
        XCTAssertEqual(try Data(contentsOf: liveURL), liveData)

        try FileManager.default.removeItem(at: journalURL)
        let stagingURL = rootDirectory.appendingPathComponent(validStagingName)
        try FileManager.default.createSymbolicLink(at: stagingURL, withDestinationURL: victimURL)
        try journalData(stagingName: validStagingName).write(to: journalURL)
        XCTAssertThrowsError(try store.recoverPendingPublication(settingsStore: settingsStore)) {
            XCTAssertEqual(
                $0 as? RemoteSyncReadingPlanDefinitionError,
                .recoveryFailed("readingplan")
            )
        }
        XCTAssertEqual(try Data(contentsOf: victimFileURL), victimData)
        XCTAssertEqual(try Data(contentsOf: liveURL), liveData)

        try FileManager.default.removeItem(at: stagingURL)
        try FileManager.default.removeItem(at: journalURL)
        let journalTargetURL = rootDirectory.appendingPathComponent("journal-target.json")
        let journalTargetData = try journalData(stagingName: validStagingName)
        try journalTargetData.write(to: journalTargetURL)
        try FileManager.default.createSymbolicLink(
            at: journalURL,
            withDestinationURL: journalTargetURL
        )
        XCTAssertThrowsError(try store.recoverPendingPublication(settingsStore: settingsStore)) {
            XCTAssertEqual(
                $0 as? RemoteSyncReadingPlanDefinitionError,
                .recoveryFailed("readingplan")
            )
        }
        XCTAssertEqual(try Data(contentsOf: journalTargetURL), journalTargetData)
        XCTAssertEqual(try Data(contentsOf: victimFileURL), victimData)
        XCTAssertEqual(try Data(contentsOf: liveURL), liveData)
    }

    /**
     Verifies reading-plan patch replay commits each archive before opening the next archive.

     The first exact Room archive contains no row mutations but must durably record its applied patch
     status. The second archive carries an unsupported Room version and must fail without rolling back
     that earlier commit or recording its own patch status.
     */
    func testReadingPlanPatchApplyCommitsEachArchiveBeforeLaterSchemaFailure() throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userPlanDirectory = rootDirectory.appendingPathComponent("readingplan", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let firstDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [],
            statuses: []
        )
        defer { try? FileManager.default.removeItem(at: firstDatabaseURL) }
        let secondDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [],
            statuses: []
        )
        defer { try? FileManager.default.removeItem(at: secondDatabaseURL) }
        var database: OpaquePointer?
        guard sqlite3_open(secondDatabaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }
        XCTAssertEqual(
            sqlite3_exec(database, "PRAGMA user_version = 2;", nil, nil, nil),
            SQLITE_OK
        )
        sqlite3_close(database)

        let firstArchive = try makeReadingPlanPatchArchive(
            patchDatabaseURL: firstDatabaseURL,
            sourceDevice: "android-archive-boundary",
            patchNumber: 1,
            fileTimestamp: 900
        )
        defer { try? FileManager.default.removeItem(at: firstArchive.archiveFileURL) }
        let secondArchive = try makeReadingPlanPatchArchive(
            patchDatabaseURL: secondDatabaseURL,
            sourceDevice: "android-archive-boundary",
            patchNumber: 2,
            fileTimestamp: 1_000
        )
        defer { try? FileManager.default.removeItem(at: secondArchive.archiveFileURL) }

        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: context)
        XCTAssertThrowsError(
            try RemoteSyncReadingPlanPatchApplyService(
                userPlanDirectory: userPlanDirectory,
                temporaryDirectory: rootDirectory,
                planFetcher: { try $0.fetch(FetchDescriptor<ReadingPlan>()) }
            ).applyPatchArchives(
                [firstArchive, secondArchive],
                modelContext: context,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncAndroidDatabaseContractError,
                .invalidUserVersion(expected: 1, actual: 2)
            )
        }
        XCTAssertEqual(
            RemoteSyncPatchStatusStore(settingsStore: settingsStore)
                .statuses(for: .readingPlans).map(\.patchNumber),
            [1]
        )
    }

    /** Verifies a bundled-plan initial archive uses the exact Android reading-plan table set. */
    func testBundledInitialUploadUsesExactAndroidReadingPlanTables() async throws {
        let rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let container = try makeReadingPlanRestoreModelContainer()
        let context = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: context)
        let template = try XCTUnwrap(ReadingPlanService.availablePlans.first)
        _ = try ReadingPlanService.startPlan(template: template, modelContext: context)
        let adapter = ReadingPlanMockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/sync/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 0,
                timestamp: 1,
                parentID: "/sync",
                mimeType: "application/gzip"
            )
        )
        let service = RemoteSyncInitialBackupUploadService(
            adapter: adapter,
            deviceIdentifier: "device",
            readingPlanSnapshotService: RemoteSyncReadingPlanSnapshotService(
                userPlanDirectory: rootDirectory.appendingPathComponent("readingplan")
            ),
            temporaryDirectory: rootDirectory,
            retryDirectory: rootDirectory.appendingPathComponent("retry")
        )
        _ = try await service.uploadInitialBackup(
            for: .readingPlans,
            bootstrapState: RemoteSyncBootstrapState(syncFolderID: "/sync"),
            modelContext: context,
            settingsStore: settingsStore
        )
        let uploads = await adapter.uploadedFilesSnapshot()
        let databaseURL = rootDirectory.appendingPathComponent("initial.sqlite3")
        try gunzipTestData(try XCTUnwrap(uploads.first).data).write(to: databaseURL)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        let openDatabase = try XCTUnwrap(database)
        defer { sqlite3_close(openDatabase) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                openDatabase,
                "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        var tableNames: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            tableNames.append(String(cString: try XCTUnwrap(sqlite3_column_text(statement, 0))))
        }
        XCTAssertEqual(
            tableNames,
            [
                "LogEntry",
                "ReadingPlan",
                "ReadingPlanStatus",
                "SyncConfiguration",
                "SyncStatus",
                "room_master_table",
            ]
        )
    }
}
