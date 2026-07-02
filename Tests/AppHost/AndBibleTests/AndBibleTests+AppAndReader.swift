import SwiftData
import SQLite3
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit
#if os(iOS)
import UIKit
#endif

private let memorizeParitySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension AndBibleTests {
    #if os(iOS)
    /**
     Keeps app-host coverage for the scene delegate bootstrap that package tests cannot exercise.

     `AndBibleApplicationDelegate.sceneConfiguration` is the remaining `+AppAndReader` test that
     depends on the app target rather than BibleUI package logic. A failure here means app launch
     would stop installing `AndBibleWindowSceneDelegate`, breaking the iPadOS windowing-control
     policy wiring even though the package-level policy tests still pass.
     */
    func testApplicationDelegateSceneConfigurationUsesWindowSceneDelegate() {
        let configuration = AndBibleApplicationDelegate.sceneConfiguration(
            sessionRole: UISceneSession.Role.windowApplication
        )

        XCTAssertEqual(
            ObjectIdentifier(configuration.delegateClass!),
            ObjectIdentifier(AndBibleWindowSceneDelegate.self)
        )
        XCTAssertNil(configuration.name)
    }
    #endif

    /**
     Verifies local memorization progress can write Android's KJVA-global rows directly.

     Android stores memorized verses and memorization targets as KJV-normalized ordinals without a
     module identity. This app-host regression test keeps that storage contract visible to the
     locally runnable unit-test scheme: inserts must accept an empty `bookInitials` global range,
     return Android-style delta arrays, and remain readable from any module initials.

     Failure means new iOS memorization writes still depend on an iOS-only module-specific storage
     key instead of the Android progress domain used by backup/restore and the shared Vue client.
     */
    func testMemorizationProgressStoreWritesKJVGlobalRangesAndDeltas() throws {
        let settingsStore = try makeMemorizeParitySettingsStore()
        let store = MemorizationProgressStore(settingsStore: settingsStore)

        let addDelta = store.addMemorizationTarget(bookInitials: "", startOrdinal: 4, endOrdinal: 5)
        XCTAssertEqual(addDelta.addedTargets, [4, 5])
        XCTAssertEqual(addDelta.removedTargets, [])
        XCTAssertEqual(store.targetOrdinals(bookInitials: "KJV", startOrdinal: 4, endOrdinal: 5), [4, 5])
        XCTAssertEqual(store.targetOrdinals(bookInitials: "FinRK", startOrdinal: 4, endOrdinal: 5), [4, 5])

        let noOpDelta = store.addMemorizationTargetIfNeeded(bookInitials: "", startOrdinal: 4, endOrdinal: 5)
        XCTAssertTrue(noOpDelta.isEmpty)

        let markDelta = store.markAsMemorized(bookInitials: "", startOrdinal: 4, endOrdinal: 4)
        XCTAssertEqual(markDelta.addedMemorized, [4])
        XCTAssertEqual(store.memorizedOrdinals(bookInitials: "ESV", startOrdinal: 4, endOrdinal: 4), [4])

        let removeDelta = store.removeMemorizationTarget(bookInitials: "", startOrdinal: 5, endOrdinal: 5)
        XCTAssertEqual(removeDelta.removedTargets, [5])
        XCTAssertEqual(store.targetOrdinals(bookInitials: "KJV", startOrdinal: 4, endOrdinal: 5), [4])

        let unmarkDelta = store.unmarkMemorized(bookInitials: "", startOrdinal: 4, endOrdinal: 4)
        XCTAssertEqual(unmarkDelta.removedMemorized, [4])
        XCTAssertEqual(store.memorizedOrdinals(bookInitials: "KJV", startOrdinal: 4, endOrdinal: 4), [])
    }

    /**
     Verifies the memorization store preserves Android's row-level progress semantics.

     Android stores `MemorizedVerse` rows per KJVA ordinal with `memorizedAt`, and
     `MemorizationTarget` rows as independently created ranges. Explicit duplicate targets are not
     collapsed, so target progress totals count each row even when their ordinal ranges overlap.

     Failure means iOS is still normalizing memorization into an artificial range union and cannot
     render Android's memorize list, timestamps, or target totals with parity.
     */
    func testMemorizationProgressStoreUsesAndroidRowsForTimestampsAndDuplicateTargets() throws {
        let settingsStore = try makeMemorizeParitySettingsStore()
        var now: Int64 = 1_700_000_100_000
        let store = MemorizationProgressStore(
            settingsStore: settingsStore,
            currentTimeMilliseconds: { now }
        )

        XCTAssertEqual(
            store.markAsMemorized(bookInitials: "", startOrdinal: 4, endOrdinal: 6).addedMemorized,
            [4, 5, 6]
        )
        now = 1_700_000_200_000
        XCTAssertEqual(
            store.unmarkMemorized(bookInitials: "", startOrdinal: 5, endOrdinal: 5).removedMemorized,
            [5]
        )
        XCTAssertEqual(
            store.markAsMemorized(bookInitials: "", startOrdinal: 5, endOrdinal: 5).addedMemorized,
            [5]
        )

        XCTAssertEqual(
            store.memorizedVerseRangesWithTimestamps(),
            [
                MemorizedVerseRangeWithTimestamp(
                    range: MemorizationProgressRange(bookInitials: "", startOrdinal: 4, endOrdinal: 6),
                    latestMemorizedAt: 1_700_000_200_000
                ),
            ]
        )

        now = 1_700_000_300_000
        XCTAssertEqual(
            store.addMemorizationTarget(bookInitials: "", startOrdinal: 10, endOrdinal: 11).addedTargets,
            [10, 11]
        )
        now = 1_700_000_400_000
        XCTAssertEqual(
            store.addMemorizationTarget(bookInitials: "", startOrdinal: 10, endOrdinal: 11).addedTargets,
            [10, 11]
        )

        let targets = store.memorizationTargets()
        XCTAssertEqual(targets.map(\.range), [
            MemorizationProgressRange(bookInitials: "", startOrdinal: 10, endOrdinal: 11),
            MemorizationProgressRange(bookInitials: "", startOrdinal: 10, endOrdinal: 11),
        ])
        XCTAssertEqual(targets.map(\.createdAt), [1_700_000_400_000, 1_700_000_300_000])
        XCTAssertEqual(store.memorizationTargetProgress(), MemorizationTargetProgress(memorized: 0, total: 4))
    }

    /**
     Verifies pre-row memorization JSON is migrated into Android-compatible rows.

     Earlier iOS slices persisted memorized progress as normalized ranges. The Android parity model
     now needs per-verse memorized rows and per-target range rows, but users with existing local
     state must keep their progress when the app decodes the old JSON shape.

     Failure means the parity migration would either drop existing local memorization progress or
     leave it in a shape the native Android-style progress tab cannot display.
     */
    func testMemorizationProgressStoreMigratesLegacyRangeSnapshotToAndroidRows() throws {
        let settingsStore = try makeMemorizeParitySettingsStore()
        settingsStore.setString(
            MemorizationProgressStore.settingsKey,
            value: """
            {
              "memorizedRanges": [
                {"bookInitials":"","startOrdinal":4,"endOrdinal":5}
              ],
              "targetRanges": [
                {"bookInitials":"","startOrdinal":8,"endOrdinal":9}
              ]
            }
            """
        )

        let store = MemorizationProgressStore(settingsStore: settingsStore)

        XCTAssertEqual(
            store.memorizedVerseRangesWithTimestamps(),
            [
                MemorizedVerseRangeWithTimestamp(
                    range: MemorizationProgressRange(bookInitials: "", startOrdinal: 4, endOrdinal: 5),
                    latestMemorizedAt: 0
                ),
            ]
        )
        XCTAssertEqual(store.memorizationTargets().map(\.createdAt), [0])
        XCTAssertEqual(store.targetOrdinals(bookInitials: "KJV", startOrdinal: 8, endOrdinal: 9), [8, 9])
    }

    /**
     Verifies Android progress restore preserves memorization row timestamps.

     Android stores memorized verses with `memorizedAt` and target rows with `createdAt`. The native
     Reading Progress Memorization list uses those values for recency ordering, duplicate target
     rows, and relative timestamps. Restore must therefore import Android row data directly instead
     of collapsing it through iOS range-only compatibility projections.

     Failure means Android backup restore can show the right ordinals while losing the timeline and
     independent target rows needed for full Memorize parity.
     */
    func testAndroidProgressMapperRestoresMemorizationTimestampsAndTargetRows() throws {
        let settingsStore = try makeMemorizeParitySettingsStore()
        let databaseURL = try makeMemorizeParityAndroidProgressDatabase(
            memorizedVerses: [
                (ordinal: 4, memorizedAt: 1_700_000_100_000),
                (ordinal: 5, memorizedAt: 1_700_000_200_000),
            ],
            memorizationTargets: [
                (startOrdinal: 10, endOrdinal: 11, createdAt: 1_700_000_300_000),
                (startOrdinal: 10, endOrdinal: 11, createdAt: 1_700_000_400_000),
            ]
        )

        let report = try AndroidDatabaseBackupProgressMapper.apply(
            from: databaseURL,
            mode: .restore,
            settingsStore: settingsStore
        )
        let store = MemorizationProgressStore(settingsStore: settingsStore)

        XCTAssertEqual(report.memorizedVerseCount, 2)
        XCTAssertEqual(report.targetCount, 2)
        XCTAssertEqual(
            store.memorizedVerseRangesWithTimestamps(),
            [
                MemorizedVerseRangeWithTimestamp(
                    range: MemorizationProgressRange(bookInitials: "", startOrdinal: 4, endOrdinal: 5),
                    latestMemorizedAt: 1_700_000_200_000
                ),
            ]
        )
        XCTAssertEqual(
            store.memorizationTargets().map(\.createdAt),
            [1_700_000_400_000, 1_700_000_300_000]
        )
        XCTAssertEqual(store.memorizationTargetProgress(), MemorizationTargetProgress(memorized: 0, total: 4))
    }

    /**
     Verifies Android progress export writes memorization timestamps from Android-shaped rows.

     iOS persists the same row model Android uses for Memorize progress. Exporting `progress.sqlite3`
     must copy `memorizedAt` and `createdAt` into Android's tables rather than deriving only ordinal
     ranges and filling timestamps with placeholders.

     Failure means backup round trips keep visible ordinals but destroy Android's recency ordering
     and target-row history.
     */
    func testAndroidProgressMapperExportsMemorizationTimestampsAndTargetRows() throws {
        let settingsStore = try makeMemorizeParitySettingsStore()
        settingsStore.setString(
            MemorizationProgressStore.settingsKey,
            value: """
            {
              "memorizedVerses": [
                {"bookInitials":"","kjvOrdinal":4,"memorizedAt":1700000100000},
                {"bookInitials":"","kjvOrdinal":5,"memorizedAt":1700000200000}
              ],
              "targetRows": [
                {
                  "id":"16000000-0000-0000-0000-000000000101",
                  "bookInitials":"",
                  "startOrdinal":10,
                  "endOrdinal":11,
                  "createdAt":1700000300000
                },
                {
                  "id":"16000000-0000-0000-0000-000000000102",
                  "bookInitials":"",
                  "startOrdinal":10,
                  "endOrdinal":11,
                  "createdAt":1700000400000
                }
              ]
            }
            """
        )
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memorize-parity-export-\(UUID().uuidString).sqlite3")

        let report = try AndroidDatabaseBackupProgressMapper.writeDatabase(
            at: databaseURL,
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.memorizedVerseCount, 2)
        XCTAssertEqual(report.targetCount, 2)
        XCTAssertEqual(
            try readMemorizeParitySQLiteInt64(
                "SELECT memorizedAt FROM MemorizedVerse WHERE kjvOrdinal = 4;",
                at: databaseURL
            ),
            1_700_000_100_000
        )
        XCTAssertEqual(
            try readMemorizeParitySQLiteInt64(
                "SELECT memorizedAt FROM MemorizedVerse WHERE kjvOrdinal = 5;",
                at: databaseURL
            ),
            1_700_000_200_000
        )
        XCTAssertEqual(
            try readMemorizeParitySQLiteInt64(
                "SELECT COUNT(*) FROM MemorizationTarget WHERE kjvOrdinalStart = 10 AND kjvOrdinalEnd = 11;",
                at: databaseURL
            ),
            2
        )
        XCTAssertEqual(
            try readMemorizeParitySQLiteInt64(
                "SELECT MIN(createdAt) FROM MemorizationTarget WHERE kjvOrdinalStart = 10 AND kjvOrdinalEnd = 11;",
                at: databaseURL
            ),
            1_700_000_300_000
        )
        XCTAssertEqual(
            try readMemorizeParitySQLiteInt64(
                "SELECT MAX(createdAt) FROM MemorizationTarget WHERE kjvOrdinalStart = 10 AND kjvOrdinalEnd = 11;",
                at: databaseURL
            ),
            1_700_000_400_000
        )
    }

    /**
     Verifies native Memorization progress presentation is built from Android KJVA rows.

     Android's Reading Progress Memorization tab renders a row-based list plus a KJVA overview:
     memorized passages sort by latest `memorizedAt`, incomplete targets keep row identity and
     target progress, book/chapter grids cover the full `SystemKJVA` scripture set, and calendar
     counts are bucketed by local day.

     Failure means the native iOS tab can regress back to an iOS-only summary or a 66-book module
     catalog instead of Android's full Memorize progress surface.
     */
    func testMemorizationProgressPresentationBuildsAndroidListOverviewAndCalendarFromKJVARows() throws {
        let gen1 = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 1))
        let gen2 = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 2))
        let gen3 = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 3))
        let exod1 = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Exod", chapter: 1, verse: 1))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let genDay: Int64 = 1_700_000_100_000
        let exodDay: Int64 = 1_700_100_100_000

        let presentation = MemorizationProgressPresentation(
            snapshot: MemorizationProgressSnapshot(
                memorizedVerses: [
                    .init(kjvOrdinal: gen1, memorizedAt: genDay),
                    .init(kjvOrdinal: gen2, memorizedAt: genDay + 1_000),
                    .init(kjvOrdinal: exod1, memorizedAt: exodDay),
                ],
                targetRows: [
                    MemorizationTargetRow(
                        id: UUID(uuidString: "16000000-0000-0000-0000-000000000201")!,
                        startOrdinal: gen1,
                        endOrdinal: gen3,
                        createdAt: genDay + 2_000
                    ),
                    MemorizationTargetRow(
                        id: UUID(uuidString: "16000000-0000-0000-0000-000000000202")!,
                        startOrdinal: exod1,
                        endOrdinal: exod1,
                        createdAt: exodDay + 2_000
                    ),
                ]
            ),
            nowMilliseconds: exodDay + 86_400_000,
            calendar: calendar
        )

        XCTAssertEqual(presentation.summary.totalMemorized, 3)
        XCTAssertEqual(presentation.summary.targetMemorized, 3)
        XCTAssertEqual(presentation.summary.targetTotal, 4)
        XCTAssertEqual(presentation.memorizedPassages.map(\.title), ["Exodus 1:1", "Genesis 1:1-2"])
        XCTAssertEqual(presentation.incompleteTargets.map(\.title), ["Genesis 1:1-3"])
        XCTAssertEqual(presentation.incompleteTargets.first?.memorizedCount, 2)
        XCTAssertEqual(presentation.incompleteTargets.first?.verseCount, 3)
        XCTAssertEqual(presentation.books.count, JSwordKJVAVersification.canonicalBookCount)

        let tobit = try XCTUnwrap(presentation.books.first { $0.osisId == "Tob" })
        XCTAssertEqual(tobit.title, "Tobit")
        XCTAssertEqual(tobit.shortTitle, "Tob")

        let revelation = try XCTUnwrap(presentation.books.first { $0.osisId == "Rev" })
        XCTAssertEqual(revelation.title, "Revelation of John")
        XCTAssertEqual(revelation.shortTitle, "Rev")

        let genesis = try XCTUnwrap(presentation.books.first { $0.osisId == "Gen" })
        XCTAssertTrue(genesis.hasTarget)
        XCTAssertEqual(genesis.memorizedVerseCount, 2)
        let genesisOrdinalSpan = try XCTUnwrap(JSwordKJVAVersification.verseOrdinalRange(osisId: "Gen"))
        XCTAssertEqual(genesis.totalVerseCount, genesisOrdinalSpan.count)
        XCTAssertGreaterThan(
            genesis.totalVerseCount,
            try XCTUnwrap(JSwordKJVAVersification.bookVerseCount(osisId: "Gen"))
        )

        let genesisDetail = try XCTUnwrap(presentation.chapterDetail(osisId: "Gen"))
        XCTAssertEqual(genesisDetail.title, "Genesis")
        XCTAssertEqual(genesisDetail.chapters.first?.chapter, 1)
        XCTAssertEqual(genesisDetail.chapters.first?.memorizedVerseCount, 2)
        XCTAssertTrue(genesisDetail.chapters.first?.hasTarget == true)

        XCTAssertEqual(
            presentation.calendarCountsByDayStartMilliseconds[
                memorizeParityLocalDayStartMilliseconds(genDay, calendar: calendar)
            ],
            2
        )
        XCTAssertEqual(
            presentation.calendarCountsByDayStartMilliseconds[
                memorizeParityLocalDayStartMilliseconds(exodDay, calendar: calendar)
            ],
            1
        )
    }

    /**
     Guards native Memorization progress UI affordances against preserving iOS-only shortcuts.

     Android's `ReadingProgressActivity` displays counted pagination labels, target progress as a
     percentage plus ratio, destructive confirmations with the affected passage/goal name, and
     tappable chapter detail cells that return to the selected Bible chapter. The SwiftUI callbacks
     are private view composition, so this app-host guard reads the source boundary directly.

     Failure means the data model may still be Android-shaped while the user-visible progress UI
     has drifted away from Android behavior.
     */
    func testMemorizationProgressUISourceKeepsAndroidListAndOverviewContracts() throws {
        let progressSource = try memorizeParitySource(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/ReadingProgressViews.swift"
        )
        let sheetSource = try memorizeParitySource(
            at: "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderActiveSheetContent.swift"
        )

        XCTAssertTrue(progressSource.contains("let onOpenChapter: (String, Int) -> Void"))
        XCTAssertTrue(progressSource.contains("onOpenChapter: @escaping (String, Int) -> Void = { _, _ in }"))
        XCTAssertTrue(progressSource.contains("Button(showMoreTitle(remaining: presentation.memorizedPassages.count - memorizedPassagesShown))"))
        XCTAssertTrue(progressSource.contains("Button(showMoreTitle(remaining: presentation.incompleteTargets.count - targetsShown))"))
        XCTAssertTrue(progressSource.contains("formatter.unitsStyle = .short"))
        XCTAssertTrue(progressSource.contains("targetProgressLabel("))
        XCTAssertTrue(progressSource.contains("String(format: \"%.0f%% (%d/%d)\", percent, memorized, total)"))
        XCTAssertTrue(progressSource.contains("removeMemorizedPassageConfirmationTitle(passage.title)"))
        XCTAssertTrue(progressSource.contains("removeMemorizationTargetConfirmationTitle(item.title)"))
        XCTAssertTrue(progressSource.contains(".alert(item: $memorizationDeletionRequest)"))
        XCTAssertTrue(progressSource.contains(".default(Text(String(localized: \"ok\", defaultValue: \"OK\")))"))
        XCTAssertTrue(progressSource.contains(".cancel(Text(String(localized: \"cancel\", defaultValue: \"Cancel\")))"))
        XCTAssertFalse(progressSource.contains(".confirmationDialog("))
        XCTAssertTrue(progressSource.contains("onOpenChapter(detail.osisId, chapter.chapter)"))
        XCTAssertTrue(progressSource.contains("MemorizationSummaryView(summary: presentation.summary)"))
        XCTAssertTrue(progressSource.contains("MemorizationViewToggle(overviewActive: $memorizationOverviewActive)"))
        XCTAssertTrue(progressSource.contains("weight: overviewActive ? .bold : .regular"))
        XCTAssertTrue(progressSource.contains("weight: overviewActive ? .regular : .bold"))
        XCTAssertTrue(progressSource.contains(".buttonStyle(.borderless)"))
        XCTAssertTrue(progressSource.contains(".font(.system(size: 28, weight: .bold))"))
        XCTAssertTrue(progressSource.contains(".font(.system(size: 12))"))
        XCTAssertTrue(progressSource.contains(".frame(maxWidth: .infinity, alignment: .center)"))
        XCTAssertTrue(progressSource.contains("AndroidReadingProgressColor.targetDot"))
        XCTAssertTrue(progressSource.contains("AndroidReadingProgressColor.memorizationProgressColor"))
        XCTAssertTrue(progressSource.contains("AndroidReadingProgressColor.memorizationCalendarColor"))
        XCTAssertTrue(progressSource.contains("AndroidReadingProgressColor.memorizationTextColor"))
        XCTAssertTrue(progressSource.contains("Array(repeating: GridItem(.flexible(), spacing: 2), count: 6)"))
        XCTAssertTrue(progressSource.contains("min(max(detail.chapters.count, 5), 10)"))
        XCTAssertTrue(progressSource.contains(".font(.system(size: 11))"))
        XCTAssertTrue(progressSource.contains(".font(.system(size: 12))"))
        XCTAssertTrue(progressSource.contains("let calendarLevelColors: [Color]"))
        XCTAssertTrue(progressSource.contains("maxCount = max(counts.values.max() ?? 1, 1)"))
        XCTAssertTrue(progressSource.contains("ForEach(0..<53, id: \\.self)"))
        XCTAssertTrue(progressSource.contains("Text(\"M\")"))
        XCTAssertTrue(progressSource.contains("proxy.scrollTo(52, anchor: .trailing)"))
        XCTAssertFalse(progressSource.contains("Color.purple"))
        XCTAssertFalse(progressSource.contains("Color.green.opacity"))
        XCTAssertFalse(progressSource.contains("Color.yellow.opacity"))
        XCTAssertFalse(progressSource.contains("Color.orange.opacity"))
        XCTAssertFalse(progressSource.contains("Color.blue.opacity"))

        XCTAssertTrue(sheetSource.contains("onOpenChapter: { osisId, chapter in"))
        XCTAssertTrue(sheetSource.contains("_ = controller?.navigateToRef(\"\\(osisId).\\(chapter)\")"))
    }

    /**
     Verifies bridge memorization mutations use Android's storage and event contracts.

     The shared Vue client expects native `markAsMemorized`, `addMemorizationTarget`,
     `removeMemorizationTarget`, and `unmarkMemorized` calls to emit
     `update_memorization_data` deltas in the current rendered ordinal domain while persistence is
     normalized to Android KJVA ordinals. This test uses the no-module reader fallback so it runs in
     the app-host scheme without a SWORD fixture: rendered ordinals 1 and 2 are Genesis 1:1-2, while
     KJVA storage ordinals are 4 and 5.

     Failure means the bridge can persist native state without updating the open Vue document, or
     can continue writing iOS-only module-specific memorization rows.
     */
    func testMemorizationBridgePersistsKJVAGlobalRowsAndEmitsRenderedDeltas() throws {
        let (bridge, recordedScripts) = makeMemorizeParityRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = try makeMemorizeParitySettingsStore()
        let store = try XCTUnwrap(controller.memorizationProgressStore)

        XCTAssertEqual(
            bridge.dispatchMessage(method: "addMemorizationTarget", args: ["KJV", 1, 2]),
            .handled
        )
        XCTAssertEqual(
            store.snapshot().targetRanges,
            [MemorizationProgressRange(bookInitials: "", startOrdinal: 4, endOrdinal: 5)]
        )
        XCTAssertEqual(
            try memorizationParityPayloads(from: recordedScripts()).last?["addedTargets"] as? [Int],
            [1, 2]
        )

        XCTAssertEqual(
            bridge.dispatchMessage(method: "markAsMemorized", args: ["KJV", 1, 1]),
            .handled
        )
        XCTAssertEqual(
            store.snapshot().memorizedRanges,
            [MemorizationProgressRange(bookInitials: "", startOrdinal: 4, endOrdinal: 4)]
        )
        XCTAssertEqual(
            try memorizationParityPayloads(from: recordedScripts()).last?["addedMemorized"] as? [Int],
            [1]
        )

        XCTAssertEqual(
            bridge.dispatchMessage(method: "removeMemorizationTarget", args: ["KJV", 2, 2]),
            .handled
        )
        XCTAssertEqual(store.snapshot().targetRanges, [
            MemorizationProgressRange(bookInitials: "", startOrdinal: 4, endOrdinal: 4),
        ])
        XCTAssertEqual(
            try memorizationParityPayloads(from: recordedScripts()).last?["removedTargets"] as? [Int],
            [2]
        )

        XCTAssertEqual(
            bridge.dispatchMessage(method: "unmarkMemorized", args: ["KJV", 1, 1]),
            .handled
        )
        XCTAssertTrue(store.snapshot().memorizedRanges.isEmpty)
        XCTAssertEqual(
            try memorizationParityPayloads(from: recordedScripts()).last?["removedMemorized"] as? [Int],
            [1]
        )
    }

    /**
     Verifies cross-chapter bridge targets persist Android's complete KJVA ordinal span.

     Android's `ProgressControl.addMemorizationTarget` converts the selected `VerseRange` to KJVA,
     stores one inclusive `kjvOrdinalStart...kjvOrdinalEnd` row, and posts UI updates from that
     same range. The KJVA span between Genesis 1:31 and Genesis 2:2 includes a chapter-intro
     ordinal that is not a rendered verse; iOS must keep that storage ordinal while emitting only
     visible rendered ordinals back to Vue.

     Failure means iOS is preserving a visible-verse-only storage shape, which changes Android
     target totals, backup rows, duplicate-target detection, and removal behavior.
     */
    func testMemorizationBridgePersistsInclusiveKJVASpanAcrossChapterIntroOrdinals() throws {
        let (bridge, recordedScripts) = makeMemorizeParityRecordingBridge()
        let modulePath = try makeMemorizeParityTemporarySwordPath()
        defer { try? FileManager.default.removeItem(atPath: modulePath) }
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeMemorizeParitySettingsStore()
        let store = try XCTUnwrap(controller.memorizationProgressStore)
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let renderedStart = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31))
        let renderedMiddle = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 1))
        let renderedEnd = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 2))
        let kjvaStart = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 1, verse: 31))
        let kjvaEnd = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Gen", chapter: 2, verse: 2))

        XCTAssertGreaterThan(kjvaEnd - kjvaStart, 2)
        XCTAssertEqual(
            bridge.dispatchMessage(method: "addMemorizationTarget", args: ["KJV", renderedStart, renderedEnd]),
            .handled
        )

        XCTAssertEqual(
            store.snapshot().targetRanges,
            [MemorizationProgressRange(bookInitials: "", startOrdinal: kjvaStart, endOrdinal: kjvaEnd)]
        )
        XCTAssertEqual(
            try memorizationParityPayloads(from: recordedScripts()).last?["addedTargets"] as? [Int],
            [renderedStart, renderedMiddle, renderedEnd]
        )
    }

    /**
     Verifies normal Bible documents project global KJVA progress back to rendered ordinals.

     The bridge stores Android-compatible global KJVA rows, but Vue's Bible document payload still
     consumes ordinals in the currently rendered document domain. The no-module fallback makes the
     two domains intentionally different: rendered Genesis 1:1-2 are stored as KJVA ordinals 4-5.

     Failure means a reload can highlight the wrong visible verses even though the bridge mutation
     itself wrote Android-parity persistence rows.
     */
    func testBibleDocumentPayloadProjectsKJVAGlobalProgressToRenderedOrdinals() throws {
        let (bridge, recordedScripts) = makeMemorizeParityRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = try makeMemorizeParitySettingsStore()

        XCTAssertEqual(
            bridge.dispatchMessage(method: "addMemorizationTarget", args: ["KJV", 1, 2]),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(method: "markAsMemorized", args: ["KJV", 1, 1]),
            .handled
        )

        controller.bridgeDidSetClientReady(bridge)

        let document = try XCTUnwrap(
            memorizeParityBridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "bible")
        XCTAssertEqual(document["targetOrdinals"] as? [Int], [1, 2])
        XCTAssertEqual(document["memorizedOrdinals"] as? [Int], [1])
    }

    /**
     Verifies Memorize document payloads reuse saved page-manager state.

     Android stores the full Vue state blob on `PageManager.jsState` through `saveState`, then passes
     that same state into the next Memorize fake document. This regression keeps iOS from
     synthesizing a fresh blur-mode-only state that loses the user's selected memorization mode or
     sibling document state keys.

     Failure means opening Memorize on iOS resets the shared Vue document state instead of restoring
     the Android `pageManager.jsState` contract.
     */
    func testMemorizeDocumentUsesSavedPageManagerState() throws {
        let (bridge, recordedScripts) = makeMemorizeParityRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.settingsStore = try makeMemorizeParitySettingsStore()

        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.jsState = #"{"memorize":{"mode":"scramble","modeConfig":{"memorizeWordVisibility":"hidden","customLevel":7}},"otherDocument":{"selectedTab":"lexicon"}}"#
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)

        let baselineScriptCount = recordedScripts().count
        XCTAssertEqual(bridge.dispatchMessage(method: "memorize", args: ["KJV", 1, 1]), .handled)

        let memorizeScripts = Array(recordedScripts().dropFirst(baselineScriptCount))
        let document = try XCTUnwrap(
            memorizeParityBridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        let state = try XCTUnwrap(document["state"] as? [String: Any])
        let memorizeState = try XCTUnwrap(state["memorize"] as? [String: Any])
        XCTAssertEqual(memorizeState["mode"] as? String, "scramble")
        XCTAssertEqual(
            (memorizeState["modeConfig"] as? [String: Any])?["memorizeWordVisibility"] as? String,
            "hidden"
        )
        XCTAssertEqual(
            (state["otherDocument"] as? [String: Any])?["selectedTab"] as? String,
            "lexicon"
        )
    }

    /**
     Verifies Memorize document payloads preserve Android's cross-chapter `VerseRange`.

     Android creates the fake Memorize document from the selected JSword `VerseRange`, so a
     selection spanning Genesis 1:31 through Genesis 2:2 yields all three concrete verses, a
     cross-chapter title, and a cross-chapter OSIS range. This app-host test keeps that parity
     executable in the iOS simulator because package tests cannot currently compile on macOS.

     Failure means iOS is still using a same-chapter Memorize loader shape instead of the selected
     Android range contract.
     */
    func testMemorizeDocumentPreservesCrossChapterAndroidRange() throws {
        let (bridge, recordedScripts) = makeMemorizeParityRecordingBridge()
        let modulePath = try makeMemorizeParityTemporarySwordPath()
        defer { try? FileManager.default.removeItem(atPath: modulePath) }
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeMemorizeParitySettingsStore()
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31))
        let middleOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 1))
        let endOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 2))

        controller.bridgeDidSetClientReady(bridge)
        let baselineScriptCount = recordedScripts().count
        XCTAssertEqual(
            bridge.dispatchMessage(method: "memorize", args: ["KJV", startOrdinal, endOrdinal]),
            .handled
        )

        let memorizeScripts = Array(recordedScripts().dropFirst(baselineScriptCount))
        let document = try XCTUnwrap(
            memorizeParityBridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "memorize")
        XCTAssertEqual(document["title"] as? String, "Genesis 1:31-2:2")
        XCTAssertEqual(document["osisRef"] as? String, "Gen.1.31-Gen.2.2")
        XCTAssertEqual(document["startOrdinal"] as? Int, startOrdinal)
        XCTAssertEqual(document["endOrdinal"] as? Int, endOrdinal)
        XCTAssertEqual(document["targetOrdinals"] as? [Int], [startOrdinal, middleOrdinal, endOrdinal])

        let texts = try XCTUnwrap(document["texts"] as? [[String: String]])
        XCTAssertEqual(texts.map { $0["key"] }, ["Gen.1.31", "Gen.2.1", "Gen.2.2"])
        XCTAssertTrue(
            texts[0]["text"]?.contains("saw <H07200> every thing") == true,
            "Unexpected Gen.1.31 text: \(texts[0]["text"] ?? "<nil>")"
        )
        XCTAssertTrue(
            texts[1]["text"]?.contains("heavens <H08064> and the earth") == true,
            "Unexpected Gen.2.1 text: \(texts[1]["text"] ?? "<nil>")"
        )
        XCTAssertTrue(
            texts[2]["text"]?.contains("seventh <H07637> day") == true,
            "Unexpected Gen.2.2 text: \(texts[2]["text"] ?? "<nil>")"
        )
    }

    /**
     Verifies Reading Progress memorization rows open practice from global KJVA ordinals.

     Android's Reading Progress list is not scoped to the currently visible book. A memorized
     passage or target row may point to any KJVA verse range, and tapping it opens Memorize for that
     exact range. The native iOS sheet therefore must not route row taps through the current
     reader book/chapter ordinal resolver.

     Failure means the Reading Progress memorization list is preserving an iOS-only current-book
     structure instead of using Android's global KJVA progress domain.
     */
    func testReadingProgressMemorizationRowOpensKJVARangeOutsideCurrentBook() throws {
        let (bridge, recordedScripts) = makeMemorizeParityRecordingBridge()
        let modulePath = try makeMemorizeParityTemporarySwordPath()
        defer { try? FileManager.default.removeItem(atPath: modulePath) }
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.settingsStore = try makeMemorizeParitySettingsStore()

        let startOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Exod", chapter: 1, verse: 22)
        )
        let endOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Exod", chapter: 2, verse: 1)
        )
        try XCTUnwrap(controller.memorizationProgressStore)
            .addMemorizationTarget(bookInitials: "", startOrdinal: startOrdinal, endOrdinal: endOrdinal)

        controller.bridgeDidSetClientReady(bridge)
        let baselineScriptCount = recordedScripts().count

        XCTAssertTrue(
            controller.openMemorizeKJVARange(startOrdinal: startOrdinal, endOrdinal: endOrdinal)
        )

        let memorizeScripts = Array(recordedScripts().dropFirst(baselineScriptCount))
        let document = try XCTUnwrap(
            memorizeParityBridgeEmissionPayload(from: memorizeScripts, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(document["type"] as? String, "memorize")
        XCTAssertEqual(document["title"] as? String, "Exodus 1:22-2:1")
        XCTAssertEqual(document["osisRef"] as? String, "Exod.1.22-Exod.2.1")
        XCTAssertEqual(document["v11n"] as? String, "KJVA")
        XCTAssertEqual(document["startOrdinal"] as? Int, startOrdinal)
        XCTAssertEqual(document["endOrdinal"] as? Int, endOrdinal)
        XCTAssertEqual(document["targetOrdinals"] as? [Int], [startOrdinal, endOrdinal])

        let texts = try XCTUnwrap(document["texts"] as? [[String: String]])
        XCTAssertEqual(texts.map { $0["key"] }, ["Exod.1.22", "Exod.2.1"])
    }
}

