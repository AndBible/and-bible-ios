import XCTest
@testable import BibleCore
import CLibSword
import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class AndBibleTests: XCTestCase {
    private var temporarySwordModulePaths: [String] = []

    override func tearDown() {
        let fm = FileManager.default
        for path in temporarySwordModulePaths {
            try? fm.removeItem(atPath: path)
        }
        temporarySwordModulePaths.removeAll()
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testAppPreferenceRegistryHasDefinitionForAllKeys() {
        let keys = AppPreferenceKey.allCases
        XCTAssertEqual(keys.count, 35)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(AppPreferenceRegistry.definitions.count, keys.count)

        for key in keys {
            XCTAssertEqual(AppPreferenceRegistry.definition(for: key).key, key)
        }
    }

    func testCriticalPreferenceDefaultsMatchParityContract() {
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .nightModePref3), "system")
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .toolbarButtonActions), "default")
        XCTAssertEqual(AppPreferenceRegistry.stringDefault(for: .bibleViewSwipeMode), "CHAPTER")
        XCTAssertEqual(AppPreferenceRegistry.intDefault(for: .fontSizeMultiplier), 100)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .openLinksInSpecialWindowPref), true)
        XCTAssertEqual(AppPreferenceRegistry.boolDefault(for: .enableBluetoothPref), true)
    }

    func testActionPreferencesUseActionShape() {
        let actionKeys: [AppPreferenceKey] = [
            .discreteHelp,
            .openLinks,
            .crashApp,
        ]

        for key in actionKeys {
            let definition = AppPreferenceRegistry.definition(for: key)
            if case .action = definition.storage {
                // expected
            } else {
                XCTFail("Expected .action storage for \(key.rawValue)")
            }
            if case .action = definition.valueType {
                // expected
            } else {
                XCTFail("Expected .action valueType for \(key.rawValue)")
            }
            XCTAssertNil(definition.defaultValue)
        }
    }

    func testCSVSetEncodingAndDecodingRoundTrip() {
        let encoded = AppPreferenceRegistry.encodeCSVSet(["  KJV  ", "", "ESV", "KJV", "  "])
        XCTAssertEqual(encoded, "ESV,KJV,KJV")
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(encoded), ["ESV", "KJV", "KJV"])
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(nil), [])
        XCTAssertEqual(AppPreferenceRegistry.decodeCSVSet(""), [])
    }

    func testStrongsQueryNormalizationHandlesLeadingZeroes() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "H02022")
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./H02022", "Word//Lemma./H2022"]
        )
    }

    func testStrongsQueryNormalizationAcceptsDecoratedInput() {
        let options = StrongsSearchSupport.normalizedQueryOptions(for: "lemma:strong:g00123")
        XCTAssertEqual(
            options?.entryAttributeQueries,
            ["Word//Lemma./G00123", "Word//Lemma./G123"]
        )
    }

    func testParseVerseKeySupportsHumanReadableFormat() {
        let parsed = StrongsSearchSupport.parseVerseKey("I Samuel 2:3")
        XCTAssertEqual(parsed?.book, "I Samuel")
        XCTAssertEqual(parsed?.chapter, 2)
        XCTAssertEqual(parsed?.verse, 3)
    }

    func testParseVerseKeySupportsOsisFormat() {
        let parsed = StrongsSearchSupport.parseVerseKey("Gen.1.1")
        XCTAssertEqual(parsed?.book, "Genesis")
        XCTAssertEqual(parsed?.chapter, 1)
        XCTAssertEqual(parsed?.verse, 1)
    }

    func testParseVerseKeySupportsOsisFormatWithSuffix() {
        let parsed = StrongsSearchSupport.parseVerseKey("Gen.1.1!crossReference.a")
        XCTAssertEqual(parsed?.book, "Genesis")
        XCTAssertEqual(parsed?.chapter, 1)
        XCTAssertEqual(parsed?.verse, 1)
    }

    func testStrongsSearchFindAllOccurrencesReturnsBundledKJVMatches() throws {
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: modulePath),
            "Expected SwordManager to initialize against a temporary bundled sword module path"
        )
        let installedModules = manager.installedModules()
        XCTAssertTrue(
            installedModules.contains(where: { $0.name == "KJV" && $0.features.contains(.strongsNumbers) }),
            "Expected bundled KJV module with Strong's support to be installed for regression testing"
        )

        let module = try XCTUnwrap(
            manager.module(named: "KJV"),
            "Expected bundled KJV module to be available for Strong's regression testing"
        )
        let queryOptions = try XCTUnwrap(
            StrongsSearchSupport.normalizedQueryOptions(for: "H02022"),
            "Expected H02022 to normalize into entry-attribute Strong's search queries"
        )

        let hits = StrongsSearchSupport.searchVerseHits(in: module, queryOptions: queryOptions)

        XCTAssertFalse(
            hits.isEmpty,
            "Expected the bundled KJV Strong's search for H02022 to return at least one verse"
        )
        XCTAssertTrue(
            hits.allSatisfy { !$0.reference.isEmpty },
            "Expected Strong's hits to parse into verse references"
        )
    }

    func testBookmarkStoreBibleBookmarksCanFilterByLabel() throws {
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
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let store = BookmarkStore(modelContext: ModelContext(container))

        let matchingLabel = Label(name: "Matching")
        let otherLabel = Label(name: "Other")
        store.insert(matchingLabel)
        store.insert(otherLabel)

        let matchingBookmark = BibleBookmark(kjvOrdinalStart: 1, kjvOrdinalEnd: 1)
        matchingBookmark.book = "Genesis"
        store.insert(matchingBookmark)

        let otherBookmark = BibleBookmark(kjvOrdinalStart: 2, kjvOrdinalEnd: 2)
        otherBookmark.book = "Genesis"
        store.insert(otherBookmark)

        let matchingJunction = BibleBookmarkToLabel()
        matchingJunction.bookmark = matchingBookmark
        matchingJunction.label = matchingLabel
        store.insert(matchingJunction)

        let otherJunction = BibleBookmarkToLabel()
        otherJunction.bookmark = otherBookmark
        otherJunction.label = otherLabel
        store.insert(otherJunction)

        let filtered = store.bibleBookmarks(labelId: matchingLabel.id)

        XCTAssertEqual(filtered.map(\.id), [matchingBookmark.id])
    }

    func testWebDAVPropfindBuildsAuthenticatedRequestAndParsesMultiStatus() async throws {
        let expectedAuth = "Basic \(Data("alice:secret".utf8).base64EncodedString())"
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), expectedAuth)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/remote.php/dav/files/alice/sync")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Self.sampleWebDAVMultiStatusXML.data(using: .utf8)!)
        }

        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )
        let files = try await client.propfind(path: "sync", depth: 1)

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "/remote.php/dav/files/alice/sync/")
        XCTAssertTrue(files[0].isDirectory)
        XCTAssertEqual(files[0].displayName, "sync")
        XCTAssertEqual(files[1].path, "/remote.php/dav/files/alice/sync/1.1.sqlite3.gz")
        XCTAssertFalse(files[1].isDirectory)
        XCTAssertEqual(files[1].contentLength, 12345)
        XCTAssertEqual(files[1].contentType, "application/gzip")
    }

    func testRemoteSyncReadingPlanStatusStorePersistsAndClearsStatuses() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)

        statusStore.setStatus(#"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#, planCode: "y1ot1nt1_OTthenNT", dayNumber: 1)
        statusStore.setStatus(#"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#, planCode: "plan.with.dots", dayNumber: 2)

        XCTAssertEqual(
            statusStore.status(planCode: "y1ot1nt1_OTthenNT", dayNumber: 1),
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
        )
        XCTAssertEqual(
            statusStore.status(planCode: "plan.with.dots", dayNumber: 2),
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
        )

        XCTAssertEqual(
            statusStore.allStatuses(),
            [
                .init(planCode: "plan.with.dots", dayNumber: 2, readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#),
                .init(planCode: "y1ot1nt1_OTthenNT", dayNumber: 1, readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#),
            ]
        )

        statusStore.clearAll()
        XCTAssertTrue(statusStore.allStatuses().isEmpty)
    }

    func testRemoteSyncReadingPlanStatusStorePreservesRemoteStatusIdentifiers() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let remoteStatusID = UUID(uuidString: "12345678-1234-1234-1234-123456789abc")!

        statusStore.setStatus(
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
            planCode: "y1ot1nt1_OTthenNT",
            dayNumber: 1,
            remoteStatusID: remoteStatusID
        )

        XCTAssertEqual(
            statusStore.storedStatus(planCode: "y1ot1nt1_OTthenNT", dayNumber: 1),
            .init(
                planCode: "y1ot1nt1_OTthenNT",
                dayNumber: 1,
                readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
                remoteStatusID: remoteStatusID
            )
        )
        XCTAssertEqual(
            statusStore.status(remoteStatusID: remoteStatusID),
            .init(
                planCode: "y1ot1nt1_OTthenNT",
                dayNumber: 1,
                readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
                remoteStatusID: remoteStatusID
            )
        )
    }

    func testRemoteSyncReadingPlanRestoreReadsAndroidSnapshot() throws {
        let service = RemoteSyncReadingPlanRestoreService()
        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 3
                )
            ],
            statuses: [
                .init(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 3,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )

        let snapshot = try service.readSnapshot(from: databaseURL)

        XCTAssertEqual(snapshot.orphanStatuses, [])
        XCTAssertEqual(snapshot.plans.count, 1)
        XCTAssertEqual(snapshot.plans[0].id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(snapshot.plans[0].planCode, "y1ot1nt1_OTthenNT")
        XCTAssertEqual(snapshot.plans[0].currentDay, 3)
        XCTAssertEqual(snapshot.plans[0].statuses.count, 1)
        XCTAssertEqual(snapshot.plans[0].statuses[0].dayNumber, 3)
    }

    func testRemoteSyncReadingPlanRestoreReplacesLocalPlansAndPreservesAndroidStatuses() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let service = RemoteSyncReadingPlanRestoreService()

        let existingPlan = ReadingPlan(
            planCode: "legacy_plan",
            planName: "Legacy",
            startDate: Date(timeIntervalSince1970: 42),
            currentDay: 1,
            totalDays: 1,
            isActive: true
        )
        modelContext.insert(existingPlan)
        try modelContext.save()

        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 3
                )
            ],
            statuses: [
                .init(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 3,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )

        let snapshot = try service.readSnapshot(from: databaseURL)
        let report = try service.replaceLocalReadingPlans(
            from: snapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        XCTAssertEqual(report.restoredPlanCodes, ["y1ot1nt1_OTthenNT"])
        XCTAssertEqual(report.preservedStatusCount, 1)

        let restoredPlans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(restoredPlans.count, 1)
        XCTAssertEqual(restoredPlans[0].id, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(restoredPlans[0].planCode, "y1ot1nt1_OTthenNT")
        XCTAssertEqual(restoredPlans[0].currentDay, 3)
        XCTAssertTrue(restoredPlans[0].isActive)
        XCTAssertEqual(restoredPlans[0].days?.count, report.restoredDayCount)

        let restoredDays = (restoredPlans[0].days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertTrue(restoredDays[0].isCompleted)
        XCTAssertTrue(restoredDays[1].isCompleted)
        XCTAssertFalse(restoredDays[2].isCompleted)

        XCTAssertEqual(
            statusStore.status(planCode: "y1ot1nt1_OTthenNT", dayNumber: 3),
            #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
        )
    }

    func testRemoteSyncReadingPlanRestoreRejectsUnknownPlanDefinitionsWithoutMutation() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let service = RemoteSyncReadingPlanRestoreService()

        let existingPlan = ReadingPlan(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            planCode: "existing_plan",
            planName: "Existing",
            startDate: Date(timeIntervalSince1970: 100),
            currentDay: 1,
            totalDays: 1,
            isActive: true
        )
        modelContext.insert(existingPlan)
        try modelContext.save()

        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                    planCode: "custom_missing",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1
                )
            ],
            statuses: []
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
                .unsupportedPlanDefinitions(["custom_missing"])
            )
        }

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.map(\.planCode), ["existing_plan"])
        XCTAssertTrue(statusStore.allStatuses().isEmpty)
    }

    func testRemoteSyncReadingPlanRestoreRejectsOrphanStatusesWithoutMutation() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let service = RemoteSyncReadingPlanRestoreService()

        let existingPlan = ReadingPlan(
            id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
            planCode: "existing_plan",
            planName: "Existing",
            startDate: Date(timeIntervalSince1970: 100),
            currentDay: 1,
            totalDays: 1,
            isActive: true
        )
        modelContext.insert(existingPlan)
        try modelContext.save()

        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [],
            statuses: [
                .init(
                    id: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
                    planCode: "orphan_plan",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ]
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
                .orphanStatuses(["orphan_plan"])
            )
        }

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.map(\.planCode), ["existing_plan"])
        XCTAssertTrue(statusStore.allStatuses().isEmpty)
    }

    func testRemoteSyncReadingPlanRestoreRejectsMalformedStatusPayloads() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let service = RemoteSyncReadingPlanRestoreService()

        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":"bad"}"#
                )
            ]
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
                .malformedReadingStatus(planCode: "y1ot1nt1_OTthenNT", dayNumber: 1)
            )
        }
    }

    func testRemoteSyncInitialBackupRestoreDispatchesReadingPlanBackups() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncInitialBackupRestoreService()

        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: UUID(uuidString: "a1000000-0000-0000-0000-000000000011")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 1_024,
                timestamp: 1_735_689_600_000,
                parentID: "/org.andbible.ios-sync-readingplans",
                mimeType: "application/gzip"
            ),
            databaseFileURL: databaseURL,
            schemaVersion: 1
        )

        let report = try service.restoreInitialBackup(
            stagedBackup,
            category: .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report,
            .readingPlans(
                RemoteSyncReadingPlanRestoreReport(
                    restoredPlanCodes: ["y1ot1nt1_OTthenNT"],
                    restoredDayCount: ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })!.totalDays,
                    preservedStatusCount: 1
                )
            )
        )

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.map(\.planCode), ["y1ot1nt1_OTthenNT"])

        let preservedStatuses = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore).allStatuses()
        XCTAssertEqual(
            preservedStatuses,
            [
                .init(
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
                    remoteStatusID: UUID(uuidString: "a1000000-0000-0000-0000-000000000011")!
                )
            ]
        )
    }

    func testRemoteSyncReadingPlanPatchApplyReplaysNewerRowsAndRecordsPatchStatus() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let restoreService = RemoteSyncReadingPlanRestoreService()
        let patchService = RemoteSyncReadingPlanPatchApplyService()

        let planID = UUID(uuidString: "d1000000-0000-0000-0000-000000000001")!
        let baselineStatusID = UUID(uuidString: "d1000000-0000-0000-0000-000000000011")!
        let patchStatusID = UUID(uuidString: "d1000000-0000-0000-0000-000000000022")!

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: baselineStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalReadingPlans(
            from: initialSnapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlan",
                entityID1: .blob(uuidBlob(planID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlanStatus",
                entityID1: .blob(uuidBlob(baselineStatusID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: patchStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(uuidBlob(planID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(uuidBlob(patchStatusID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeReadingPlanPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "pixel",
            patchNumber: 2,
            fileTimestamp: 1_735_689_800_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 2)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(report.restoredPlanCodes, ["y1ot1nt1_OTthenNT"])
        XCTAssertEqual(report.preservedStatusCount, 2)

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].currentDay, 2)

        let days = (plans[0].days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertTrue(days[0].isCompleted)
        XCTAssertTrue(days[1].isCompleted)

        XCTAssertEqual(
            statusStore.storedStatus(planCode: "y1ot1nt1_OTthenNT", dayNumber: 2),
            .init(
                planCode: "y1ot1nt1_OTthenNT",
                dayNumber: 2,
                readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#,
                remoteStatusID: patchStatusID
            )
        )
        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                .init(
                    sourceDevice: "pixel",
                    patchNumber: 2,
                    sizeBytes: Int64((try FileManager.default.attributesOfItem(atPath: stagedArchive.archiveFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0),
                    appliedDate: 1_735_689_800_000
                )
            ]
        )
    }

    func testRemoteSyncReadingPlanPatchApplyDeletesStatusesByRemoteIdentifier() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let restoreService = RemoteSyncReadingPlanRestoreService()
        let patchService = RemoteSyncReadingPlanPatchApplyService()

        let planID = UUID(uuidString: "d2000000-0000-0000-0000-000000000001")!
        let statusID = UUID(uuidString: "d2000000-0000-0000-0000-000000000011")!

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: statusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalReadingPlans(
            from: initialSnapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlanStatus",
                entityID1: .blob(uuidBlob(statusID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "tablet"
            ),
            for: .readingPlans
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [],
            statuses: [],
            logEntries: [
                .init(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(uuidBlob(statusID)),
                    entityID2: .text(""),
                    type: .delete,
                    lastUpdated: 2_000,
                    sourceDevice: "tablet"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeReadingPlanPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "tablet",
            patchNumber: 3,
            fileTimestamp: 1_735_689_900_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedLogEntryCount, 1)
        XCTAssertNil(statusStore.status(planCode: "y1ot1nt1_OTthenNT", dayNumber: 1))

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        let days = (plans[0].days ?? []).sorted { $0.dayNumber < $1.dayNumber }
        XCTAssertFalse(days[0].isCompleted)
    }

    func testRemoteSyncReadingPlanPatchApplySkipsOlderRows() throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchService = RemoteSyncReadingPlanPatchApplyService()

        let planID = UUID(uuidString: "d3000000-0000-0000-0000-000000000001")!
        let plan = ReadingPlan(
            id: planID,
            planCode: "y1ot1nt1_OTthenNT",
            planName: "Read the Bible in One Year",
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            currentDay: 1,
            totalDays: ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })!.totalDays,
            isActive: true
        )
        modelContext.insert(plan)
        try modelContext.save()

        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlan",
                entityID1: .blob(uuidBlob(planID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 5_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 9
                )
            ],
            statuses: [],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(uuidBlob(planID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 4_000,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeReadingPlanPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "pixel",
            patchNumber: 4,
            fileTimestamp: 1_735_690_000_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 0)
        XCTAssertEqual(report.appliedLogEntryCount, 0)
        XCTAssertEqual(report.skippedLogEntryCount, 1)

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans[0].currentDay, 1)
        XCTAssertTrue(statusStore.allStatuses().isEmpty)
    }

    func testRemoteSyncBookmarkPlaybackSettingsStorePersistsAndClearsEntries() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let store = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        let bibleBookmarkID = UUID(uuidString: "b1000000-0000-0000-0000-000000000001")!
        let genericBookmarkID = UUID(uuidString: "b1000000-0000-0000-0000-000000000002")!

        store.setPlaybackSettingsJSON(#"{"bookId":"KJV","speed":120}"#, for: bibleBookmarkID, kind: .bible)
        store.setPlaybackSettingsJSON(#"{"bookId":"MHC","queue":true}"#, for: genericBookmarkID, kind: .generic)

        XCTAssertEqual(
            store.playbackSettingsJSON(for: bibleBookmarkID, kind: .bible),
            #"{"bookId":"KJV","speed":120}"#
        )
        XCTAssertEqual(
            store.playbackSettingsJSON(for: genericBookmarkID, kind: .generic),
            #"{"bookId":"MHC","queue":true}"#
        )
        XCTAssertEqual(
            store.allEntries(),
            [
                .init(
                    bookmarkKind: .bible,
                    bookmarkID: bibleBookmarkID,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":120}"#
                ),
                .init(
                    bookmarkKind: .generic,
                    bookmarkID: genericBookmarkID,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#
                ),
            ]
        )

        store.clearAll()
        XCTAssertTrue(store.allEntries().isEmpty)
    }

    func testRemoteSyncBookmarkLabelAliasStorePersistsAndClearsAliases() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let store = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)
        let remoteSpeakID = UUID(uuidString: "c1000000-0000-0000-0000-000000000001")!
        let remoteUnlabeledID = UUID(uuidString: "c1000000-0000-0000-0000-000000000002")!

        store.setAlias(remoteLabelID: remoteSpeakID, localLabelID: Label.speakLabelId)
        store.setAlias(remoteLabelID: remoteUnlabeledID, localLabelID: Label.unlabeledId)

        XCTAssertEqual(store.localLabelID(forRemoteLabelID: remoteSpeakID), Label.speakLabelId)
        XCTAssertEqual(store.localLabelID(forRemoteLabelID: remoteUnlabeledID), Label.unlabeledId)
        XCTAssertEqual(
            store.allAliases(),
            [
                .init(remoteLabelID: remoteSpeakID, localLabelID: Label.speakLabelId),
                .init(remoteLabelID: remoteUnlabeledID, localLabelID: Label.unlabeledId),
            ]
        )

        store.clearAll()
        XCTAssertTrue(store.allAliases().isEmpty)
    }

    func testRemoteSyncBookmarkRestoreReadsAndroidSnapshot() throws {
        let service = RemoteSyncBookmarkRestoreService()
        let speakLabelID = UUID(uuidString: "d1000000-0000-0000-0000-000000000001")!
        let userLabelID = UUID(uuidString: "d1000000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "d1000000-0000-0000-0000-000000000020")!
        let genericBookmarkID = UUID(uuidString: "d1000000-0000-0000-0000-000000000021")!
        let studyPadEntryID = UUID(uuidString: "d1000000-0000-0000-0000-000000000030")!

        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: speakLabelID, name: Label.speakLabelName, colour: Int(Int32(bitPattern: 0xFFFF0000))),
                .init(id: userLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)), favourite: true, type: "HIGHLIGHT")
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 10,
                    kjvOrdinalEnd: 12,
                    ordinalStart: 10,
                    ordinalEnd: 12,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":110}"#,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    book: "Genesis",
                    startOffset: 3,
                    endOffset: 8,
                    primaryLabelID: speakLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_000_100),
                    wholeVerse: false,
                    type: "EXAMPLE",
                    customIcon: "star",
                    editActionMode: "APPEND",
                    editActionContent: "Amen"
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Bible note")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: userLabelID, orderNumber: 2, indentLevel: 1, expandContent: false)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.1",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_200),
                    bookInitials: "MHC",
                    ordinalStart: 5,
                    ordinalEnd: 5,
                    primaryLabelID: userLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_000_300),
                    wholeVerse: true,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#
                )
            ],
            genericNotes: [
                .init(bookmarkID: genericBookmarkID, notes: "Generic note")
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: userLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: userLabelID, orderNumber: 4, indentLevel: 2)
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Study text")
            ]
        )

        let snapshot = try service.readSnapshot(from: databaseURL)

        XCTAssertEqual(snapshot.labels.count, 2)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: snapshot.labels.map { ($0.name, $0.id) }),
            [
                Label.speakLabelName: speakLabelID,
                "Prayer": userLabelID,
            ]
        )
        XCTAssertEqual(snapshot.bibleBookmarks.count, 1)
        XCTAssertEqual(snapshot.bibleBookmarks[0].id, bibleBookmarkID)
        XCTAssertEqual(snapshot.bibleBookmarks[0].notes, "Bible note")
        XCTAssertEqual(snapshot.bibleBookmarks[0].primaryLabelID, speakLabelID)
        XCTAssertEqual(snapshot.bibleBookmarks[0].labelLinks, [
            .init(labelID: userLabelID, orderNumber: 2, indentLevel: 1, expandContent: false)
        ])
        XCTAssertEqual(snapshot.genericBookmarks.count, 1)
        XCTAssertEqual(snapshot.genericBookmarks[0].notes, "Generic note")
        XCTAssertEqual(snapshot.studyPadEntries, [
            .init(id: studyPadEntryID, labelID: userLabelID, orderNumber: 4, indentLevel: 2, text: "Study text")
        ])
    }

    func testRemoteSyncBookmarkRestoreReplacesLocalDataAndPreservesAndroidFidelity() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncBookmarkRestoreService()

        let legacyLabel = Label(name: "Legacy")
        modelContext.insert(legacyLabel)
        let legacyBookmark = BibleBookmark(kjvOrdinalStart: 1, kjvOrdinalEnd: 1)
        legacyBookmark.book = "Genesis"
        modelContext.insert(legacyBookmark)
        try modelContext.save()

        let remoteSpeakID = UUID(uuidString: "e1000000-0000-0000-0000-000000000001")!
        let remoteUnlabeledID = UUID(uuidString: "e1000000-0000-0000-0000-000000000002")!
        let remoteParagraphID = UUID(uuidString: "e1000000-0000-0000-0000-000000000003")!
        let userLabelID = UUID(uuidString: "e1000000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "e1000000-0000-0000-0000-000000000020")!
        let genericBookmarkID = UUID(uuidString: "e1000000-0000-0000-0000-000000000021")!
        let studyPadEntryID = UUID(uuidString: "e1000000-0000-0000-0000-000000000030")!

        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteSpeakID, name: Label.speakLabelName, colour: Int(Int32(bitPattern: 0xFFFF9999)), customIcon: "microphone"),
                .init(id: remoteUnlabeledID, name: Label.unlabeledName, colour: Int(Int32(bitPattern: 0xFFFFFF99))),
                .init(id: remoteParagraphID, name: Label.paragraphBreakLabelName, colour: Int(Int32(bitPattern: 0xFF99CCFF))),
                .init(id: userLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)), favourite: true, type: "HIGHLIGHT", customIcon: "heart")
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 15,
                    kjvOrdinalEnd: 16,
                    ordinalStart: 15,
                    ordinalEnd: 16,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":125,"speakFootnotes":true}"#,
                    createdAt: Date(timeIntervalSince1970: 1_700_100_000),
                    book: "Exodus",
                    startOffset: 2,
                    endOffset: 9,
                    primaryLabelID: remoteSpeakID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_100_100),
                    wholeVerse: false,
                    type: "EXAMPLE",
                    customIcon: "star",
                    editActionMode: "APPEND",
                    editActionContent: "Amen"
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Bible note")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: userLabelID, orderNumber: 3, indentLevel: 1, expandContent: false),
                .init(bookmarkID: bibleBookmarkID, labelID: remoteParagraphID, orderNumber: 4, indentLevel: 0, expandContent: true)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.1",
                    createdAt: Date(timeIntervalSince1970: 1_700_100_200),
                    bookInitials: "MHC",
                    ordinalStart: 4,
                    ordinalEnd: 4,
                    primaryLabelID: remoteUnlabeledID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_100_300),
                    wholeVerse: true,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#,
                    customIcon: "link",
                    editActionMode: "PREPEND",
                    editActionContent: "Intro"
                )
            ],
            genericNotes: [
                .init(bookmarkID: genericBookmarkID, notes: "Generic note")
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: userLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: userLabelID, orderNumber: 7, indentLevel: 2)
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Study text")
            ]
        )

        let snapshot = try service.readSnapshot(from: databaseURL)
        let report = try service.replaceLocalBookmarks(
            from: snapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report,
            RemoteSyncBookmarkRestoreReport(
                restoredLabelCount: 4,
                restoredBibleBookmarkCount: 1,
                restoredGenericBookmarkCount: 1,
                restoredStudyPadEntryCount: 1,
                preservedPlaybackSettingsCount: 2,
                preservedSystemLabelAliasCount: 3
            )
        )

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertEqual(labels.count, 4)
        XCTAssertNil(labels.first(where: { $0.name == "Legacy" }))
        XCTAssertEqual(labels.first(where: { $0.name == Label.speakLabelName })?.id, Label.speakLabelId)
        XCTAssertEqual(labels.first(where: { $0.name == Label.unlabeledName })?.id, Label.unlabeledId)
        XCTAssertEqual(labels.first(where: { $0.name == Label.paragraphBreakLabelName })?.id, Label.paragraphBreakLabelId)
        XCTAssertEqual(labels.first(where: { $0.name == "Prayer" })?.id, userLabelID)

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.count, 1)
        XCTAssertEqual(bibleBookmarks[0].id, bibleBookmarkID)
        XCTAssertEqual(bibleBookmarks[0].book, "Exodus")
        XCTAssertEqual(bibleBookmarks[0].primaryLabelId, Label.speakLabelId)
        XCTAssertEqual(bibleBookmarks[0].notes?.notes, "Bible note")
        XCTAssertEqual(bibleBookmarks[0].playbackSettings?.bookId, "KJV")
        XCTAssertEqual(bibleBookmarks[0].type, "EXAMPLE")
        XCTAssertEqual(bibleBookmarks[0].customIcon, "star")
        XCTAssertEqual(bibleBookmarks[0].editAction, EditAction(mode: .append, content: "Amen"))

        let genericBookmarks = try modelContext.fetch(FetchDescriptor<GenericBookmark>())
        XCTAssertEqual(genericBookmarks.count, 1)
        XCTAssertEqual(genericBookmarks[0].id, genericBookmarkID)
        XCTAssertEqual(genericBookmarks[0].primaryLabelId, Label.unlabeledId)
        XCTAssertEqual(genericBookmarks[0].notes?.notes, "Generic note")
        XCTAssertEqual(genericBookmarks[0].playbackSettings?.bookId, "MHC")
        XCTAssertEqual(genericBookmarks[0].customIcon, "link")
        XCTAssertEqual(genericBookmarks[0].editAction, EditAction(mode: .prepend, content: "Intro"))

        let bibleLinks = try modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>())
        XCTAssertEqual(bibleLinks.count, 2)
        XCTAssertEqual(
            Set(bibleLinks.compactMap { $0.label?.id }),
            Set([userLabelID, Label.paragraphBreakLabelId])
        )
        XCTAssertEqual(
            bibleLinks.first(where: { $0.label?.id == userLabelID })?.orderNumber,
            3
        )

        let genericLinks = try modelContext.fetch(FetchDescriptor<GenericBookmarkToLabel>())
        XCTAssertEqual(genericLinks.count, 1)
        XCTAssertEqual(genericLinks[0].label?.id, userLabelID)

        let studyPadEntries = try modelContext.fetch(FetchDescriptor<StudyPadTextEntry>())
        XCTAssertEqual(studyPadEntries.count, 1)
        XCTAssertEqual(studyPadEntries[0].id, studyPadEntryID)
        XCTAssertEqual(studyPadEntries[0].label?.id, userLabelID)
        XCTAssertEqual(studyPadEntries[0].textEntry?.text, "Study text")

        let playbackStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        XCTAssertEqual(
            playbackStore.allEntries(),
            [
                .init(
                    bookmarkKind: .bible,
                    bookmarkID: bibleBookmarkID,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":125,"speakFootnotes":true}"#
                ),
                .init(
                    bookmarkKind: .generic,
                    bookmarkID: genericBookmarkID,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#
                ),
            ]
        )

        let aliasStore = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)
        XCTAssertEqual(
            aliasStore.allAliases(),
            [
                .init(remoteLabelID: remoteSpeakID, localLabelID: Label.speakLabelId),
                .init(remoteLabelID: remoteUnlabeledID, localLabelID: Label.unlabeledId),
                .init(remoteLabelID: remoteParagraphID, localLabelID: Label.paragraphBreakLabelId),
            ]
        )
    }

    func testRemoteSyncBookmarkRestoreRejectsOrphanReferencesWithoutMutation() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let service = RemoteSyncBookmarkRestoreService()
        let missingLabelID = UUID(uuidString: "f1000000-0000-0000-0000-000000000001")!
        let bibleBookmarkID = UUID(uuidString: "f1000000-0000-0000-0000-000000000002")!
        let studyPadEntryID = UUID(uuidString: "f1000000-0000-0000-0000-000000000003")!

        let legacyLabel = Label(name: "Legacy")
        modelContext.insert(legacyLabel)
        try modelContext.save()

        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 1,
                    kjvOrdinalEnd: 1,
                    ordinalStart: 1,
                    ordinalEnd: 1,
                    createdAt: Date(timeIntervalSince1970: 1_700_200_000),
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_700_200_100)
                )
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: missingLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: missingLabelID, orderNumber: 1, indentLevel: 0)
            ],
            studyPadTexts: []
        )

        XCTAssertThrowsError(try service.readSnapshot(from: databaseURL)) { error in
            XCTAssertEqual(
                error as? RemoteSyncBookmarkRestoreError,
                .orphanReferences([
                    "BibleBookmarkToLabel.labelId=\(missingLabelID.uuidString) missing label",
                    "StudyPadTextEntry.id=\(studyPadEntryID.uuidString) missing StudyPadTextEntryText",
                    "StudyPadTextEntry.labelId=\(missingLabelID.uuidString) missing label for entry \(studyPadEntryID.uuidString)",
                ])
            )
        }

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertEqual(labels.map(\.name), ["Legacy"])
    }

    func testRemoteSyncInitialBackupRestoreDispatchesBookmarkBackups() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let service = RemoteSyncInitialBackupRestoreService()
        let remoteSpeakID = UUID(uuidString: "ab000000-0000-0000-0000-000000000001")!
        let bibleBookmarkID = UUID(uuidString: "ab000000-0000-0000-0000-000000000010")!

        let databaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteSpeakID, name: Label.speakLabelName, colour: Int(Int32(bitPattern: 0xFFFF9999)))
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 20,
                    kjvOrdinalEnd: 20,
                    ordinalStart: 20,
                    ordinalEnd: 20,
                    playbackSettingsJSON: #"{"bookId":"KJV"}"#,
                    createdAt: Date(timeIntervalSince1970: 1_735_689_600),
                    primaryLabelID: remoteSpeakID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_689_700)
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 2_048,
                timestamp: 1_735_689_600_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: "application/gzip"
            ),
            databaseFileURL: databaseURL,
            schemaVersion: 1
        )

        let report = try service.restoreInitialBackup(
            stagedBackup,
            category: .bookmarks,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            report,
            .bookmarks(
                RemoteSyncBookmarkRestoreReport(
                    restoredLabelCount: 3,
                    restoredBibleBookmarkCount: 1,
                    restoredGenericBookmarkCount: 0,
                    restoredStudyPadEntryCount: 0,
                    preservedPlaybackSettingsCount: 1,
                    preservedSystemLabelAliasCount: 1
                )
            )
        )

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertEqual(labels.count, 3)
        XCTAssertEqual(labels.first(where: { $0.name == Label.speakLabelName })?.id, Label.speakLabelId)

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.map(\.id), [bibleBookmarkID])

        let aliasStore = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)
        XCTAssertEqual(aliasStore.localLabelID(forRemoteLabelID: remoteSpeakID), Label.speakLabelId)
    }

    func testRemoteSyncBookmarkPatchApplyReplaysNewerRowsAndPreservesSystemLabelAliases() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncBookmarkRestoreService()
        let patchService = RemoteSyncBookmarkPatchApplyService()
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let playbackStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
        let aliasStore = RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore)

        let remoteSpeakID = UUID(uuidString: "bb100000-0000-0000-0000-000000000001")!
        let remoteUserLabelID = UUID(uuidString: "bb100000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "bb100000-0000-0000-0000-000000000020")!
        let genericBookmarkID = UUID(uuidString: "bb100000-0000-0000-0000-000000000021")!
        let studyPadEntryID = UUID(uuidString: "bb100000-0000-0000-0000-000000000030")!

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteSpeakID, name: Label.speakLabelName, colour: Int(Int32(bitPattern: 0xFFFF9999))),
                .init(id: remoteUserLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)))
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 40,
                    kjvOrdinalEnd: 41,
                    ordinalStart: 40,
                    ordinalEnd: 41,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":120}"#,
                    createdAt: Date(timeIntervalSince1970: 1_735_700_000),
                    book: "Leviticus",
                    primaryLabelID: remoteUserLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_700_100)
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Old bible note")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: remoteUserLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.1",
                    createdAt: Date(timeIntervalSince1970: 1_735_700_200),
                    bookInitials: "MHC",
                    ordinalStart: 2,
                    ordinalEnd: 2,
                    primaryLabelID: remoteUserLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_700_300),
                    wholeVerse: true,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":true}"#,
                    customIcon: "book"
                )
            ],
            genericNotes: [
                .init(bookmarkID: genericBookmarkID, notes: "Old generic note")
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: remoteUserLabelID, orderNumber: 2, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: remoteUserLabelID, orderNumber: 5, indentLevel: 1)
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Old study text")
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalBookmarks(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        logEntryStore.replaceEntries([
            RemoteSyncLogEntry(
                tableName: "Label",
                entityID1: .blob(uuidBlob(remoteUserLabelID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "seed-device"
            ),
            RemoteSyncLogEntry(
                tableName: "BibleBookmark",
                entityID1: .blob(uuidBlob(bibleBookmarkID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "seed-device"
            ),
            RemoteSyncLogEntry(
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(uuidBlob(bibleBookmarkID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "seed-device"
            ),
            RemoteSyncLogEntry(
                tableName: "GenericBookmark",
                entityID1: .blob(uuidBlob(genericBookmarkID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "seed-device"
            ),
            RemoteSyncLogEntry(
                tableName: "StudyPadTextEntryText",
                entityID1: .blob(uuidBlob(studyPadEntryID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "seed-device"
            ),
        ], for: .bookmarks)

        let patchDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteUserLabelID, name: "Prayer updated", colour: Int(Int32(bitPattern: 0xFF33AA33)), favourite: true)
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 40,
                    kjvOrdinalEnd: 42,
                    ordinalStart: 40,
                    ordinalEnd: 42,
                    playbackSettingsJSON: #"{"bookId":"KJV","speed":140}"#,
                    createdAt: Date(timeIntervalSince1970: 1_735_700_000),
                    book: "Leviticus",
                    primaryLabelID: remoteSpeakID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_701_100),
                    customIcon: "star"
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Patched bible note")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: remoteSpeakID, orderNumber: 3, indentLevel: 0, expandContent: true)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.1",
                    createdAt: Date(timeIntervalSince1970: 1_735_700_200),
                    bookInitials: "MHC",
                    ordinalStart: 2,
                    ordinalEnd: 2,
                    primaryLabelID: remoteSpeakID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_701_300),
                    wholeVerse: true,
                    playbackSettingsJSON: #"{"bookId":"MHC","queue":false}"#,
                    customIcon: "comment"
                )
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Patched study text")
            ],
            logEntries: [
                .init(tableName: "Label", entityID1: .blob(uuidBlob(remoteUserLabelID)), entityID2: .null(), type: .upsert, lastUpdated: 2_000, sourceDevice: "android-a"),
                .init(tableName: "BibleBookmark", entityID1: .blob(uuidBlob(bibleBookmarkID)), entityID2: .null(), type: .upsert, lastUpdated: 2_100, sourceDevice: "android-a"),
                .init(tableName: "BibleBookmarkNotes", entityID1: .blob(uuidBlob(bibleBookmarkID)), entityID2: .null(), type: .upsert, lastUpdated: 2_200, sourceDevice: "android-a"),
                .init(tableName: "BibleBookmarkToLabel", entityID1: .blob(uuidBlob(bibleBookmarkID)), entityID2: .blob(uuidBlob(remoteSpeakID)), type: .upsert, lastUpdated: 2_300, sourceDevice: "android-a"),
                .init(tableName: "GenericBookmark", entityID1: .blob(uuidBlob(genericBookmarkID)), entityID2: .null(), type: .upsert, lastUpdated: 2_400, sourceDevice: "android-a"),
                .init(tableName: "StudyPadTextEntryText", entityID1: .blob(uuidBlob(studyPadEntryID)), entityID2: .null(), type: .upsert, lastUpdated: 2_500, sourceDevice: "android-a"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeBookmarkPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-a",
            patchNumber: 1,
            fileTimestamp: 3_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 6)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(
            report.restoreReport,
            RemoteSyncBookmarkRestoreReport(
                restoredLabelCount: 4,
                restoredBibleBookmarkCount: 1,
                restoredGenericBookmarkCount: 1,
                restoredStudyPadEntryCount: 1,
                preservedPlaybackSettingsCount: 2,
                preservedSystemLabelAliasCount: 3
            )
        )

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertEqual(labels.first(where: { $0.id == remoteUserLabelID })?.name, "Prayer updated")

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.count, 1)
        XCTAssertEqual(bibleBookmarks[0].primaryLabelId, Label.speakLabelId)
        XCTAssertEqual(bibleBookmarks[0].notes?.notes, "Patched bible note")
        XCTAssertEqual(
            Set(bibleBookmarks[0].bookmarkToLabels?.compactMap { $0.label?.id } ?? []),
            Set([remoteUserLabelID, Label.speakLabelId])
        )

        let genericBookmarks = try modelContext.fetch(FetchDescriptor<GenericBookmark>())
        XCTAssertEqual(genericBookmarks.count, 1)
        XCTAssertEqual(genericBookmarks[0].primaryLabelId, Label.speakLabelId)
        XCTAssertEqual(genericBookmarks[0].customIcon, "comment")

        let studyPadEntries = try modelContext.fetch(FetchDescriptor<StudyPadTextEntry>())
        XCTAssertEqual(studyPadEntries.count, 1)
        XCTAssertEqual(studyPadEntries[0].textEntry?.text, "Patched study text")

        XCTAssertEqual(
            playbackStore.playbackSettingsJSON(for: bibleBookmarkID, kind: .bible),
            #"{"bookId":"KJV","speed":140}"#
        )
        XCTAssertEqual(
            playbackStore.playbackSettingsJSON(for: genericBookmarkID, kind: .generic),
            #"{"bookId":"MHC","queue":false}"#
        )
        XCTAssertEqual(aliasStore.localLabelID(forRemoteLabelID: remoteSpeakID), Label.speakLabelId)
        XCTAssertEqual(patchStatusStore.lastPatchNumber(for: .bookmarks, sourceDevice: "android-a"), 1)
        XCTAssertEqual(
            logEntryStore.entry(
                for: .bookmarks,
                tableName: "Label",
                entityID1: .blob(uuidBlob(remoteUserLabelID)),
                entityID2: .null()
            )?.lastUpdated,
            2_000
        )
    }

    func testRemoteSyncBookmarkPatchApplyDeletesBookmarkChildrenByCompositeIdentifiers() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncBookmarkRestoreService()
        let patchService = RemoteSyncBookmarkPatchApplyService()

        let remoteUserLabelID = UUID(uuidString: "bb200000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "bb200000-0000-0000-0000-000000000020")!
        let genericBookmarkID = UUID(uuidString: "bb200000-0000-0000-0000-000000000021")!

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteUserLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)))
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 50,
                    kjvOrdinalEnd: 50,
                    ordinalStart: 50,
                    ordinalEnd: 50,
                    createdAt: Date(timeIntervalSince1970: 1_735_710_000),
                    primaryLabelID: remoteUserLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_710_100)
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Delete me")
            ],
            bibleLinks: [
                .init(bookmarkID: bibleBookmarkID, labelID: remoteUserLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.2",
                    createdAt: Date(timeIntervalSince1970: 1_735_710_200),
                    bookInitials: "MHC",
                    ordinalStart: 8,
                    ordinalEnd: 8,
                    primaryLabelID: remoteUserLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_710_300)
                )
            ],
            genericNotes: [
                .init(bookmarkID: genericBookmarkID, notes: "Delete generic")
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: remoteUserLabelID, orderNumber: 2, indentLevel: 0, expandContent: true)
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalBookmarks(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let patchDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [],
            logEntries: [
                .init(tableName: "BibleBookmarkNotes", entityID1: .blob(uuidBlob(bibleBookmarkID)), entityID2: .null(), type: .delete, lastUpdated: 2_000, sourceDevice: "android-b"),
                .init(tableName: "BibleBookmarkToLabel", entityID1: .blob(uuidBlob(bibleBookmarkID)), entityID2: .blob(uuidBlob(remoteUserLabelID)), type: .delete, lastUpdated: 2_100, sourceDevice: "android-b"),
                .init(tableName: "GenericBookmarkNotes", entityID1: .blob(uuidBlob(genericBookmarkID)), entityID2: .null(), type: .delete, lastUpdated: 2_200, sourceDevice: "android-b"),
                .init(tableName: "GenericBookmarkToLabel", entityID1: .blob(uuidBlob(genericBookmarkID)), entityID2: .blob(uuidBlob(remoteUserLabelID)), type: .delete, lastUpdated: 2_300, sourceDevice: "android-b"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeBookmarkPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-b",
            patchNumber: 2,
            fileTimestamp: 4_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 4)
        XCTAssertEqual(report.skippedLogEntryCount, 0)

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.count, 1)
        XCTAssertNil(bibleBookmarks[0].notes)
        XCTAssertTrue(bibleBookmarks[0].bookmarkToLabels?.isEmpty ?? true)

        let genericBookmarks = try modelContext.fetch(FetchDescriptor<GenericBookmark>())
        XCTAssertEqual(genericBookmarks.count, 1)
        XCTAssertNil(genericBookmarks[0].notes)
        XCTAssertTrue(genericBookmarks[0].bookmarkToLabels?.isEmpty ?? true)
    }

    func testRemoteSyncBookmarkPatchApplySkipsOlderRows() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncBookmarkRestoreService()
        let patchService = RemoteSyncBookmarkPatchApplyService()
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        let remoteUserLabelID = UUID(uuidString: "bb300000-0000-0000-0000-000000000010")!
        let bibleBookmarkID = UUID(uuidString: "bb300000-0000-0000-0000-000000000020")!

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteUserLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)))
            ],
            bibleBookmarks: [
                .init(
                    id: bibleBookmarkID,
                    kjvOrdinalStart: 60,
                    kjvOrdinalEnd: 60,
                    ordinalStart: 60,
                    ordinalEnd: 60,
                    createdAt: Date(timeIntervalSince1970: 1_735_720_000),
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_720_100)
                )
            ],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Local newer note")
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalBookmarks(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        logEntryStore.replaceEntries([
            .init(
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(uuidBlob(bibleBookmarkID)),
                entityID2: .null(),
                type: .upsert,
                lastUpdated: 5_000,
                sourceDevice: "ios-local"
            )
        ], for: .bookmarks)

        let patchDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [],
            bibleNotes: [
                .init(bookmarkID: bibleBookmarkID, notes: "Older remote note")
            ],
            logEntries: [
                .init(tableName: "BibleBookmarkNotes", entityID1: .blob(uuidBlob(bibleBookmarkID)), entityID2: .null(), type: .upsert, lastUpdated: 4_000, sourceDevice: "android-c")
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeBookmarkPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-c",
            patchNumber: 3,
            fileTimestamp: 5_500
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 0)
        XCTAssertEqual(report.appliedLogEntryCount, 0)
        XCTAssertEqual(report.skippedLogEntryCount, 1)

        let bibleBookmarks = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bibleBookmarks.count, 1)
        XCTAssertEqual(bibleBookmarks[0].notes?.notes, "Local newer note")
        XCTAssertNil(patchStatusStore.status(for: .bookmarks, sourceDevice: "android-c", patchNumber: 3))
        XCTAssertEqual(
            logEntryStore.entry(
                for: .bookmarks,
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(uuidBlob(bibleBookmarkID)),
                entityID2: .null()
            )?.lastUpdated,
            5_000
        )
    }

    func testRemoteSyncBookmarkPatchApplyRunsForeignKeyCleanupForLaterTablesWithoutPatchRows() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let restoreService = RemoteSyncBookmarkRestoreService()
        let patchService = RemoteSyncBookmarkPatchApplyService()

        let remoteUserLabelID = UUID(uuidString: "bb400000-0000-0000-0000-000000000010")!
        let genericBookmarkID = UUID(uuidString: "bb400000-0000-0000-0000-000000000021")!
        let studyPadEntryID = UUID(uuidString: "bb400000-0000-0000-0000-000000000030")!

        let initialDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [
                .init(id: remoteUserLabelID, name: "Prayer", colour: Int(Int32(bitPattern: 0xFF00FF00)))
            ],
            genericBookmarks: [
                .init(
                    id: genericBookmarkID,
                    key: "Entry.3",
                    createdAt: Date(timeIntervalSince1970: 1_735_730_000),
                    bookInitials: "MHC",
                    ordinalStart: 3,
                    ordinalEnd: 3,
                    primaryLabelID: remoteUserLabelID,
                    lastUpdatedOn: Date(timeIntervalSince1970: 1_735_730_100)
                )
            ],
            genericLinks: [
                .init(bookmarkID: genericBookmarkID, labelID: remoteUserLabelID, orderNumber: 1, indentLevel: 0, expandContent: true)
            ],
            studyPadEntries: [
                .init(id: studyPadEntryID, labelID: remoteUserLabelID, orderNumber: 1, indentLevel: 0)
            ],
            studyPadTexts: [
                .init(entryID: studyPadEntryID, text: "Study text")
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalBookmarks(
            from: initialSnapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let patchDatabaseURL = try makeAndroidBookmarksDatabase(
            labels: [],
            logEntries: [
                .init(tableName: "Label", entityID1: .blob(uuidBlob(remoteUserLabelID)), entityID2: .null(), type: .delete, lastUpdated: 2_000, sourceDevice: "android-d")
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let stagedArchive = try makeBookmarkPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android-d",
            patchNumber: 4,
            fileTimestamp: 6_000
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try patchService.applyPatchArchives(
            [stagedArchive],
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 1)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(
            report.restoreReport,
            RemoteSyncBookmarkRestoreReport(
                restoredLabelCount: 3,
                restoredBibleBookmarkCount: 0,
                restoredGenericBookmarkCount: 0,
                restoredStudyPadEntryCount: 0,
                preservedPlaybackSettingsCount: 0,
                preservedSystemLabelAliasCount: 3
            )
        )

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        XCTAssertNil(labels.first(where: { $0.name == "Prayer" }))
        XCTAssertEqual(labels.count, 3)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<GenericBookmark>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<StudyPadTextEntry>()).isEmpty)
    }

    func testWebDAVSearchBuildsSearchRequestBody() async throws {
        let modifiedAfter = Date(timeIntervalSince1970: 1_730_000_000)

        MockURLProtocol.requestHandler = { [self] request in
            XCTAssertEqual(request.httpMethod, "SEARCH")
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/remote.php/dav/files/alice/sync/bookmarks")

            let body = try XCTUnwrap(requestBodyData(for: request))
            let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(bodyString.contains("<d:searchrequest"))
            XCTAssertTrue(bodyString.contains("<d:href>/remote.php/dav/files/alice/sync/bookmarks</d:href>"))
            XCTAssertTrue(bodyString.contains("Sun, 27 Oct 2024 03:33:20 GMT"))

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Self.sampleWebDAVMultiStatusXML.data(using: .utf8)!)
        }

        let client = WebDAVClient(
            baseURL: URL(string: "https://example.com/remote.php/dav/files/alice")!,
            username: "alice",
            password: "secret",
            session: makeMockedURLSession()
        )
        let files = try await client.search(path: "sync/bookmarks", modifiedAfter: modifiedAfter)

        XCTAssertEqual(files.count, 2)
    }

    func testWebDAVMultiStatusParserDecodesPercentEncodedHrefs() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/remote.php/dav/files/alice/Study%20Pad/entry%201.txt</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>entry 1.txt</d:displayname>
                <d:getcontentlength>42</d:getcontentlength>
              </d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        let files = try WebDAVMultiStatusParser.parse(data: Data(xml.utf8))

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].href, "/remote.php/dav/files/alice/Study Pad/entry 1.txt")
        XCTAssertEqual(files[0].path, "/remote.php/dav/files/alice/Study Pad/entry 1.txt")
        XCTAssertEqual(files[0].displayName, "entry 1.txt")
        XCTAssertEqual(files[0].contentLength, 42)
    }

    func testNextCloudSyncAdapterCreatesConfiguredBaseFolderBeforeListing() async throws {
        let requestLog = RequestLog()
        let listingXML = Self.webDAVMultiStatusXML(
            folderPath: "/remote.php/dav/files/alice/AndBible/Sync/",
            fileName: "1.1.sqlite3.gz"
        )

        MockURLProtocol.requestHandler = { request in
            requestLog.append(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? ""
            )

            let path = try XCTUnwrap(request.url?.path)
            let statusCode: Int
            let payload: Data
            switch (request.httpMethod ?? "", path) {
            case ("MKCOL", "/remote.php/dav/files/alice/AndBible"),
                 ("MKCOL", "/remote.php/dav/files/alice/AndBible/Sync"):
                statusCode = 201
                payload = Data()
            case ("PROPFIND", "/remote.php/dav/files/alice/AndBible/Sync"):
                statusCode = 207
                payload = Data(listingXML.utf8)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
                statusCode = 500
                payload = Data()
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, payload)
        }

        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: "AndBible/Sync"
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let files = try await adapter.listFiles()

        XCTAssertEqual(
            requestLog.snapshot(),
            [
                .init(method: "MKCOL", path: "/remote.php/dav/files/alice/AndBible"),
                .init(method: "MKCOL", path: "/remote.php/dav/files/alice/AndBible/Sync"),
                .init(method: "PROPFIND", path: "/remote.php/dav/files/alice/AndBible/Sync"),
            ]
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].id, "/AndBible/Sync/1.1.sqlite3.gz")
        XCTAssertEqual(files[0].parentID, "/AndBible/Sync")
        XCTAssertEqual(files[0].mimeType, "application/gzip")
    }

    func testNextCloudSyncAdapterTreatsExistingBaseFolderAsReady() async throws {
        let requestLog = RequestLog()

        MockURLProtocol.requestHandler = { request in
            requestLog.append(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? ""
            )

            let path = try XCTUnwrap(request.url?.path)
            let statusCode: Int
            let payload: Data
            switch (request.httpMethod ?? "", path) {
            case ("MKCOL", "/remote.php/dav/files/alice/AndBible"),
                 ("MKCOL", "/remote.php/dav/files/alice/AndBible/Sync"):
                statusCode = 405
                payload = Data()
            case ("PROPFIND", "/remote.php/dav/files/alice/AndBible/Sync"):
                statusCode = 207
                payload = Data(Self.webDAVMultiStatusXML(
                    folderPath: "/remote.php/dav/files/alice/AndBible/Sync/",
                    fileName: "2.1.sqlite3.gz"
                ).utf8)
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "") \(path)")
                statusCode = 500
                payload = Data()
            }

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, payload)
        }

        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: "AndBible/Sync"
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let files = try await adapter.listFiles()

        XCTAssertEqual(files.map(\.id), ["/AndBible/Sync/2.1.sqlite3.gz"])
        XCTAssertEqual(
            requestLog.snapshot().prefix(2).map(\.path),
            [
                "/remote.php/dav/files/alice/AndBible",
                "/remote.php/dav/files/alice/AndBible/Sync",
            ]
        )
    }

    func testNextCloudSyncAdapterUsesSearchForIncrementalListing() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "SEARCH")
            XCTAssertEqual(request.url?.path, "/remote.php/dav/files/alice/sync")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (
                response,
                Data(Self.webDAVMultiStatusXML(
                    folderPath: "/remote.php/dav/files/alice/sync/",
                    fileName: "3.1.sqlite3.gz"
                ).utf8)
            )
        }

        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let files = try await adapter.listFiles(
            parentIDs: ["/sync"],
            modifiedAtLeast: Date(timeIntervalSince1970: 1_730_000_000)
        )

        XCTAssertEqual(files.map(\.id), ["/sync/3.1.sqlite3.gz"])
    }

    func testNextCloudSyncAdapterMakeSyncFolderKnownUploadsAndroidStyleMarker() async throws {
        MockURLProtocol.requestHandler = { [self] request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertTrue(
                try XCTUnwrap(request.url?.path)
                    .hasPrefix("/remote.php/dav/files/alice/bookmarks/device-known-ios-device-")
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), NextCloudSyncAdapter.gzipMimeType)
            XCTAssertTrue(
                requestBodyData(for: request)?.isEmpty ?? true,
                "Expected the secret marker upload to use an empty request body"
            )

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 201,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let secret = try await adapter.makeSyncFolderKnown(
            syncFolderID: "/bookmarks",
            deviceIdentifier: "ios-device"
        )

        XCTAssertTrue(secret.hasPrefix("device-known-ios-device-"))
    }

    func testNextCloudSyncAdapterReportsUnknownFolderWhenMarkerIsMissing() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.url?.path, "/remote.php/dav/files/alice/bookmarks/device-known-ios-device-secret")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let adapter = try NextCloudSyncAdapter(
            configuration: WebDAVSyncConfiguration(
                serverURL: "https://example.com",
                username: "alice",
                folderPath: nil
            ),
            password: "secret",
            session: makeMockedURLSession()
        )

        let known = try await adapter.isSyncFolderKnown(
            syncFolderID: "/bookmarks",
            secretFileName: "device-known-ios-device-secret"
        )

        XCTAssertFalse(known)
    }

    func testRemoteSyncSettingsStoreDefaultsToICloudWhenBackendMissing() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        XCTAssertEqual(store.selectedBackend, .iCloud)
        XCTAssertNil(store.loadWebDAVConfiguration())
        XCTAssertNil(store.webDAVPassword())
    }

    func testRemoteSyncSettingsStorePersistsAndroidCompatibleNextCloudKeys() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        store.selectedBackend = .nextCloud
        try store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: " https://nextcloud.example/remote.php/dav/files/alice ",
                username: " alice ",
                folderPath: " Sync Folder "
            ),
            password: " secret "
        )

        XCTAssertEqual(settingsStore.getString("sync_adapter"), "NEXT_CLOUD")
        XCTAssertEqual(
            settingsStore.getString("gdrive_server_url"),
            "https://nextcloud.example/remote.php/dav/files/alice"
        )
        XCTAssertEqual(settingsStore.getString("gdrive_username"), "alice")
        XCTAssertEqual(settingsStore.getString("gdrive_folder_path"), "Sync Folder")
        XCTAssertEqual(secretStore.secret(forKey: "gdrive_password"), "secret")
        XCTAssertEqual(
            store.loadWebDAVConfiguration(),
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example/remote.php/dav/files/alice",
                username: "alice",
                folderPath: "Sync Folder"
            )
        )
        XCTAssertEqual(store.webDAVPassword(), "secret")
    }

    func testRemoteSyncSettingsStoreFallsBackToICloudForUnknownBackendValue() throws {
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString("sync_adapter", value: "DROPBOX")

        let store = RemoteSyncSettingsStore(
            settingsStore: settingsStore,
            secretStore: InMemorySecretStore()
        )

        XCTAssertEqual(store.selectedBackend, .iCloud)
    }

    func testRemoteSyncSettingsStoreClearsStoredValuesAndPassword() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        store.selectedBackend = .nextCloud
        try store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example",
                username: "alice",
                folderPath: "sync"
            ),
            password: "secret"
        )

        try store.clearWebDAVConfiguration()

        XCTAssertEqual(store.selectedBackend, .nextCloud)
        XCTAssertNil(store.loadWebDAVConfiguration())
        XCTAssertNil(store.webDAVPassword())
        XCTAssertEqual(settingsStore.getString("gdrive_server_url"), "")
        XCTAssertEqual(settingsStore.getString("gdrive_username"), "")
        XCTAssertEqual(settingsStore.getString("gdrive_folder_path"), "")
    }

    func testRemoteSyncSettingsStoreClearsPasswordWhenSaveReceivesWhitespaceOnlySecret() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        try store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example",
                username: "alice",
                folderPath: nil
            ),
            password: "secret"
        )
        XCTAssertEqual(store.webDAVPassword(), "secret")

        try store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example",
                username: "alice",
                folderPath: nil
            ),
            password: "   "
        )

        XCTAssertNil(store.webDAVPassword())
        XCTAssertNil(store.loadWebDAVConfiguration()?.folderPath)
    }

    func testWebDAVSyncConfigurationExpandsServerRootToNextCloudDAVEndpoint() async throws {
        let configuration = WebDAVSyncConfiguration(
            serverURL: "https://nextcloud.example.com",
            username: "alice",
            folderPath: nil
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://nextcloud.example.com/remote.php/dav/files/alice"
            )
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Self.sampleWebDAVMultiStatusXML.data(using: .utf8)!)
        }

        let client = try configuration.makeWebDAVClient(
            password: "secret",
            session: makeMockedURLSession()
        )
        _ = try await client.testConnection()
    }

    func testWebDAVSyncConfigurationPreservesExplicitDAVEndpoint() async throws {
        let configuration = WebDAVSyncConfiguration(
            serverURL: "https://nextcloud.example.com/custom/remote.php/dav/files/alice",
            username: "alice",
            folderPath: nil
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://nextcloud.example.com/custom/remote.php/dav/files/alice"
            )
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Self.sampleWebDAVMultiStatusXML.data(using: .utf8)!)
        }

        let client = try configuration.makeWebDAVClient(
            password: "secret",
            session: makeMockedURLSession()
        )
        _ = try await client.testConnection()
    }

    func testRemoteSyncSettingsStoreMakeWebDAVClientReturnsNilWhenPasswordMissing() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let secretStore = InMemorySecretStore()
        let store = RemoteSyncSettingsStore(settingsStore: settingsStore, secretStore: secretStore)

        try store.saveWebDAVConfiguration(
            WebDAVSyncConfiguration(
                serverURL: "https://nextcloud.example.com",
                username: "alice",
                folderPath: nil
            ),
            password: nil
        )

        XCTAssertNil(try store.makeWebDAVClient(session: makeMockedURLSession()))
    }

    func testRemoteSyncCategoryBuildsAndroidStyleFolderNames() {
        XCTAssertEqual(
            RemoteSyncCategory.bookmarks.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            "org.andbible.ios-sync-bookmarks"
        )
        XCTAssertEqual(
            RemoteSyncCategory.workspaces.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            "org.andbible.ios-sync-workspaces"
        )
        XCTAssertEqual(
            RemoteSyncCategory.readingPlans.syncFolderName(bundleIdentifier: "org.andbible.ios"),
            "org.andbible.ios-sync-readingplans"
        )
    }

    func testRemoteSyncStateStorePersistsBootstrapStateUsingAndroidRawKeys() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncStateStore(settingsStore: settingsStore)

        store.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .bookmarks
        )

        XCTAssertEqual(
            settingsStore.getString("remote_sync.bookmarks.syncId"),
            "/org.andbible.ios-sync-bookmarks"
        )
        XCTAssertEqual(
            settingsStore.getString("remote_sync.bookmarks.deviceFolderId"),
            "/org.andbible.ios-sync-bookmarks/ios-device"
        )
        XCTAssertEqual(
            settingsStore.getString("remote_sync.bookmarks.nextCloudSecretFile"),
            "device-known-ios-device-secret"
        )
        XCTAssertEqual(
            store.bootstrapState(for: .bookmarks),
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            )
        )
    }

    func testRemoteSyncStateStorePersistsProgressStatePerCategory() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncStateStore(settingsStore: settingsStore)

        store.setProgressState(
            RemoteSyncProgressState(
                lastPatchWritten: 111,
                lastSynchronized: 222,
                disabledForVersion: 7
            ),
            for: .workspaces
        )
        store.setProgressState(
            RemoteSyncProgressState(
                lastPatchWritten: 333,
                lastSynchronized: nil,
                disabledForVersion: nil
            ),
            for: .bookmarks
        )

        XCTAssertEqual(
            store.progressState(for: .workspaces),
            RemoteSyncProgressState(
                lastPatchWritten: 111,
                lastSynchronized: 222,
                disabledForVersion: 7
            )
        )
        XCTAssertEqual(
            store.progressState(for: .bookmarks),
            RemoteSyncProgressState(
                lastPatchWritten: 333,
                lastSynchronized: nil,
                disabledForVersion: nil
            )
        )
    }

    func testRemoteSyncStateStoreClearCategoryDoesNotTouchOtherCategories() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncStateStore(settingsStore: settingsStore)

        store.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/bookmark-sync",
                deviceFolderID: "/bookmark-sync/ios-device",
                secretFileName: "bookmark-secret"
            ),
            for: .bookmarks
        )
        store.setProgressState(
            RemoteSyncProgressState(
                lastPatchWritten: 444,
                lastSynchronized: 555,
                disabledForVersion: 8
            ),
            for: .bookmarks
        )
        store.setBootstrapState(
            RemoteSyncBootstrapState(syncFolderID: "/workspace-sync"),
            for: .workspaces
        )

        store.clearCategory(.bookmarks)

        XCTAssertEqual(store.bootstrapState(for: .bookmarks), RemoteSyncBootstrapState())
        XCTAssertEqual(store.progressState(for: .bookmarks), RemoteSyncProgressState())
        XCTAssertEqual(
            store.bootstrapState(for: .workspaces),
            RemoteSyncBootstrapState(syncFolderID: "/workspace-sync")
        )
    }

    func testRemoteSyncBootstrapCoordinatorReturnsReadyForKnownStoredFolder() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .bookmarks
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: "/org.andbible.ios-sync-bookmarks",
            secretFileName: "device-known-ios-device-secret"
        )

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let status = try await coordinator.inspect(.bookmarks)

        XCTAssertEqual(
            status,
            .ready(
                RemoteSyncBootstrapState(
                    syncFolderID: "/org.andbible.ios-sync-bookmarks",
                    deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                    secretFileName: "device-known-ios-device-secret"
                )
            )
        )
        let events = await adapter.eventsSnapshot()

        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                secretFileName: "device-known-ios-device-secret"
            )
        ])
    }

    func testRemoteSyncBootstrapCoordinatorRepairsMissingDeviceFolderForKnownStoredFolder() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: nil,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .bookmarks
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: "/org.andbible.ios-sync-bookmarks",
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/ios-device",
                name: "ios-device",
                size: 0,
                timestamp: 0,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let status = try await coordinator.inspect(.bookmarks)

        XCTAssertEqual(
            status,
            .ready(
                RemoteSyncBootstrapState(
                    syncFolderID: "/org.andbible.ios-sync-bookmarks",
                    deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                    secretFileName: "device-known-ios-device-secret"
                )
            )
        )
        XCTAssertEqual(
            stateStore.bootstrapState(for: .bookmarks),
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            )
        )
    }

    func testRemoteSyncBootstrapCoordinatorRequiresRemoteAdoptionWhenNamedFolderExists() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let adapter = MockRemoteSyncAdapter()
        await adapter.setListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks",
                name: "org.andbible.ios-sync-bookmarks",
                size: 0,
                timestamp: 123,
                parentID: "/",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let status = try await coordinator.inspect(.bookmarks)

        XCTAssertEqual(
            status,
            .requiresRemoteAdoption(
                RemoteSyncBootstrapCandidate(
                    category: .bookmarks,
                    syncFolderName: "org.andbible.ios-sync-bookmarks",
                    remoteFolderID: "/org.andbible.ios-sync-bookmarks"
                )
            )
        )
    }

    func testRemoteSyncBootstrapCoordinatorClearsStaleBootstrapAndRequestsCreationWhenMarkerMissing() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: "/stale-bookmarks",
                deviceFolderID: "/stale-bookmarks/ios-device",
                secretFileName: "stale-secret"
            ),
            for: .bookmarks
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.setKnownResponse(false, forSyncFolderID: "/stale-bookmarks", secretFileName: "stale-secret")
        await adapter.setListFilesResult([])

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let status = try await coordinator.inspect(.bookmarks)

        XCTAssertEqual(
            status,
            .requiresRemoteCreation(
                RemoteSyncBootstrapCreation(
                    category: .bookmarks,
                    syncFolderName: "org.andbible.ios-sync-bookmarks"
                )
            )
        )
        XCTAssertEqual(stateStore.bootstrapState(for: .bookmarks), RemoteSyncBootstrapState())
    }

    func testRemoteSyncBootstrapCoordinatorAdoptRemoteFolderPersistsMarkerAndDeviceFolder() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let adapter = MockRemoteSyncAdapter()
        await adapter.setMakeKnownResponse("device-known-ios-device-secret")
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/ios-device",
                name: "ios-device",
                size: 0,
                timestamp: 0,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let state = try await coordinator.adoptRemoteFolder(
            for: .bookmarks,
            remoteFolderID: "/org.andbible.ios-sync-bookmarks"
        )

        XCTAssertEqual(
            state,
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            )
        )
        XCTAssertEqual(stateStore.bootstrapState(for: .bookmarks), state)
    }

    func testRemoteSyncBootstrapCoordinatorCreateRemoteFolderCanReplaceExistingRemoteFolder() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let adapter = MockRemoteSyncAdapter()
        await adapter.setMakeKnownResponse("device-known-ios-device-secret")
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks",
                name: "org.andbible.ios-sync-bookmarks",
                size: 0,
                timestamp: 0,
                parentID: "/",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/ios-device",
                name: "ios-device",
                size: 0,
                timestamp: 0,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )

        let coordinator = RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: stateStore,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device"
        )

        let state = try await coordinator.createRemoteFolder(
            for: .bookmarks,
            replacingRemoteFolderID: "/stale-remote-bookmarks"
        )

        XCTAssertEqual(
            state,
            RemoteSyncBootstrapState(
                syncFolderID: "/org.andbible.ios-sync-bookmarks",
                deviceFolderID: "/org.andbible.ios-sync-bookmarks/ios-device",
                secretFileName: "device-known-ios-device-secret"
            )
        )
        let events = await adapter.eventsSnapshot()

        XCTAssertEqual(events, [
            .delete(id: "/stale-remote-bookmarks"),
            .createFolder(name: "org.andbible.ios-sync-bookmarks", parentID: nil),
            .makeKnown(syncFolderID: "/org.andbible.ios-sync-bookmarks", deviceIdentifier: "ios-device"),
            .createFolder(name: "ios-device", parentID: "/org.andbible.ios-sync-bookmarks"),
        ])
    }

    func testRemoteSyncPatchStatusStorePersistsAndQueriesStatuses() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        store.addStatuses([
            RemoteSyncPatchStatus(sourceDevice: "device-a", patchNumber: 1, sizeBytes: 100, appliedDate: 1_000),
            RemoteSyncPatchStatus(sourceDevice: "device-a", patchNumber: 2, sizeBytes: 200, appliedDate: 2_000),
            RemoteSyncPatchStatus(sourceDevice: "device-b", patchNumber: 1, sizeBytes: 300, appliedDate: 3_000),
        ], for: .bookmarks)

        XCTAssertEqual(
            store.status(for: .bookmarks, sourceDevice: "device-a", patchNumber: 2),
            RemoteSyncPatchStatus(sourceDevice: "device-a", patchNumber: 2, sizeBytes: 200, appliedDate: 2_000)
        )
        XCTAssertEqual(store.lastPatchNumber(for: .bookmarks, sourceDevice: "device-a"), 2)
        XCTAssertEqual(store.totalBytesUsed(for: .bookmarks), 600)
        XCTAssertEqual(store.statuses(for: .bookmarks).count, 3)
    }

    func testRemoteSyncPatchStatusStoreClearCategoryDoesNotTouchOtherCategories() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        store.addStatus(
            RemoteSyncPatchStatus(sourceDevice: "device-a", patchNumber: 1, sizeBytes: 100, appliedDate: 1_000),
            for: .bookmarks
        )
        store.addStatus(
            RemoteSyncPatchStatus(sourceDevice: "device-b", patchNumber: 1, sizeBytes: 200, appliedDate: 2_000),
            for: .workspaces
        )

        store.clearCategory(.bookmarks)

        XCTAssertTrue(store.statuses(for: .bookmarks).isEmpty)
        XCTAssertEqual(store.statuses(for: .workspaces).count, 1)
    }

    func testRemoteSyncPatchDiscoveryParsesAndroidPatchFileNames() {
        XCTAssertEqual(
            RemoteSyncPatchDiscoveryService.parsePatchFileName("7.12.sqlite3.gz")?.patchNumber,
            7
        )
        XCTAssertEqual(
            RemoteSyncPatchDiscoveryService.parsePatchFileName("7.12.sqlite3.gz")?.schemaVersion,
            12
        )
        XCTAssertEqual(
            RemoteSyncPatchDiscoveryService.parsePatchFileName("5.sqlite3.gz")?.schemaVersion,
            1
        )
        XCTAssertNil(RemoteSyncPatchDiscoveryService.parsePatchFileName("initial.sqlite3.gz"))
    }

    func testRemoteSyncPatchDiscoveryFindsInitialBackup() async throws {
        let adapter = MockRemoteSyncAdapter()
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 123,
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: "application/gzip"
            )
        ])
        let service = RemoteSyncPatchDiscoveryService(
            adapter: adapter,
            statusStore: RemoteSyncPatchStatusStore(settingsStore: try makeInMemorySettingsStore())
        )

        let file = try await service.findInitialBackup(syncFolderID: "/org.andbible.ios-sync-bookmarks")

        XCTAssertEqual(file?.name, "initial.sqlite3.gz")
    }

    func testRemoteSyncPatchDiscoveryReturnsPendingPatchesFilteredByAppliedStatus() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        statusStore.addStatus(
            RemoteSyncPatchStatus(sourceDevice: "device-a", patchNumber: 1, sizeBytes: 100, appliedDate: 1_000),
            for: .bookmarks
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a",
                name: "device-a",
                size: 0,
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            ),
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-b",
                name: "device-b",
                size: 0,
                timestamp: 1_100,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            ),
        ])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 111,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-bookmarks/device-a",
                mimeType: "application/gzip"
            ),
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a/2.1.sqlite3.gz",
                name: "2.1.sqlite3.gz",
                size: 222,
                timestamp: 2_100,
                parentID: "/org.andbible.ios-sync-bookmarks/device-a",
                mimeType: "application/gzip"
            ),
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-b/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 333,
                timestamp: 2_050,
                parentID: "/org.andbible.ios-sync-bookmarks/device-b",
                mimeType: "application/gzip"
            ),
        ])

        let service = RemoteSyncPatchDiscoveryService(adapter: adapter, statusStore: statusStore)
        let result = try await service.discoverPendingPatches(
            for: .bookmarks,
            bootstrapState: RemoteSyncBootstrapState(syncFolderID: "/org.andbible.ios-sync-bookmarks"),
            progressState: RemoteSyncProgressState(lastSynchronized: 100_000),
            currentSchemaVersion: 1
        )

        XCTAssertEqual(result.deviceFolders.map(\.name), ["device-a", "device-b"])
        XCTAssertEqual(result.pendingPatches.count, 2)
        XCTAssertEqual(result.pendingPatches[0].sourceDevice, "device-b")
        XCTAssertEqual(result.pendingPatches[0].patchNumber, 1)
        XCTAssertEqual(result.pendingPatches[1].sourceDevice, "device-a")
        XCTAssertEqual(result.pendingPatches[1].patchNumber, 2)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-bookmarks"],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [
                    "/org.andbible.ios-sync-bookmarks/device-a",
                    "/org.andbible.ios-sync-bookmarks/device-b",
                ],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: Date(timeIntervalSince1970: 100)
            ),
        ])
    }

    func testRemoteSyncPatchDiscoveryThrowsWhenPatchSequenceHasGap() async throws {
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: try makeInMemorySettingsStore())
        let adapter = MockRemoteSyncAdapter()
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a",
                name: "device-a",
                size: 0,
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a/3.1.sqlite3.gz",
                name: "3.1.sqlite3.gz",
                size: 333,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-bookmarks/device-a",
                mimeType: "application/gzip"
            )
        ])

        let service = RemoteSyncPatchDiscoveryService(adapter: adapter, statusStore: statusStore)

        await XCTAssertThrowsErrorAsync(
            try await service.discoverPendingPatches(
                for: .bookmarks,
                bootstrapState: RemoteSyncBootstrapState(syncFolderID: "/org.andbible.ios-sync-bookmarks"),
                progressState: RemoteSyncProgressState(),
                currentSchemaVersion: 1
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncPatchDiscoveryError, .patchFilesSkipped)
        }
    }

    func testRemoteSyncPatchDiscoveryThrowsWhenRemotePatchNeedsNewerSchema() async throws {
        let statusStore = RemoteSyncPatchStatusStore(settingsStore: try makeInMemorySettingsStore())
        let adapter = MockRemoteSyncAdapter()
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a",
                name: "device-a",
                size: 0,
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/device-a/1.7.sqlite3.gz",
                name: "1.7.sqlite3.gz",
                size: 333,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-bookmarks/device-a",
                mimeType: "application/gzip"
            )
        ])

        let service = RemoteSyncPatchDiscoveryService(adapter: adapter, statusStore: statusStore)

        await XCTAssertThrowsErrorAsync(
            try await service.discoverPendingPatches(
                for: .bookmarks,
                bootstrapState: RemoteSyncBootstrapState(syncFolderID: "/org.andbible.ios-sync-bookmarks"),
                progressState: RemoteSyncProgressState(),
                currentSchemaVersion: 3
            )
        ) { error in
            XCTAssertEqual(error as? RemoteSyncPatchDiscoveryError, .incompatiblePatchVersion(7))
        }
    }

    func testRemoteSyncArchiveStagingDownloadsInitialBackupAndExtractsSQLiteFile() async throws {
        let adapter = MockRemoteSyncAdapter()
        let initialDatabaseURL = try makeTemporarySQLiteDatabase(userVersion: 3)
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }
        let initialArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: initialDatabaseURL))
        await adapter.setDownloadData(initialArchiveData, forID: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz")

        let service = RemoteSyncArchiveStagingService(adapter: adapter)
        let stagedBackup = try await service.downloadInitialBackup(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: Int64(initialArchiveData.count),
                timestamp: 1_000,
                parentID: "/org.andbible.ios-sync-bookmarks",
                mimeType: "application/gzip"
            ),
            currentSchemaVersion: 5
        )

        XCTAssertEqual(stagedBackup.schemaVersion, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedBackup.databaseFileURL.path))
        XCTAssertEqual(try readSQLiteUserVersion(at: stagedBackup.databaseFileURL), 3)
        let initialEvents = await adapter.eventsSnapshot()
        XCTAssertEqual(initialEvents, [
            .download(id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz")
        ])

        service.cleanupInitialBackup(stagedBackup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedBackup.databaseFileURL.path))
    }

    func testRemoteSyncArchiveStagingRejectsInitialBackupWithNewerSchemaVersion() async throws {
        let adapter = MockRemoteSyncAdapter()
        let initialDatabaseURL = try makeTemporarySQLiteDatabase(userVersion: 7)
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }
        let initialArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: initialDatabaseURL))
        await adapter.setDownloadData(initialArchiveData, forID: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz")

        let service = RemoteSyncArchiveStagingService(adapter: adapter)

        await XCTAssertThrowsErrorAsync(
            try await service.downloadInitialBackup(
                RemoteSyncFile(
                    id: "/org.andbible.ios-sync-bookmarks/initial.sqlite3.gz",
                    name: "initial.sqlite3.gz",
                    size: Int64(initialArchiveData.count),
                    timestamp: 1_000,
                    parentID: "/org.andbible.ios-sync-bookmarks",
                    mimeType: "application/gzip"
                ),
                currentSchemaVersion: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncArchiveStagingError,
                .incompatibleInitialBackupVersion(7)
            )
        }
    }

    func testRemoteSyncArchiveStagingDownloadsPatchArchivesInSuppliedOrder() async throws {
        let adapter = MockRemoteSyncAdapter()
        let firstArchive = Data("first-archive".utf8)
        let secondArchive = Data("second-archive".utf8)
        await adapter.setDownloadData(firstArchive, forID: "/org.andbible.ios-sync-bookmarks/device-b/1.1.sqlite3.gz")
        await adapter.setDownloadData(secondArchive, forID: "/org.andbible.ios-sync-bookmarks/device-a/2.1.sqlite3.gz")

        let service = RemoteSyncArchiveStagingService(adapter: adapter)
        let stagedArchives = try await service.downloadPatchArchives([
            RemoteSyncDiscoveredPatch(
                sourceDevice: "device-b",
                patchNumber: 1,
                schemaVersion: 1,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-bookmarks/device-b/1.1.sqlite3.gz",
                    name: "1.1.sqlite3.gz",
                    size: Int64(firstArchive.count),
                    timestamp: 1_000,
                    parentID: "/org.andbible.ios-sync-bookmarks/device-b",
                    mimeType: "application/gzip"
                )
            ),
            RemoteSyncDiscoveredPatch(
                sourceDevice: "device-a",
                patchNumber: 2,
                schemaVersion: 1,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-bookmarks/device-a/2.1.sqlite3.gz",
                    name: "2.1.sqlite3.gz",
                    size: Int64(secondArchive.count),
                    timestamp: 1_200,
                    parentID: "/org.andbible.ios-sync-bookmarks/device-a",
                    mimeType: "application/gzip"
                )
            ),
        ])

        XCTAssertEqual(stagedArchives.map(\.patch.sourceDevice), ["device-b", "device-a"])
        XCTAssertEqual(try Data(contentsOf: stagedArchives[0].archiveFileURL), firstArchive)
        XCTAssertEqual(try Data(contentsOf: stagedArchives[1].archiveFileURL), secondArchive)
        let patchDownloadEvents = await adapter.eventsSnapshot()
        XCTAssertEqual(patchDownloadEvents, [
            .download(id: "/org.andbible.ios-sync-bookmarks/device-b/1.1.sqlite3.gz"),
            .download(id: "/org.andbible.ios-sync-bookmarks/device-a/2.1.sqlite3.gz"),
        ])

        service.cleanupPatchArchives(stagedArchives)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedArchives[0].archiveFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedArchives[1].archiveFileURL.path))
    }

    /// Verifies that synchronization stops at the Android adopt-vs-create branch when a same-named remote folder exists.
    func testRemoteSyncSynchronizationServiceReturnsRemoteAdoptionDecision() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)

        let adapter = MockRemoteSyncAdapter()
        await adapter.setListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans",
                name: "org.andbible.ios-sync-readingplans",
                size: 0,
                timestamp: 1_000,
                parentID: "/",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 2_000_000 }
        )

        let outcome = try await service.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(
            outcome,
            .requiresRemoteAdoption(
                RemoteSyncBootstrapCandidate(
                    category: .readingPlans,
                    syncFolderName: "org.andbible.ios-sync-readingplans",
                    remoteFolderID: "/org.andbible.ios-sync-readingplans"
                )
            )
        )
    }

    /// Verifies that a ready reading-plan category downloads and applies the next valid remote patch.
    func testRemoteSyncSynchronizationServiceSynchronizesReadyReadingPlanCategory() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let restoreService = RemoteSyncReadingPlanRestoreService()

        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "/org.andbible.ios-sync-readingplans/ios-device"
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: deviceFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .readingPlans
        )

        let planID = UUID(uuidString: "e1000000-0000-0000-0000-000000000001")!
        let baselineStatusID = UUID(uuidString: "e1000000-0000-0000-0000-000000000011")!
        let patchStatusID = UUID(uuidString: "e1000000-0000-0000-0000-000000000022")!

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: baselineStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalReadingPlans(
            from: initialSnapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlan",
                entityID1: .blob(uuidBlob(planID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlanStatus",
                entityID1: .blob(uuidBlob(baselineStatusID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: patchStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(uuidBlob(planID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(uuidBlob(patchStatusID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let patchArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let patchFile = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/pixel/1.1.sqlite3.gz",
            name: "1.1.sqlite3.gz",
            size: Int64(patchArchiveData.count),
            timestamp: 1_735_689_800_000,
            parentID: "/org.andbible.ios-sync-readingplans/pixel",
            mimeType: "application/gzip"
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/pixel",
                name: "pixel",
                size: 0,
                timestamp: 1_735_689_700_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([patchFile])
        await adapter.setDownloadData(patchArchiveData, forID: patchFile.id)

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 2_000_000 }
        )

        let outcome = try await service.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected synchronized outcome")
        }

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertNil(report.initialRestoreReport)
        XCTAssertEqual(report.discoveredPatchCount, 1)
        XCTAssertEqual(report.lastPatchWritten, nil)
        XCTAssertEqual(report.lastSynchronized, 2_000_000)
        XCTAssertNil(report.patchUploadReport)

        guard case .readingPlans(let patchReport)? = report.patchReplayReport else {
            return XCTFail("Expected reading-plan patch replay report")
        }

        XCTAssertEqual(patchReport.appliedPatchCount, 1)
        XCTAssertEqual(patchReport.appliedLogEntryCount, 2)
        XCTAssertEqual(patchReport.skippedLogEntryCount, 0)

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].currentDay, 2)

        let persistedProgress = stateStore.progressState(for: .readingPlans)
        XCTAssertEqual(persistedProgress.lastSynchronized, 2_000_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: syncFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans/pixel"],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .download(id: patchFile.id),
        ])
    }

    /// Verifies that a ready reading-plan category uploads one sparse local patch when no newer remote patches exist.
    func testRemoteSyncSynchronizationServiceUploadsLocalReadingPlanChangesWhenNoRemotePatchesExist() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let restoreService = RemoteSyncReadingPlanRestoreService()

        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "/org.andbible.ios-sync-readingplans/ios-device"
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: deviceFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .readingPlans
        )

        let planID = UUID(uuidString: "d5000000-0000-0000-0000-000000000001")!
        let baselineStatusID = UUID(uuidString: "d5000000-0000-0000-0000-000000000011")!

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: baselineStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalReadingPlans(
            from: initialSnapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlan",
                entityID1: .blob(uuidBlob(planID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlanStatus",
                entityID1: .blob(uuidBlob(baselineStatusID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let plan = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<ReadingPlan>()).first)
        plan.currentDay = 2
        let dayTwo = try XCTUnwrap((plan.days ?? []).first(where: { $0.dayNumber == 2 }))
        dayTwo.isCompleted = true
        try modelContext.save()

        let adapter = MockRemoteSyncAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: deviceFolderID,
                name: "ios-device",
                size: 0,
                timestamp: 1_735_689_700_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([])

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 4_000_000 }
        )

        let outcome = try await service.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected synchronized outcome")
        }

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertNil(report.initialRestoreReport)
        XCTAssertNil(report.patchReplayReport)
        XCTAssertEqual(report.discoveredPatchCount, 0)
        XCTAssertEqual(report.lastPatchWritten, 4_000_000)
        XCTAssertEqual(report.lastSynchronized, 4_000_000)

        guard case .readingPlans(let uploadReport)? = report.patchUploadReport else {
            return XCTFail("Expected reading-plan patch upload report")
        }

        XCTAssertEqual(uploadReport.patchNumber, 1)
        XCTAssertEqual(uploadReport.upsertedPlanCount, 1)
        XCTAssertEqual(uploadReport.upsertedStatusCount, 1)
        XCTAssertEqual(uploadReport.deletedRowCount, 0)
        XCTAssertEqual(uploadReport.logEntryCount, 2)
        XCTAssertEqual(uploadReport.lastUpdated, 4_000_000)
        XCTAssertEqual(uploadReport.uploadedFile.name, "1.1.sqlite3.gz")
        XCTAssertEqual(uploadReport.uploadedFile.parentID, deviceFolderID)

        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: uploadReport.uploadedFile.size,
                    appliedDate: 4_000_000
                )
            ]
        )
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastPatchWritten, 4_000_000)
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastSynchronized, 4_000_000)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(uploadedFiles.count, 1)
        XCTAssertEqual(
            uploadedFiles[0],
            MockRemoteSyncUploadedFile(
                name: "1.1.sqlite3.gz",
                parentID: deviceFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType,
                data: uploadedFiles[0].data
            )
        )

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: syncFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [deviceFolderID],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .upload(
                name: "1.1.sqlite3.gz",
                parentID: deviceFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            ),
        ])
    }

    /// Verifies that skipped-patch discovery retries once from a zero sync baseline before applying the next valid patch.
    func testRemoteSyncSynchronizationServiceRetriesSkippedPatchDiscoveryOnce() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        let restoreService = RemoteSyncReadingPlanRestoreService()

        let syncFolderID = "/org.andbible.ios-sync-readingplans"
        let deviceFolderID = "/org.andbible.ios-sync-readingplans/ios-device"
        stateStore.setBootstrapState(
            RemoteSyncBootstrapState(
                syncFolderID: syncFolderID,
                deviceFolderID: deviceFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            for: .readingPlans
        )

        let planID = UUID(uuidString: "f1000000-0000-0000-0000-000000000001")!
        let baselineStatusID = UUID(uuidString: "f1000000-0000-0000-0000-000000000011")!
        let patchStatusID = UUID(uuidString: "f1000000-0000-0000-0000-000000000022")!

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: baselineStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialSnapshot = try restoreService.readSnapshot(from: initialDatabaseURL)
        _ = try restoreService.replaceLocalReadingPlans(
            from: initialSnapshot,
            modelContext: modelContext,
            statusStore: statusStore
        )

        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlan",
                entityID1: .blob(uuidBlob(planID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        logEntryStore.addEntry(
            .init(
                tableName: "ReadingPlanStatus",
                entityID1: .blob(uuidBlob(baselineStatusID)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: patchStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(uuidBlob(planID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(uuidBlob(patchStatusID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let patchArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let skippedPatch = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/pixel/2.1.sqlite3.gz",
            name: "2.1.sqlite3.gz",
            size: Int64(patchArchiveData.count),
            timestamp: 1_735_689_800_000,
            parentID: "/org.andbible.ios-sync-readingplans/pixel",
            mimeType: "application/gzip"
        )
        let retriedPatch = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/pixel/1.1.sqlite3.gz",
            name: "1.1.sqlite3.gz",
            size: Int64(patchArchiveData.count),
            timestamp: 1_735_689_810_000,
            parentID: "/org.andbible.ios-sync-readingplans/pixel",
            mimeType: "application/gzip"
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.setKnownResponse(
            true,
            forSyncFolderID: syncFolderID,
            secretFileName: "device-known-ios-device-secret"
        )
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/pixel",
                name: "pixel",
                size: 0,
                timestamp: 1_735_689_700_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([skippedPatch])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/pixel",
                name: "pixel",
                size: 0,
                timestamp: 1_735_689_700_000,
                parentID: syncFolderID,
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([retriedPatch])
        await adapter.setDownloadData(patchArchiveData, forID: retriedPatch.id)

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 2_500_000 }
        )

        let outcome = try await service.synchronize(
            .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        guard case .synchronized(let report) = outcome else {
            return XCTFail("Expected synchronized outcome")
        }

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertEqual(report.discoveredPatchCount, 1)
        XCTAssertEqual(report.lastSynchronized, 2_500_000)
        XCTAssertNil(report.patchUploadReport)

        guard case .readingPlans(let patchReport)? = report.patchReplayReport else {
            return XCTFail("Expected reading-plan patch replay report")
        }

        XCTAssertEqual(patchReport.appliedPatchCount, 1)
        XCTAssertEqual(patchReport.appliedLogEntryCount, 2)
        XCTAssertEqual(patchReport.skippedLogEntryCount, 0)

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].currentDay, 2)

        let persistedProgress = stateStore.progressState(for: .readingPlans)
        XCTAssertEqual(persistedProgress.lastSynchronized, 2_500_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .isSyncFolderKnown(
                syncFolderID: syncFolderID,
                secretFileName: "device-known-ios-device-secret"
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans/pixel"],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [syncFolderID],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans/pixel"],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .download(id: retriedPatch.id),
        ])
    }

    /// Verifies that adopting a remote folder restores its initial backup, records patch zero, and then runs ready-state synchronization.
    func testRemoteSyncSynchronizationServiceAdoptRemoteFolderRestoresInitialAndRecordsPatchZero() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: UUID(uuidString: "e2000000-0000-0000-0000-000000000001")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: UUID(uuidString: "e2000000-0000-0000-0000-000000000011")!,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: initialDatabaseURL))
        let initialFile = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/initial.sqlite3.gz",
            name: "initial.sqlite3.gz",
            size: Int64(initialArchiveData.count),
            timestamp: 1_735_689_700_000,
            parentID: "/org.andbible.ios-sync-readingplans",
            mimeType: "application/gzip"
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.setMakeKnownResponse("device-known-ios-device-secret")
        await adapter.enqueueCreateFolderResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/ios-device",
                name: "ios-device",
                size: 0,
                timestamp: 1_735_689_650_000,
                parentID: "/org.andbible.ios-sync-readingplans",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        )
        await adapter.enqueueListFilesResult([initialFile])
        await adapter.enqueueListFilesResult([
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/ios-device",
                name: "ios-device",
                size: 0,
                timestamp: 1_735_689_650_000,
                parentID: "/org.andbible.ios-sync-readingplans",
                mimeType: NextCloudSyncAdapter.folderMimeType
            )
        ])
        await adapter.enqueueListFilesResult([])
        await adapter.setDownloadData(initialArchiveData, forID: initialFile.id)

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 3_000_000 }
        )

        let report = try await service.adoptRemoteFolderAndSynchronize(
            for: .readingPlans,
            remoteFolderID: "/org.andbible.ios-sync-readingplans",
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertEqual(report.discoveredPatchCount, 0)
        XCTAssertEqual(report.lastPatchWritten, 3_000_000)
        XCTAssertEqual(report.lastSynchronized, 3_000_000)
        XCTAssertNil(report.patchReplayReport)
        XCTAssertNil(report.patchUploadReport)
        XCTAssertEqual(
            report.initialRestoreReport,
            .readingPlans(
                RemoteSyncReadingPlanRestoreReport(
                    restoredPlanCodes: ["y1ot1nt1_OTthenNT"],
                    restoredDayCount: ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })!.totalDays,
                    preservedStatusCount: 1
                )
            )
        )

        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 0,
                    sizeBytes: initialFile.size,
                    appliedDate: initialFile.timestamp
                )
            ]
        )
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastPatchWritten, 3_000_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .makeKnown(syncFolderID: "/org.andbible.ios-sync-readingplans", deviceIdentifier: "ios-device"),
            .createFolder(name: "ios-device", parentID: "/org.andbible.ios-sync-readingplans"),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans"],
                name: "initial.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .download(id: initialFile.id),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans"],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans/ios-device"],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
        ])
    }

    /// Verifies that adopting a remote folder can replay newer remote patches without uploading a local patch in the same pass.
    func testRemoteSyncSynchronizationServiceAdoptRemoteFolderReplaysRemotePatchWithoutUploadingLocally() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)

        let initialPlanID = UUID(uuidString: "e3000000-0000-0000-0000-000000000001")!
        let initialStatusID = UUID(uuidString: "e3000000-0000-0000-0000-000000000011")!
        let remotePatchStatusID = UUID(uuidString: "e3000000-0000-0000-0000-000000000022")!

        let initialDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: initialPlanID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 1
                )
            ],
            statuses: [
                .init(
                    id: initialStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 1,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":false}]}"#
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: initialDatabaseURL) }

        let initialArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: initialDatabaseURL))
        let initialFile = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/initial.sqlite3.gz",
            name: "initial.sqlite3.gz",
            size: Int64(initialArchiveData.count),
            timestamp: 1_735_689_700_000,
            parentID: "/org.andbible.ios-sync-readingplans",
            mimeType: "application/gzip"
        )

        let patchDatabaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: initialPlanID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 2
                )
            ],
            statuses: [
                .init(
                    id: remotePatchStatusID,
                    planCode: "y1ot1nt1_OTthenNT",
                    dayNumber: 2,
                    readingStatusJSON: #"{"chapterReadArray":[{"readingNumber":1,"isRead":true}]}"#
                )
            ],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(uuidBlob(initialPlanID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
                .init(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(uuidBlob(remotePatchStatusID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 2_000,
                    sourceDevice: "pixel"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }

        let patchArchiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let pixelFolder = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/pixel",
            name: "pixel",
            size: 0,
            timestamp: 1_735_689_710_000,
            parentID: "/org.andbible.ios-sync-readingplans",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
        let localDeviceFolder = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/ios-device",
            name: "ios-device",
            size: 0,
            timestamp: 1_735_689_705_000,
            parentID: "/org.andbible.ios-sync-readingplans",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
        let patchFile = RemoteSyncFile(
            id: "/org.andbible.ios-sync-readingplans/pixel/1.1.sqlite3.gz",
            name: "1.1.sqlite3.gz",
            size: Int64(patchArchiveData.count),
            timestamp: 1_735_689_800_000,
            parentID: pixelFolder.id,
            mimeType: "application/gzip"
        )

        let adapter = MockRemoteSyncAdapter()
        await adapter.setMakeKnownResponse("device-known-ios-device-secret")
        await adapter.enqueueCreateFolderResult(localDeviceFolder)
        await adapter.enqueueListFilesResult([initialFile])
        await adapter.enqueueListFilesResult([pixelFolder, localDeviceFolder])
        await adapter.enqueueListFilesResult([patchFile])
        await adapter.setDownloadData(initialArchiveData, forID: initialFile.id)
        await adapter.setDownloadData(patchArchiveData, forID: patchFile.id)

        let service = RemoteSyncSynchronizationService(
            adapter: adapter,
            bundleIdentifier: "org.andbible.ios",
            deviceIdentifier: "ios-device",
            nowProvider: { 3_500_000 }
        )

        let report = try await service.adoptRemoteFolderAndSynchronize(
            for: .readingPlans,
            remoteFolderID: "/org.andbible.ios-sync-readingplans",
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.category, .readingPlans)
        XCTAssertEqual(report.discoveredPatchCount, 1)
        XCTAssertEqual(report.lastPatchWritten, 3_500_000)
        XCTAssertEqual(report.lastSynchronized, 3_500_000)
        XCTAssertNil(report.patchUploadReport)

        guard case .readingPlans(let patchReport)? = report.patchReplayReport else {
            return XCTFail("Expected reading-plan patch replay report")
        }

        XCTAssertEqual(patchReport.appliedPatchCount, 1)
        XCTAssertEqual(patchReport.appliedLogEntryCount, 2)
        XCTAssertEqual(patchReport.skippedLogEntryCount, 0)

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.count, 1)
        XCTAssertEqual(plans[0].currentDay, 2)

        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 0,
                    sizeBytes: initialFile.size,
                    appliedDate: initialFile.timestamp
                ),
                RemoteSyncPatchStatus(
                    sourceDevice: "pixel",
                    patchNumber: 1,
                    sizeBytes: patchFile.size,
                    appliedDate: patchFile.timestamp
                )
            ]
        )
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastPatchWritten, 3_500_000)
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastSynchronized, 3_500_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .makeKnown(syncFolderID: "/org.andbible.ios-sync-readingplans", deviceIdentifier: "ios-device"),
            .createFolder(name: "ios-device", parentID: "/org.andbible.ios-sync-readingplans"),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans"],
                name: "initial.sqlite3.gz",
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .download(id: initialFile.id),
            .listFiles(
                parentIDs: ["/org.andbible.ios-sync-readingplans"],
                name: nil,
                mimeType: NextCloudSyncAdapter.folderMimeType,
                modifiedAtLeast: nil
            ),
            .listFiles(
                parentIDs: [pixelFolder.id, localDeviceFolder.id],
                name: nil,
                mimeType: nil,
                modifiedAtLeast: nil
            ),
            .download(id: patchFile.id),
        ])
    }

    /// Verifies that outbound upload stays idle when the current reading-plan snapshot matches the stored baseline exactly.
    func testRemoteSyncReadingPlanPatchUploadReturnsNilWhenStateMatchesBaseline() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)

        let template = ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })!
        let plan = ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.startDate = Date(timeIntervalSince1970: 1_735_689_600)
        plan.currentDay = 1
        try modelContext.save()

        logEntryStore.addEntry(
            RemoteSyncLogEntry(
                tableName: "ReadingPlan",
                entityID1: .blob(uuidBlob(plan.id)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let currentSnapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let planKey = logEntryStore.key(
            for: .readingPlans,
            tableName: "ReadingPlan",
            entityID1: .blob(uuidBlob(plan.id)),
            entityID2: .text("")
        )
        let persistedFingerprint = fingerprintStore.fingerprint(
            for: .readingPlans,
            tableName: "ReadingPlan",
            entityID1: .blob(uuidBlob(plan.id)),
            entityID2: .text("")
        )
        XCTAssertEqual(persistedFingerprint, currentSnapshot.fingerprintsByKey[planKey])

        let adapter = MockRemoteSyncAdapter()
        let service = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            nowProvider: { 2_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        XCTAssertNil(report)
        let events = await adapter.eventsSnapshot()
        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(events, [])
        XCTAssertTrue(uploadedFiles.isEmpty)
    }

    /// Verifies that outbound upload writes an Android-shaped sparse patch, uploads it, and advances local sync bookkeeping.
    func testRemoteSyncReadingPlanPatchUploadWritesAndUploadsSparsePatch() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let restoreService = RemoteSyncReadingPlanRestoreService()

        let template = ReadingPlanService.availablePlans.first(where: { $0.code == "y1ot1nt1_OTthenNT" })!
        let plan = ReadingPlanService.startPlan(template: template, modelContext: modelContext)
        plan.startDate = Date(timeIntervalSince1970: 1_735_689_600)
        plan.currentDay = 1
        try modelContext.save()

        logEntryStore.addEntry(
            RemoteSyncLogEntry(
                tableName: "ReadingPlan",
                entityID1: .blob(uuidBlob(plan.id)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: 1_000,
                sourceDevice: "pixel"
            ),
            for: .readingPlans
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        plan.currentDay = 2
        let dayOne = try XCTUnwrap(plan.days?.first(where: { $0.dayNumber == 1 }))
        dayOne.isCompleted = true
        dayOne.completedDate = Date(timeIntervalSince1970: 1_735_689_700)
        try modelContext.save()

        let adapter = MockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/ios-device/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 0,
                timestamp: 2_000,
                parentID: "/org.andbible.ios-sync-readingplans/ios-device",
                mimeType: "application/gzip"
            )
        )
        let service = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            nowProvider: { 2_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.patchNumber, 1)
        XCTAssertEqual(unwrappedReport.upsertedPlanCount, 1)
        XCTAssertEqual(unwrappedReport.upsertedStatusCount, 1)
        XCTAssertEqual(unwrappedReport.deletedRowCount, 0)
        XCTAssertEqual(unwrappedReport.logEntryCount, 2)
        XCTAssertEqual(unwrappedReport.lastUpdated, 2_000)

        let events = await adapter.eventsSnapshot()
        XCTAssertEqual(events, [
            .upload(
                name: "1.1.sqlite3.gz",
                parentID: "/org.andbible.ios-sync-readingplans/ios-device",
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
        ])

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-readingplan-patch-\(UUID().uuidString).sqlite3.gz")
        let databaseURL = archiveURL.deletingPathExtension()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: databaseURL)
        }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)
        let patchDatabaseData = try gunzipTestData(uploadedArchive.data)
        try patchDatabaseData.write(to: databaseURL, options: .atomic)

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL)
        let patchSnapshot = try restoreService.readSnapshot(from: databaseURL)
        XCTAssertEqual(patchSnapshot.plans.count, 1)
        XCTAssertEqual(patchSnapshot.plans[0].currentDay, 2)
        XCTAssertEqual(patchSnapshot.plans[0].statuses.count, 1)
        XCTAssertEqual(patchSnapshot.plans[0].statuses[0].dayNumber, 1)
        XCTAssertEqual(metadataSnapshot.logEntries.map(\.type), [.upsert, .upsert])
        XCTAssertEqual(Set(metadataSnapshot.logEntries.map(\.tableName)), ["ReadingPlan", "ReadingPlanStatus"])
        XCTAssertEqual(Set(metadataSnapshot.logEntries.map(\.sourceDevice)), ["ios-device"])

        XCTAssertEqual(
            patchStatusStore.statuses(for: .readingPlans),
            [
                RemoteSyncPatchStatus(
                    sourceDevice: "ios-device",
                    patchNumber: 1,
                    sizeBytes: unwrappedReport.uploadedFile.size,
                    appliedDate: 2_000
                )
            ]
        )
        XCTAssertEqual(stateStore.progressState(for: .readingPlans).lastPatchWritten, 2_000)
        XCTAssertEqual(logEntryStore.entries(for: .readingPlans).count, 2)

        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let currentSnapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let currentStatusKey = try XCTUnwrap(currentSnapshot.statusRowsByKey.keys.first)
        XCTAssertEqual(currentSnapshot.statusRowsByKey.count, 1)
        XCTAssertEqual(
            fingerprintStore.fingerprint(
                forLogKey: currentStatusKey,
                category: .readingPlans
            ),
            currentSnapshot.fingerprintsByKey[currentStatusKey]
        )

        let secondReport = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertNil(secondReport)
        let finalUploadedFiles = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(finalUploadedFiles.count, 1)
    }

    /// Verifies that reading-plan initial restore refreshes the outbound fingerprint baseline so later local deletes emit delete patches.
    func testRemoteSyncReadingPlanPatchUploadDetectsDeleteAfterInitialRestoreRefresh() async throws {
        let container = try makeReadingPlanRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let metadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService()
        let restoreDispatcher = RemoteSyncInitialBackupRestoreService()

        let planID = UUID(uuidString: "d9000000-0000-0000-0000-000000000001")!
        let databaseURL = try makeAndroidReadingPlansDatabase(
            plans: [
                .init(
                    id: planID,
                    planCode: "y1ot1nt1_OTthenNT",
                    startDate: Date(timeIntervalSince1970: 1_735_689_600),
                    currentDay: 3
                )
            ],
            statuses: [],
            logEntries: [
                .init(
                    tableName: "ReadingPlan",
                    entityID1: .blob(uuidBlob(planID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 1_500,
                    sourceDevice: "pixel"
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let stagedBackup = RemoteSyncStagedInitialBackup(
            remoteFile: RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/initial.sqlite3.gz",
                name: "initial.sqlite3.gz",
                size: 1,
                timestamp: 1_500,
                parentID: "/org.andbible.ios-sync-readingplans",
                mimeType: "application/gzip"
            ),
            databaseFileURL: databaseURL,
            schemaVersion: 1
        )

        _ = try restoreDispatcher.restoreInitialBackup(
            stagedBackup,
            category: .readingPlans,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let plans = try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        XCTAssertEqual(plans.count, 1)
        modelContext.delete(plans[0])
        try modelContext.save()

        let adapter = MockRemoteSyncAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/org.andbible.ios-sync-readingplans/ios-device/1.1.sqlite3.gz",
                name: "1.1.sqlite3.gz",
                size: 0,
                timestamp: 2_500,
                parentID: "/org.andbible.ios-sync-readingplans/ios-device",
                mimeType: "application/gzip"
            )
        )
        let uploadService = RemoteSyncReadingPlanPatchUploadService(
            adapter: adapter,
            nowProvider: { 2_500 }
        )

        let report = try await uploadService.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/org.andbible.ios-sync-readingplans/ios-device"),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let unwrappedReport = try XCTUnwrap(report)
        XCTAssertEqual(unwrappedReport.upsertedPlanCount, 0)
        XCTAssertEqual(unwrappedReport.upsertedStatusCount, 0)
        XCTAssertEqual(unwrappedReport.deletedRowCount, 1)
        XCTAssertEqual(unwrappedReport.logEntryCount, 1)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploadedArchive = try XCTUnwrap(uploadedFiles.first)
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("uploaded-readingplan-delete-\(UUID().uuidString).sqlite3.gz")
        let databaseURL2 = archiveURL.deletingPathExtension()
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: databaseURL2)
        }
        try uploadedArchive.data.write(to: archiveURL, options: .atomic)
        let patchDatabaseData = try gunzipTestData(uploadedArchive.data)
        try patchDatabaseData.write(to: databaseURL2, options: .atomic)

        let metadataSnapshot = try metadataRestoreService.readSnapshot(from: databaseURL2)
        XCTAssertEqual(metadataSnapshot.logEntries.count, 1)
        XCTAssertEqual(metadataSnapshot.logEntries[0].type, .delete)
        XCTAssertEqual(metadataSnapshot.logEntries[0].tableName, "ReadingPlan")
    }

    func testWebDAVSyncConfigurationRejectsLoginPageURLs() {
        let configuration = WebDAVSyncConfiguration(
            serverURL: "https://nextcloud.example.com/login",
            username: "alice",
            folderPath: nil
        )

        XCTAssertThrowsError(try configuration.resolvedDAVBaseURL()) { error in
            XCTAssertEqual(error as? WebDAVClientError, .invalidURL)
        }
    }

    private func makeTemporaryBundledSwordPath() throws -> String {
        let fm = FileManager.default
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundledSwordURL = sourceRoot
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        XCTAssertTrue(
            fm.fileExists(atPath: bundledSwordURL.path),
            "Expected repo-bundled sword resources at \(bundledSwordURL.path)"
        )

        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try copyDirectoryContents(from: bundledSwordURL, to: tempRoot)

        temporarySwordModulePaths.append(tempRoot.path)
        return tempRoot.path
    }

    private func copyDirectoryContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try copyDirectoryContents(from: item, to: target)
            } else {
                try fm.copyItem(at: item, to: target)
            }
        }
    }

    private func makeMockedURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeInMemorySettingsStore() throws -> SettingsStore {
        let schema = Schema([Setting.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return SettingsStore(modelContext: ModelContext(container))
    }

    private func requestBodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var data = Data()
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                return nil
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }

    private static let sampleWebDAVMultiStatusXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:">
      <d:response>
        <d:href>/remote.php/dav/files/alice/sync/</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>sync</d:displayname>
            <d:resourcetype><d:collection /></d:resourcetype>
            <d:getlastmodified>Wed, 26 Feb 2026 12:00:00 GMT</d:getlastmodified>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/alice/sync/1.1.sqlite3.gz</d:href>
        <d:propstat>
          <d:prop>
            <d:displayname>1.1.sqlite3.gz</d:displayname>
            <d:getcontentlength>12345</d:getcontentlength>
            <d:getcontenttype>application/gzip</d:getcontenttype>
            <d:getlastmodified>Wed, 26 Feb 2026 12:01:00 GMT</d:getlastmodified>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    private static func webDAVMultiStatusXML(folderPath: String, fileName: String) -> String {
        let normalizedFolderPath = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        let folderDisplayName = normalizedFolderPath
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        return [
            #"<?xml version="1.0" encoding="utf-8"?>"#,
            #"<d:multistatus xmlns:d="DAV:">"#,
            #"  <d:response>"#,
            "    <d:href>\(normalizedFolderPath)</d:href>",
            #"    <d:propstat>"#,
            #"      <d:prop>"#,
            "        <d:displayname>\(folderDisplayName)</d:displayname>",
            #"        <d:resourcetype><d:collection /></d:resourcetype>"#,
            #"        <d:getlastmodified>Wed, 26 Feb 2026 12:00:00 GMT</d:getlastmodified>"#,
            #"      </d:prop>"#,
            #"      <d:status>HTTP/1.1 200 OK</d:status>"#,
            #"    </d:propstat>"#,
            #"  </d:response>"#,
            #"  <d:response>"#,
            "    <d:href>\(normalizedFolderPath)\(fileName)</d:href>",
            #"    <d:propstat>"#,
            #"      <d:prop>"#,
            "        <d:displayname>\(fileName)</d:displayname>",
            #"        <d:getcontentlength>12345</d:getcontentlength>"#,
            #"        <d:getcontenttype>application/gzip</d:getcontenttype>"#,
            #"        <d:getlastmodified>Wed, 26 Feb 2026 12:01:00 GMT</d:getlastmodified>"#,
            #"      </d:prop>"#,
            #"      <d:status>HTTP/1.1 200 OK</d:status>"#,
            #"    </d:propstat>"#,
            #"  </d:response>"#,
            #"</d:multistatus>"#,
        ].joined(separator: "\n")
    }

    private struct AndroidReadingPlanRow {
        let id: UUID
        let planCode: String
        let startDate: Date
        let currentDay: Int
    }

    private struct AndroidReadingPlanStatusRow {
        let id: UUID
        let planCode: String
        let dayNumber: Int
        let readingStatusJSON: String
    }

    private struct AndroidLogEntryRow {
        let tableName: String
        let entityID1: RemoteSyncSQLiteValue
        let entityID2: RemoteSyncSQLiteValue
        let type: RemoteSyncLogEntryType
        let lastUpdated: Int64
        let sourceDevice: String
    }

    private struct AndroidLabelRow {
        let id: UUID
        let name: String
        let colour: Int
        let markerStyle: Bool
        let markerStyleWholeVerse: Bool
        let underlineStyle: Bool
        let underlineStyleWholeVerse: Bool
        let hideStyle: Bool
        let hideStyleWholeVerse: Bool
        let favourite: Bool
        let type: String?
        let customIcon: String?

        init(
            id: UUID,
            name: String,
            colour: Int = Label.defaultColor,
            markerStyle: Bool = false,
            markerStyleWholeVerse: Bool = false,
            underlineStyle: Bool = false,
            underlineStyleWholeVerse: Bool = true,
            hideStyle: Bool = false,
            hideStyleWholeVerse: Bool = false,
            favourite: Bool = false,
            type: String? = nil,
            customIcon: String? = nil
        ) {
            self.id = id
            self.name = name
            self.colour = colour
            self.markerStyle = markerStyle
            self.markerStyleWholeVerse = markerStyleWholeVerse
            self.underlineStyle = underlineStyle
            self.underlineStyleWholeVerse = underlineStyleWholeVerse
            self.hideStyle = hideStyle
            self.hideStyleWholeVerse = hideStyleWholeVerse
            self.favourite = favourite
            self.type = type
            self.customIcon = customIcon
        }
    }

    private struct AndroidBibleBookmarkRow {
        let id: UUID
        let kjvOrdinalStart: Int
        let kjvOrdinalEnd: Int
        let ordinalStart: Int
        let ordinalEnd: Int
        let v11n: String
        let playbackSettingsJSON: String?
        let createdAt: Date
        let book: String?
        let startOffset: Int?
        let endOffset: Int?
        let primaryLabelID: UUID?
        let lastUpdatedOn: Date
        let wholeVerse: Bool
        let type: String?
        let customIcon: String?
        let editActionMode: String?
        let editActionContent: String?

        init(
            id: UUID,
            kjvOrdinalStart: Int,
            kjvOrdinalEnd: Int,
            ordinalStart: Int,
            ordinalEnd: Int,
            v11n: String = "KJVA",
            playbackSettingsJSON: String? = nil,
            createdAt: Date,
            book: String? = nil,
            startOffset: Int? = nil,
            endOffset: Int? = nil,
            primaryLabelID: UUID? = nil,
            lastUpdatedOn: Date,
            wholeVerse: Bool = true,
            type: String? = nil,
            customIcon: String? = nil,
            editActionMode: String? = nil,
            editActionContent: String? = nil
        ) {
            self.id = id
            self.kjvOrdinalStart = kjvOrdinalStart
            self.kjvOrdinalEnd = kjvOrdinalEnd
            self.ordinalStart = ordinalStart
            self.ordinalEnd = ordinalEnd
            self.v11n = v11n
            self.playbackSettingsJSON = playbackSettingsJSON
            self.createdAt = createdAt
            self.book = book
            self.startOffset = startOffset
            self.endOffset = endOffset
            self.primaryLabelID = primaryLabelID
            self.lastUpdatedOn = lastUpdatedOn
            self.wholeVerse = wholeVerse
            self.type = type
            self.customIcon = customIcon
            self.editActionMode = editActionMode
            self.editActionContent = editActionContent
        }
    }

    private struct AndroidGenericBookmarkRow {
        let id: UUID
        let key: String
        let createdAt: Date
        let bookInitials: String
        let ordinalStart: Int
        let ordinalEnd: Int
        let startOffset: Int?
        let endOffset: Int?
        let primaryLabelID: UUID?
        let lastUpdatedOn: Date
        let wholeVerse: Bool
        let playbackSettingsJSON: String?
        let customIcon: String?
        let editActionMode: String?
        let editActionContent: String?

        init(
            id: UUID,
            key: String,
            createdAt: Date,
            bookInitials: String,
            ordinalStart: Int,
            ordinalEnd: Int,
            startOffset: Int? = nil,
            endOffset: Int? = nil,
            primaryLabelID: UUID? = nil,
            lastUpdatedOn: Date,
            wholeVerse: Bool = true,
            playbackSettingsJSON: String? = nil,
            customIcon: String? = nil,
            editActionMode: String? = nil,
            editActionContent: String? = nil
        ) {
            self.id = id
            self.key = key
            self.createdAt = createdAt
            self.bookInitials = bookInitials
            self.ordinalStart = ordinalStart
            self.ordinalEnd = ordinalEnd
            self.startOffset = startOffset
            self.endOffset = endOffset
            self.primaryLabelID = primaryLabelID
            self.lastUpdatedOn = lastUpdatedOn
            self.wholeVerse = wholeVerse
            self.playbackSettingsJSON = playbackSettingsJSON
            self.customIcon = customIcon
            self.editActionMode = editActionMode
            self.editActionContent = editActionContent
        }
    }

    private struct AndroidBookmarkNoteRow {
        let bookmarkID: UUID
        let notes: String
    }

    private struct AndroidBookmarkLabelLinkRow {
        let bookmarkID: UUID
        let labelID: UUID
        let orderNumber: Int
        let indentLevel: Int
        let expandContent: Bool
    }

    private struct AndroidStudyPadEntryRow {
        let id: UUID
        let labelID: UUID
        let orderNumber: Int
        let indentLevel: Int
    }

    private struct AndroidStudyPadTextRow {
        let entryID: UUID
        let text: String
    }

    private func makeReadingPlanRestoreModelContainer() throws -> ModelContainer {
        let schema = Schema([
            ReadingPlan.self,
            ReadingPlanDay.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeBookmarkRestoreModelContainer() throws -> ModelContainer {
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
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func makeAndroidReadingPlansDatabase(
        plans: [AndroidReadingPlanRow],
        statuses: [AndroidReadingPlanStatusRow],
        logEntries: [AndroidLogEntryRow] = []
    ) throws -> URL {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-readingplans-\(UUID().uuidString).sqlite3")

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            XCTFail("Failed to open temporary Android reading plan database")
            throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(db) }

        XCTAssertEqual(
            sqlite3_exec(
                db,
                """
                CREATE TABLE ReadingPlan (
                    planCode TEXT NOT NULL,
                    planStartDate INTEGER NOT NULL,
                    planCurrentDay INTEGER NOT NULL DEFAULT 1,
                    id BLOB NOT NULL PRIMARY KEY
                );
                CREATE TABLE ReadingPlanStatus (
                    planCode TEXT NOT NULL,
                    planDay INTEGER NOT NULL,
                    readingStatus TEXT NOT NULL,
                    id BLOB NOT NULL PRIMARY KEY
                );
                CREATE TABLE LogEntry (
                    tableName TEXT NOT NULL,
                    entityId1 BLOB,
                    entityId2 BLOB,
                    type TEXT NOT NULL,
                    lastUpdated INTEGER NOT NULL,
                    sourceDevice TEXT NOT NULL
                );
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        for plan in plans {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO ReadingPlan (planCode, planStartDate, planCurrentDay, id) VALUES (?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )

            sqlite3_bind_text(statement, 1, plan.planCode, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 2, Int64(plan.startDate.timeIntervalSince1970 * 1000))
            sqlite3_bind_int(statement, 3, Int32(plan.currentDay))
            let blob = uuidBlob(plan.id)
            _ = blob.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(blob.count), sqliteTransient)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for status in statuses {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO ReadingPlanStatus (planCode, planDay, readingStatus, id) VALUES (?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )

            sqlite3_bind_text(statement, 1, status.planCode, -1, sqliteTransient)
            sqlite3_bind_int(statement, 2, Int32(status.dayNumber))
            sqlite3_bind_text(statement, 3, status.readingStatusJSON, -1, sqliteTransient)
            let blob = uuidBlob(status.id)
            _ = blob.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(blob.count), sqliteTransient)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for entry in logEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )

            sqlite3_bind_text(statement, 1, entry.tableName, -1, sqliteTransient)
            bindSQLiteValue(entry.entityID1, to: statement, index: 2)
            bindSQLiteValue(entry.entityID2, to: statement, index: 3)
            sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 5, entry.lastUpdated)
            sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, sqliteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        return databaseURL
    }

    /**
     Builds one staged patch-archive fixture for reading-plan replay tests.

     - Parameters:
       - patchDatabaseURL: Local SQLite database containing Android patch rows.
       - sourceDevice: Android source-device name owning the patch stream.
       - patchNumber: Monotonic patch number within the source-device stream.
       - fileTimestamp: Remote millisecond timestamp that should be recorded on the staged archive.
     - Returns: Staged patch archive pointing at a temporary gzip file.
     - Side effects:
       - reads the supplied SQLite database
       - writes one temporary gzip archive beneath the process temporary directory
     - Failure modes:
       - rethrows filesystem read and write errors
       - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService`
     */
    private func makeReadingPlanPatchArchive(
        patchDatabaseURL: URL,
        sourceDevice: String,
        patchNumber: Int64,
        fileTimestamp: Int64
    ) throws -> RemoteSyncStagedPatchArchive {
        let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-readingplans-patch-\(UUID().uuidString).sqlite3.gz")
        try archiveData.write(to: archiveURL, options: .atomic)

        return RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                schemaVersion: 1,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-readingplans/\(sourceDevice)/\(patchNumber).sqlite3.gz",
                    name: "\(patchNumber).sqlite3.gz",
                    size: Int64(archiveData.count),
                    timestamp: fileTimestamp,
                    parentID: "/org.andbible.ios-sync-readingplans/\(sourceDevice)",
                    mimeType: "application/gzip"
                )
            ),
            archiveFileURL: archiveURL
        )
    }

    /**
     Creates one staged bookmark patch archive from a temporary SQLite database fixture.

     - Parameters:
       - patchDatabaseURL: Local SQLite database containing Android bookmark patch rows.
       - sourceDevice: Android source-device name owning the patch stream.
       - patchNumber: Monotonic patch number within the source-device stream.
       - fileTimestamp: Remote millisecond timestamp that should be recorded on the staged archive.
     - Returns: Staged patch archive pointing at a temporary gzip file.
     - Side effects:
       - reads the supplied SQLite database
       - writes one temporary gzip archive beneath the process temporary directory
     - Failure modes:
       - rethrows filesystem read and write errors
       - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService`
     */
    private func makeBookmarkPatchArchive(
        patchDatabaseURL: URL,
        sourceDevice: String,
        patchNumber: Int64,
        fileTimestamp: Int64
    ) throws -> RemoteSyncStagedPatchArchive {
        let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-bookmarks-patch-\(UUID().uuidString).sqlite3.gz")
        try archiveData.write(to: archiveURL, options: .atomic)

        return RemoteSyncStagedPatchArchive(
            patch: RemoteSyncDiscoveredPatch(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                schemaVersion: 1,
                file: RemoteSyncFile(
                    id: "/org.andbible.ios-sync-bookmarks/\(sourceDevice)/\(patchNumber).sqlite3.gz",
                    name: "\(patchNumber).sqlite3.gz",
                    size: Int64(archiveData.count),
                    timestamp: fileTimestamp,
                    parentID: "/org.andbible.ios-sync-bookmarks/\(sourceDevice)",
                    mimeType: "application/gzip"
                )
            ),
            archiveFileURL: archiveURL
        )
    }

    private func makeAndroidBookmarksDatabase(
        labels: [AndroidLabelRow],
        bibleBookmarks: [AndroidBibleBookmarkRow] = [],
        bibleNotes: [AndroidBookmarkNoteRow] = [],
        bibleLinks: [AndroidBookmarkLabelLinkRow] = [],
        genericBookmarks: [AndroidGenericBookmarkRow] = [],
        genericNotes: [AndroidBookmarkNoteRow] = [],
        genericLinks: [AndroidBookmarkLabelLinkRow] = [],
        studyPadEntries: [AndroidStudyPadEntryRow] = [],
        studyPadTexts: [AndroidStudyPadTextRow] = [],
        logEntries: [AndroidLogEntryRow] = []
    ) throws -> URL {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-bookmarks-\(UUID().uuidString).sqlite3")

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            XCTFail("Failed to open temporary Android bookmark database")
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(db) }

        XCTAssertEqual(
            sqlite3_exec(
                db,
                """
                CREATE TABLE Label (
                    id BLOB NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    color INTEGER NOT NULL DEFAULT 0,
                    markerStyle INTEGER NOT NULL DEFAULT 0,
                    markerStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                    underlineStyle INTEGER NOT NULL DEFAULT 0,
                    underlineStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                    hideStyle INTEGER NOT NULL DEFAULT 0,
                    hideStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                    favourite INTEGER NOT NULL DEFAULT 0,
                    type TEXT DEFAULT NULL,
                    customIcon TEXT DEFAULT NULL
                );
                CREATE TABLE BibleBookmark (
                    kjvOrdinalStart INTEGER NOT NULL,
                    kjvOrdinalEnd INTEGER NOT NULL,
                    ordinalStart INTEGER NOT NULL,
                    ordinalEnd INTEGER NOT NULL,
                    v11n TEXT NOT NULL,
                    playbackSettings TEXT DEFAULT NULL,
                    id BLOB NOT NULL PRIMARY KEY,
                    createdAt INTEGER NOT NULL,
                    book TEXT DEFAULT NULL,
                    startOffset INTEGER DEFAULT NULL,
                    endOffset INTEGER DEFAULT NULL,
                    primaryLabelId BLOB DEFAULT NULL,
                    lastUpdatedOn INTEGER NOT NULL DEFAULT 0,
                    wholeVerse INTEGER NOT NULL DEFAULT 0,
                    type TEXT DEFAULT NULL,
                    customIcon TEXT DEFAULT NULL,
                    editAction_mode TEXT DEFAULT NULL,
                    editAction_content TEXT DEFAULT NULL
                );
                CREATE TABLE BibleBookmarkNotes (
                    bookmarkId BLOB NOT NULL PRIMARY KEY,
                    notes TEXT NOT NULL
                );
                CREATE TABLE BibleBookmarkToLabel (
                    bookmarkId BLOB NOT NULL,
                    labelId BLOB NOT NULL,
                    orderNumber INTEGER NOT NULL DEFAULT -1,
                    indentLevel INTEGER NOT NULL DEFAULT 0,
                    expandContent INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (bookmarkId, labelId)
                );
                CREATE TABLE GenericBookmark (
                    id BLOB NOT NULL PRIMARY KEY,
                    `key` TEXT NOT NULL,
                    createdAt INTEGER NOT NULL,
                    bookInitials TEXT NOT NULL DEFAULT '',
                    ordinalStart INTEGER NOT NULL,
                    ordinalEnd INTEGER NOT NULL,
                    startOffset INTEGER DEFAULT NULL,
                    endOffset INTEGER DEFAULT NULL,
                    primaryLabelId BLOB DEFAULT NULL,
                    lastUpdatedOn INTEGER NOT NULL DEFAULT 0,
                    wholeVerse INTEGER NOT NULL DEFAULT 0,
                    playbackSettings TEXT DEFAULT NULL,
                    customIcon TEXT DEFAULT NULL,
                    editAction_mode TEXT DEFAULT NULL,
                    editAction_content TEXT DEFAULT NULL
                );
                CREATE TABLE GenericBookmarkNotes (
                    bookmarkId BLOB NOT NULL PRIMARY KEY,
                    notes TEXT NOT NULL
                );
                CREATE TABLE GenericBookmarkToLabel (
                    bookmarkId BLOB NOT NULL,
                    labelId BLOB NOT NULL,
                    orderNumber INTEGER NOT NULL DEFAULT -1,
                    indentLevel INTEGER NOT NULL DEFAULT 0,
                    expandContent INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (bookmarkId, labelId)
                );
                CREATE TABLE StudyPadTextEntry (
                    id BLOB NOT NULL PRIMARY KEY,
                    labelId BLOB NOT NULL,
                    orderNumber INTEGER NOT NULL,
                    indentLevel INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE StudyPadTextEntryText (
                    studyPadTextEntryId BLOB NOT NULL PRIMARY KEY,
                    text TEXT NOT NULL
                );
                CREATE TABLE LogEntry (
                    tableName TEXT NOT NULL,
                    entityId1 BLOB NOT NULL,
                    entityId2 BLOB,
                    type TEXT NOT NULL,
                    lastUpdated INTEGER NOT NULL,
                    sourceDevice TEXT NOT NULL,
                    PRIMARY KEY (tableName, entityId1, entityId2)
                );
                """,
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )

        for label in labels {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO Label (id, name, color, markerStyle, markerStyleWholeVerse, underlineStyle, underlineStyleWholeVerse, hideStyle, hideStyleWholeVerse, favourite, type, customIcon) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(label.id, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, label.name, -1, sqliteTransient)
            sqlite3_bind_int(statement, 3, Int32(label.colour))
            sqlite3_bind_int(statement, 4, label.markerStyle ? 1 : 0)
            sqlite3_bind_int(statement, 5, label.markerStyleWholeVerse ? 1 : 0)
            sqlite3_bind_int(statement, 6, label.underlineStyle ? 1 : 0)
            sqlite3_bind_int(statement, 7, label.underlineStyleWholeVerse ? 1 : 0)
            sqlite3_bind_int(statement, 8, label.hideStyle ? 1 : 0)
            sqlite3_bind_int(statement, 9, label.hideStyleWholeVerse ? 1 : 0)
            sqlite3_bind_int(statement, 10, label.favourite ? 1 : 0)
            bindOptionalText(label.type, to: statement, index: 11)
            bindOptionalText(label.customIcon, to: statement, index: 12)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for bookmark in bibleBookmarks {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO BibleBookmark (kjvOrdinalStart, kjvOrdinalEnd, ordinalStart, ordinalEnd, v11n, playbackSettings, id, createdAt, book, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, type, customIcon, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_int(statement, 1, Int32(bookmark.kjvOrdinalStart))
            sqlite3_bind_int(statement, 2, Int32(bookmark.kjvOrdinalEnd))
            sqlite3_bind_int(statement, 3, Int32(bookmark.ordinalStart))
            sqlite3_bind_int(statement, 4, Int32(bookmark.ordinalEnd))
            sqlite3_bind_text(statement, 5, bookmark.v11n, -1, sqliteTransient)
            bindOptionalText(bookmark.playbackSettingsJSON, to: statement, index: 6)
            bindUUIDBlob(bookmark.id, to: statement, index: 7)
            sqlite3_bind_int64(statement, 8, Int64(bookmark.createdAt.timeIntervalSince1970 * 1000))
            bindOptionalText(bookmark.book, to: statement, index: 9)
            bindOptionalInt(bookmark.startOffset, to: statement, index: 10)
            bindOptionalInt(bookmark.endOffset, to: statement, index: 11)
            bindOptionalUUIDBlob(bookmark.primaryLabelID, to: statement, index: 12)
            sqlite3_bind_int64(statement, 13, Int64(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000))
            sqlite3_bind_int(statement, 14, bookmark.wholeVerse ? 1 : 0)
            bindOptionalText(bookmark.type, to: statement, index: 15)
            bindOptionalText(bookmark.customIcon, to: statement, index: 16)
            bindOptionalText(bookmark.editActionMode, to: statement, index: 17)
            bindOptionalText(bookmark.editActionContent, to: statement, index: 18)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for note in bibleNotes {
            try insertBookmarkNote(note, tableName: "BibleBookmarkNotes", db: db)
        }

        for link in bibleLinks {
            try insertBookmarkLabelLink(link, tableName: "BibleBookmarkToLabel", db: db)
        }

        for bookmark in genericBookmarks {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO GenericBookmark (id, `key`, createdAt, bookInitials, ordinalStart, ordinalEnd, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, playbackSettings, customIcon, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(bookmark.id, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, bookmark.key, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 3, Int64(bookmark.createdAt.timeIntervalSince1970 * 1000))
            sqlite3_bind_text(statement, 4, bookmark.bookInitials, -1, sqliteTransient)
            sqlite3_bind_int(statement, 5, Int32(bookmark.ordinalStart))
            sqlite3_bind_int(statement, 6, Int32(bookmark.ordinalEnd))
            bindOptionalInt(bookmark.startOffset, to: statement, index: 7)
            bindOptionalInt(bookmark.endOffset, to: statement, index: 8)
            bindOptionalUUIDBlob(bookmark.primaryLabelID, to: statement, index: 9)
            sqlite3_bind_int64(statement, 10, Int64(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000))
            sqlite3_bind_int(statement, 11, bookmark.wholeVerse ? 1 : 0)
            bindOptionalText(bookmark.playbackSettingsJSON, to: statement, index: 12)
            bindOptionalText(bookmark.customIcon, to: statement, index: 13)
            bindOptionalText(bookmark.editActionMode, to: statement, index: 14)
            bindOptionalText(bookmark.editActionContent, to: statement, index: 15)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for note in genericNotes {
            try insertBookmarkNote(note, tableName: "GenericBookmarkNotes", db: db)
        }

        for link in genericLinks {
            try insertBookmarkLabelLink(link, tableName: "GenericBookmarkToLabel", db: db)
        }

        for entry in studyPadEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO StudyPadTextEntry (id, labelId, orderNumber, indentLevel) VALUES (?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(entry.id, to: statement, index: 1)
            bindUUIDBlob(entry.labelID, to: statement, index: 2)
            sqlite3_bind_int(statement, 3, Int32(entry.orderNumber))
            sqlite3_bind_int(statement, 4, Int32(entry.indentLevel))
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for text in studyPadTexts {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO StudyPadTextEntryText (studyPadTextEntryId, text) VALUES (?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            bindUUIDBlob(text.entryID, to: statement, index: 1)
            sqlite3_bind_text(statement, 2, text.text, -1, sqliteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        for entry in logEntries {
            var statement: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(
                    db,
                    "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)",
                    -1,
                    &statement,
                    nil
                ),
                SQLITE_OK
            )
            sqlite3_bind_text(statement, 1, entry.tableName, -1, sqliteTransient)
            bindSQLiteValue(entry.entityID1, to: statement, index: 2)
            bindSQLiteValue(entry.entityID2, to: statement, index: 3)
            sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, sqliteTransient)
            sqlite3_bind_int64(statement, 5, entry.lastUpdated)
            sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, sqliteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }

        return databaseURL
    }

    private func insertBookmarkNote(_ note: AndroidBookmarkNoteRow, tableName: String, db: OpaquePointer) throws {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO \(tableName) (bookmarkId, notes) VALUES (?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        bindUUIDBlob(note.bookmarkID, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, note.notes, -1, sqliteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    private func insertBookmarkLabelLink(_ link: AndroidBookmarkLabelLinkRow, tableName: String, db: OpaquePointer) throws {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO \(tableName) (bookmarkId, labelId, orderNumber, indentLevel, expandContent) VALUES (?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        bindUUIDBlob(link.bookmarkID, to: statement, index: 1)
        bindUUIDBlob(link.labelID, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(link.orderNumber))
        sqlite3_bind_int(statement, 4, Int32(link.indentLevel))
        sqlite3_bind_int(statement, 5, link.expandContent ? 1 : 0)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    private func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let blob = uuidBlob(uuid)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(blob.count), sqliteTransient)
        }
    }

    private func bindOptionalUUIDBlob(_ uuid: UUID?, to statement: OpaquePointer?, index: Int32) {
        guard let uuid else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(uuid, to: statement, index: index)
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    /**
     Binds one typed Android SQLite scalar into a fixture statement.

     - Parameters:
       - value: Typed scalar payload that should be bound into SQLite.
       - statement: SQLite statement receiving the bound parameter.
       - index: One-based parameter index.
     - Side effects:
       - mutates the bound SQLite statement parameter state
     - Failure modes: This helper cannot fail.
     */
    private func bindSQLiteValue(_ value: RemoteSyncSQLiteValue, to statement: OpaquePointer?, index: Int32) {
        switch value.kind {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer:
            sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
        case .real:
            sqlite3_bind_double(statement, index, value.realValue ?? 0)
        case .text:
            sqlite3_bind_text(statement, index, value.textValue ?? "", -1, sqliteTransient)
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), sqliteTransient)
            }
        }
    }

    private func uuidBlob(_ uuid: UUID) -> Data {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        var bytes = Data()
        bytes.reserveCapacity(16)

        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            let byteString = hex[index..<nextIndex]
            bytes.append(UInt8(byteString, radix: 16)!)
            index = nextIndex
        }
        return bytes
    }
}

private final class InMemorySecretStore: SecretStoring {
    private var secrets: [String: String] = [:]

    func secret(forKey key: String) -> String? {
        secrets[key]
    }

    func setSecret(_ value: String, forKey key: String) throws {
        secrets[key] = value
    }

    func removeSecret(forKey key: String) throws {
        secrets.removeValue(forKey: key)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("MockURLProtocol.requestHandler must be set before use")
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

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RequestLogEntry] = []

    func append(method: String, path: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(RequestLogEntry(method: method, path: path))
    }

    func snapshot() -> [RequestLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private struct RequestLogEntry: Equatable {
    let method: String
    let path: String
}

private actor MockRemoteSyncAdapter: RemoteSyncAdapting {
    private var fallbackListFilesResult: [RemoteSyncFile] = []
    private var listFilesResultsQueue: [[RemoteSyncFile]] = []
    private var createFolderResults: [RemoteSyncFile] = []
    private var uploadResults: [RemoteSyncFile] = []
    private var downloadDataByID: [String: Data] = [:]
    private var knownResponses: [String: Bool] = [:]
    private var makeKnownResponse = "device-known-default"
    private var events: [MockRemoteSyncAdapterEvent] = []
    private var uploadedFiles: [MockRemoteSyncUploadedFile] = []

    func setListFilesResult(_ result: [RemoteSyncFile]) {
        fallbackListFilesResult = result
    }

    func enqueueListFilesResult(_ result: [RemoteSyncFile]) {
        listFilesResultsQueue.append(result)
    }

    func enqueueCreateFolderResult(_ result: RemoteSyncFile) {
        createFolderResults.append(result)
    }

    func enqueueUploadResult(_ result: RemoteSyncFile) {
        uploadResults.append(result)
    }

    func setDownloadData(_ data: Data, forID id: String) {
        downloadDataByID[id] = data
    }

    func setKnownResponse(_ value: Bool, forSyncFolderID syncFolderID: String, secretFileName: String) {
        knownResponses["\(syncFolderID)|\(secretFileName)"] = value
    }

    func setMakeKnownResponse(_ value: String) {
        makeKnownResponse = value
    }

    func eventsSnapshot() -> [MockRemoteSyncAdapterEvent] {
        events
    }

    func uploadedFilesSnapshot() -> [MockRemoteSyncUploadedFile] {
        uploadedFiles
    }

    func listFiles(
        parentIDs: [String]?,
        name: String?,
        mimeType: String?,
        modifiedAtLeast: Date?
    ) async throws -> [RemoteSyncFile] {
        events.append(
            .listFiles(
                parentIDs: parentIDs,
                name: name,
                mimeType: mimeType,
                modifiedAtLeast: modifiedAtLeast
            )
        )
        if !listFilesResultsQueue.isEmpty {
            return listFilesResultsQueue.removeFirst()
        }
        return fallbackListFilesResult
    }

    func createNewFolder(name: String, parentID: String?) async throws -> RemoteSyncFile {
        events.append(.createFolder(name: name, parentID: parentID))
        if !createFolderResults.isEmpty {
            return createFolderResults.removeFirst()
        }
        return RemoteSyncFile(
            id: [parentID, name].compactMap { $0 }.joined(separator: "/"),
            name: name,
            size: 0,
            timestamp: 0,
            parentID: parentID ?? "/",
            mimeType: NextCloudSyncAdapter.folderMimeType
        )
    }

    func download(id: String) async throws -> Data {
        events.append(.download(id: id))
        return downloadDataByID[id] ?? Data()
    }

    func upload(
        name: String,
        fileURL: URL,
        parentID: String,
        contentType: String
    ) async throws -> RemoteSyncFile {
        events.append(.upload(name: name, parentID: parentID, contentType: contentType))
        let data = try Data(contentsOf: fileURL)
        uploadedFiles.append(
            MockRemoteSyncUploadedFile(
                name: name,
                parentID: parentID,
                contentType: contentType,
                data: data
            )
        )
        if !uploadResults.isEmpty {
            let result = uploadResults.removeFirst()
            return RemoteSyncFile(
                id: result.id,
                name: result.name,
                size: Int64(data.count),
                timestamp: result.timestamp,
                parentID: result.parentID,
                mimeType: result.mimeType
            )
        }
        return RemoteSyncFile(
            id: [parentID, name].joined(separator: "/"),
            name: name,
            size: Int64(data.count),
            timestamp: 0,
            parentID: parentID,
            mimeType: contentType
        )
    }

    func delete(id: String) async throws {
        events.append(.delete(id: id))
    }

    func isSyncFolderKnown(syncFolderID: String, secretFileName: String) async throws -> Bool {
        events.append(.isSyncFolderKnown(syncFolderID: syncFolderID, secretFileName: secretFileName))
        return knownResponses["\(syncFolderID)|\(secretFileName)"] ?? false
    }

    func makeSyncFolderKnown(syncFolderID: String, deviceIdentifier: String) async throws -> String {
        events.append(.makeKnown(syncFolderID: syncFolderID, deviceIdentifier: deviceIdentifier))
        return makeKnownResponse
    }
}

private enum MockRemoteSyncAdapterEvent: Equatable {
    case listFiles(parentIDs: [String]?, name: String?, mimeType: String?, modifiedAtLeast: Date?)
    case createFolder(name: String, parentID: String?)
    case download(id: String)
    case upload(name: String, parentID: String, contentType: String)
    case delete(id: String)
    case isSyncFolderKnown(syncFolderID: String, secretFileName: String)
    case makeKnown(syncFolderID: String, deviceIdentifier: String)
}

private struct MockRemoteSyncUploadedFile: Equatable {
    let name: String
    let parentID: String
    let contentType: String
    let data: Data
}

private func gunzipTestData(_ data: Data) throws -> Data {
    try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
        guard let baseAddress = ptr.baseAddress else {
            throw RemoteSyncArchiveStagingError.decompressionFailed
        }

        var outputLength: UInt = 0
        guard let output = gunzip_data(
            baseAddress.assumingMemoryBound(to: UInt8.self),
            UInt(data.count),
            &outputLength
        ) else {
            throw RemoteSyncArchiveStagingError.decompressionFailed
        }

        defer { gunzip_free(output) }
        return Data(bytes: output, count: Int(outputLength))
    }
}

private func makeTemporarySQLiteDatabase(userVersion: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "remote-sync-test-\(UUID().uuidString).sqlite3"
    )

    var database: OpaquePointer?
    guard sqlite3_open_v2(
        url.path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        nil
    ) == SQLITE_OK,
    let database else {
        if let database {
            sqlite3_close(database)
        }
        throw NSError(domain: "AndBibleTests.SQLite", code: 1)
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(database, "PRAGMA user_version = \(userVersion);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 2)
    }
    guard sqlite3_exec(database, "CREATE TABLE IF NOT EXISTS sample (id INTEGER PRIMARY KEY, value TEXT);", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 3)
    }
    guard sqlite3_exec(database, "INSERT INTO sample (value) VALUES ('fixture');", nil, nil, nil) == SQLITE_OK else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 4)
    }

    return url
}

private func readSQLiteUserVersion(at url: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        if let database {
            sqlite3_close(database)
        }
        throw NSError(domain: "AndBibleTests.SQLite", code: 5)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        if let statement {
            sqlite3_finalize(statement)
        }
        throw NSError(domain: "AndBibleTests.SQLite", code: 6)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw NSError(domain: "AndBibleTests.SQLite", code: 7)
    }
    return Int(sqlite3_column_int(statement, 0))
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
