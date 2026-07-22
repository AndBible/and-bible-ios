import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 Protects production AI text transformation reads and atomic writeback for Bible and generic
 bookmark notes, StudyPad text entries, and My Documents pages.
 */
@MainActor
final class AITextTargetConflictProtectionTests: XCTestCase {
    /**
     Verifies every production target reads exact source content and preserves its durable type.

     Successful writes are persisted through the owning service, including generic bookmark notes
     in the generic table and OSIS My Documents content without representation conversion.
     */
    func testEveryTextTargetReadsAndWritesThroughItsOwningService() async throws {
        let fixture = try makeFixture()
        let store = AITextTargetStore(backing: fixture.backing)
        let expectations: [(AITextTarget, String, AITextContentType, String)] = [
            (.bibleBookmarkNote(fixture.bibleBookmarkID), "Bible original", .markdown, "Bible changed"),
            (.genericBookmarkNote(fixture.genericBookmarkID), "Generic original", .html, "Generic changed"),
            (.studyPadText(fixture.studyPadEntryID), "StudyPad original", .markdown, "StudyPad changed"),
            (.myDocumentPage(fixture.pageID), "Page original", .osis, "Page changed"),
        ]

        for (target, original, contentType, replacement) in expectations {
            let snapshot = try await store.capture(target)
            XCTAssertEqual(snapshot.content, original)
            XCTAssertEqual(snapshot.contentType, contentType)

            let written = try await store.write(
                content: replacement,
                to: target,
                capturedInputDigest: snapshot.capturedInputDigest
            )
            XCTAssertEqual(written.content, replacement)
            XCTAssertEqual(written.contentType, contentType)
            let persisted = try await fixture.backing.read(target)
            XCTAssertEqual(persisted, AITextTargetValue(
                content: replacement,
                contentType: contentType
            ))
        }

        XCTAssertEqual(
            fixture.bookmarkService.bibleBookmark(id: fixture.bibleBookmarkID)?.notes?.notes,
            "Bible changed"
        )
        XCTAssertEqual(
            fixture.bookmarkService.genericBookmark(id: fixture.genericBookmarkID)?.notes?.notes,
            "Generic changed"
        )
        XCTAssertEqual(
            fixture.bookmarkService.studyPadEntry(id: fixture.studyPadEntryID)?.textEntry?.text,
            "StudyPad changed"
        )
        XCTAssertEqual(
            fixture.myDocumentStore.page(pageId: fixture.pageID)?.pageContent?.content,
            "Page changed"
        )
    }

    /**
     Verifies independent UI or sync edits make compare-and-write fail for all target kinds.

     The external values must remain intact. Failure would allow an AI response generated from
     stale content to overwrite a newer bookmark, StudyPad, or My Documents edit.
     */
    func testIndependentEditsRejectStaleWritebackWithoutOverwritingNewContent() async throws {
        let fixture = try makeFixture()
        let targets: [AITextTarget] = [
            .bibleBookmarkNote(fixture.bibleBookmarkID),
            .genericBookmarkNote(fixture.genericBookmarkID),
            .studyPadText(fixture.studyPadEntryID),
            .myDocumentPage(fixture.pageID),
        ]
        var captured: [AITextTarget: AITextTargetValue] = [:]
        for target in targets {
            captured[target] = try await fixture.backing.read(target)
        }

        fixture.bookmarkService.saveBibleBookmarkNote(
            bookmarkId: fixture.bibleBookmarkID,
            note: "Bible external"
        )
        fixture.bookmarkService.saveBibleBookmarkNote(
            bookmarkId: fixture.genericBookmarkID,
            note: "Generic external"
        )
        fixture.bookmarkService.updateStudyPadTextEntryText(
            id: fixture.studyPadEntryID,
            text: "StudyPad external"
        )
        XCTAssertTrue(fixture.myDocumentStore.savePageContent(
            bookInitials: "MYDOC",
            pageId: fixture.pageID,
            content: "Page external",
            title: nil
        ))

        for target in targets {
            let expected = try XCTUnwrap(captured[target])
            let result = try await fixture.backing.compareAndWrite(
                AITextTargetValue(content: "AI replacement", contentType: expected.contentType),
                to: target,
                replacing: expected
            )
            XCTAssertEqual(result, .staleContent)
        }

        let finalValues = try await readValues(targets, from: fixture.backing)
        XCTAssertEqual(finalValues.map(\.content), [
            "Bible external",
            "Generic external",
            "StudyPad external",
            "Page external",
        ])
    }

    /**
     Verifies the captured digest also detects a change made outside `AITextTargetStore`.

     Failure means actor serialization alone could be mistaken for database atomicity even though
     editor and sync services can mutate the same row independently.
     */
    func testCapturedDigestRejectsExternalMutationBeforeConditionalWrite() async throws {
        let fixture = try makeFixture()
        let store = AITextTargetStore(backing: fixture.backing)
        let target = AITextTarget.genericBookmarkNote(fixture.genericBookmarkID)
        let snapshot = try await store.capture(target)
        fixture.bookmarkService.saveBibleBookmarkNote(
            bookmarkId: fixture.genericBookmarkID,
            note: "External edit"
        )

        do {
            _ = try await store.write(
                content: "AI edit",
                to: target,
                capturedInputDigest: snapshot.capturedInputDigest
            )
            XCTFail("Expected stale-content rejection")
        } catch let error as AITextTargetStoreError {
            XCTAssertEqual(error, .staleContent)
        }
        XCTAssertEqual(
            fixture.bookmarkService.genericBookmark(id: fixture.genericBookmarkID)?.notes?.notes,
            "External edit"
        )
    }