/**
 Creates an in-memory settings store for app-host memorization parity tests.

 - Returns: `SettingsStore` backed by a transient SwiftData container.
 - Side effects: Allocates an in-memory model container for the duration of the test.
 - Failure modes: Throws if SwiftData cannot create the transient settings schema.
 */
private func makeMemorizeParitySettingsStore() throws -> SettingsStore {
    let schema = Schema([Setting.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return SettingsStore(modelContext: ModelContext(container))
}

/**
 Builds Android's Progress database shape for app-host memorization parity tests.

 - Parameters:
   - memorizedVerses: Android `MemorizedVerse` rows with one KJVA ordinal and timestamp each.
   - memorizationTargets: Android `MemorizationTarget` rows with independent creation times.
 - Returns: Temporary SQLite database URL with Android's progress schema version.
 - Side effects: Writes a temporary SQLite file under the process temporary directory.
 - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite setup or
   insertion fails.
 */
private func makeMemorizeParityAndroidProgressDatabase(
    memorizedVerses: [(ordinal: Int, memorizedAt: Int64)],
    memorizationTargets: [(startOrdinal: Int, endOrdinal: Int, createdAt: Int64)]
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("memorize-parity-android-progress-\(UUID().uuidString).sqlite3")
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
    }
    defer { sqlite3_close(database) }

    try executeMemorizeParitySQLite(
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
            cycle INTEGER NOT NULL DEFAULT 1,
            readAt INTEGER NOT NULL,
            bookInitials TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT 'MANUAL'
        );
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
        PRAGMA user_version = 9;
        """,
        on: database,
        fileName: url.lastPathComponent
    )

    for verse in memorizedVerses {
        let statement = try prepareMemorizeParitySQLite(
            "INSERT INTO MemorizedVerse (id, kjvOrdinal, memorizedAt) VALUES (?, ?, ?);",
            on: database,
            fileName: url.lastPathComponent
        )
        bindMemorizeParityUUIDBlob(UUID(), to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(verse.ordinal))
        sqlite3_bind_int64(statement, 3, verse.memorizedAt)
        try stepMemorizeParitySQLite(statement, fileName: url.lastPathComponent)
    }

    for target in memorizationTargets {
        let statement = try prepareMemorizeParitySQLite(
            "INSERT INTO MemorizationTarget (id, kjvOrdinalStart, kjvOrdinalEnd, createdAt) VALUES (?, ?, ?, ?);",
            on: database,
            fileName: url.lastPathComponent
        )
        bindMemorizeParityUUIDBlob(UUID(), to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(target.startOrdinal))
        sqlite3_bind_int(statement, 3, Int32(target.endOrdinal))
        sqlite3_bind_int64(statement, 4, target.createdAt)
        try stepMemorizeParitySQLite(statement, fileName: url.lastPathComponent)
    }

    return url
}

/**
 Reads one SQLite integer for app-host Android progress export assertions.

 - Parameters:
   - sql: Single-row, single-column SQL query.
   - url: SQLite database URL to inspect.
 - Returns: The first result column as a 64-bit integer.
 - Side effects: Opens and closes the SQLite database read-only.
 - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when the database or
   statement cannot be read.
 */
private func readMemorizeParitySQLiteInt64(_ sql: String, at url: URL) throws -> Int64 {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database else {
        if let database {
            sqlite3_close(database)
        }
        throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
    }
    defer { sqlite3_close(database) }

    let statement = try prepareMemorizeParitySQLite(sql, on: database, fileName: url.lastPathComponent)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
    }
    return sqlite3_column_int64(statement, 0)
}

/**
 Buckets a millisecond timestamp at local midnight for presentation parity assertions.

 - Parameters:
   - timestamp: Unix epoch milliseconds.
   - calendar: Calendar whose timezone defines the local day.
 - Returns: Unix epoch milliseconds at the start of the containing local day.
 - Side effects: None.
 - Failure modes: None.
 */
private func memorizeParityLocalDayStartMilliseconds(_ timestamp: Int64, calendar: Calendar) -> Int64 {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
    return Int64(calendar.startOfDay(for: date).timeIntervalSince1970 * 1000.0)
}

/**
 Executes SQLite schema setup for app-host Android progress fixtures.

 - Parameters:
   - sql: SQL batch to execute.
   - database: Open SQLite connection.
   - fileName: Fixture filename used for mapped errors.
 - Side effects: Mutates the open SQLite database.
 - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite rejects the
   SQL batch.
 */
private func executeMemorizeParitySQLite(_ sql: String, on database: OpaquePointer, fileName: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
    }
}

/**
 Prepares a SQLite statement for app-host Android progress fixtures.

 - Parameters:
   - sql: SQL statement to prepare.
   - database: Open SQLite connection.
   - fileName: Fixture filename used for mapped errors.
 - Returns: Prepared SQLite statement. The caller owns finalization unless it calls
   `stepMemorizeParitySQLite`.
 - Side effects: Allocates a prepared statement.
 - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when preparation fails.
 */
private func prepareMemorizeParitySQLite(
    _ sql: String,
    on database: OpaquePointer,
    fileName: String
) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
    }
    return statement
}

/**
 Steps and finalizes an app-host SQLite insert statement.

 - Parameters:
   - statement: Prepared SQLite statement with all values bound.
   - fileName: Fixture filename used for mapped errors.
 - Side effects: Executes and finalizes the statement.
 - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when stepping fails.
 */
private func stepMemorizeParitySQLite(_ statement: OpaquePointer, fileName: String) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else {
        sqlite3_finalize(statement)
        throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
    }
    sqlite3_finalize(statement)
}

/**
 Binds UUIDs using the same 16-byte blob representation Android backup mappers use.

 - Parameters:
   - uuid: UUID to bind.
   - statement: Prepared SQLite statement receiving the blob.
   - index: One-based bind parameter index.
 - Side effects: Mutates SQLite statement bindings.
 - Failure modes: None; SQLite reports binding issues during statement execution.
 */
private func bindMemorizeParityUUIDBlob(_ uuid: UUID, to statement: OpaquePointer, index: Int32) {
    let blob = RemoteSyncBookmarkSnapshotService.uuidBlob(uuid)
    _ = blob.withUnsafeBytes { bytes in
        sqlite3_bind_blob(
            statement,
            index,
            bytes.baseAddress,
            Int32(blob.count),
            memorizeParitySQLiteTransient
        )
    }
}

/**
 Creates a recording bridge for app-host memorization parity tests.

 - Returns: A bridge plus ordered JavaScript evaluations emitted by native bridge code.
 - Side effects: Installs a JavaScript evaluation observer on the returned bridge.
 - Failure modes: None.
 */
private func makeMemorizeParityRecordingBridge() -> (BibleBridge, () -> [String]) {
    let bridge = BibleBridge()
    var scripts: [String] = []
    bridge.javaScriptEvaluationObserver = { scripts.append($0) }
    return (bridge, { scripts })
}

/**
 Copies bundled KJV SWORD resources into an isolated app-host test directory.

 - Returns: Path to a temporary `sword` module root containing `mods.d` and module data.
 - Side effects: Creates a temporary directory and recursively copies repository fixture files.
 - Failure modes: Throws when the repository fixture cannot be located or copied.
 */
private func makeMemorizeParityTemporarySwordPath(file: StaticString = #filePath) throws -> String {
    let fileManager = FileManager.default
    let sourceFile = URL(fileURLWithPath: String(describing: file), isDirectory: false)
    let bundledSwordURL = try memorizeParityRepositoryRoot(from: sourceFile)
        .appendingPathComponent("AndBible", isDirectory: true)
        .appendingPathComponent("Resources", isDirectory: true)
        .appendingPathComponent("sword", isDirectory: true)

    let tempRoot = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("sword", isDirectory: true)
    try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    try copyMemorizeParityDirectoryContents(from: bundledSwordURL, to: tempRoot)
    return tempRoot.path
}

/**
 Finds the repository root that contains the bundled SWORD fixture.

 - Parameter sourceFile: Source file URL used as the upward-search anchor.
 - Returns: Repository root URL.
 - Side effects: None.
 - Failure modes: Throws when `AndBible/Resources/sword` cannot be found from the source path.
 */
private func memorizeParityRepositoryRoot(from sourceFile: URL) throws -> URL {
    var candidate = sourceFile.deletingLastPathComponent()
    while candidate.path != candidate.deletingLastPathComponent().path {
        let swordPath = candidate
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("sword", isDirectory: true)
        if FileManager.default.fileExists(atPath: swordPath.path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw NSError(
        domain: "AndBibleTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not locate AndBible/Resources/sword from \(sourceFile.path)"]
    )
}

/**
 Reads a repository-relative source file for app-host source-contract tests.

 - Parameters:
   - relativePath: Path under the repository root to read.
   - file: Test source file used as the root lookup anchor.
 - Returns: UTF-8 source text.
 - Side effects: Performs read-only filesystem access.
 - Failure modes: Throws when the repository root or requested file cannot be located/read.
 */
private func memorizeParitySource(at relativePath: String, file: StaticString = #filePath) throws -> String {
    let sourceFile = URL(fileURLWithPath: String(describing: file), isDirectory: false)
    let sourceURL = try memorizeParityRepositoryRoot(from: sourceFile)
        .appendingPathComponent(relativePath, isDirectory: false)
    return try String(contentsOf: sourceURL, encoding: .utf8)
}

/**
 Recursively copies directory contents for app-host SWORD fixture setup.

 - Parameters:
   - source: Existing directory whose contents should be copied.
   - destination: Destination directory to create or populate.
 - Side effects: Creates directories and copies files under `destination`.
 - Failure modes: Propagates filesystem enumeration, directory creation, and copy errors.
 */
private func copyMemorizeParityDirectoryContents(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

    for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
        let values = try item.resourceValues(forKeys: [.isDirectoryKey])
        let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: values.isDirectory == true)
        if values.isDirectory == true {
            try copyMemorizeParityDirectoryContents(from: item, to: target)
        } else {
            try fileManager.copyItem(at: item, to: target)
        }
    }
}

/**
 Decodes every recorded `update_memorization_data` bridge payload.

 - Parameter scripts: JavaScript snippets recorded from `BibleBridge.emit`.
 - Returns: Payload dictionaries in emission order.
 - Side effects: None.
 - Failure modes: Throws XCTest unwrap or JSON errors when an emission wrapper is malformed.
 */
private func memorizationParityPayloads(from scripts: [String]) throws -> [[String: Any]] {
    try scripts
        .filter { $0.contains("bibleView.emit('update_memorization_data'") }
        .map { script in
            let prefix = "bibleView.emit('update_memorization_data', "
            let start = try XCTUnwrap(script.range(of: prefix)?.upperBound)
            let end = try XCTUnwrap(
                script.range(of: "); } catch", options: .backwards, range: start..<script.endIndex)?.lowerBound
            )
            let json = String(script[start..<end])
            let data = try XCTUnwrap(json.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
}

/**
 Decodes a recorded `bibleView.emit` payload for app-host memorization parity tests.

 - Parameters:
   - scripts: JavaScript snippets recorded from `BibleBridge.emit`.
   - event: Event name passed to `bibleView.emit`.
 - Returns: Decoded JSON payload for the first matching event.
 - Side effects: None.
 - Failure modes: Throws XCTest unwrap or JSON errors when the emission wrapper is malformed.
 */
private func memorizeParityBridgeEmissionPayload(from scripts: [String], event: String) throws -> Any {
    let json = try memorizeParityBridgeEmissionPayloadJSON(from: scripts, event: event)
    let data = try XCTUnwrap(json.data(using: .utf8))
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

private func memorizeParityBridgeEmissionPayloadJSON(from scripts: [String], event: String) throws -> String {
    let prefix = "bibleView.emit('\(event)', "
    let script = try XCTUnwrap(scripts.first { $0.contains(prefix) })
    let start = try XCTUnwrap(script.range(of: prefix)?.upperBound)
    let end = try XCTUnwrap(
        script.range(of: "); } catch", options: .backwards, range: start..<script.endIndex)?.lowerBound
    )
    return String(script[start..<end])
}
