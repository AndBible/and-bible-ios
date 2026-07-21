import SwiftData
import SwordKit
import XCTest
@testable import BibleCore

/**
 Mutable exact-source resolver used by persisted-ordinal migration tests.

 Tests register results by module and source range so bookmark and memorization migrations can be
 exercised without depending on installed SWORD modules. Unregistered calls model a module that is
 not installed yet.
 */
private final class StubPersistedOrdinalSourceRangeResolver: PersistedOrdinalSourceRangeResolving {
    private struct Key: Hashable {
        let moduleInitials: String
        let startOrdinal: Int
        let endOrdinal: Int
    }

    private var resolutions: [Key: PersistedOrdinalSourceRangeResolution] = [:]

    /**
     Registers one deterministic source-range resolution.

     - Parameters:
       - resolution: Result that migration should observe.
       - moduleInitials: Exact legacy source module initials.
       - startOrdinal: Legacy source start ordinal.
       - endOrdinal: Legacy source end ordinal.
     - Side effects: Replaces any prior result for the same source range.
     - Failure modes: This helper cannot fail.
     */
    func set(
        _ resolution: PersistedOrdinalSourceRangeResolution,
        moduleInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) {
        resolutions[
            Key(
                moduleInitials: moduleInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            )
        ] = resolution
    }

