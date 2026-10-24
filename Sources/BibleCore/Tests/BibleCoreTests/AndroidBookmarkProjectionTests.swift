import Foundation
import SwiftData
import XCTest
@testable import BibleCore
import SwordKit

/** Android lookup compatibility never replaces source identity or the strict progress contract. */
final class AndroidBookmarkProjectionTests: XCTestCase {
    /** JSword's unchecked chapter offset places Calvin Rev 12:18 one slot after KJVA Rev 12:17. */
    func testCalvinProjectionIsBookmarkOnlyAndRejectsTampering() throws {
        let ordinal = try XCTUnwrap(JSwordCanon.referenceIndex(
            for: .init(osisBookId: "Rev", chapter: 12, verse: 18), versification: "Calvin"))
        let range = try XCTUnwrap(VerifiedBibleBookmarkRange(sourceBookInitials: "HunKar",
            sourceVersification: "Calvin", sourceOrdinalStart: ordinal, sourceOrdinalEnd: ordinal))
        let expected = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Rev", chapter: 12, verse: 17)) + 1
        XCTAssertEqual(range.kjvaOrdinalStart, expected)
        XCTAssertEqual(range.ordinalTrust.state, .verifiedBookmarkProjectionV1)
        XCTAssertTrue(PersistedOrdinalTrustPolicy.isTrustedBookmarkRange(metadata: range.ordinalTrust, start: expected, end: expected))
        XCTAssertFalse(PersistedOrdinalTrustPolicy.isTrustedBookmarkRange(metadata: range.ordinalTrust, start: expected + 1, end: expected + 1))
        XCTAssertFalse(PersistedOrdinalTrustPolicy.isTrustedKJVARange(metadata: range.ordinalTrust, start: expected, end: expected))
        XCTAssertNil(VerifiedKJVAOrdinalRange(resolvingSourceBookInitials: "HunKar", sourceVersification: "Calvin",
                                            sourceOrdinalStart: ordinal, sourceOrdinalEnd: ordinal))
    }

