import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import SwordKit

/**
 Protects generic SWORD bookmark seed fidelity across persistence and Android Room-v12 sync.

 Tests use in-memory SwiftData stores and the production bookmark snapshot/restore services. The
 source category remains an installed-module property exactly as on Android; its durable identity is
 the `bookInitials` and key pair carried by every asserted row.
 */
final class GenericBookmarkSeedSyncTests: XCTestCase {
    /**
     Verifies every Android-persisted generic bookmark seed field survives export and restore.

     - Setup: Produces a selected-text seed through the production OSIS processor, persists it via
       `BookmarkService.addGenericBookmark(seed:)`, snapshots to Android's Room-v12 row, and restores
       that row into a fresh store.
     - Expected result: Exact initials/key, local ordinals, paired UTF-16 offsets, and `wholeVerse`
       remain byte-for-value identical at the service, export, and restored-model boundaries.
     - Failure meaning: Seed persistence bypassed a field or Android sync synthesized/dropped
       nullable generic bookmark state.
     - Side effects: Writes only to two in-memory SwiftData containers.
    */
    func testSwordGenericBookmarkSeedRoundTripsAndroidSnapshotAndRestore() throws {
        let fragment = try makeGenericBookmarkSeedSyncFragment()
        let seed = try fragment.genericSelectedTextBookmark(
            ordinalRange: fragment.contentOrdinalRange,
            startOffset: 2,
            endOffset: 7,
            wholeVerse: false
        )
        try assertGenericBookmarkSeedSyncRoundTrip(seed)
    }

    /**
     Verifies whole-entry null ordinals and offsets survive Android export and restore unchanged.

     - Setup: Creates a whole-entry seed from the same validated dictionary fragment and sends it
       through production persistence, snapshot, and restore services.
     - Expected result: Initials/key remain exact, both ordinal/offset pairs remain nil, and
       `wholeVerse` remains true at every boundary.
     - Failure meaning: Sync invented zero ranges, synthesized offsets, or lost whole-entry state.
     - Side effects: Writes only to two in-memory SwiftData containers.
     */
    func testWholeEntryGenericBookmarkSeedPreservesNullsAcrossAndroidSync() throws {
        let seed = try makeGenericBookmarkSeedSyncFragment().genericWholeEntryBookmark()
        XCTAssertNil(seed.ordinalStart)
        XCTAssertNil(seed.ordinalEnd)
        XCTAssertNil(seed.startOffset)
        XCTAssertNil(seed.endOffset)
        try assertGenericBookmarkSeedSyncRoundTrip(seed)
    }
}

/**
 Builds one validated generic SWORD fragment without introducing a persistence representation.

 - Returns: Fragment with dictionary category, exact source/key, and two local text anchors.
 - Side effects: None.
 - Failure modes: Propagates OSIS processing errors.
 */
private func makeGenericBookmarkSeedSyncFragment() throws -> SwordRawOSISFragment {
    let processed = try SwordOSISFragmentProcessor.process(
        sourceXML: "<entryFree><p>First anchor. </p><p>Second anchor.</p></entryFree>",
        category: .dictionary,
        moduleInitials: "SEEDSYNC"
    )
    let source = SwordRawOSISSource(
        initials: "SEEDSYNC",
        name: "Generic Bookmark Seed Sync Dictionary",
        abbreviation: "A2S",
        category: .dictionary,
        language: "en",
        direction: "ltr",
        versification: "KJV",
        hasStrongs: false,
        moduleFeatures: []
    )
    let key = "entry/exact"
    return SwordRawOSISFragment(
        xml: processed.xml,
        originalXML: processed.originalXML,
        key: key,
        keyName: "Exact entry",
        fragmentKey: "SEEDSYNC--\(SwordRawOSISIdentity.uniqueID(key: key, keyOrdinalRange: nil))",
        osisRef: key,
        source: source,
        isNewTestament: false,
        features: [:],
        contentOrdinalRange: processed.contentOrdinalRange,
        keyOrdinalRange: nil,
        annotateRef: processed.annotateRef,
        anchorTexts: processed.anchorTexts,
        comparablePlainText: processed.comparablePlainText,
        hasRenderableContent: processed.hasRenderableContent
    )
}

/**
 Asserts one generic bookmark seed at service, Android export, and restored-model boundaries.

 - Parameter seed: Selected or whole-entry seed whose nullable fields must remain exact.
 - Side effects: Writes the seed into two in-memory SwiftData containers.
 - Failure modes: Throws for container, snapshot lookup, or restore failures; assertions identify
   any field that changes between boundaries.
 */
private func assertGenericBookmarkSeedSyncRoundTrip(_ seed: SwordGenericBookmarkSeed) throws {
    let sourceContainer = try makeBookmarkRestoreModelContainer()
    let sourceContext = ModelContext(sourceContainer)
    let sourceSettings = SettingsStore(modelContext: sourceContext)
    let sourceService = BookmarkService(store: BookmarkStore(modelContext: sourceContext))

    let bookmark = sourceService.addGenericBookmark(seed: seed)
    assertGenericBookmarkSeedFields(bookmark, equalTo: seed)

    let snapshot = RemoteSyncBookmarkSnapshotService().snapshotCurrentState(
        modelContext: sourceContext,
        settingsStore: sourceSettings
    )
    let exported = try XCTUnwrap(
        snapshot.genericBookmarkRowsByKey.values.first(where: { $0.id == bookmark.id })
    )
    XCTAssertEqual(exported.bookInitials, seed.source.bookInitials)
    XCTAssertEqual(exported.key, seed.source.key)
    XCTAssertEqual(exported.ordinalStart, seed.ordinalStart)
    XCTAssertEqual(exported.ordinalEnd, seed.ordinalEnd)
    XCTAssertEqual(exported.startOffset, seed.startOffset)
    XCTAssertEqual(exported.endOffset, seed.endOffset)
    XCTAssertEqual(exported.wholeVerse, seed.wholeVerse)

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
    assertGenericBookmarkSeedFields(restored, equalTo: seed)
}

/** Asserts every persisted seed field on one existing generic bookmark model. */
private func assertGenericBookmarkSeedFields(
    _ bookmark: GenericBookmark,
    equalTo seed: SwordGenericBookmarkSeed,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(bookmark.bookInitials, seed.source.bookInitials, file: file, line: line)
    XCTAssertEqual(bookmark.key, seed.source.key, file: file, line: line)
    XCTAssertEqual(bookmark.ordinalStart, seed.ordinalStart, file: file, line: line)
    XCTAssertEqual(bookmark.ordinalEnd, seed.ordinalEnd, file: file, line: line)
    XCTAssertEqual(bookmark.startOffset, seed.startOffset, file: file, line: line)
    XCTAssertEqual(bookmark.endOffset, seed.endOffset, file: file, line: line)
    XCTAssertEqual(bookmark.wholeVerse, seed.wholeVerse, file: file, line: line)
}