    /**
     Resolves a registered source range or reports that its module is unavailable.

     - Parameters:
       - moduleInitials: Exact legacy source module initials.
       - startOrdinal: Legacy source start ordinal.
       - endOrdinal: Legacy source end ordinal.
     - Returns: Registered result, or `.moduleUnavailable` when none exists.
     - Side effects: none.
     - Failure modes: This fake reports failures through the result enum.
     */
    func resolveSourceRange(
        moduleInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> PersistedOrdinalSourceRangeResolution {
        resolutions[
            Key(
                moduleInitials: moduleInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            )
        ] ?? .moduleUnavailable
    }
}

/**
 Persisted ordinal trust, migration, Android-boundary, and suppression contract coverage.

 These tests use in-memory SwiftData and settings stores. They validate that exact source metadata
 is the only native repair authority, Android rows become trusted only after bounds validation,
 and quarantined rows remain durable without entering consumer or deletion-inference snapshots.
 */
final class PersistedOrdinalTrustTests: XCTestCase {
    /**
     Verifies a legacy KJV New Testament bookmark is remapped instead of treated as KJVA identity.

     KJV and KJVA have different intro-inclusive offsets by Matthew because KJVA includes the
     deuterocanonical books. The fixture intentionally stores the KJV source ordinal in the KJVA
     field and labels the row KJVA, then supplies exact KJV module provenance to migration.

     Failure means numeric plausibility or a legacy `v11n` label can bypass exact-source repair.
     */
    func testMigrationRepairsMislabeledKJVNewTestamentBookmark() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let sourceOrdinal = try XCTUnwrap(
            SwordVersification.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 1, verse: 1),
                versification: "KJV"
            )
        )
        let sourceReference = VerseKeyReference(
            osisBookId: "Matt",
            chapter: 1,
            verse: 1,
            ordinal: sourceOrdinal
        )
        let expectedKJVA = try XCTUnwrap(
            VersificationMapper.kjvaOrdinal(for: sourceReference, sourceVersification: "KJV")
        )
        XCTAssertNotEqual(sourceOrdinal, expectedKJVA)

        let bookmark = makeLegacyBookmark(
            id: UUID(uuidString: "a0000000-0000-0000-0000-000000000001")!,
            moduleInitials: "KJV",
            sourceStart: sourceOrdinal,
            sourceEnd: sourceOrdinal,
            storedKJVAStart: sourceOrdinal,
            storedKJVAEnd: sourceOrdinal
        )
        modelContext.insert(bookmark)
        try modelContext.save()

        let resolver = StubPersistedOrdinalSourceRangeResolver()
        resolver.set(
            .resolved(start: sourceReference, end: sourceReference, sourceVersification: "KJV"),
            moduleInitials: "KJV",
            startOrdinal: sourceOrdinal,
            endOrdinal: sourceOrdinal
        )
        let report = try PersistedOrdinalTrustMigrationService(
            modelContext: modelContext,
            settingsStore: settingsStore,
            sourceResolver: resolver
        ).migrate()

        let migrated = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<BibleBookmark>()).first
        )
        XCTAssertEqual(report.repairedBookmarkCount, 1)
        XCTAssertEqual(migrated.kjvOrdinalStart, expectedKJVA)
        XCTAssertEqual(migrated.kjvOrdinalEnd, expectedKJVA)
        XCTAssertEqual(migrated.ordinalStart, sourceOrdinal)
        XCTAssertEqual(migrated.ordinalEnd, sourceOrdinal)
        XCTAssertEqual(migrated.v11n, "KJV")
        XCTAssertEqual(migrated.ordinalTrustState, .verifiedMappingV1)
        XCTAssertEqual(migrated.ordinalProvenance, .legacyMigration)
        XCTAssertEqual(migrated.ordinalSourceVersification, "KJV")
        XCTAssertTrue(migrated.hasTrustedPersistedOrdinals)
    }

    /**
     Verifies an origin-main Android bookmark with a NULL book column survives trust migration.

     The test seeds the exact post-lightweight-migration shape: the pre-trust bookmark fields are
     populated, all newly added trust fields have their schema defaults, and both Android book
     identities are empty. Migration must validate the existing Android KJVA and source columns
     without requiring a module, after which list, overlap/highlight, navigation, and shared
     sync/backup consumers can use the admitted KJVA row and preserve Android NULL on export. A
     second NULL-book row with an unknown versification must remain quarantined.

     Failure means upgrading can make a valid Android bookmark invisible or turn its absence from
     sync/backup into data loss. The in-memory SwiftData container is discarded with the test.
     */
    func testMigrationRetainsLegacyAndroidNullBookBookmarkAsTrustedKJVA() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let bookmarkID = UUID(uuidString: "a0000000-0000-0000-0000-000000000002")!
        let unknownID = UUID(uuidString: "a0000000-0000-0000-0000-000000000003")!
        let bookmark = BibleBookmark(
            id: bookmarkID,
            kjvOrdinalStart: 15,
            kjvOrdinalEnd: 16,
            ordinalStart: 15,
            ordinalEnd: 16,
            v11n: "KJVA",
            bookInitials: ""
        )
        bookmark.book = nil
        bookmark.ordinalTrustStateRaw = PersistedOrdinalTrustState.legacyPendingModule.rawValue
        bookmark.ordinalMappingVersion = 0
        bookmark.ordinalProvenanceRaw = PersistedOrdinalProvenance.unknown.rawValue
        bookmark.ordinalSourceVersification = nil
        bookmark.ordinalSourceStart = nil
        bookmark.ordinalSourceEnd = nil
        modelContext.insert(bookmark)

        let unknown = BibleBookmark(
            id: unknownID,
            kjvOrdinalStart: 17,
            kjvOrdinalEnd: 17,
            ordinalStart: 17,
            ordinalEnd: 17,
            v11n: "UnknownV11n",
            bookInitials: ""
        )
        unknown.book = nil
        unknown.ordinalTrustStateRaw = PersistedOrdinalTrustState.legacyPendingModule.rawValue
        unknown.ordinalMappingVersion = 0
        unknown.ordinalProvenanceRaw = PersistedOrdinalProvenance.unknown.rawValue
        unknown.ordinalSourceVersification = nil
        unknown.ordinalSourceStart = nil
        unknown.ordinalSourceEnd = nil
        modelContext.insert(unknown)
        try modelContext.save()

        let report = try PersistedOrdinalTrustMigrationService(
            modelContext: modelContext,
            settingsStore: settingsStore,
            sourceResolver: StubPersistedOrdinalSourceRangeResolver()
        ).migrate()

        XCTAssertEqual(report.repairedBookmarkCount, 1)
        XCTAssertEqual(report.unresolvedCount, 1)
        XCTAssertTrue(report.didChangePersistence)
        XCTAssertEqual(bookmark.ordinalTrustState, .verifiedAndroid)
        XCTAssertEqual(bookmark.ordinalProvenance, .androidImport)
        XCTAssertEqual(bookmark.ordinalSourceVersification, "KJVA")
        XCTAssertEqual(bookmark.ordinalSourceStart, 15)
        XCTAssertEqual(bookmark.ordinalSourceEnd, 16)
        XCTAssertTrue(bookmark.hasTrustedPersistedOrdinals)
        XCTAssertEqual(unknown.ordinalTrustState, .legacyUnresolved)
        XCTAssertFalse(unknown.hasTrustedPersistedOrdinals)

        let store = BookmarkStore(modelContext: modelContext)
        XCTAssertEqual(store.bibleBookmarks().map(\.id), [bookmarkID])
        XCTAssertEqual(store.bibleBookmark(id: bookmarkID)?.id, bookmarkID)
        XCTAssertEqual(
            store.bibleBookmarks(overlapping: 15, endOrdinal: 16).map(\.id),
            [bookmarkID]
        )

        let snapshot = RemoteSyncBookmarkSnapshotService().snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let exported = try XCTUnwrap(snapshot.bibleBookmarkRowsByKey.values.first)
        XCTAssertEqual(exported.id, bookmarkID)
        XCTAssertNil(exported.book)
        XCTAssertEqual(snapshot.suppressedKeys.count, 1)
    }

    /**
     Verifies divergent mapping repairs both endpoints atomically and quarantines partial failure.

     Vulgate Psalm 10 maps into a different KJVA Psalm. A second row has the same valid start but
     an invalid end reference; migration must leave both of its persisted KJVA values untouched and
     mark the whole row unresolved.

     Failure means migration can persist a mixed-domain or partially repaired bookmark range.
     */
    func testMigrationRepairsDivergentRangeAndQuarantinesInvalidEndpoint() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let validID = UUID(uuidString: "a0000000-0000-0000-0000-000000000011")!
        let invalidID = UUID(uuidString: "a0000000-0000-0000-0000-000000000012")!
        let sourceStartOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Ps", chapter: 10, verse: 1),
                versification: "Vulg"
            )
        )
        let sourceEndOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Ps", chapter: 10, verse: 2),
                versification: "Vulg"
            )
        )
        let sourceStart = VerseKeyReference(
            osisBookId: "Ps",
            chapter: 10,
            verse: 1,
            ordinal: sourceStartOrdinal
        )
        let sourceEnd = VerseKeyReference(
            osisBookId: "Ps",
            chapter: 10,
            verse: 2,
            ordinal: sourceEndOrdinal
        )
        let expected = try XCTUnwrap(
            VersificationMapper.kjvaOrdinalRange(
                start: sourceStart,
                end: sourceEnd,
                sourceVersification: "Vulg"
            )
        )

        modelContext.insert(
            makeLegacyBookmark(
                id: validID,
                moduleInitials: "VULG",
                sourceStart: sourceStartOrdinal,
                sourceEnd: sourceEndOrdinal,
                storedKJVAStart: 500,
                storedKJVAEnd: 501
            )
        )
        modelContext.insert(
            makeLegacyBookmark(
                id: invalidID,
                moduleInitials: "BROKEN",
                sourceStart: sourceStartOrdinal,
                sourceEnd: sourceEndOrdinal,
                storedKJVAStart: 123,
                storedKJVAEnd: 124
            )
        )
        try modelContext.save()

        let resolver = StubPersistedOrdinalSourceRangeResolver()
        resolver.set(
            .resolved(start: sourceStart, end: sourceEnd, sourceVersification: "Vulg"),
            moduleInitials: "VULG",
            startOrdinal: sourceStartOrdinal,
            endOrdinal: sourceEndOrdinal
        )
        resolver.set(
            .resolved(
                start: sourceStart,
                end: VerseKeyReference(
                    osisBookId: "Ps",
                    chapter: 10,
                    verse: 3,
                    ordinal: sourceEndOrdinal
                ),
                sourceVersification: "Vulg"
            ),
            moduleInitials: "BROKEN",
            startOrdinal: sourceStartOrdinal,
            endOrdinal: sourceEndOrdinal
        )

        let report = try PersistedOrdinalTrustMigrationService(
            modelContext: modelContext,
            settingsStore: settingsStore,
            sourceResolver: resolver
        ).migrate()
        let rows = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let repaired = try XCTUnwrap(rowsByID[validID])
        let unresolved = try XCTUnwrap(rowsByID[invalidID])

        XCTAssertEqual(report.repairedBookmarkCount, 1)
        XCTAssertEqual(report.unresolvedCount, 1)
        XCTAssertEqual(repaired.kjvOrdinalStart, expected.lowerBound)
        XCTAssertEqual(repaired.kjvOrdinalEnd, expected.upperBound)
        XCTAssertTrue(repaired.hasTrustedPersistedOrdinals)
        XCTAssertEqual(unresolved.kjvOrdinalStart, 123)
        XCTAssertEqual(unresolved.kjvOrdinalEnd, 124)
        XCTAssertEqual(unresolved.ordinalTrustState, .legacyUnresolved)
        XCTAssertFalse(unresolved.hasTrustedPersistedOrdinals)
        XCTAssertEqual(BookmarkStore(modelContext: modelContext).bibleBookmarks().map(\.id), [validID])
    }

    /**
     Verifies migration rejects resolver output that does not prove the preserved endpoints.

     The bookmark and memorized-verse resolver results deliberately carry the requested ordinal
     integers paired with different canonical verse coordinates. The target result carries exact but
     reversed source endpoints. No path may manufacture migration trust after either violation.

     Failure means a lying resolver or reversed range can relabel arbitrary KJVA numbers verified.
     */
    func testMigrationQuarantinesLyingResolverAndReversedSourceRange() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let sourceStartOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 1),
                versification: "KJV"
            )
        )
        let sourceEndOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 2),
                versification: "KJV"
            )
        )
        let memorizedSourceOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 3),
                versification: "KJV"
            )
        )
        let reversedSourceStart = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 4),
                versification: "KJV"
            )
        )
        let reversedSourceEnd = memorizedSourceOrdinal
        let bookmark = makeLegacyBookmark(
            id: UUID(uuidString: "a0000000-0000-0000-0000-000000000015")!,
            moduleInitials: "LIAR",
            sourceStart: sourceStartOrdinal,
            sourceEnd: sourceEndOrdinal,
            storedKJVAStart: 70,
            storedKJVAEnd: 71
        )
        modelContext.insert(bookmark)
        try modelContext.save()

        let store = MemorizationProgressStore(settingsStore: settingsStore)
        try store.replacePersistenceSnapshot(
            MemorizationProgressSnapshot(
                memorizedVerses: [
                    MemorizedVerseProgress(
                        bookInitials: "LIAR",
                        kjvOrdinal: 80,
                        ordinalTrust: PersistedOrdinalTrustPolicy.legacyMetadata(
                            sourceBookInitials: "LIAR",
                            sourceOrdinalStart: memorizedSourceOrdinal,
                            sourceOrdinalEnd: memorizedSourceOrdinal
                        )
                    ),
                ],
                targetRows: [
                    MemorizationTargetRow(
                        bookInitials: "REVERSED",
                        startOrdinal: 90,
                        endOrdinal: 91,
                        ordinalTrust: PersistedOrdinalTrustPolicy.legacyMetadata(
                            sourceBookInitials: "REVERSED",
                            sourceOrdinalStart: reversedSourceStart,
                            sourceOrdinalEnd: reversedSourceEnd
                        )
                    ),
                ]
            )
        )

        let resolver = StubPersistedOrdinalSourceRangeResolver()
        resolver.set(
            .resolved(
                start: VerseKeyReference(
                    osisBookId: "Exod",
                    chapter: 1,
                    verse: 1,
                    ordinal: sourceStartOrdinal
                ),
                end: VerseKeyReference(
                    osisBookId: "Exod",
                    chapter: 1,
                    verse: 2,
                    ordinal: sourceEndOrdinal
                ),
                sourceVersification: "KJV"
            ),
            moduleInitials: "LIAR",
            startOrdinal: sourceStartOrdinal,
            endOrdinal: sourceEndOrdinal
        )
        resolver.set(
            .resolved(
                start: VerseKeyReference(
                    osisBookId: "Gen",
                    chapter: 2,
                    verse: 1,
                    ordinal: memorizedSourceOrdinal
                ),
                end: VerseKeyReference(
                    osisBookId: "Gen",
                    chapter: 2,
                    verse: 1,
                    ordinal: memorizedSourceOrdinal
                ),
                sourceVersification: "KJV"
            ),
            moduleInitials: "LIAR",
            startOrdinal: memorizedSourceOrdinal,
            endOrdinal: memorizedSourceOrdinal
        )
        resolver.set(
            .resolved(
                start: VerseKeyReference(
                    osisBookId: "Gen",
                    chapter: 1,
                    verse: 4,
                    ordinal: reversedSourceStart
                ),
                end: VerseKeyReference(
                    osisBookId: "Gen",
                    chapter: 1,
                    verse: 3,
                    ordinal: reversedSourceEnd
                ),
                sourceVersification: "KJV"
            ),
            moduleInitials: "REVERSED",
            startOrdinal: reversedSourceStart,
            endOrdinal: reversedSourceEnd
        )

        let report = try PersistedOrdinalTrustMigrationService(
            modelContext: modelContext,
            settingsStore: settingsStore,
            sourceResolver: resolver
        ).migrate()
        let persisted = store.persistenceSnapshot()

        XCTAssertEqual(report.repairedBookmarkCount, 0)
        XCTAssertEqual(report.repairedMemorizedVerseCount, 0)
        XCTAssertEqual(report.repairedMemorizationTargetCount, 0)
        XCTAssertEqual(report.unresolvedCount, 3)
        XCTAssertEqual(bookmark.ordinalTrustState, .legacyUnresolved)
        XCTAssertEqual(bookmark.kjvOrdinalStart, 70)
        XCTAssertEqual(bookmark.kjvOrdinalEnd, 71)
        XCTAssertEqual(persisted.memorizedVerses.first?.ordinalTrust.state, .legacyUnresolved)
        XCTAssertEqual(persisted.memorizedVerses.first?.kjvOrdinal, 80)
        XCTAssertEqual(persisted.targetRows.first?.ordinalTrust.state, .legacyUnresolved)
        XCTAssertEqual(persisted.targetRows.first?.range, MemorizationProgressRange(
            bookInitials: "REVERSED",
            startOrdinal: 90,
            endOrdinal: 91
        ))
    }

    /**
     Verifies missing-module rows remain retryable and a completed migration is idempotent.

     One bookmark, memorized verse, and target start with explicit pending metadata. The first pass
     has no installed module and must retain all three. Once exact resolver results appear, a second
     pass repairs every row, and a third pass must perform no persistence writes.

     Failure means startup can discard pending data, skip a later module retry, or churn completed
     rows on every launch.
     */
    func testPendingModuleRowsRetryAndCompletedMigrationIsIdempotent() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let sourceStartOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 1),
                versification: "KJV"
            )
        )
        let sourceEndOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 2),
                versification: "KJV"
            )
        )
        let bookmark = makeLegacyBookmark(
            id: UUID(uuidString: "a0000000-0000-0000-0000-000000000021")!,
            moduleInitials: "LATE",
            sourceStart: sourceStartOrdinal,
            sourceEnd: sourceEndOrdinal,
            storedKJVAStart: 700,
            storedKJVAEnd: 701
        )
        modelContext.insert(bookmark)
        try modelContext.save()

        let memorizedID = UUID(uuidString: "a0000000-0000-0000-0000-000000000022")!
        let targetID = UUID(uuidString: "a0000000-0000-0000-0000-000000000023")!
        let pendingVerse = PersistedOrdinalTrustPolicy.legacyMetadata(
            sourceBookInitials: "LATE",
            sourceOrdinalStart: sourceStartOrdinal,
            sourceOrdinalEnd: sourceStartOrdinal
        )
        let pendingTarget = PersistedOrdinalTrustPolicy.legacyMetadata(
            sourceBookInitials: "LATE",
            sourceOrdinalStart: sourceStartOrdinal,
            sourceOrdinalEnd: sourceEndOrdinal
        )
        let memorizationStore = MemorizationProgressStore(settingsStore: settingsStore)
        try memorizationStore.replacePersistenceSnapshot(
            MemorizationProgressSnapshot(
                memorizedVerses: [
                    MemorizedVerseProgress(
                        id: memorizedID,
                        bookInitials: "LATE",
                        kjvOrdinal: 700,
                        memorizedAt: 100,
                        ordinalTrust: pendingVerse
                    ),
                ],
                targetRows: [
                    MemorizationTargetRow(
                        id: targetID,
                        bookInitials: "LATE",
                        startOrdinal: 700,
                        endOrdinal: 701,
                        createdAt: 200,
                        ordinalTrust: pendingTarget
                    ),
                ]
            )
        )

        let resolver = StubPersistedOrdinalSourceRangeResolver()
        let service = PersistedOrdinalTrustMigrationService(
            modelContext: modelContext,
            settingsStore: settingsStore,
            sourceResolver: resolver
        )
        let pendingReport = try service.migrate()
        XCTAssertEqual(pendingReport.pendingModuleCount, 3)
        XCTAssertFalse(pendingReport.didChangePersistence)
        XCTAssertTrue(memorizationStore.snapshot().memorizedVerses.isEmpty)
        XCTAssertTrue(memorizationStore.snapshot().targetRows.isEmpty)

        let start = VerseKeyReference(
            osisBookId: "Gen",
            chapter: 1,
            verse: 1,
            ordinal: sourceStartOrdinal
        )
        let end = VerseKeyReference(
            osisBookId: "Gen",
            chapter: 1,
            verse: 2,
            ordinal: sourceEndOrdinal
        )
        resolver.set(
            .resolved(start: start, end: start, sourceVersification: "KJV"),
            moduleInitials: "LATE",
            startOrdinal: sourceStartOrdinal,
            endOrdinal: sourceStartOrdinal
        )
        resolver.set(
            .resolved(start: start, end: end, sourceVersification: "KJV"),
            moduleInitials: "LATE",
            startOrdinal: sourceStartOrdinal,
            endOrdinal: sourceEndOrdinal
        )

        let repairedReport = try service.migrate()
        XCTAssertEqual(repairedReport.repairedBookmarkCount, 1)
        XCTAssertEqual(repairedReport.repairedMemorizedVerseCount, 1)
        XCTAssertEqual(repairedReport.repairedMemorizationTargetCount, 1)
        XCTAssertEqual(repairedReport.pendingModuleCount, 0)
        XCTAssertTrue(repairedReport.didChangePersistence)
        XCTAssertEqual(memorizationStore.snapshot().memorizedVerses.map(\.id), [memorizedID])
        XCTAssertEqual(memorizationStore.snapshot().targetRows.map(\.id), [targetID])

        let idempotentReport = try service.migrate()
        XCTAssertEqual(idempotentReport.repairedBookmarkCount, 0)
        XCTAssertEqual(idempotentReport.repairedMemorizedVerseCount, 0)
        XCTAssertEqual(idempotentReport.repairedMemorizationTargetCount, 0)
        XCTAssertFalse(idempotentReport.didChangePersistence)
    }

    /**
     Verifies origin-main memorization JSON backfills trusted KJVA metadata without hiding progress.

     The valid fixtures omit trust metadata exactly as origin main encoded global Android-compatible
     KJVA rows. Migration must persist explicit identity-mapping metadata and keep both rows visible
     and exportable. An out-of-range row in the same old shape must remain quarantined, proving the
     compatibility boundary does not trust arbitrary integers. A second pass must be idempotent.

     Failure means an upgrade can hide valid memorization data or promote invalid source-domain data.
     */
    func testOriginMainMemorizationRowsBackfillTrustedKJVAAndRemainExportable() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let memorizedID = UUID(uuidString: "a0000000-0000-0000-0000-000000000031")!
        let targetID = UUID(uuidString: "a0000000-0000-0000-0000-000000000032")!
        let invalidID = UUID(uuidString: "a0000000-0000-0000-0000-000000000033")!
        let invalidOrdinal = JSwordKJVAVersification.progressOrdinalRange.upperBound + 1
        settingsStore.setString(
            MemorizationProgressStore.settingsKey,
            value: """
            {
              "memorizedVerses": [
                {"id": "\(memorizedID.uuidString)", "bookInitials": "", "kjvOrdinal": 15, "memorizedAt": 100},
                {"id": "\(invalidID.uuidString)", "bookInitials": "", "kjvOrdinal": \(invalidOrdinal), "memorizedAt": 300}
              ],
              "targetRows": [
                {"id": "\(targetID.uuidString)", "bookInitials": "", "startOrdinal": 20, "endOrdinal": 21, "createdAt": 200}
              ]
            }
            """
        )

        let service = PersistedOrdinalTrustMigrationService(
            modelContext: modelContext,
            settingsStore: settingsStore,
            sourceResolver: StubPersistedOrdinalSourceRangeResolver()
        )
        let firstReport = try service.migrate()
        let store = MemorizationProgressStore(settingsStore: settingsStore)
        let persisted = store.persistenceSnapshot()

        XCTAssertTrue(firstReport.didChangePersistence)
        XCTAssertEqual(firstReport.unresolvedCount, 1)
        XCTAssertEqual(
            Set(persisted.memorizedVerses.map(\.ordinalTrust.state)),
            [.verifiedMappingV1, .legacyUnresolved]
        )
        XCTAssertEqual(persisted.targetRows.map(\.ordinalTrust.state), [.verifiedMappingV1])
        XCTAssertEqual(store.snapshot().memorizedVerses.map(\.id), [memorizedID])
        XCTAssertEqual(store.snapshot().targetRows.map(\.id), [targetID])
        XCTAssertEqual(
            persisted.memorizedVerses.first(where: { $0.id == memorizedID })?.ordinalTrust.provenance,
            .legacyMigration
        )
        XCTAssertEqual(
            persisted.targetRows.first?.ordinalTrust.sourceBookInitials,
            "KJVA"
        )

        let syncSnapshot = RemoteSyncProgressSnapshotService().snapshotCurrentState(
            settingsStore: settingsStore
        )
        XCTAssertEqual(
            Set(syncSnapshot.memorizedVerseRowsByKey.values.map(\.id)),
            Set([memorizedID])
        )
        XCTAssertEqual(
            Set(syncSnapshot.memorizationTargetRowsByKey.values.map(\.id)),
            Set([targetID])
        )
        XCTAssertEqual(syncSnapshot.suppressedKeys.count, 1)
        XCTAssertTrue(
            try XCTUnwrap(settingsStore.getString(MemorizationProgressStore.settingsKey))
                .contains("ordinalTrust")
        )
        XCTAssertFalse(try service.migrate().didChangePersistence)
    }

    /**
     Verifies colliding legacy memorized rows keep the newest timestamp after exact repair.

     Two different source modules resolve to the same KJVA verse. Migration repairs both before
     normalization; the durable snapshot must retain the newer Android-compatible timestamp and
     row identity rather than whichever row happened to be iterated last.

     Failure means migration conflict resolution is order-dependent or loses the newest event.
     */
    func testMigrationKeepsNewestTimestampWhenRowsMapToSameKJVAOrdinal() throws {
        let container = try makeInMemorySettingsContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let sourceOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 1),
                versification: "KJV"
            )
        )
        let oldID = UUID(uuidString: "a0000000-0000-0000-0000-000000000041")!
        let newID = UUID(uuidString: "a0000000-0000-0000-0000-000000000042")!
        let store = MemorizationProgressStore(settingsStore: settingsStore)
        try store.replacePersistenceSnapshot(
            MemorizationProgressSnapshot(
                memorizedVerses: [
                    MemorizedVerseProgress(
                        id: oldID,
                        bookInitials: "OLD",
                        kjvOrdinal: 800,
                        memorizedAt: 100,
                        ordinalTrust: PersistedOrdinalTrustPolicy.legacyMetadata(
                            sourceBookInitials: "OLD",
                            sourceOrdinalStart: sourceOrdinal,
                            sourceOrdinalEnd: sourceOrdinal
                        )
                    ),
                    MemorizedVerseProgress(
                        id: newID,
                        bookInitials: "NEW",
                        kjvOrdinal: 900,
                        memorizedAt: 200,
                        ordinalTrust: PersistedOrdinalTrustPolicy.legacyMetadata(
                            sourceBookInitials: "NEW",
                            sourceOrdinalStart: sourceOrdinal,
                            sourceOrdinalEnd: sourceOrdinal
                        )
                    ),
                ]
            )
        )
        let sourceReference = VerseKeyReference(
            osisBookId: "Gen",
            chapter: 1,
            verse: 1,
            ordinal: sourceOrdinal
        )
        let resolver = StubPersistedOrdinalSourceRangeResolver()
        resolver.set(
            .resolved(start: sourceReference, end: sourceReference, sourceVersification: "KJV"),
            moduleInitials: "OLD",
            startOrdinal: sourceOrdinal,
            endOrdinal: sourceOrdinal
        )
        resolver.set(
            .resolved(start: sourceReference, end: sourceReference, sourceVersification: "KJV"),
            moduleInitials: "NEW",
            startOrdinal: sourceOrdinal,
            endOrdinal: sourceOrdinal
        )

        let report = try PersistedOrdinalTrustMigrationService(
            modelContext: modelContext,
            settingsStore: settingsStore,
            sourceResolver: resolver
        ).migrate()

        XCTAssertEqual(report.repairedMemorizedVerseCount, 2)
        XCTAssertEqual(store.persistenceSnapshot().memorizedVerses.map(\.id), [newID])
        XCTAssertEqual(store.snapshot().memorizedVerses.map(\.memorizedAt), [200])
    }

    /**
     Verifies the native memorization API persists actual source metadata with mapped KJVA rows.

     The verified value carries Vulgate source coordinates and a divergent KJVA Psalm range. Both
     target and memorized rows must retain that source contract; unknown versification input must
     fail before any store mutation can be requested.

     Failure means a native write can again record synthetic KJVA coordinates as its provenance.
     */
    func testVerifiedMemorizationWriteBoundaryRetainsExactSourceMetadata() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let sourceStartOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Ps", chapter: 10, verse: 1),
                versification: "Vulg"
            )
        )
        let sourceEndOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Ps", chapter: 10, verse: 2),
                versification: "Vulg"
            )
        )
        let sourceStart = VerseKeyReference(
            osisBookId: "Ps",
            chapter: 10,
            verse: 1,
            ordinal: sourceStartOrdinal
        )
        let sourceEnd = VerseKeyReference(
            osisBookId: "Ps",
            chapter: 10,
            verse: 2,
            ordinal: sourceEndOrdinal
        )
        let mapped = try XCTUnwrap(
            VersificationMapper.kjvaOrdinalRange(
                start: sourceStart,
                end: sourceEnd,
                sourceVersification: "Vulg"
            )
        )
        let verifiedRange = try XCTUnwrap(
            VerifiedKJVAOrdinalRange(
                sourceBookInitials: "VULG",
                sourceVersification: "Vulg",
                sourceOrdinalStart: sourceStartOrdinal,
                sourceOrdinalEnd: sourceEndOrdinal,
                sourceReferenceStart: sourceStart,
                sourceReferenceEnd: sourceEnd
            )
        )
        XCTAssertNil(
            VerifiedKJVAOrdinalRange(
                sourceBookInitials: "VULG",
                sourceVersification: "UnknownV11n",
                sourceOrdinalStart: sourceStartOrdinal,
                sourceOrdinalEnd: sourceEndOrdinal,
                sourceReferenceStart: sourceStart,
                sourceReferenceEnd: sourceEnd
            )
        )
        XCTAssertEqual(verifiedRange.kjvaOrdinalStart, mapped.lowerBound)
        XCTAssertEqual(verifiedRange.kjvaOrdinalEnd, mapped.upperBound)

        let store = MemorizationProgressStore(
            settingsStore: settingsStore,
            currentTimeMilliseconds: { 500 }
        )
        _ = try store.addMemorizationTarget(verifiedRange)
        _ = try store.markAsMemorized(verifiedRange)
        let persisted = store.persistenceSnapshot()

        XCTAssertEqual(persisted.targetRows.count, 1)
        XCTAssertFalse(persisted.memorizedVerses.isEmpty)
        let targetMetadata = persisted.targetRows[0].ordinalTrust
        XCTAssertEqual(targetMetadata.sourceOrdinalStart, sourceStartOrdinal)
        XCTAssertEqual(targetMetadata.sourceOrdinalEnd, sourceEndOrdinal)
        for verse in persisted.memorizedVerses {
            XCTAssertTrue(verse.hasTrustedPersistedOrdinals)
            XCTAssertEqual(verse.ordinalTrust.state, .verifiedMappingV1)
            XCTAssertEqual(verse.ordinalTrust.provenance, .nativeMapping)
            XCTAssertEqual(verse.ordinalTrust.mappingVersion, 1)
            XCTAssertEqual(verse.ordinalTrust.sourceBookInitials, "VULG")
            XCTAssertEqual(verse.ordinalTrust.sourceVersification, "Vulg")
            XCTAssertEqual(verse.ordinalTrust.sourceOrdinalStart, verse.ordinalTrust.sourceOrdinalEnd)
            XCTAssertEqual(
                verse.ordinalTrust,
                try XCTUnwrap(
                    verifiedRange.exactSubrange(
                        kjvaOrdinalStart: verse.kjvOrdinal,
                        kjvaOrdinalEnd: verse.kjvOrdinal
                    )
                ).ordinalTrust
            )
        }
    }

    /**
     Verifies omitted model trust and integer-only write APIs cannot synthesize provenance.

     Valid-looking KJVA numbers are supplied to every legacy boundary. Model rows must remain
     quarantined, and store mutation APIs must return empty deltas without creating settings data.

     Failure means a caller can bypass `VerifiedKJVAOrdinalRange` with plausible raw integers.
     */
    func testRawModelAndMemorizationWriteBoundariesFailClosed() throws {
        let bookmark = BibleBookmark(
            kjvOrdinalStart: 15,
            kjvOrdinalEnd: 16,
            ordinalStart: 15,
            ordinalEnd: 16,
            v11n: "KJVA",
            bookInitials: "KJV"
        )
        let memorized = MemorizedVerseProgress(kjvOrdinal: 15)
        let target = MemorizationTargetRow(startOrdinal: 15, endOrdinal: 16)

        XCTAssertEqual(bookmark.ordinalTrustState, .legacyPendingModule)
        XCTAssertFalse(bookmark.hasTrustedPersistedOrdinals)
        XCTAssertEqual(memorized.ordinalTrust.state, .legacyUnresolved)
        XCTAssertFalse(memorized.hasTrustedPersistedOrdinals)
        XCTAssertEqual(target.ordinalTrust.state, .legacyUnresolved)
        XCTAssertFalse(target.hasTrustedPersistedOrdinals)

        let settingsStore = try makeInMemorySettingsStore()
        let store = MemorizationProgressStore(settingsStore: settingsStore)
        XCTAssertTrue(
            store.addMemorizationTarget(
                bookInitials: "KJVA",
                startOrdinal: 15,
                endOrdinal: 16
            ).isEmpty
        )
        XCTAssertTrue(
            store.markAsMemorized(
                bookInitials: "KJVA",
                startOrdinal: 15,
                endOrdinal: 16
            ).isEmpty
        )
        XCTAssertTrue(store.persistenceSnapshot().memorizedVerses.isEmpty)
        XCTAssertTrue(store.persistenceSnapshot().targetRows.isEmpty)
        XCTAssertNil(settingsStore.getString(MemorizationProgressStore.settingsKey))
    }

    /**
     Verifies a persisted mapping claim cannot become trusted by pairing valid but unrelated coordinates.

     The fixture forges mapping-version-one metadata around a real KJV source verse and an adjacent,
     numerically valid KJVA verse. It also removes source module identity from otherwise correct
     metadata and supplies a source reference whose integer matches the claim but whose canonical
     verse coordinates do not. Every forged claim must fail, while the typed range remains trusted.

     Failure means persisted state/version strings can bypass the typed mapping boundary.
     */
    func testForgedVerifiedMappingMetadataFailsExactRevalidation() throws {
        let sourceOrdinal = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Gen", chapter: 1, verse: 1),
                versification: "KJV"
            )
        )
        let verified = try XCTUnwrap(
            VerifiedKJVAOrdinalRange(
                resolvingSourceBookInitials: "KJV",
                sourceVersification: "KJV",
                sourceOrdinalStart: sourceOrdinal,
                sourceOrdinalEnd: sourceOrdinal
            )
        )
        let unrelatedKJVAOrdinal = verified.kjvaOrdinalStart + 1
        let forged = PersistedOrdinalTrustMetadata(
            state: .verifiedMappingV1,
            mappingVersion: PersistedOrdinalTrustPolicy.currentMappingVersion,
            provenance: .nativeMapping,
            sourceBookInitials: "KJV",
            sourceVersification: "KJV",
            sourceOrdinalStart: sourceOrdinal,
            sourceOrdinalEnd: sourceOrdinal
        )
        let missingSourceIdentity = PersistedOrdinalTrustMetadata(
            state: verified.ordinalTrust.state,
            mappingVersion: verified.ordinalTrust.mappingVersion,
            provenance: verified.ordinalTrust.provenance,
            sourceBookInitials: nil,
            sourceVersification: verified.ordinalTrust.sourceVersification,
            sourceOrdinalStart: verified.ordinalTrust.sourceOrdinalStart,
            sourceOrdinalEnd: verified.ordinalTrust.sourceOrdinalEnd
        )
        let mismatchedReference = VerseKeyReference(
            osisBookId: "Gen",
            chapter: 1,
            verse: 2,
            ordinal: sourceOrdinal
        )

        XCTAssertTrue(
            PersistedOrdinalTrustPolicy.isTrustedKJVARange(
                metadata: verified.ordinalTrust,
                start: verified.kjvaOrdinalStart,
                end: verified.kjvaOrdinalEnd
            )
        )
        XCTAssertFalse(
            PersistedOrdinalTrustPolicy.isTrustedKJVARange(
                metadata: forged,
                start: unrelatedKJVAOrdinal,
                end: unrelatedKJVAOrdinal
            )
        )
        XCTAssertFalse(
            PersistedOrdinalTrustPolicy.isTrustedKJVARange(
                metadata: missingSourceIdentity,
                start: verified.kjvaOrdinalStart,
                end: verified.kjvaOrdinalEnd
            )
        )
        XCTAssertNil(
            VerifiedKJVAOrdinalRange(
                sourceBookInitials: "KJV",
                sourceVersification: "KJV",
                sourceOrdinalStart: sourceOrdinal,
                sourceOrdinalEnd: sourceOrdinal,
                sourceReferenceStart: mismatchedReference,
                sourceReferenceEnd: mismatchedReference
            )
        )
    }

    /**
     Verifies Android bookmarks are trusted only after KJVA validation and known-v11n checks.

     A valid KJV row becomes `verifiedAndroid`; a bounds-valid row with an unknown v11n remains
     durable but unresolved. Bookmark queries and outbound snapshots must expose only the verified
     row, while the unknown row's baseline key remains suppressed rather than deleted.

     Failure means Android authority bypasses validation or quarantine leaks into consumers/sync.
     */
    func testAndroidRestoreTrustsValidatedRowsAndSuppressesUnknownVersification() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let trustedID = UUID(uuidString: "a0000000-0000-0000-0000-000000000051")!
        let unknownID = UUID(uuidString: "a0000000-0000-0000-0000-000000000052")!
        let restore = RemoteSyncBookmarkRestoreService(bookNameResolver: nil)
        _ = try restore.replaceLocalBookmarks(
            from: RemoteSyncAndroidBookmarkSnapshot(
                labels: [],
                bibleBookmarks: [
                    makeAndroidBookmark(id: trustedID, kjvaOrdinal: 15, v11n: "KJV"),
                    makeAndroidBookmark(id: unknownID, kjvaOrdinal: 16, v11n: "UnknownV11n"),
                ],
                genericBookmarks: [],
                studyPadEntries: []
            ),
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        let rows = try modelContext.fetch(FetchDescriptor<BibleBookmark>())
        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(rowsByID[trustedID]?.ordinalTrustState, .verifiedAndroid)
        XCTAssertEqual(rowsByID[trustedID]?.ordinalProvenance, .androidImport)
        XCTAssertTrue(rowsByID[trustedID]?.hasTrustedPersistedOrdinals == true)
        XCTAssertEqual(rowsByID[unknownID]?.ordinalTrustState, .legacyUnresolved)
        XCTAssertFalse(rowsByID[unknownID]?.hasTrustedPersistedOrdinals == true)
        XCTAssertEqual(BookmarkStore(modelContext: modelContext).bibleBookmarks().map(\.id), [trustedID])

        let snapshotService = RemoteSyncBookmarkSnapshotService()
        let snapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(snapshot.bibleBookmarkRowsByKey.values.map(\.id), [trustedID])

        let entityID = RemoteSyncSQLiteValue.blob(RemoteSyncBookmarkSnapshotService.uuidBlob(unknownID))
        // Android SyncableRoomDatabase.LogEntry makes entityId2 non-null and defaults
        // single-identifier rows to an empty IdType; use the shared Room-v12 boundary value.
        let entityID2 = AndroidBookmarkDatabaseContract.emptySecondaryEntityID
        let logStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let unknownKey = logStore.key(
            for: .bookmarks,
            tableName: "BibleBookmark",
            entityID1: entityID,
            entityID2: entityID2
        )
        XCTAssertTrue(snapshot.suppressedKeys.contains(unknownKey))

        let baselineStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        baselineStore.setFingerprint(
            "unknown-baseline",
            for: .bookmarks,
            tableName: "BibleBookmark",
            entityID1: entityID,
            entityID2: entityID2
        )
        logStore.addEntry(
            RemoteSyncLogEntry(
                tableName: "BibleBookmark",
                entityID1: entityID,
                entityID2: entityID2,
                type: .upsert,
                lastUpdated: 100,
                sourceDevice: "android"
            ),
            for: .bookmarks
        )
        snapshotService.refreshBaselineFingerprints(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        XCTAssertEqual(
            baselineStore.fingerprint(
                for: .bookmarks,
                tableName: "BibleBookmark",
                entityID1: entityID,
                entityID2: entityID2
            ),
            "unknown-baseline"
        )
    }

    /**
     Verifies an Android row outside the KJVA persistence bounds fails before replacement.

     - Failure meaning: A successful restore would make Android authority equivalent to trusting
       arbitrary numbers and could place invalid ordinals into navigation, export, or sync.
     */
    func testAndroidRestoreRejectsOutOfBoundsKJVAOrdinals() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let settingsStore = SettingsStore(modelContext: modelContext)
        let row = makeAndroidBookmark(
            id: UUID(uuidString: "a0000000-0000-0000-0000-000000000061")!,
            kjvaOrdinal: JSwordKJVAVersification.progressOrdinalRange.upperBound + 1,
            v11n: "KJV"
        )

        XCTAssertThrowsError(
            try RemoteSyncBookmarkRestoreService(bookNameResolver: nil).replaceLocalBookmarks(
                from: RemoteSyncAndroidBookmarkSnapshot(
                    labels: [],
                    bibleBookmarks: [row],
                    genericBookmarks: [],
                    studyPadEntries: []
                ),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncBookmarkRestoreError,
                .invalidColumnValue(
                    table: "BibleBookmark",
                    column: "kjvOrdinalStart/kjvOrdinalEnd"
                )
            )
        }
    }

    /**
     Verifies quarantined progress rows are absent from export but retain delete baselines.

     The legacy row names a module source but has no trust metadata, so its candidate ordinal is not
     known to be KJVA. Snapshot projection must omit it, mark its Android key suppressed, and leave
     an existing fingerprint untouched during baseline refresh so omission cannot generate a later
     remote DELETE.

     Failure means quarantine itself can delete a remote memorization row.
     */
    func testProgressSnapshotSuppressesQuarantineWithoutDeletingBaseline() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let rowID = UUID(uuidString: "a0000000-0000-0000-0000-000000000071")!
        settingsStore.setString(
            MemorizationProgressStore.settingsKey,
            value: """
            {
              "memorizedVerses": [
                {"id": "\(rowID.uuidString)", "bookInitials": "UNKNOWN", "kjvOrdinal": 15, "memorizedAt": 100}
              ],
              "targetRows": []
            }
            """
        )
        let entityID = RemoteSyncSQLiteValue.blob(RemoteSyncProgressSnapshotService.uuidBlob(rowID))
        let entityID2 = RemoteSyncSQLiteValue.text("")
        let logStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let key = logStore.key(
            for: .progress,
            tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
            entityID1: entityID,
            entityID2: entityID2
        )
        logStore.addEntry(
            RemoteSyncLogEntry(
                tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                entityID1: entityID,
                entityID2: entityID2,
                type: .upsert,
                lastUpdated: 100,
                sourceDevice: "android"
            ),
            for: .progress
        )
        let baselineStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        baselineStore.setFingerprint(
            "progress-baseline",
            for: .progress,
            tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
            entityID1: entityID,
            entityID2: entityID2
        )

        let persisted = MemorizationProgressStore(settingsStore: settingsStore).persistenceSnapshot()
        XCTAssertEqual(persisted.memorizedVerses.count, 1)
        XCTAssertEqual(persisted.memorizedVerses.first?.id, rowID)
        XCTAssertFalse(persisted.memorizedVerses.first?.hasTrustedPersistedOrdinals == true)

        let snapshotService = RemoteSyncProgressSnapshotService()
        let snapshot = snapshotService.snapshotCurrentState(settingsStore: settingsStore)
        XCTAssertTrue(snapshot.memorizedVerseRowsByKey.isEmpty)
        XCTAssertEqual(snapshot.suppressedKeys, [key])
        XCTAssertTrue(snapshot.containsRow(for: key))

        snapshotService.refreshBaselineFingerprints(settingsStore: settingsStore)
        XCTAssertEqual(
            baselineStore.fingerprint(
                for: .progress,
                tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                entityID1: entityID,
                entityID2: entityID2
            ),
            "progress-baseline"
        )
    }

    /**
     Builds one pending legacy bookmark whose stored KJVA fields still contain untrusted numbers.

     - Parameters:
       - id: Stable bookmark identifier.
       - moduleInitials: Exact legacy source module initials.
       - sourceStart: Legacy source start ordinal.
       - sourceEnd: Legacy source end ordinal.
       - storedKJVAStart: Untrusted value currently in the KJVA start column.
       - storedKJVAEnd: Untrusted value currently in the KJVA end column.
     - Returns: A bookmark awaiting exact-source migration.
     - Side effects: none.
     - Failure modes: This fixture helper cannot fail.
     */
    private func makeLegacyBookmark(
        id: UUID,
        moduleInitials: String,
        sourceStart: Int,
        sourceEnd: Int,
        storedKJVAStart: Int,
        storedKJVAEnd: Int
    ) -> BibleBookmark {
        BibleBookmark(
            id: id,
            kjvOrdinalStart: storedKJVAStart,
            kjvOrdinalEnd: storedKJVAEnd,
            ordinalStart: sourceStart,
            ordinalEnd: sourceEnd,
            v11n: "KJVA",
            bookInitials: moduleInitials,
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.legacyMetadata(
                sourceBookInitials: moduleInitials,
                sourceOrdinalStart: sourceStart,
                sourceOrdinalEnd: sourceEnd
            )
        )
    }

    /**
     Builds one label-free staged Android bookmark for restore-boundary tests.

     - Parameters:
       - id: Stable Android bookmark identifier.
       - kjvaOrdinal: Candidate KJVA start and end ordinal.
       - v11n: Raw Android source versification name.
     - Returns: Android-shaped bookmark with matching source endpoints.
     - Side effects: none.
     - Failure modes: This fixture helper cannot fail.
     */
    private func makeAndroidBookmark(
        id: UUID,
        kjvaOrdinal: Int,
        v11n: String
    ) -> RemoteSyncAndroidBibleBookmark {
        RemoteSyncAndroidBibleBookmark(
            id: id,
            kjvOrdinalStart: kjvaOrdinal,
            kjvOrdinalEnd: kjvaOrdinal,
            ordinalStart: 1,
            ordinalEnd: 1,
            v11n: v11n,
            playbackSettingsJSON: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            book: "KJV",
            startOffset: nil,
            endOffset: nil,
            primaryLabelID: nil,
            notes: nil,
            lastUpdatedOn: Date(timeIntervalSince1970: 2),
            wholeVerse: true,
            type: nil,
            customIcon: nil,
            editAction: nil,
            labelLinks: []
        )
    }
}
