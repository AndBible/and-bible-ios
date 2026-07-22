import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 Protects generic-bookmark sync fidelity and Android fixed-label behavior.

 The tests consume the shared Android-authority fixture used by BibleUI so storage, sync, and bridge
 assertions cannot drift into separate hand-written examples. All persistence uses transient
 SwiftData containers.
 */
final class BookmarkSyncParityTests: XCTestCase {
    /**
     Verifies Android's descending Bible order keeps nullable offsets before concrete offsets.

     - Setup: Persists three trusted bookmarks at the same verse with nil, low, and high offsets.
     - Expected result: `.bibleOrderDesc` returns nil first, then concrete offsets descending,
       matching `BookmarksDao.orderBy` and its `-startOffset` SQLite expression.
     - Side effects: Writes only to an in-memory SwiftData container.
     - Failure modes: A failure means the persistence query delegated NULL placement to SQL DESC
       semantics, which differs from Android even when the visible list projection remains correct.
     */
    func testBookmarkStoreDescendingBibleOrderMatchesAndroidNullableOffsetOrdering() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let store = BookmarkStore(modelContext: modelContext)
        let service = BookmarkService(store: store)
        let range = try XCTUnwrap(
            VerifiedKJVAOrdinalRange(
                resolvingSourceBookInitials: "KJVA",
                sourceVersification: "KJVA",
                sourceOrdinalStart: 4,
                sourceOrdinalEnd: 4
            )
        )
        let nilOffset = service.addBibleBookmark(ordinalRange: range, startOffset: nil, endOffset: nil)
        let lowOffset = service.addBibleBookmark(ordinalRange: range, startOffset: 2, endOffset: 4)
        let highOffset = service.addBibleBookmark(ordinalRange: range, startOffset: 8, endOffset: 12)

