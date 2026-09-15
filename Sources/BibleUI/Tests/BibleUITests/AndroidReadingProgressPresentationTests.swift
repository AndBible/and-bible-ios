import BibleCore
import XCTest
@testable import BibleUI

/** Android Reading/Memory Progress presentation and interaction-contract coverage. */
final class AndroidReadingProgressPresentationTests: XCTestCase {
    /**
     Verifies the app-owned settings projection cannot reorder, omit, or invent Android preferences.

     Failure means the Swift activity has drifted from `reading_progress_settings.xml`, including
     reintroduction of the unrelated native `autoTrackReading` field or local icon substitutions.
     */
    func testProgressSettingsMatchAndroidXMLOrderResourcesAndAssets() {
        let preferences = AndroidReadingProgressPreference.allCases

        XCTAssertEqual(preferences.map(\.rawValue), [
            "auto_mark_memorized",
            "memorize_type_full_words",
            "memorize_word_visibility",
            "memorize_error_heatmap",
            "memorize_scramble_hide_used",
            "memorize_include_reference",
        ])
        XCTAssertEqual(preferences.map(\.summaryResourceKey), [
            "memorize_auto_mark_summary",
            "memorize_type_full_words_summary",
            "memorize_word_visibility_summary",
            "memorize_error_heatmap_summary",
            "memorize_scramble_hide_used_summary",
            "memorize_include_reference_summary",
        ])
        XCTAssertEqual(preferences.map(\.iconName), [
            "ProgressAutoMark",
            "ProgressTypeFullWords",
            "ProgressWordVisibility",
            "ProgressErrorHeatmap",
            "ProgressHideUsedWords",
            "ProgressIncludeReference",
        ])
        XCTAssertFalse(preferences.map(\.rawValue).contains("autoTrackReading"))
    }

    /**
     Verifies book, day, and chapter entry points query the same active-cycle history semantics.

     Failure means one launcher can show the inline/recent approximation that previously diverged
     from Android `ReadHistoryDialog`, or a local-day query crosses its calendar boundary.
     */
    func testReadHistorySelectionsFilterCapturedActiveCycleRows() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let store = ReadingProgressStore(settingsStore: settingsStore)
        let genesisOne = try XCTUnwrap(
            ReadingProgressKJVAIdentity(androidKJVBookOrdinal: 2, chapter: 1)
        )
        let genesisTwo = try XCTUnwrap(
            ReadingProgressKJVAIdentity(androidKJVBookOrdinal: 2, chapter: 2)
        )
        let exodusOne = try XCTUnwrap(
            ReadingProgressKJVAIdentity(androidKJVBookOrdinal: 3, chapter: 1)
        )
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_767_355_200))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let firstDayMilliseconds = try AndroidTimestamp.milliseconds(from: firstDay)

        _ = try store.recordChapterRead(
            bookInitials: "KJV",
            identity: genesisOne,
            source: .manual,
            readAt: try AndroidTimestamp.milliseconds(from: firstDay.addingTimeInterval(3_600))
        )
        _ = try store.recordChapterRead(
            bookInitials: "KJV",
            identity: genesisTwo,
            source: .manual,
            readAt: try AndroidTimestamp.milliseconds(from: firstDay.addingTimeInterval(7_200))
        )
        _ = try store.recordChapterRead(
            bookInitials: "KJV",
            identity: exodusOne,
            source: .manual,
            readAt: try AndroidTimestamp.milliseconds(from: secondDay.addingTimeInterval(3_600))
        )

        let bookSelection = AndroidReadHistorySelection.book(
            kjvBookOrdinal: 2,
            longName: "Genesis"
        )
        XCTAssertEqual(bookSelection.rows(in: store).map(\.chapter), [2, 1])
        XCTAssertTrue(bookSelection.showsChapterReference)
        XCTAssertEqual(bookSelection.localizedSubject, "Genesis")

        let daySelection = AndroidReadHistorySelection.day(
            startMilliseconds: firstDayMilliseconds
        )
        XCTAssertEqual(daySelection.rows(in: store).map(\.chapter), [2, 1])
        XCTAssertTrue(daySelection.showsChapterReference)
        XCTAssertFalse(daySelection.localizedSubject.isEmpty)

        let chapterTarget = ChapterReadHistoryTarget(
            bookInitials: "KJV",
            startOrdinal: 0,
            kjvBookOrdinal: 2,
            bookName: "Genesis",
            chapter: 1
        )
        let chapterSelection = AndroidReadHistorySelection.chapter(chapterTarget)
        XCTAssertEqual(chapterSelection.rows(in: store).map(\.chapter), [1])
        XCTAssertFalse(chapterSelection.showsChapterReference)
        XCTAssertEqual(chapterSelection.localizedSubject, "Gen 1")
    }
}

