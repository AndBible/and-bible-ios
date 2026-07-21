import XCTest
import SwiftData
@testable import BibleCore
@testable import BibleUI

/** Bookmark-list coverage for exact destinations, visible corruption, notes, and Android sorts. */
final class BookmarkNavigationAndNotesTests: XCTestCase {
    /**
     Verifies a Bible row preserves source identity and exact verse-range coordinates.

     Failure meaning:
     - bookmark selection can collapse to a chapter, substitute the active module's numbering, or
       discard the module/versification needed for authoritative parent mapping.
     */
    func testBibleRowEmitsExactTypedRangeWithSourceIdentity() throws {
        let start = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "John", chapter: 3, verse: 16)
        )
        let end = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "John", chapter: 3, verse: 18)
        )
        let bookmark = verifiedBibleBookmark(
            ordinalRange: start...end,
            moduleInitials: "NASB"
        )

        let item = BookmarkListItem(bibleBookmark: bookmark)
        guard case .bible(let target)? = item.exactNavigationTarget else {
            return XCTFail("Expected an exact Bible navigation target")
        }
        XCTAssertEqual(target.sourceModuleInitials, "NASB")
        XCTAssertEqual(target.sourceVersification, "KJVA")
        XCTAssertEqual(target.sourceOrdinalRange, start...end)
        XCTAssertEqual(target.sourceOSISReference, "John.3.16-John.3.18")
        XCTAssertEqual(target.kjvaOrdinalRange, start...end)
        XCTAssertEqual(target.kjvaOSISReference, "John.3.16-John.3.18")
        XCTAssertNil(item.navigationError)
    }

    /**
     Verifies a generic row keeps its exact module, key, and optional ordinal range.

     Failure meaning:
     - non-Bible bookmark rows remain inert or navigate using a key that is meaningless outside
       their owning module.
     */
    func testGenericRowEmitsExactTypedModuleKeyAndOrdinals() {
        let bookmark = GenericBookmark(
            key: " ἀγάπη ",
            bookInitials: "StrongsGreek ",
            ordinalStart: 26,
            ordinalEnd: 28
        )

        let item = BookmarkListItem(genericBookmark: bookmark)
        XCTAssertEqual(
            item.exactNavigationTarget,
            .generic(GenericBookmarkNavigationTarget(
                moduleInitials: "StrongsGreek ",
                key: " ἀγάπη ",
                ordinalRange: 26...28
            ))
        )
        XCTAssertNil(item.navigationError)
    }

    /**
     Verifies corrupt and unverified Bible coordinates do not produce a typed destination.

     Failure meaning:
     - the list can fabricate Genesis/chapter arithmetic or treat plausible legacy numbers as
       authoritative, navigating to a passage unrelated to the bookmark.
     */
    func testCorruptAndUntrustedBibleRowsFailClosedWithoutFallbackTarget() {
        let corrupt = BibleBookmark(
            kjvOrdinalStart: 999_999,
            kjvOrdinalEnd: 999_999,
            ordinalStart: 999_999,
            ordinalEnd: 999_999,
            v11n: "KJVA",
            bookInitials: "KJV"
        )
        let corruptItem = BookmarkListItem(bibleBookmark: corrupt)
        XCTAssertNil(corruptItem.exactNavigationTarget)
        XCTAssertEqual(corruptItem.navigationError, .untrustedBibleOrdinals)
        XCTAssertEqual(
            corruptItem.reference,
            String(localized: "error_occurred", defaultValue: "An error has occurred")
        )

        let validButUntrusted = BibleBookmark(
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "KJVA",
            bookInitials: "KJV"
        )
        let untrustedItem = BookmarkListItem(bibleBookmark: validButUntrusted)
        XCTAssertNil(untrustedItem.exactNavigationTarget)
        XCTAssertEqual(untrustedItem.navigationError, .untrustedBibleOrdinals)
    }

    /**
     Verifies duplicated source fields cannot drift away from their trusted provenance silently.

     Failure meaning:
     - a row with valid KJVA coordinates but damaged source ordinals can emit a typed target whose
       module/versification identity points at a different passage.
     */
    func testTrustedBibleRowWithInconsistentSourceMetadataFailsClosed() {
        let bookmark = verifiedBibleBookmark(ordinalRange: 4...4, moduleInitials: "KJV")
        bookmark.ordinalStart = 5
        bookmark.ordinalEnd = 5
        XCTAssertTrue(bookmark.hasTrustedPersistedOrdinals)

        let item = BookmarkListItem(bibleBookmark: bookmark)

        XCTAssertNil(item.exactNavigationTarget)
        XCTAssertEqual(item.navigationError, .invalidSourceOrdinals(start: 5, end: 5))
    }

    /**
     Verifies note-bearing Bible and generic rows remain members while Show Notes affects search.

     Failure meaning:
     - hiding previews deletes rows from the effective list, or note text continues matching after
       Android's persisted `bookmark_show_notes` option is disabled.
     */
    func testShowNotesControlsNoteSearchWithoutRemovingNoteBearingRows() {
        let bible = verifiedBibleBookmark(ordinalRange: 4...4, moduleInitials: "KJV")
        let bibleNote = BibleBookmarkNotes(bookmarkId: bible.id, notes: "private phrase")
        bibleNote.bookmark = bible
        bible.notes = bibleNote
        let generic = GenericBookmark(key: "Entry", bookInitials: "Dictionary")
        let genericNote = GenericBookmarkNotes(bookmarkId: generic.id, notes: "private phrase")
        genericNote.bookmark = generic
        generic.notes = genericNote
        let items = [
            BookmarkListItem(bibleBookmark: bible),
            BookmarkListItem(genericBookmark: generic),
        ]

        XCTAssertEqual(
            BookmarkListProjection.filteredItems(
                items,
                selectedLabelId: nil,
                searchText: "",
                sortOrder: .bibleOrder,
                showNotes: false
            ).count,
            2
        )
        XCTAssertEqual(
            BookmarkListProjection.filteredItems(
                items,
                selectedLabelId: nil,
                searchText: "private phrase",
                sortOrder: .bibleOrder,
                showNotes: true
            ).count,
            2
        )
        XCTAssertEqual(
            BookmarkListProjection.filteredItems(
                items,
                selectedLabelId: nil,
                searchText: "private phrase",
                sortOrder: .bibleOrder,
                showNotes: false
            ).count,
            2,
            "Disabling Show Notes clears/disables Android's note search instead of removing rows"
        )
        XCTAssertTrue(
            BookmarkListProjection.filteredItems(
                items,
                selectedLabelId: nil,
                searchText: "Genesis",
                sortOrder: .bibleOrder,
                showNotes: true
            ).isEmpty,
            "Android bookmark search matches note content, not rendered references"
        )
    }

    /**
     Verifies all four Android bookmark-list sort directions persist distinct ordering behavior.

     Failure meaning:
     - one persisted enum value aliases another direction or disappears from list projection.
     */
    func testProjectionSupportsAllFourAndroidSortDirections() throws {
        let exodusOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Exod", chapter: 1, verse: 1)
        )
        let matthewOrdinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "Matt", chapter: 1, verse: 1)
        )
        let exodus = BookmarkListItem(bibleBookmark: verifiedBibleBookmark(
            ordinalRange: exodusOrdinal...exodusOrdinal,
            moduleInitials: "KJV",
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        let matthew = BookmarkListItem(bibleBookmark: verifiedBibleBookmark(
            ordinalRange: matthewOrdinal...matthewOrdinal,
            moduleInitials: "KJV",
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        let items = [matthew, exodus]

        XCTAssertEqual(references(items, sortOrder: .bibleOrder), ["Exodus 1:1", "Matthew 1:1"])
        XCTAssertEqual(references(items, sortOrder: .bibleOrderDesc), ["Matthew 1:1", "Exodus 1:1"])
        XCTAssertEqual(references(items, sortOrder: .createdAt), ["Matthew 1:1", "Exodus 1:1"])
        XCTAssertEqual(references(items, sortOrder: .createdAtDesc), ["Exodus 1:1", "Matthew 1:1"])
    }

    /**
     Verifies Android bookmark-list preferences persist through their declared storage backends.

     Setup saves and clears the process-global sort preference, then uses an isolated SwiftData
     store for Show Notes and unchecked CSV columns. Each of Android's four visible sort values is
     written and read before a second `SettingsStore` verifies the database-backed values.

     Failure meaning:
     - a sort direction cannot survive reopening the list, Show Notes loses Android's true default,
       or the CSV column selector forgets the user's unchecked columns.
     */
    @MainActor
    func testAndroidBookmarkPreferencesPersistSortNotesAndCSVColumns() throws {
        let sortKey = AppPreferenceKey.bookmarkSortOrder.rawValue
        let savedSortValue = UserDefaults.standard.object(forKey: sortKey)
        UserDefaults.standard.removeObject(forKey: sortKey)
        defer {
            if let savedSortValue {
                UserDefaults.standard.set(savedSortValue, forKey: sortKey)
            } else {
                UserDefaults.standard.removeObject(forKey: sortKey)
            }
        }

        let schema = Schema([Setting.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        XCTAssertEqual(
            settings.getString(AppPreferenceKey.bookmarkSortOrder),
            BookmarkSortOrder.bibleOrder.rawValue
        )
        XCTAssertTrue(settings.getBool(AppPreferenceKey.bookmarkShowNotes))

        let visibleOrders: [BookmarkSortOrder] = [
            .bibleOrder,
            .bibleOrderDesc,
            .createdAtDesc,
            .createdAt,
        ]
        for order in visibleOrders {
            settings.setString(AppPreferenceKey.bookmarkSortOrder, value: order.rawValue)
            XCTAssertEqual(settings.getString(AppPreferenceKey.bookmarkSortOrder), order.rawValue)
        }
        settings.setBool(AppPreferenceKey.bookmarkShowNotes, value: false)
        settings.setStringSet(
            AppPreferenceKey.bookmarkCSVUncheckedColumns,
            values: [AndroidBookmarkCSVColumn.labels.rawValue, AndroidBookmarkCSVColumn.notes.rawValue]
        )

        let reloaded = SettingsStore(modelContext: context)
        XCTAssertEqual(
            reloaded.getString(AppPreferenceKey.bookmarkSortOrder),
            BookmarkSortOrder.createdAt.rawValue
        )
        XCTAssertFalse(reloaded.getBool(AppPreferenceKey.bookmarkShowNotes))
        XCTAssertEqual(
            Set(reloaded.getStringSet(AppPreferenceKey.bookmarkCSVUncheckedColumns)),
            Set([AndroidBookmarkCSVColumn.labels.rawValue, AndroidBookmarkCSVColumn.notes.rawValue])
        )
    }

    /** Builds one verified KJVA bookmark for exact navigation and sorting fixtures. */
    private func verifiedBibleBookmark(
        ordinalRange: ClosedRange<Int>,
        moduleInitials: String,
        createdAt: Date = Date(timeIntervalSince1970: 100)
    ) -> BibleBookmark {
        BibleBookmark(
            kjvOrdinalStart: ordinalRange.lowerBound,
            kjvOrdinalEnd: ordinalRange.upperBound,
            ordinalStart: ordinalRange.lowerBound,
            ordinalEnd: ordinalRange.upperBound,
            v11n: "KJVA",
            bookInitials: moduleInitials,
            createdAt: createdAt,
            lastUpdatedOn: createdAt,
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: "KJVA",
                sourceOrdinalStart: ordinalRange.lowerBound,
                sourceOrdinalEnd: ordinalRange.upperBound,
                kjvaOrdinalStart: ordinalRange.lowerBound,
                kjvaOrdinalEnd: ordinalRange.upperBound
            )
        )
    }

    /** Applies one sort direction and returns the resulting visible references. */
    private func references(
        _ items: [BookmarkListItem],
        sortOrder: BookmarkSortOrder
    ) -> [String] {
        BookmarkListProjection.filteredItems(
            items,
            selectedLabelId: nil,
            searchText: "",
            sortOrder: sortOrder
        ).map(\.reference)
    }
}
