import XCTest
@testable import BibleCore

/**
 BibleCore memorization and reading-progress persistence coverage.

 These tests validate native store behavior without reader controller or web bridge integration, so
 the lowest owning target is `BibleCoreTests`.
 */
final class ProgressStoreTests: XCTestCase {
    /**
     Verifies memorization targets follow Android's independent-row range semantics.

     Android skips only exact duplicate `MemorizationTarget` rows in
     `ProgressControl.addMemorizationTargetIfNeeded`; nested ranges remain independent targets and
     are later split by overlapping removals. The test persists through `SettingsStore` so it
     covers both mutation behavior and JSON reload compatibility for the native store.

     Failure means iOS has reintroduced collapsed or containment-based target behavior that changes
     Android backup rows, target totals, and removal deltas.
     */
    func testMemorizationProgressStorePersistsRangesAndSplitsTargets() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = MemorizationProgressStore(settingsStore: settingsStore)

        try store.addMemorizationTarget(verifiedKJVARange(start: 4, end: 8))
        let rawAfterInitialTarget = try XCTUnwrap(settingsStore.getString(MemorizationProgressStore.settingsKey))
        try store.addMemorizationTargetIfNeeded(verifiedKJVARange(start: 5, end: 7))
        let rawAfterNestedTarget = try XCTUnwrap(settingsStore.getString(MemorizationProgressStore.settingsKey))
        XCTAssertNotEqual(rawAfterNestedTarget, rawAfterInitialTarget)
        XCTAssertEqual(Set(store.snapshot().targetRanges), Set([
            MemorizationProgressRange(bookInitials: "", startOrdinal: 4, endOrdinal: 8),
            MemorizationProgressRange(bookInitials: "", startOrdinal: 5, endOrdinal: 7),
        ]))

        try store.addMemorizationTargetIfNeeded(verifiedKJVARange(start: 5, end: 7))
        XCTAssertEqual(settingsStore.getString(MemorizationProgressStore.settingsKey), rawAfterNestedTarget)

        try store.removeMemorizationTarget(bookInitials: "KJV", startOrdinal: 5, endOrdinal: 7)
        try store.markAsMemorized(verifiedKJVARange(start: 6, end: 8))
        try store.unmarkMemorized(bookInitials: "KJV", startOrdinal: 7, endOrdinal: 7)

        let reloadedStore = MemorizationProgressStore(settingsStore: settingsStore)
        XCTAssertEqual(
            reloadedStore.targetOrdinals(bookInitials: "KJV", startOrdinal: 4, endOrdinal: 8),
            [4, 8]
        )
        XCTAssertEqual(
            reloadedStore.memorizedOrdinals(bookInitials: "KJV", startOrdinal: 4, endOrdinal: 8),
            [6, 8]
        )
        XCTAssertEqual(
            reloadedStore.targetOrdinals(bookInitials: "ESV", startOrdinal: 4, endOrdinal: 8),
            [4, 8]
        )

