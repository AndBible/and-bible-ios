// BibleReaderPreparedMyDocumentTests.swift -- My Documents immutable preparation contracts

import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView

@MainActor
final class BibleReaderPreparedMyDocumentTests: XCTestCase {
    /** The immutable worker encoder preserves the established generated-book document schema. */
    func testEncodedDocumentPreservesExistingCoordinatorPayloadContract() throws {
        let documentID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let pageID = try XCTUnwrap(UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa"))
        let promptID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let marker = makeMarker(promptID: promptID)
        let metadata = MyDocumentReaderMetadata(
            sourcePromptId: promptID,
            sourcePromptName: "Explain passage",
            sourceModelName: "model-1",
            aiDocMarkers: [marker]
        )
        let prepared = BibleReaderPreparedMyDocument(
            documentID: documentID,
            documentName: "AI Documents",
            documentInitials: "AIDocuments",
            pageID: pageID,
            pageTitle: "Answer",
            pageKey: "answer",
            contentType: .markdown,
            rawContent: "**Answer**",
            pageSourcePromptID: promptID,
            metadata: metadata,
            sourceDependencies: [.independent],
            genericBookmarkInputs: [],
            genericBookmarks: [],
            generatedBookLanguageCode: "en"
        )
        let actualJSON = try XCTUnwrap(prepared.encodedJSON())
        let actual = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(actualJSON.utf8)) as? [String: Any]
        )

        // Android sanitizes every non-letter/digit in `"initials-key"` to an underscore.
        XCTAssertEqual(actual["id"] as? String, "AIDocuments_answer")
        XCTAssertEqual(actual["type"] as? String, "osis")
        XCTAssertEqual(actual["bookInitials"] as? String, "AIDocuments")
        XCTAssertEqual(actual["bookName"] as? String, "AI Documents")
        XCTAssertEqual(actual["key"] as? String, "answer")
        XCTAssertEqual(actual["myDocumentPageId"] as? String, pageID.uuidString)
        XCTAssertEqual(actual["sourcePromptId"] as? String, promptID.uuidString)
        XCTAssertEqual(actual["sourcePromptName"] as? String, "Explain passage")
        XCTAssertEqual(actual["sourceModelName"] as? String, "model-1")
        XCTAssertEqual((actual["genericBookmarks"] as? [Any])?.count, 0)
        let fragment = try XCTUnwrap(actual["osisFragment"] as? [String: Any])
        XCTAssertEqual(fragment["key"] as? String, "AIDocuments--answer")
        XCTAssertEqual(fragment["language"] as? String, "en")
        XCTAssertTrue(try XCTUnwrap(fragment["xml"] as? String).contains("Answer"))
        let markers = try XCTUnwrap(actual["aiDocMarkers"] as? [[String: Any]])
        // ClientAiDocMarker exposes the visible page title under its bridge key `title`.
        XCTAssertEqual(markers.first?["title"] as? String, "Related answer")
    }

    /** Raw content and AI marker mutations invalidate results without relying on updatedAt. */
    func testOwnerIdentityRejectsDirectPageAndMarkerMutation() throws {
        let documentID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let pageID = try XCTUnwrap(UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa"))
        let promptID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let baselineMetadata = MyDocumentReaderMetadata(
            sourcePromptId: promptID,
            sourcePromptName: "Prompt",
            sourceModelName: "model",
            aiDocMarkers: [makeMarker(promptID: promptID, title: "Before")]
        )
        let changedMetadata = MyDocumentReaderMetadata(
            sourcePromptId: promptID,
            sourcePromptName: "Prompt",
            sourceModelName: "model",
            aiDocMarkers: [makeMarker(promptID: promptID, title: "After")]
        )
        let baseline = makePrepared(
            documentID: documentID,
            pageID: pageID,
            rawContent: "Before",
            metadata: baselineMetadata
        )
        let changedContent = makePrepared(
            documentID: documentID,
            pageID: pageID,
            rawContent: "After",
            metadata: baselineMetadata
        )
        let changedMarker = makePrepared(
            documentID: documentID,
            pageID: pageID,
            rawContent: "Before",
            metadata: changedMetadata
        )

        XCTAssertNotEqual(baseline.ownerIdentity, changedContent.ownerIdentity)
        XCTAssertNotEqual(baseline.ownerIdentity, changedMarker.ownerIdentity)
    }

    /** Page keys, raw content, and marker text retain exact UTF-16 publication identity. */
    func testOwnerIdentityPreservesExactUTF16PageAndMarkerValues() throws {
        let documentID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let pageID = try XCTUnwrap(UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa"))
        let promptID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "The fixture must exercise Swift's canonical equality.")
        let composedMetadata = MyDocumentReaderMetadata(
            sourcePromptId: promptID,
            sourcePromptName: "Prompt",
            sourceModelName: "model",
            aiDocMarkers: [makeMarker(promptID: promptID, title: composed)]
        )
        let decomposedMetadata = MyDocumentReaderMetadata(
            sourcePromptId: promptID,
            sourcePromptName: "Prompt",
            sourceModelName: "model",
            aiDocMarkers: [makeMarker(promptID: promptID, title: decomposed)]
        )
        let baseline = makePrepared(
            documentID: documentID,
            pageID: pageID,
            pageKey: composed,
            rawContent: composed,
            metadata: composedMetadata
        )
        let changedKey = makePrepared(
            documentID: documentID,
            pageID: pageID,
            pageKey: decomposed,
            rawContent: composed,
            metadata: composedMetadata
        )
        let changedContent = makePrepared(
            documentID: documentID,
            pageID: pageID,
            pageKey: composed,
            rawContent: decomposed,
            metadata: composedMetadata
        )
        let changedMarker = makePrepared(
            documentID: documentID,
            pageID: pageID,
            pageKey: composed,
            rawContent: composed,
            metadata: decomposedMetadata
        )

        XCTAssertNotEqual(baseline.ownerIdentity, changedKey.ownerIdentity)
        XCTAssertNotEqual(baseline.ownerIdentity, changedContent.ownerIdentity)
        XCTAssertNotEqual(baseline.ownerIdentity, changedMarker.ownerIdentity)
    }

    /** Builds a copied My Documents request without any persistence object. */
    private func makePrepared(
        documentID: UUID,
        pageID: UUID,
        pageKey: String = "answer",
        rawContent: String,
        metadata: MyDocumentReaderMetadata
    ) -> BibleReaderPreparedMyDocument {
        BibleReaderPreparedMyDocument(
            documentID: documentID,
            documentName: "AI Documents",
            documentInitials: "AIDocuments",
            pageID: pageID,
            pageTitle: "Answer",
            pageKey: pageKey,
            contentType: .markdown,
            rawContent: rawContent,
            pageSourcePromptID: metadata.sourcePromptId,
            metadata: metadata,
            sourceDependencies: [.independent],
            genericBookmarkInputs: [],
            genericBookmarks: [],
            generatedBookLanguageCode: "en"
        )
    }

    /** Creates a source-page marker with a stable owner and independently varying title. */
    private func makeMarker(
        promptID: UUID,
        title: String = "Related answer"
    ) -> MyDocumentAIDocMarker {
        MyDocumentAIDocMarker(
            pageId: UUID(uuidString: "12345678-2222-3333-4444-555555555555")!,
            documentId: UUID(uuidString: "87654321-7777-8888-9999-aaaaaaaaaaaa")!,
            documentInitials: "AIDocuments",
            pageTitle: title,
            pageKey: "related",
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            sourcePromptId: promptID,
            sourceBookInitials: "KJV",
            sourceBookKey: "Gen.1.1"
        )
    }

}