        XCTAssertEqual(
            store.bibleBookmarks(sortOrder: .bibleOrderDesc).map(\.id),
            [nilOffset.id, highOffset.id, lowOffset.id]
        )
    }

    /**
     Verifies a partial generic selection survives Android-shaped snapshot export and restore.

     - Setup: Creates the fixture selection through `BookmarkService`, exports it with
       `RemoteSyncBookmarkSnapshotService`, and restores that row into a fresh model container.
     - Expected result: Stored source initials/key, nullable ordinals, UTF-16 offsets, and
       `wholeVerse=false` remain byte-for-value identical at both sync boundaries.
     - Side effects: Writes only to two in-memory SwiftData containers.
     - Failure modes: A failure means generic selection state is dropped or synthesized while
       crossing iOS model and Android Room-v12 sync representations.
     */
    func testGenericSelectionRoundTripsThroughAndroidSnapshotWithOffsetsAndFlags() throws {
        let input = try loadBookmarkSyncParityFixture().genericSelection
        let sourceContainer = try makeBookmarkRestoreModelContainer()
        let sourceContext = ModelContext(sourceContainer)
        let sourceSettings = SettingsStore(modelContext: sourceContext)
        let sourceService = BookmarkService(store: BookmarkStore(modelContext: sourceContext))

        let bookmark = sourceService.addGenericBookmark(
            bookInitials: input.bookInitials,
            key: input.key,
            startOrdinal: input.ordinalStart,
            endOrdinal: input.ordinalEnd,
            wholeVerse: input.wholeVerse,
            startOffset: input.startOffset,
            endOffset: input.endOffset
        )

        let snapshot = RemoteSyncBookmarkSnapshotService().snapshotCurrentState(
            modelContext: sourceContext,
            settingsStore: sourceSettings
        )
        let exported = try XCTUnwrap(
            snapshot.genericBookmarkRowsByKey.values.first(where: { $0.id == bookmark.id })
        )
        XCTAssertEqual(exported.bookInitials, input.bookInitials)
        XCTAssertEqual(exported.key, input.key)
        XCTAssertEqual(exported.ordinalStart, input.ordinalStart)
        XCTAssertEqual(exported.ordinalEnd, input.ordinalEnd)
        XCTAssertEqual(exported.startOffset, input.startOffset)
        XCTAssertEqual(exported.endOffset, input.endOffset)
        XCTAssertEqual(exported.wholeVerse, input.wholeVerse)

        let destinationContainer = try makeBookmarkRestoreModelContainer()
        let destinationContext = ModelContext(destinationContainer)
        _ = try RemoteSyncBookmarkRestoreService(bookNameResolver: nil).replaceLocalBookmarks(
            from: RemoteSyncAndroidBookmarkSnapshot(
                labels: [],
                bibleBookmarks: [],
                genericBookmarks: [exported],
                studyPadEntries: []
            ),
            modelContext: destinationContext,
            settingsStore: SettingsStore(modelContext: destinationContext)
        )

        let restored = try XCTUnwrap(
            try destinationContext.fetch(FetchDescriptor<GenericBookmark>()).first
        )
        XCTAssertEqual(restored.bookInitials, input.bookInitials)
        XCTAssertEqual(restored.key, input.key)
        XCTAssertEqual(restored.ordinalStart, input.ordinalStart)
        XCTAssertEqual(restored.ordinalEnd, input.ordinalEnd)
        XCTAssertEqual(restored.startOffset, input.startOffset)
        XCTAssertEqual(restored.endOffset, input.endOffset)
        XCTAssertEqual(restored.wholeVerse, input.wholeVerse)
    }

    /**
     Verifies reserved labels normalize to Android IDs and primary-label removal cannot leave stale state.

     - Setup: Attaches a pre-parity iOS Speak label and a user label to one generic bookmark, marks
       Speak primary, and inserts an AI label under a noncanonical ID.
     - Expected result: Bootstrap rewrites every present reserved label to the fixture's Android ID,
       preserves the Speak relationship/primary pointer, then removing Speak promotes the remaining
       attached label and removing that label clears the primary pointer.
     - Side effects: Mutates only an in-memory SwiftData graph.
     - Failure modes: A failure means fixed identities do not round-trip with Android or a label
       mutation can leave `primaryLabelId` pointing at a detached label.
     */
    func testFixedLabelNormalizationAndPrimaryRemovalRepairMatchAndroid() throws {
        let fixedIDs = try loadBookmarkSyncParityFixture().fixedLabelIDs
        XCTAssertEqual(Label.speakLabelId, try XCTUnwrap(UUID(uuidString: fixedIDs.speak)))
        XCTAssertEqual(Label.unlabeledId, try XCTUnwrap(UUID(uuidString: fixedIDs.unlabeled)))
        XCTAssertEqual(Label.paragraphBreakLabelId, try XCTUnwrap(UUID(uuidString: fixedIDs.paragraphBreak)))
        XCTAssertEqual(Label.aiLabelId, try XCTUnwrap(UUID(uuidString: fixedIDs.ai)))

        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let store = BookmarkStore(modelContext: modelContext)
        let service = BookmarkService(store: store)
        let legacySpeak = Label(id: Label.legacySpeakLabelId, name: Label.speakLabelName)
        let noncanonicalAI = Label(
            id: UUID(uuidString: "a2000000-0000-0000-0000-000000000099")!,
            name: Label.aiLabelName
        )
        let userLabel = Label(
            id: UUID(uuidString: "a2000000-0000-0000-0000-000000000098")!,
            name: "Prayer"
        )
        modelContext.insert(legacySpeak)
        modelContext.insert(noncanonicalAI)
        modelContext.insert(userLabel)
        let bookmark = service.addGenericBookmark(
            bookInitials: "DICT-AUTH",
            key: "entry-alpha",
            startOrdinal: nil,
            endOrdinal: nil
        )
        let speakLink = GenericBookmarkToLabel(orderNumber: 0)
        speakLink.bookmark = bookmark
        speakLink.label = legacySpeak
        let userLink = GenericBookmarkToLabel(orderNumber: 1)
        userLink.bookmark = bookmark
        userLink.label = userLabel
        bookmark.bookmarkToLabels = [speakLink, userLink]
        bookmark.primaryLabelId = legacySpeak.id
        modelContext.insert(speakLink)
        modelContext.insert(userLink)
        try modelContext.save()

        service.ensureSystemLabels()

        let normalizedIDs = Set(store.labels(includeSystem: true).map(\.id))
        XCTAssertTrue(normalizedIDs.contains(Label.speakLabelId))
        XCTAssertTrue(normalizedIDs.contains(Label.unlabeledId))
        XCTAssertTrue(normalizedIDs.contains(Label.paragraphBreakLabelId))
        XCTAssertTrue(normalizedIDs.contains(Label.aiLabelId))
        XCTAssertFalse(normalizedIDs.contains(Label.legacySpeakLabelId))
        XCTAssertEqual(bookmark.primaryLabelId, Label.speakLabelId)
        XCTAssertTrue(bookmark.bookmarkToLabels?.contains { $0.label?.id == Label.speakLabelId } == true)

        service.removeLabel(bookmarkId: bookmark.id, labelId: Label.speakLabelId)
        XCTAssertEqual(bookmark.primaryLabelId, userLabel.id)
        XCTAssertFalse(bookmark.bookmarkToLabels?.contains { $0.label?.id == Label.speakLabelId } == true)

        service.removeLabel(bookmarkId: bookmark.id, labelId: userLabel.id)
        XCTAssertNil(bookmark.primaryLabelId)
        XCTAssertTrue(bookmark.bookmarkToLabels?.isEmpty ?? true)
    }
}