        let retainedRows = reloadedStore.persistenceSnapshot().targetRows.sorted {
            $0.startOrdinal < $1.startOrdinal
        }
        XCTAssertEqual(retainedRows.map(\.startOrdinal), [4, 8])
        XCTAssertTrue(retainedRows.allSatisfy(\.hasTrustedPersistedOrdinals))
        XCTAssertEqual(retainedRows.map(\.ordinalTrust.sourceOrdinalStart), [4, 8])
        XCTAssertEqual(retainedRows.map(\.ordinalTrust.sourceOrdinalEnd), [4, 8])
    }

    func testReadingProgressStorePersistsChapterHistoryAndClearsActiveCycle() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = ReadingProgressStore(settingsStore: settingsStore)
        let identity = try XCTUnwrap(
            ReadingProgressKJVAIdentity(androidKJVBookOrdinal: 3, chapter: 2)
        )

        XCTAssertEqual(
            try store.recordChapterRead(
                bookInitials: "KJV",
                identity: identity,
                source: .autoScroll,
                readAt: 100
            ),
            1
        )
        XCTAssertEqual(
            try store.recordChapterRead(
                bookInitials: "KJV",
                identity: identity,
                source: ReadingProgressSource(bridgeValue: "AUTO_TTS"),
                readAt: 200
            ),
            2
        )
        XCTAssertEqual(ReadingProgressSource(bridgeValue: "unknown"), .manual)

        let reloadedStore = ReadingProgressStore(settingsStore: settingsStore)
        XCTAssertEqual(reloadedStore.chapterReadCount(kjvBookOrdinal: 3, chapter: 2), 2)
        XCTAssertEqual(
            reloadedStore.snapshot().history.map(\.source),
            [.autoScroll, .autoTts]
        )
        XCTAssertEqual(reloadedStore.snapshot().history.map(\.startOrdinal), [0, 0])
        let summary = reloadedStore.readingSummary(recentLimit: 1)
        XCTAssertEqual(summary.cycle, 1)
        XCTAssertEqual(summary.distinctChapterCount, 1)
        XCTAssertEqual(summary.readingCount, 2)
        XCTAssertEqual(summary.recentRows.map(\.source), [.autoTts])
        XCTAssertTrue(reloadedStore.readingSummary(recentLimit: 0).recentRows.isEmpty)

        XCTAssertEqual(try reloadedStore.clearChapterReadStatus(kjvBookOrdinal: 3, chapter: 2), 0)
        XCTAssertTrue(ReadingProgressStore(settingsStore: settingsStore).snapshot().history.isEmpty)
    }

    func testReadingProgressStorePersistsSettingsBundleAndPreservesNativeFields() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = ReadingProgressStore(settingsStore: settingsStore)
        var nativeSettings = ReadingProgressSettingsSnapshot(autoTrackReading: true, activeCycle: 4)
        nativeSettings.memorizeWordVisibility = "hidden"
        try store.saveSettings(nativeSettings)

        XCTAssertTrue(try store.applySettingsBundle(json: """
        {
          "autoMarkMemorized": false,
          "memorizeTypeFullWords": true,
          "memorizeWordVisibility": "dim",
          "memorizeErrorHeatmap": false,
          "memorizeScrambleHideUsed": true,
          "memorizeIncludeReference": false
        }
        """))

        let updated = store.snapshot().settings
        XCTAssertEqual(updated.autoTrackReading, true)
        XCTAssertEqual(updated.activeCycle, 4)
        XCTAssertEqual(updated.autoMarkMemorized, false)
        XCTAssertEqual(updated.memorizeTypeFullWords, true)
        XCTAssertEqual(updated.memorizeWordVisibility, "dim")
        XCTAssertEqual(updated.memorizeErrorHeatmap, false)
        XCTAssertEqual(updated.memorizeScrambleHideUsed, true)
        XCTAssertEqual(updated.memorizeIncludeReference, false)

        XCTAssertFalse(try store.applySettingsBundle(json: #"{}"#))
        XCTAssertFalse(try store.applySettingsBundle(json: #"{"autoMarkMemorized":true}"#))
        XCTAssertFalse(try store.applySettingsBundle(json: #"{"memorizeWordVisibility":"opaque"}"#))
        XCTAssertFalse(try store.applySettingsBundle(json: #"{"autoMarkMemorized":true,"unexpected":true}"#))
        XCTAssertFalse(try store.applySettingsBundle(json: #"{"autoMarkMemorized":null}"#))
        XCTAssertEqual(store.snapshot().settings, updated)
    }

    /**
     Verifies malformed reading-progress persistence cannot be reinterpreted as an empty history.

     Failure means a local Read event can overwrite corrupt but recoverable bytes with a fresh row,
     hiding integrity damage and losing the original persistence evidence.
     */
    func testReadingProgressMutationRejectsCorruptionWithoutOverwrite() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let malformed = #"{"history":["#
        settingsStore.setString(ReadingProgressStore.settingsKey, value: malformed)
        let store = ReadingProgressStore(settingsStore: settingsStore)
        let identity = try XCTUnwrap(
            ReadingProgressKJVAIdentity(androidKJVBookOrdinal: 2, chapter: 1)
        )

        XCTAssertThrowsError(
            try store.recordChapterRead(
                bookInitials: "KJV",
                identity: identity,
                source: .manual,
                readAt: 1_700_000_000_001
            )
        ) { error in
            XCTAssertEqual(
                error as? ProgressPersistenceSnapshotError,
                .invalidReadingProgress
            )
        }
        XCTAssertEqual(
            settingsStore.getString(ReadingProgressStore.settingsKey),
            malformed
        )
    }

    /**
     Verifies malformed memorization persistence aborts a typed mutation before any replacement.

     Failure means marking one verse can erase corrupt target and memorized rows by treating the
     undecodable snapshot as empty.
     */
    func testMemorizationMutationRejectsCorruptionWithoutOverwrite() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let malformed = #"{"memorizedVerses":["#
        settingsStore.setString(MemorizationProgressStore.settingsKey, value: malformed)
        let store = MemorizationProgressStore(settingsStore: settingsStore)

        XCTAssertThrowsError(
            try store.markAsMemorized(verifiedKJVARange(start: 4, end: 4))
        ) { error in
            XCTAssertEqual(
                error as? ProgressPersistenceSnapshotError,
                .invalidMemorizationProgress
            )
        }
        XCTAssertEqual(
            settingsStore.getString(MemorizationProgressStore.settingsKey),
            malformed
        )
    }

    /**
     Verifies a corrupt mutation journal rolls back the progress value staged in the same batch.

     Failure means local history can commit without its Android `LogEntry`, making the mutation
     invisible to sparse upload and conflict resolution.
     */
    func testReadingProgressJournalFailureIsObservableAndAtomic() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let malformedMarkerKey = "remote_sync.pending_mutations.progress.corrupt"
        settingsStore.setString(malformedMarkerKey, value: "{")
        let store = ReadingProgressStore(settingsStore: settingsStore)
        let identity = try XCTUnwrap(
            ReadingProgressKJVAIdentity(androidKJVBookOrdinal: 2, chapter: 1)
        )

        XCTAssertThrowsError(
            try store.recordChapterRead(
                bookInitials: "KJV",
                identity: identity,
                source: .manual,
                readAt: 1_700_000_000_002
            )
        ) { error in
            XCTAssertEqual(
                error as? RemoteSyncMutationJournalError,
                .malformedPendingMutation(storageKey: malformedMarkerKey)
            )
        }
        XCTAssertNil(settingsStore.getString(ReadingProgressStore.settingsKey))
        XCTAssertEqual(settingsStore.getString(malformedMarkerKey), "{")
    }

    /**
     Verifies origin-main KJVA rows keep stable identity while module-scoped rows stay quarantined.

     Android sync keys `MemorizedVerse` mutations by row UUID, not by KJVA ordinal alone. Existing
     iOS JSON did not have an `id` field, so those rows need deterministic identities rather than a
     new random UUID each time they are decoded. The empty-initial shape is the prior store's known
     global KJVA contract and remains visible; the named-module row still awaits exact migration.

     Failure means an upgrade can hide valid progress, emit unstable Android `LogEntry` keys, or
     trust module-local ordinals before their source domain has been established.
     */
    func testMemorizedVerseProgressPreservesAndroidIdentityAndStabilizesLegacyRows() throws {
        let importedID = UUID(uuidString: "15000000-0000-0000-0000-000000000901")!
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString(
            MemorizationProgressStore.settingsKey,
            value: """
            {
              "memorizedVerses": [
                {
                  "id": "\(importedID.uuidString)",
                  "bookInitials": "",
                  "kjvOrdinal": 15,
                  "memorizedAt": 1700000100
                },
                {
                  "bookInitials": "ESV",
                  "kjvOrdinal": 16,
                  "memorizedAt": 1700000200
                }
              ],
              "targetRows": []
            }
            """
        )

        let firstStore = MemorizationProgressStore(settingsStore: settingsStore)
        let secondStore = MemorizationProgressStore(settingsStore: settingsStore)
        let firstSnapshot = firstStore.persistenceSnapshot()
        let secondSnapshot = secondStore.persistenceSnapshot()

        XCTAssertEqual(firstSnapshot.memorizedVerses[0].id, importedID)
        XCTAssertEqual(firstSnapshot.memorizedVerses[1].id, secondSnapshot.memorizedVerses[1].id)
        XCTAssertEqual(Set(firstSnapshot.memorizedVerses.map(\.kjvOrdinal)), [15, 16])
        XCTAssertEqual(
            Set(firstSnapshot.memorizedVerses.map(\.ordinalTrust.state)),
            [.verifiedMappingV1, .legacyPendingModule]
        )
        XCTAssertEqual(firstStore.snapshot().memorizedVerses.map(\.id), [importedID])
    }

    /**
     Creates a deterministic KJVA-identity range through the same typed boundary production uses.

     - Parameters:
       - start: Inclusive source and KJVA start ordinal.
       - end: Inclusive source and KJVA end ordinal.
     - Returns: Verified mapping contract for one test mutation.
     - Side effects: Reads bundled canon and mapping fixtures only.
     - Failure modes: Throws an XCTest unwrap failure for invalid fixture ordinals.
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
}