    /**
     Verifies missing identities and representation changes cannot produce a successful write.

     Failure would allow a deleted row to be recreated under the wrong owner or permit an AI
     transformation to silently change Markdown, HTML, or OSIS storage semantics.
     */
    func testMissingTargetsAndContentTypeChangesAreRejected() async throws {
        let fixture = try makeFixture()
        let missing = AITextTarget.genericBookmarkNote(UUID())
        let missingValue = try await fixture.backing.read(missing)
        XCTAssertNil(missingValue)
        let missingResult = try await fixture.backing.compareAndWrite(
            AITextTargetValue(content: "Replacement", contentType: .html),
            to: missing,
            replacing: AITextTargetValue(content: "Original", contentType: .html)
        )
        XCTAssertEqual(missingResult, .targetNotFound)

        let genericTarget = AITextTarget.genericBookmarkNote(fixture.genericBookmarkID)
        let expectedValue = try await fixture.backing.read(genericTarget)
        let expected = try XCTUnwrap(expectedValue)
        let typeChange = try await fixture.backing.compareAndWrite(
            AITextTargetValue(content: "Replacement", contentType: .markdown),
            to: genericTarget,
            replacing: expected
        )
        XCTAssertEqual(typeChange, .staleContent)
        XCTAssertEqual(
            fixture.bookmarkService.genericBookmark(id: fixture.genericBookmarkID)?.notes?.notes,
            "Generic original"
        )
    }

    /** Reads target values sequentially to keep assertions outside async autoclosures. */
    private func readValues(
        _ targets: [AITextTarget],
        from backing: BibleUIAITextTargetBacking
    ) async throws -> [AITextTargetValue] {
        var values: [AITextTargetValue] = []
        for target in targets {
            let value = try await backing.read(target)
            values.append(try XCTUnwrap(value))
        }
        return values
    }

    /** Creates deterministic in-memory rows in each owning production persistence service. */
    private func makeFixture() throws -> TextTargetFixture {
        let bookmarkContainer = try makeBookmarkListModelContainer()
        let bookmarkContext = ModelContext(bookmarkContainer)
        let bookmarkService = BookmarkService(
            store: BookmarkStore(modelContext: bookmarkContext)
        )
        let range = try XCTUnwrap(VerifiedKJVAOrdinalRange(
            resolvingSourceBookInitials: "KJV",
            sourceVersification: "KJV",
            sourceOrdinalStart: 4,
            sourceOrdinalEnd: 4
        ))
        let bibleBookmark = bookmarkService.addBibleBookmark(
            ordinalRange: range,
            wholeVerse: true
        )
        bookmarkService.saveBibleBookmarkNote(
            bookmarkId: bibleBookmark.id,
            note: "Bible original",
            defaultContentType: "MARKDOWN"
        )
        let genericBookmark = bookmarkService.addGenericBookmark(
            bookInitials: "DICT",
            key: "entry-key",
            startOrdinal: 1,
            endOrdinal: 1
        )
        bookmarkService.saveBibleBookmarkNote(
            bookmarkId: genericBookmark.id,
            note: "Generic original",
            defaultContentType: "HTML"
        )
        let label = bookmarkService.createLabel(name: "Study", color: Label.defaultColor)
        let studyPadEntry = try XCTUnwrap(bookmarkService.createStudyPadEntry(
            labelId: label.id,
            afterOrderNumber: -1,
            contentType: "MARKDOWN"
        )).0
        bookmarkService.updateStudyPadTextEntryText(
            id: studyPadEntry.id,
            text: "StudyPad original"
        )

        let myDocumentContainer = try makeMyDocumentModelContainer()
        let myDocumentContext = ModelContext(myDocumentContainer)
        let myDocumentStore = MyDocumentStore(modelContext: myDocumentContext)
        let pageID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        let document = MyDocument(name: "My Document", initials: "MYDOC")
        let page = MyDocumentPage(
            id: pageID,
            title: "Page",
            pageKey: "page-1",
            contentType: .osis
        )
        let pageContent = MyDocumentPageContent(pageId: pageID, content: "Page original")
        page.document = document
        page.pageContent = pageContent
        pageContent.page = page
        document.pages = [page]
        myDocumentContext.insert(document)
        myDocumentContext.insert(page)
        myDocumentContext.insert(pageContent)
        try myDocumentContext.save()

        let backing = BibleUIAITextTargetBacking(
            bookmarkService: bookmarkService,
            myDocumentStore: myDocumentStore
        )
        return TextTargetFixture(
            bookmarkService: bookmarkService,
            myDocumentStore: myDocumentStore,
            backing: backing,
            bibleBookmarkID: bibleBookmark.id,
            genericBookmarkID: genericBookmark.id,
            studyPadEntryID: studyPadEntry.id,
            pageID: pageID
        )
    }
}

/** Retains every owning store and stable entity identity used by one text-target test. */
@MainActor
private struct TextTargetFixture {
    let bookmarkService: BookmarkService
    let myDocumentStore: MyDocumentStore
    let backing: BibleUIAITextTargetBacking
    let bibleBookmarkID: UUID
    let genericBookmarkID: UUID
    let studyPadEntryID: UUID
    let pageID: UUID
}