// MARK: - Memorization presentation contracts

extension AndroidReadingProgressPresentationTests {
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
        let gen1Trust = try readingProgressVerifiedKJVARange(start: gen1, end: gen1).ordinalTrust
        let gen2Trust = try readingProgressVerifiedKJVARange(start: gen2, end: gen2).ordinalTrust
        let exod1Trust = try readingProgressVerifiedKJVARange(start: exod1, end: exod1).ordinalTrust
        let genesisTargetTrust = try readingProgressVerifiedKJVARange(start: gen1, end: gen3).ordinalTrust

        let presentation = MemorizationProgressPresentation(
            snapshot: MemorizationProgressSnapshot(
                memorizedVerses: [
                    .init(kjvOrdinal: gen1, memorizedAt: genDay, ordinalTrust: gen1Trust),
                    .init(kjvOrdinal: gen2, memorizedAt: genDay + 1_000, ordinalTrust: gen2Trust),
                    .init(kjvOrdinal: exod1, memorizedAt: exodDay, ordinalTrust: exod1Trust),
                ],
                targetRows: [
                    MemorizationTargetRow(
                        id: UUID(uuidString: "16000000-0000-0000-0000-000000000201")!,
                        startOrdinal: gen1,
                        endOrdinal: gen3,
                        createdAt: genDay + 2_000,
                        ordinalTrust: genesisTargetTrust
                    ),
                    MemorizationTargetRow(
                        id: UUID(uuidString: "16000000-0000-0000-0000-000000000202")!,
                        startOrdinal: exod1,
                        endOrdinal: exod1,
                        createdAt: exodDay + 2_000,
                        ordinalTrust: exod1Trust
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
        let incompleteTarget = try XCTUnwrap(presentation.incompleteTargets.first)
        XCTAssertEqual(incompleteTarget.memorizedCount, 2)
        XCTAssertEqual(incompleteTarget.verseCount, 3)
        XCTAssertEqual(incompleteTarget.progressFraction, 2.0 / 3.0, accuracy: 0.000_001)
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
                readingProgressLocalDayStartMilliseconds(genDay, calendar: calendar)
            ],
            2
        )
        XCTAssertEqual(
            presentation.calendarCountsByDayStartMilliseconds[
                readingProgressLocalDayStartMilliseconds(exodDay, calendar: calendar)
            ],
            1
        )
    }
}

/** Creates one trusted KJVA range for presentation fixtures. */
private func readingProgressVerifiedKJVARange(
    start: Int,
    end: Int
) throws -> VerifiedKJVAOrdinalRange {
    try XCTUnwrap(
        VerifiedKJVAOrdinalRange(
            resolvingSourceBookInitials: "KJVA",
            sourceVersification: "KJVA",
            sourceOrdinalStart: start,
            sourceOrdinalEnd: end
        )
    )
}

/** Buckets a millisecond timestamp at local midnight for presentation assertions. */
private func readingProgressLocalDayStartMilliseconds(
    _ timestamp: Int64,
    calendar: Calendar
) -> Int64 {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
    return Int64(calendar.startOfDay(for: date).timeIntervalSince1970 * 1_000)
}