/** Shared Android fixture subset needed by bookmark sync and label tests. */
private struct BookmarkSyncParityFixture: Decodable {
    /// Android fixed-label UUIDs.
    let fixedLabelIDs: BookmarkSyncParityFixedLabelIDs
    /// Android generic-selection storage contract.
    let genericSelection: BookmarkSyncParityGenericSelection
}

/** Android fixed-label UUID strings from `BookmarkEntities.kt`. */
private struct BookmarkSyncParityFixedLabelIDs: Decodable {
    /// Speak label UUID.
    let speak: String
    /// Synthetic unlabeled UUID.
    let unlabeled: String
    /// Paragraph-break UUID.
    let paragraphBreak: String
    /// AI label UUID.
    let ai: String
}

/** Android generic bookmark fields that must survive sync unchanged. */
private struct BookmarkSyncParityGenericSelection: Decodable {
    /// Stored source module initials.
    let bookInitials: String
    /// Stored source key.
    let key: String
    /// Optional source start ordinal represented by this fixture as present.
    let ordinalStart: Int
    /// Optional source end ordinal represented by this fixture as present.
    let ordinalEnd: Int
    /// UTF-16 selection start.
    let startOffset: Int
    /// UTF-16 selection end.
    let endOffset: Int
    /// Android whole-entry flag.
    let wholeVerse: Bool
}

/**
 Loads the Android-authority bookmark fixture shared with BibleUI tests.

 - Returns: Typed generic-selection and fixed-label values.
 - Side effects: Reads one checked-in JSON fixture.
 - Failure modes: Throws filesystem or decoding errors when fixture location or shape drifts.
 */
private func loadBookmarkSyncParityFixture() throws -> BookmarkSyncParityFixture {
    let sourceFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = (0..<5).reduce(sourceFile) { url, _ in
        url.deletingLastPathComponent()
    }
    let fixtureURL = repositoryRoot
        .appendingPathComponent("Tests")
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("android-bookmark-behavior-parity.json")
    return try JSONDecoder().decode(
        BookmarkSyncParityFixture.self,
        from: Data(contentsOf: fixtureURL)
    )
}
