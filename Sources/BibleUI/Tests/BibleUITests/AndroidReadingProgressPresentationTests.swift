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