    /** Existing Android provenance still navigates by source identity after upgrading. */
    @MainActor
    func testExistingAndroidExtraVerseBookmarkKeepsSourceNavigationAndCSVReference() throws {
        let source = try XCTUnwrap(JSwordCanon.referenceIndex(
            for: .init(osisBookId: "Rev", chapter: 12, verse: 18), versification: "Calvin"))
        let lookup = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Rev", chapter: 12, verse: 17)) + 1
        let bookmark = BibleBookmark(kjvOrdinalStart: lookup, kjvOrdinalEnd: lookup,
            ordinalStart: source, ordinalEnd: source, v11n: "Calvin", bookInitials: "HunKar",
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: "Calvin", sourceOrdinalStart: source, sourceOrdinalEnd: source,
                kjvaOrdinalStart: lookup, kjvaOrdinalEnd: lookup))
        guard case .bible(let target) = try BookmarkNavigationTargetResolver.resolve(bookmark) else {
            return XCTFail("Expected Bible destination")
        }
        XCTAssertTrue(target.usesLookupProjection)
        XCTAssertEqual(target.sourceOSISReference, "Rev.12.18")
        let csv = try AndroidBookmarkCSVCodec.encode(bookmarks: [bookmark], selectedColumns: [.osisReference, .ordinalStart])
        XCTAssertEqual(String(data: csv, encoding: .utf8), "osisRef;ordinalStart\nRev.12.18;\(lookup)\n")
    }

    /** Native zero-lookup bookmarks remain exportable with their source reference and notes. */
    @MainActor
    func testNativeAbsentBookBookmarkExportsOriginalPassage() throws {
        let source = try XCTUnwrap(JSwordCanon.referenceIndex(
            for: .init(osisBookId: "3Macc", chapter: 1, verse: 29), versification: "LXX"))
        let range = try XCTUnwrap(VerifiedBibleBookmarkRange(sourceBookInitials: "LXX",
            sourceVersification: "LXX", sourceOrdinalStart: source, sourceOrdinalEnd: source))
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        let service = BookmarkService(store: BookmarkStore(modelContext: context))
        let bookmark = service.addBibleBookmark(ordinalRange: range)
        service.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Source note")
        let snapshot = try RemoteSyncBookmarkSnapshotService().snapshotCurrentStateThrowing(
            modelContext: context, settingsStore: settings)
        let row = try XCTUnwrap(snapshot.bibleBookmarkRowsByKey.values.first)
        XCTAssertEqual(row.kjvOrdinalStart, 0)
        XCTAssertEqual(row.ordinalStart, source)
        XCTAssertEqual(row.v11n, "LXX")
        XCTAssertEqual(row.notes, "Source note")
        let csv = try AndroidBookmarkCSVCodec.encode(bookmarks: [bookmark], selectedColumns: [.osisReference, .ordinalStart])
        XCTAssertEqual(String(data: csv, encoding: .utf8), "osisRef;ordinalStart\n3Macc.1.29;0\n")
    }

    /**
     Restores real Android SQLite rows, then projects the complete graph back for backup/sync.
     Extra verses and absent target books/chapters preserve original identity, notes, label links,
     and StudyPad ordering/text. Zero lookup indexes must not reject or silently quarantine data.
     All database files are temporary; the SwiftData graph is in-memory and local to this test.
     */
    @MainActor
    func testAndroidBackupRestoreAndSyncProjectionPreserveExtraVerseStudyData() throws {
        let labelID = UUID(), padID = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let rev = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(osisId: "Rev", chapter: 12, verse: 17)) + 1
        let cases = [("Calvin", "Rev", 12, 18, rev), ("LXX", "3Macc", 1, 29, 0), ("Vulg", "Esth", 11, 12, 0)]
        let rows: [AndroidBibleBookmarkRow] = try cases.map { v11n, book, chapter, verse, lookup in
            let source = try XCTUnwrap(JSwordCanon.referenceIndex(
                for: .init(osisBookId: book, chapter: chapter, verse: verse), versification: v11n))
            return .init(id: UUID(), kjvOrdinalStart: lookup, kjvOrdinalEnd: lookup,
                ordinalStart: source, ordinalEnd: source, v11n: v11n, createdAt: date,
                book: "SourceModule", primaryLabelID: labelID, lastUpdatedOn: date)
        }
        let database = try makeAndroidBookmarksDatabase(
            labels: [.init(id: labelID, name: "Source study", colour: -1)], bibleBookmarks: rows,
            bibleNotes: rows.map { .init(bookmarkID: $0.id, notes: "Note \($0.v11n)", contentType: "MARKDOWN") },
            bibleLinks: rows.enumerated().map { index, row in
                .init(bookmarkID: row.id, labelID: labelID, orderNumber: index, indentLevel: 1, expandContent: true)
            },
            studyPadEntries: [.init(id: padID, labelID: labelID, orderNumber: 4, indentLevel: 2, contentType: "MARKDOWN")],
            studyPadTexts: [.init(entryID: padID, text: "Preserved StudyPad text")]
        )
        defer { try? FileManager.default.removeItem(at: database) }
        let service = RemoteSyncBookmarkRestoreService(bookNameResolver: nil)
        let incoming = try service.readSnapshot(from: database)
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        _ = try service.replaceLocalBookmarks(from: incoming, modelContext: context, settingsStore: settings)
        let visible = BookmarkStore(modelContext: context).bibleBookmarks()
        XCTAssertEqual(Set(visible.map(\.id)), Set(rows.map(\.id)))
        let exported = try RemoteSyncBookmarkSnapshotService().snapshotCurrentStateThrowing(modelContext: context, settingsStore: settings)
        XCTAssertEqual(exported.bibleBookmarkRowsByKey.count, 3)
        XCTAssertEqual(exported.bibleNoteRowsByKey.count, 3)
        XCTAssertEqual(exported.bibleLinkRowsByKey.count, 3)
        for row in rows {
            let actual = try XCTUnwrap(exported.bibleBookmarkRowsByKey.values.first { $0.id == row.id })
            XCTAssertEqual(actual.ordinalStart, row.ordinalStart)
            XCTAssertEqual(actual.ordinalEnd, row.ordinalEnd)
            XCTAssertEqual(actual.v11n, row.v11n)
            XCTAssertEqual(actual.kjvOrdinalStart, row.kjvOrdinalStart)
            XCTAssertEqual(actual.kjvOrdinalEnd, row.kjvOrdinalEnd)
            XCTAssertEqual(actual.notes, "Note \(row.v11n)")
        }
        XCTAssertEqual(exported.studyPadTextRowsByKey.values.first?.text, "Preserved StudyPad text")
        XCTAssertEqual(exported.studyPadEntryRowsByKey.values.first?.orderNumber, 4)
    }
}
